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
        uint256 lastUpdateTime;   // [timestamp]
        uint256 updateDelay;      // [seconds]
        uint256 targetValue;      // [ray]
    }

    // --- Variables ---
    uint256                       public lastUpdateBlock;

    mapping(bytes32 => DebtFloor) public floors;

    OracleRelayerLike             public oracleRelayer;
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

        emit ModifyParameters("oracleRelayer", oracleRelayer_);
    }

    // --- Administration ---
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
    }

    // --- Add/Remove Floor Data ---
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
    function removeFloorData(bytes32 collateralType) external isAuthorized {
        require(floors[collateralType].lastUpdateTime > 0, "DebtFloorAdjuster/inexistent-floor-data");
        delete(floors[collateralType]);
        emit RemoveFloorData(collateralType);
    }

    // --- Core Logic ---
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
