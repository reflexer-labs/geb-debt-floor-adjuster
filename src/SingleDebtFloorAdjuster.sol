pragma solidity 0.6.7;

import "geb-treasury-reimbursement/reimbursement/IncreasingTreasuryReimbursement.sol";

abstract contract SAFEEngineLike {
    function modifyParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint256 data
    ) virtual external;
    function collateralTypes(bytes32) virtual public view returns (
        uint256 debtAmount,        // [wad]
        uint256 accumulatedRate,   // [ray]
        uint256 safetyPrice,       // [ray]
        uint256 debtCeiling        // [rad]
    );
}
abstract contract OracleRelayerLike {
    function redemptionPrice() virtual public returns (uint256);
}
abstract contract OracleLike {
    function read() virtual external view returns (uint256);
}

contract SingleDebtFloorAdjuster is IncreasingTreasuryReimbursement {
    // --- Auth ---
    // Mapping of addresses that are allowed to manually recompute the debt floor (without being rewarded for it)
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
        require(manualSetters[msg.sender] == 1, "SingleDebtFloorAdjuster/not-manual-setter");
        _;
    }

    // --- Variables ---
    // The collateral's name
    bytes32 public collateralName;
    // Gas amount needed to liquidate a Safe backed by the collateral type with the collateralName
    uint256 public gasAmountForLiquidation;
    // The max value for the debt floor
    uint256 public maxDebtFloor;                         // [rad]
    // The min amount of system coins that must be generated using this collateral type
    uint256 public minDebtFloor;                         // [rad]
    // Max expected 1h deviation, to ensure bids are profitable in a scenario price of collateral is severely devaluing
    uint256 public max1hPriceDeviation = 0.2e18;         // [wad], default 20%
    // Liquidation Ratio of Collateral
    uint256 public collateralLiquidationRatio = 1.35e27; // [rad], default 135%
    // When the debt floor was last updated
    uint256 public lastUpdateTime;                       // [timestamp]
    // Enforced gap between calls
    uint256 public updateDelay;                          // [seconds]
    // Last timestamp of a manual update
    uint256 public lastManualUpdateTime;                 // [seconds]

    // The SAFEEngine contract
    SAFEEngineLike    public safeEngine;
    // The OracleRelayer contract
    OracleRelayerLike public oracleRelayer;
    // The gas price oracle
    OracleLike        public gasPriceOracle;
    // The ETH price oracle
    OracleLike        public ethPriceOracle;

    // --- Events ---
    event AddManualSetter(address account);
    event RemoveManualSetter(address account);
    event UpdateFloor(uint256 nextDebtFloor);

    constructor(
      address safeEngine_,
      address oracleRelayer_,
      address treasury_,
      address gasPriceOracle_,
      address ethPriceOracle_,
      bytes32 collateralName_,
      uint256 baseUpdateCallerReward_,
      uint256 maxUpdateCallerReward_,
      uint256 perSecondCallerRewardIncrease_,
      uint256 updateDelay_,
      uint256 gasAmountForLiquidation_,
      uint256 maxDebtFloor_,
      uint256 minDebtFloor_
    ) public IncreasingTreasuryReimbursement(treasury_, baseUpdateCallerReward_, maxUpdateCallerReward_, perSecondCallerRewardIncrease_) {
        require(safeEngine_ != address(0), "SingleDebtFloorAdjuster/invalid-safe-engine");
        require(oracleRelayer_ != address(0), "SingleDebtFloorAdjuster/invalid-oracle-relayer");
        require(gasPriceOracle_ != address(0), "SingleDebtFloorAdjuster/invalid-gas-price-oracle");
        require(ethPriceOracle_ != address(0), "SingleDebtFloorAdjuster/invalid-eth-price-oracle");
        require(updateDelay_ > 0, "SingleDebtFloorAdjuster/invalid-update-delay");
        require(both(gasAmountForLiquidation_ > 0, gasAmountForLiquidation_ < block.gaslimit), "SingleDebtFloorAdjuster/invalid-liq-gas-amount");
        require(minDebtFloor_ > 0, "SingleDebtFloorAdjuster/invalid-min-floor");
        require(both(maxDebtFloor_ > 0, maxDebtFloor_ > minDebtFloor_), "SingleDebtFloorAdjuster/invalid-max-floor");

        manualSetters[msg.sender] = 1;

        safeEngine              = SAFEEngineLike(safeEngine_);
        oracleRelayer           = OracleRelayerLike(oracleRelayer_);
        gasPriceOracle          = OracleLike(gasPriceOracle_);
        ethPriceOracle          = OracleLike(ethPriceOracle_);
        collateralName          = collateralName_;
        gasAmountForLiquidation = gasAmountForLiquidation_;
        updateDelay             = updateDelay_;
        maxDebtFloor            = maxDebtFloor_;
        minDebtFloor            = minDebtFloor_;
        lastManualUpdateTime    = now;

        oracleRelayer.redemptionPrice();

        emit AddManualSetter(msg.sender);
        emit ModifyParameters("oracleRelayer", oracleRelayer_);
        emit ModifyParameters("gasPriceOracle", gasPriceOracle_);
        emit ModifyParameters("ethPriceOracle", ethPriceOracle_);
        emit ModifyParameters("gasAmountForLiquidation", gasAmountForLiquidation);
        emit ModifyParameters("updateDelay", updateDelay);
        emit ModifyParameters("maxDebtFloor", maxDebtFloor);
        emit ModifyParameters("minDebtFloor", minDebtFloor);
    }

    // --- Boolean Logic ---
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- Math ---
    uint256 internal constant RAD = 10**45;
    function divide(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require(y > 0, "SingleDebtFloorAdjuster/div-y-null");
        z = x / y;
        require(z <= x, "SingleDebtFloorAdjuster/div-invalid");
    }

    // --- Administration ---
    /*
    * @notify Update the address of a contract that this adjuster is connected to
    * @param parameter The name of the contract to update the address for
    * @param addr The new contract address
    */
    function modifyParameters(bytes32 parameter, address addr) external isAuthorized {
        require(addr != address(0), "SingleDebtFloorAdjuster/null-address");
        if (parameter == "treasury") {
            treasury = StabilityFeeTreasuryLike(addr);
        }
        else if (parameter == "oracleRelayer") {
            oracleRelayer = OracleRelayerLike(addr);
            oracleRelayer.redemptionPrice();
        }
        else if (parameter == "gasPriceOracle") {
            gasPriceOracle = OracleLike(addr);
            gasPriceOracle.read();
        }
        else if (parameter == "ethPriceOracle") {
            ethPriceOracle = OracleLike(addr);
            ethPriceOracle.read();
        }
        else revert("SingleDebtFloorAdjuster/modify-unrecognized-params");
        emit ModifyParameters(parameter, addr);
    }
    /*
    * @notify Modify an uint256 param
    * @param parameter The name of the parameter to modify
    * @param val The new parameter value
    */
    function modifyParameters(bytes32 parameter, uint256 val) external isAuthorized {
        if (parameter == "baseUpdateCallerReward") {
          require(val <= maxUpdateCallerReward, "SingleDebtFloorAdjuster/invalid-base-caller-reward");
          baseUpdateCallerReward = val;
        }
        else if (parameter == "maxUpdateCallerReward") {
          require(val >= baseUpdateCallerReward, "SingleDebtFloorAdjuster/invalid-max-caller-reward");
          maxUpdateCallerReward = val;
        }
        else if (parameter == "perSecondCallerRewardIncrease") {
          require(val >= RAY, "SingleDebtFloorAdjuster/invalid-caller-reward-increase");
          perSecondCallerRewardIncrease = val;
        }
        else if (parameter == "maxRewardIncreaseDelay") {
          require(val > 0, "SingleDebtFloorAdjuster/invalid-max-increase-delay");
          maxRewardIncreaseDelay = val;
        }
        else if (parameter == "updateDelay") {
          require(val >= 0, "SingleDebtFloorAdjuster/invalid-call-gap-length");
          updateDelay = val;
        }
        else if (parameter == "maxDebtFloor") {
          require(both(val > 0, val > minDebtFloor), "SingleDebtFloorAdjuster/invalid-max-floor");
          maxDebtFloor = val;
        }
        else if (parameter == "minDebtFloor") {
          require(both(val > 0, val < maxDebtFloor), "SingleDebtFloorAdjuster/invalid-min-floor");
          minDebtFloor = val;
        }
        else if (parameter == "lastUpdateTime") {
          require(val > now, "SingleDebtFloorAdjuster/invalid-update-time");
          lastUpdateTime = val;
        }
        else if (parameter == "gasAmountForLiquidation") {
          require(both(val > 0, val < block.gaslimit), "SingleDebtFloorAdjuster/invalid-liq-gas-amount");
          gasAmountForLiquidation = val;
        }
        else if (parameter == "max1hPriceDeviation") {
          require(val <= WAD, "SingleDebtFloorAdjuster/invalid-max-price-deviation");
          max1hPriceDeviation = val;
        }
        else if (parameter == "collateralLiquidationRatio") {
          require(val > RAY, "SingleDebtFloorAdjuster/invalid-collateral-liquidation-ratio");
          collateralLiquidationRatio = val;
        }
        else revert("SingleDebtFloorAdjuster/modify-unrecognized-param");
        emit ModifyParameters(
          parameter,
          val
        );
    }

    // --- Utils ---
    /*
    * @notify Internal function meant to modify the collateral's debt floor
    * @param nextDebtFloor The new floor to set
    */
    function setFloor(uint256 nextDebtFloor) internal {
        require(nextDebtFloor > 0, "SingleDebtFloorAdjuster/null-debt-floor");
        safeEngine.modifyParameters(collateralName, "debtFloor", nextDebtFloor);
        emit UpdateFloor(nextDebtFloor);
    }

    // --- Core Logic ---
    /*
    * @notify Automatically recompute and set a new debt floor for the collateral type with collateralName
    * @param feeReceiver The address that will receive the reward for calling this function
    */
    function recomputeCollateralDebtFloor(address feeReceiver) external {
        // Check that the update time is not in the future
        require(lastUpdateTime < now, "SingleDebtFloorAdjuster/update-time-in-the-future");
        // Check delay between calls
        require(either(subtract(now, lastUpdateTime) >= updateDelay, lastUpdateTime == 0), "SingleDebtFloorAdjuster/wait-more");

        // Get the caller's reward
        uint256 callerReward = getCallerReward(lastUpdateTime, updateDelay);
        // Update lastUpdateTime
        lastUpdateTime = now;

        // Get the next floor and set it
        uint256 nextCollateralFloor = getNextCollateralFloor();
        setFloor(nextCollateralFloor);

        // Pay the caller for updating the floor
        rewardCaller(feeReceiver, callerReward);
    }
    /*
    * @notice Manually recompute and set a new debt floor for the collateral type with collateralName
    */
    function manualRecomputeCollateralDebtFloor() external isManualSetter {
        require(now > lastManualUpdateTime, "SingleDebtFloorAdjuster/cannot-update-twice-same-block");
        uint256 nextCollateralFloor = getNextCollateralFloor();
        lastManualUpdateTime = now;
        setFloor(nextCollateralFloor);
    }

    // --- Getters ---
    /*
    * @notify View function meant to return the new and upcoming debt floor. It checks for min/max bounds for newly computed floors
    */
    function getNextCollateralFloor() public returns (uint256) {
        (, , , uint256 debtCeiling) = safeEngine.collateralTypes(collateralName);
        uint256 lowestPossibleFloor  = minimum(debtCeiling, minDebtFloor);
        uint256 highestPossibleFloor = minimum(debtCeiling, maxDebtFloor);

        // Read the gas and the ETH prices
        uint256 gasPrice = gasPriceOracle.read();
        uint256 ethPrice = ethPriceOracle.read();

        // Calculate the denominated value of the new debt floor
        uint256 liquidationCostUSD = divide(multiply(multiply(gasPrice, gasAmountForLiquidation), ethPrice), WAD);

        // Calculate the new debt floor in terms of system coins
        uint256 redemptionPrice     = oracleRelayer.redemptionPrice();
        uint256 liquidationCostRAI  = multiply(divide(multiply(liquidationCostUSD, RAY), redemptionPrice), RAY);

        uint systemCoinDebtFloor = multiply(divide(liquidationCostRAI, subtract(multiply(collateralLiquidationRatio, subtract(WAD, max1hPriceDeviation)), RAD)), RAD);

        // Check boundaries
        if (systemCoinDebtFloor <= lowestPossibleFloor) return lowestPossibleFloor;
        else if (systemCoinDebtFloor >= highestPossibleFloor) return highestPossibleFloor;
        return systemCoinDebtFloor;
    }
}