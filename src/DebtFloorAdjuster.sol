pragma solidity 0.6.7;

import "geb-treasury-reimbursement/IncreasingTreasuryReimbursement.sol";

abstract contract OracleRelayerLike {
    function redemptionPrice() virtual public returns (uint256);
}
abstract contract SAFEEngineLike {
    function modifyParameters(
      bytes32,
      bytes32,
      uint256
    ) virtual external;
}

contract DebtFloorAdjuster is IncreasingTreasuryReimbursement {
    // --- Structs ---
    struct DebtFloor {
        // Last timestamp when this floor has been updated
        uint256 lastUpdateTime;   // [timestamp]
        // Delay between consecutive updates for this floor
        uint256 updateDelay;      // [seconds]
        // The value that this floor should target
        uint256 targetValue;      // [ray]
    }

    // --- Variables ---
    // Last block when a debt floor has been adjusted
    uint256                       public lastUpdateBlock;

    // Mapping with debt floor data
    mapping(bytes32 => DebtFloor) public floors;

    // Oracle relayer contract
    OracleRelayerLike             public oracleRelayer;
    // Safe engine contract
    SAFEEngineLike                public safeEngine;

    uint256                       public constant WAD_COMPLEMENT = 10 ** 9;

    // --- Events ---
    event ModifyParameters(bytes32 parameter, bytes32 collateralType, uint256 value);
    event AddFloorData(bytes32 collateralType, uint256 updateDelay, uint256 targetValue);
    event RemoveFloorData(bytes32 collateralType);
    event RecomputeCollateralDebtFloor(bytes32 collateralType, uint256 newFloor);

    constructor(
      address safeEngine_,
      address oracleRelayer_,
      address treasury_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_
    ) public IncreasingTreasuryReimbursement(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(safeEngine_ != address(0), "DebtFloorAdjuster/null-safe-engine");
        require(oracleRelayer_ != address(0), "DebtFloorAdjuster/null-oracle-relayer");

        safeEngine    = SAFEEngineLike(safeEngine_);

        oracleRelayer = OracleRelayerLike(oracleRelayer_);
        oracleRelayer.redemptionPrice();

        lastUpdateBlock = block.number;
    }

    // --- Administration ---
    /*
    * @notify Modify the treasury address
    * @param parameter The contract address to modify
    * @param addr The new address for the contract
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        if (parameter == "treasury") {
          require(StabilityFeeTreasuryLike(addr).systemCoin() != address(0), "DebtFloorAdjuster/treasury-coin-not-set");
          treasury = StabilityFeeTreasuryLike(addr);
        }
        else revert("DebtFloorAdjuster/modify-unrecognized-param");
        emit ModifyParameters(
          parameter,
          addr
        );
    }
    /*
    * @notify Modify an uint256 param
    * @param parameter The name of the parameter to modify
    * @param val The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") {
          require(val <= maxUpdateCallerReward, "DebtFloorAdjuster/invalid-base-caller-reward");
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val >= baseUpdateCallerReward, "DebtFloorAdjuster/invalid-max-caller-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "DebtFloorAdjuster/invalid-caller-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else revert("DebtFloorAdjuster/modify-unrecognized-param");
        emit ModifyParameters(parameter, val);
    }
    /*
    * @notify Modify a parameter in a DebtFloor struct
    * @param parameter The parameter to change
    * @param collateralType The collateral type whose parameter we change
    * @param val The new value for the param
    */
    function modifyParameters(bytes32 parameter, bytes32 collateralType, uint256 val) external isAuthorized {
        require(val > 0, "DebtFloorAdjuster/null-value");
        DebtFloor storage newFloor = floors[collateralType];

        if (parameter == "updateDelay") {
          newFloor.updateDelay = val;
        }
        else if (parameter == "targetValue") {
          require(val >= WAD_COMPLEMENT, "DebtFloorAdjuster/tiny-target-value");
          newFloor.targetValue = val;
        }
        else revert("DebtFloorAdjuster/modify-unrecognized-param");
        emit ModifyParameters(parameter, collateralType, val);
    }

    // --- Add/Remove Floor Data ---
    /*
    * @notify Add a new DebtFloor
    * @param collateralType The collateral type for which we create a DebtFloor entry
    * @param updateDelay The delay between consecutive floor updates
    * @param targetValue The value this collateral type debt floor should target
    */
    function addFloorData(bytes32 collateralType, uint256 updateDelay, uint256 targetValue) external isAuthorized {
        DebtFloor storage newFloor = floors[collateralType];
        require(floors[collateralType].lastUpdateTime == 0, "DebtFloorAdjuster/floor-data-already-specified");

        // Check that values are not null
        require(updateDelay > 0, "DebtFloorAdjuster/null-update-delay");
        require(targetValue >= WAD_COMPLEMENT, "DebtFloorAdjuster/tiny-target-value");

        // Update floor data
        newFloor.lastUpdateTime = now;
        newFloor.updateDelay    = updateDelay;
        newFloor.targetValue    = targetValue;

        emit AddFloorData(collateralType, updateDelay, targetValue);
    }
    /*
    * @notify Remove an existing DebtFloor entry
    * @param collateralType The collateral type whose debt floor data we delete
    */
    function removeFloorData(bytes32 collateralType) external isAuthorized {
        require(floors[collateralType].lastUpdateTime > 0, "DebtFloorAdjuster/inexistent-floor-data");
        delete(floors[collateralType]);
        emit RemoveFloorData(collateralType);
    }

    // --- Core Logic ---
    /*
    * @notify Recompute and set a new debt floor for a specific collateral type
    * @param collateralType The collateral type for which to compute and set the new debt floor
    * @param feeReceiver The address that will receive the reward for calling this function
    */
    function recomputeCollateralDebtFloor(bytes32 collateralType, address feeReceiver) external {
        // Check that we don't update twice in the same block
        require(block.number > lastUpdateBlock, "DebtFloorAdjuster/cannot-update-twice-same-block");
        lastUpdateBlock = block.number;

        // Check if we waited enough
        DebtFloor storage debtFloor = floors[collateralType];
        require(subtract(now, debtFloor.lastUpdateTime) >= debtFloor.updateDelay, "DebtFloorAdjuster/wait-more");

        // Get the caller's reward
        uint256 callerReward = getCallerReward(debtFloor.lastUpdateTime, debtFloor.updateDelay);
        // Update lastUpdateTime
        debtFloor.lastUpdateTime = now;

        // Calculate the new floor according to the latest redemption price
        uint256 newFloor = multiply(wdivide(debtFloor.targetValue, oracleRelayer.redemptionPrice()), RAY);

        // Set the new floor
        safeEngine.modifyParameters(collateralType, "debtFloor", newFloor);

        // Emit an event
        emit RecomputeCollateralDebtFloor(collateralType, newFloor);

        // Send the reward
        rewardCaller(feeReceiver, callerReward);
    }
}
