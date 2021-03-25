pragma solidity 0.6.7;

import "./IncreasingTreasuryReimbursementMock.sol";

abstract contract SAFEEngineLike {
    function collateralTypes(bytes32) virtual public view returns (
        uint256 debtAmount,        // [wad]
        uint256 accumulatedRate,   // [ray]
        uint256 safetyPrice,       // [ray]
        uint256 debtCeiling,       // [rad]
        uint256 debtFloor          // [rad]
    );
    function globalDebtCeiling() virtual public view returns (uint256);
    function modifyParameters(
        bytes32 parameter,
        uint256 data
    ) virtual external;
    function modifyParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint256 data
    ) virtual external;
}
abstract contract OracleRelayerLike {
    function redemptionRate() virtual public view returns (uint256);
}

contract SingleSpotDebtCeilingSetterMock is IncreasingTreasuryReimbursementMock {
    // --- Auth ---
    // Mapping of addresses that are allowed to manually recompute the debt ceiling (without being rewarded for it)
    mapping (address => uint256) public manualSetters;
    /*
    * @notify Add a new manual setter
    * @param account The address of the new manual setter
    */
    function addManualSetter(address account) external isAuthorized {
        manualSetters[account] = 1;
        emit AddManualSetter(account);
    }
    /*
    * @notify Remove a manual setter
    * @param account The address of the manual setter to remove
    */
    function removeManualSetter(address account) external isAuthorized {
        manualSetters[account] = 0;
        emit RemoveManualSetter(account);
    }
    /*
    * @notice Modifier for checking that the msg.sender is a whitelisted manual setter
    */
    modifier isManualSetter {
        require(manualSetters[msg.sender] == 1, "SingleSpotDebtCeilingSetter/not-manual-setter");
        _;
    }

    // --- Variables ---
    // The max amount of system coins that can be generated using this collateral type
    uint256 public maxCollateralCeiling;            // [rad]
    // The min amount of system coins that must be generated using this collateral type
    uint256 public minCollateralCeiling;            // [rad]
    // Percentage change applied to the collateral's debt ceiling
    uint256 public ceilingPercentageChange;         // [hundred]
    // When the debt ceiling was last updated
    uint256 public lastUpdateTime;                  // [timestamp]
    // Enforced gap between calls
    uint256 public updateDelay;                     // [seconds]
    // Last timestamp of a manual update
    uint256 public lastManualUpdateTime;            // [seconds]
    // Flag that blocks an increase in the debt ceiling when the redemption rate is positive
    uint256 public blockIncreaseWhenRevalue;
    // Flag that blocks a decrease in the debt ceiling when the redemption rate is negative
    uint256 public blockDecreaseWhenDevalue;
    // The collateral's name
    bytes32 public collateralName;

    // The SAFEEngine contract
    SAFEEngineLike    public safeEngine;
    // The OracleRelayer contract
    OracleRelayerLike public oracleRelayer;

    // --- Events ---
    event AddManualSetter(address account);
    event RemoveManualSetter(address account);
    event UpdateCeiling(uint256 nextCeiling);

    constructor(
      address safeEngine_,
      address oracleRelayer_,
      address treasury_,
      bytes32 collateralName_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_,
      uint256 updateDelay_,
      uint256 ceilingPercentageChange_,
      uint256 maxCollateralCeiling_,
      uint256 minCollateralCeiling_
    ) public IncreasingTreasuryReimbursementMock(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(safeEngine_ != address(0), "SingleSpotDebtCeilingSetter/invalid-safe-engine");
        require(oracleRelayer_ != address(0), "SingleSpotDebtCeilingSetter/invalid-oracle-relayer");
        require(updateDelay_ > 0, "SingleSpotDebtCeilingSetter/invalid-update-delay");
        require(both(ceilingPercentageChange_ > HUNDRED, ceilingPercentageChange_ <= THOUSAND), "SingleSpotDebtCeilingSetter/invalid-percentage-change");
        require(minCollateralCeiling_ > 0, "SingleSpotDebtCeilingSetter/invalid-min-ceiling");
        require(both(maxCollateralCeiling_ > 0, maxCollateralCeiling_ > minCollateralCeiling_), "SingleSpotDebtCeilingSetter/invalid-max-ceiling");

        manualSetters[msg.sender] = 1;

        safeEngine                = SAFEEngineLike(safeEngine_);
        oracleRelayer             = OracleRelayerLike(oracleRelayer_);
        collateralName            = collateralName_;
        updateDelay               = updateDelay_;
        ceilingPercentageChange   = ceilingPercentageChange_;
        maxCollateralCeiling      = maxCollateralCeiling_;
        minCollateralCeiling      = minCollateralCeiling_;
        lastManualUpdateTime      = now;

        // Check that the oracleRelayer has the redemption rate in it
        oracleRelayer.redemptionRate();

	      emit AddManualSetter(msg.sender);
        emit ModifyParameters("updateDelay", updateDelay);
        emit ModifyParameters("ceilingPercentageChange", ceilingPercentageChange);
        emit ModifyParameters("maxCollateralCeiling", maxCollateralCeiling);
        emit ModifyParameters("minCollateralCeiling", minCollateralCeiling);
    }

    // --- Math ---
    uint256 constant HUNDRED  = 100;
    uint256 constant THOUSAND = 1000;

    function maximum(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = (x <= y) ? y : x;
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Management ---
    /*
    * @notify Modify the treasury or the oracle relayer address
    * @param parameter The contract address to modify
    * @param addr The new address for the contract
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        if (parameter == "treasury") {
          require(StabilityFeeTreasuryLike(addr).systemCoin() != address(0), "SingleSpotDebtCeilingSetter/treasury-coin-not-set");
          treasury = StabilityFeeTreasuryLike(addr);
        }
        else if (parameter == "oracleRelayer") {
          require(addr != address(0), "SingleSpotDebtCeilingSetter/null-addr");
          oracleRelayer = OracleRelayerLike(addr);
          // Check that it has the redemption rate
          oracleRelayer.redemptionRate();
        }
        else revert("SingleSpotDebtCeilingSetter/modify-unrecognized-param");
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
          require(val <= maxUpdateCallerReward, "SingleSpotDebtCeilingSetter/invalid-base-caller-reward");
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val >= baseUpdateCallerReward, "SingleSpotDebtCeilingSetter/invalid-max-caller-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "SingleSpotDebtCeilingSetter/invalid-caller-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(val > 0, "SingleSpotDebtCeilingSetter/invalid-max-increase-delay");
          maxRewardIncreaseDelay = val;
        }
        else if (parameter == "updateDelay") {
          require(val >= 0, "SingleSpotDebtCeilingSetter/invalid-call-gap-length");
          updateDelay = val;
        }
        else if (parameter == "maxCollateralCeiling") {
          require(both(val > 0, val > minCollateralCeiling), "SingleSpotDebtCeilingSetter/invalid-max-ceiling");
          maxCollateralCeiling = val;
        }
        else if (parameter == "minCollateralCeiling") {
          require(both(val > 0, val < maxCollateralCeiling), "SingleSpotDebtCeilingSetter/invalid-min-ceiling");
          minCollateralCeiling = val;
        }
        else if (parameter == "ceilingPercentageChange") {
          require(both(val > HUNDRED, val <= THOUSAND), "SingleSpotDebtCeilingSetter/invalid-percentage-change");
          ceilingPercentageChange = val;
        }
        else if (parameter == "lastUpdateTime") {
          require(val > now, "SingleSpotDebtCeilingSetter/invalid-update-time");
          lastUpdateTime = val;
        }
        else if (parameter == "blockIncreaseWhenRevalue") {
          require(either(val == 1, val == 0), "SingleSpotDebtCeilingSetter/invalid-block-increase-value");
          blockIncreaseWhenRevalue = val;
        }
        else if (parameter == "blockDecreaseWhenDevalue") {
          require(either(val == 1, val == 0), "SingleSpotDebtCeilingSetter/invalid-block-decrease-value");
          blockDecreaseWhenDevalue = val;
        }
        else revert("SingleSpotDebtCeilingSetter/modify-unrecognized-param");
        emit ModifyParameters(
          parameter,
          val
        );
    }

    // --- Utils ---
    /*
    * @notify Internal function meant to modify the collateral's debt ceiling as well as the global debt ceiling (if needed)
    * @param nextDebtCeiling The new ceiling to set
    */
    function setCeiling(uint256 nextDebtCeiling) internal {
        (uint256 debtAmount, uint256 accumulatedRate, uint256 safetyPrice, uint256 currentDebtCeiling,) = safeEngine.collateralTypes(collateralName);

        if (safeEngine.globalDebtCeiling() < nextDebtCeiling) {
            safeEngine.modifyParameters("globalDebtCeiling", nextDebtCeiling);
        }

        if (currentDebtCeiling != nextDebtCeiling) {
            safeEngine.modifyParameters(collateralName, "debtCeiling", nextDebtCeiling);
            emit UpdateCeiling(nextDebtCeiling);
        }
    }

    // --- Auto Updates ---
    /*
    * @notify Periodically updates the debt ceiling. Can be called by anyone
    * @param feeReceiver The address that will receive the reward for updating the ceiling
    */
    function autoUpdateCeiling(address feeReceiver) external {
        // Check that the update time is not in the future
        require(lastUpdateTime < now, "SingleSpotDebtCeilingSetter/update-time-in-the-future");
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateDelay, lastUpdateTime == 0), "SingleSpotDebtCeilingSetter/wait-more");

        // Get the caller's reward
        uint256 callerReward = getCallerReward(lastUpdateTime, updateDelay);
        // Update lastUpdateTime
        lastUpdateTime = now;

        // Get the next ceiling and set it
        uint256 nextCollateralCeiling = getNextCollateralCeiling();
        setCeiling(nextCollateralCeiling);

        // Pay the caller for updating the ceiling
        rewardCaller(feeReceiver, callerReward);
    }

    // --- Manual Updates ---
    /*
    * @notify Authed function that allows manualSetters to update the debt ceiling whenever they want
    */
    function manualUpdateCeiling() external isManualSetter {
        require(now > lastManualUpdateTime, "SingleSpotDebtCeilingSetter/cannot-update-twice-same-block");
        uint256 nextCollateralCeiling = getNextCollateralCeiling();
        lastManualUpdateTime = now;
        setCeiling(nextCollateralCeiling);
    }

    // --- Getters ---
    /*
    * @notify View function meant to return the new and upcoming debt ceiling. It also applies checks regarding re or devaluation blocks
    */
    function getNextCollateralCeiling() public view returns (uint256) {
        (uint256 debtAmount, uint256 accumulatedRate, uint256 safetyPrice, uint256 currentDebtCeiling, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        uint256 adjustedCurrentDebt   = multiply(debtAmount, accumulatedRate);
        uint256 lowestPossibleCeiling = maximum(debtFloor, minCollateralCeiling);

        if (debtAmount == 0) return lowestPossibleCeiling;

        uint256 updatedCeiling = multiply(adjustedCurrentDebt, ceilingPercentageChange) / HUNDRED;
        if (updatedCeiling <= lowestPossibleCeiling) return lowestPossibleCeiling;
        else if (updatedCeiling >= maxCollateralCeiling) return maxCollateralCeiling;

        uint256 redemptionRate = oracleRelayer.redemptionRate();

        if (either(
          allowsIncrease(redemptionRate, currentDebtCeiling, updatedCeiling),
          allowsDecrease(redemptionRate, currentDebtCeiling, updatedCeiling))
        ) return updatedCeiling;

        return currentDebtCeiling;
    }
    /*
    * @notify View function meant to return the new and upcoming debt ceiling. It does not perform checks for boundaries
    */
    function getRawUpdatedCeiling() external view returns (uint256) {
        (uint256 debtAmount, uint256 accumulatedRate, uint256 safetyPrice, uint256 currentDebtCeiling, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        uint256 adjustedCurrentDebt = multiply(debtAmount, accumulatedRate);
        return multiply(adjustedCurrentDebt, ceilingPercentageChange) / HUNDRED;
    }
    /*
    * @notify View function meant to return whether an increase in the debt ceiling is currently allowed
    * @param redemptionRate A custom redemption rate
    * @param currentDebtCeiling The current debt ceiling for the collateral type with collateralName
    * @param updatedCeiling The new ceiling computed for the collateral type with collateralName
    */
    function allowsIncrease(uint256 redemptionRate, uint256 currentDebtCeiling, uint256 updatedCeiling) public view returns (bool allowIncrease) {
        allowIncrease = either(redemptionRate <= RAY, both(redemptionRate > RAY, blockIncreaseWhenRevalue == 0));
        allowIncrease = both(currentDebtCeiling <= updatedCeiling, allowIncrease);
    }
    /*
    * @notify View function meant to return whether a decrease in the debt ceiling is currently allowed
    * @param redemptionRate A custom redemption rate
    * @param currentDebtCeiling The current debt ceiling for the collateral type with collateralName
    * @param updatedCeiling The new ceiling computed for the collateral type with collateralName
    */
    function allowsDecrease(uint256 redemptionRate, uint256 currentDebtCeiling, uint256 updatedCeiling) public view returns (bool allowDecrease) {
        allowDecrease = either(redemptionRate >= RAY, both(redemptionRate < RAY, blockDecreaseWhenDevalue == 0));
        allowDecrease = both(currentDebtCeiling >= updatedCeiling, allowDecrease);
    }
}
