pragma solidity 0.6.7;

import "ds-test/test.sol";
import "ds-token/token.sol";
import {SAFEEngine} from "geb/SAFEEngine.sol";
import {OracleRelayer} from "geb/OracleRelayer.sol";
import "./Mock/MockTreasury.sol";

import {SingleDebtFloorAdjuster} from "../SingleDebtFloorAdjuster.sol";

abstract contract Hevm {
    function warp(uint) virtual public;
}

contract OracleMock {
    uint result;

    constructor(uint initialPrice) public {
        result = initialPrice;
    }

    function read() public view returns (uint) {
        return result;
    }

    function setPrice(uint price) public {
        result = price;
    }
}

contract Keeper {
    SingleDebtFloorAdjuster adjuster;

    constructor(SingleDebtFloorAdjuster _adjuster) public {
        adjuster = _adjuster;
    }

    function doAddManualSetter(address who) public {
        adjuster.addManualSetter(who);
    }

    function doRemoveManualSetter(address who) public {
        adjuster.removeManualSetter(who);
    }

    function doModifyParameters(bytes32 param, address addr) public {
        adjuster.modifyParameters(param, addr);
    }

    function doModifyParameters(bytes32 param, uint val) public {
        adjuster.modifyParameters(param, val);
    }

    function doRecomputeCollateralDebtFloor(address feeReceiver) public {
        adjuster.recomputeCollateralDebtFloor(feeReceiver);
    }

    function doManualRecomputeCollateralDebtFloor() public {
        adjuster.manualRecomputeCollateralDebtFloor();
    }
}

contract SingleDebtFloorAdjusterTest is DSTest {
    Hevm hevm;
    DSToken token;
    SAFEEngine safeEngine;
    OracleRelayer oracleRelayer;
    MockTreasury treasury;
    OracleMock gasPriceOracle;
    OracleMock ethPriceOracle;
    SingleDebtFloorAdjuster adjuster;
    Keeper keeper;

    bytes32 collateralName = "ETH";
    uint baseUpdateCallerReward          = 5 ether;
    uint maxUpdateCallerReward           = 10 ether;
    uint perSecondCallerRewardIncrease   = 1000192559420674483977255848; // 100% per hour;
    uint updateDelay                     = 1 hours;
    uint maxRewardIncreaseDelay          = 6 hours;
    uint gasAmountForLiquidation         = 6000000;
    uint maxDebtFloor                    = 1000    * 10**45; // 1k
    uint minDebtFloor                    = 100     * 10**45; // 100
    uint debtCeiling                     = 1000000 * 10**45; // 1m

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        token = new DSToken("COIN", "COIN");
        safeEngine = new SAFEEngine();
        oracleRelayer = new OracleRelayer(address(safeEngine));
        treasury = new MockTreasury(address(token));
        gasPriceOracle = new OracleMock(120000000000);  // 120 gwei
        ethPriceOracle = new OracleMock(5000 * 10**18); // 5k

        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );

        keeper = new Keeper(adjuster);

        safeEngine.modifyParameters(collateralName, "debtCeiling", debtCeiling);
        safeEngine.addAuthorization(address(adjuster));
        oracleRelayer.modifyParameters("redemptionPrice", 3.14 ether);
    }

    function test_setup() public {
        assertEq(adjuster.collateralName() ,collateralName);
        assertEq(adjuster.gasAmountForLiquidation() ,gasAmountForLiquidation);
        assertEq(adjuster.maxDebtFloor() ,maxDebtFloor);
        assertEq(adjuster.minDebtFloor() ,minDebtFloor);
        assertEq(adjuster.lastUpdateTime() ,0);
        assertEq(adjuster.updateDelay() ,updateDelay);
        assertEq(adjuster.lastManualUpdateTime() ,now);
        assertEq(address(adjuster.safeEngine()) ,address(safeEngine));
        assertEq(address(adjuster.oracleRelayer()) ,address(oracleRelayer));
        assertEq(address(adjuster.gasPriceOracle()) ,address(gasPriceOracle));
        assertEq(address(adjuster.ethPriceOracle()) ,address(ethPriceOracle));
        assertEq(adjuster.manualSetters(address(this)), 1);

        // increasing rewards
        assertEq(adjuster.baseUpdateCallerReward() ,baseUpdateCallerReward);
        assertEq(adjuster.maxUpdateCallerReward() ,maxUpdateCallerReward);
        assertEq(adjuster.perSecondCallerRewardIncrease() ,perSecondCallerRewardIncrease);
    }

    function testFail_setup_null_safe_engine() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(0),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_oracle_relayer() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(0),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_gas_price_oracle() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(0),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_eth_price_oracle() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(0),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_update_delay() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            0,
            gasAmountForLiquidation,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_gas_amount() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            0,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_gas_amount_over_block_gas_limit() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            block.gaslimit,
            maxDebtFloor,
            minDebtFloor
        );
    }

    function testFail_setup_null_max_debt_floor() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            0,
            minDebtFloor
        );
    }


    function testFail_setup_null_min_debt_floor() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            0
        );
    }

    function testFail_setup_invalid_debt_floors() public {
        adjuster = new SingleDebtFloorAdjuster(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            address(gasPriceOracle),
            address(ethPriceOracle),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            gasAmountForLiquidation,
            maxDebtFloor,
            maxDebtFloor
        );
    }

    function test_add_manual_setter() public {
        adjuster.addManualSetter(address(0xfab));
        assertEq(adjuster.manualSetters(address(0xfab)), 1);
    }

    function test_remove_manual_setter() public {
        adjuster.removeManualSetter(address(this));
        assertEq(adjuster.manualSetters(address(this)), 0);
    }

    function testFail_add_setter_unauthorized() public {
        keeper.doAddManualSetter(address(keeper));
    }

    function testFail_remove_setter_unauthorized() public {
        keeper.doRemoveManualSetter(address(this));
    }

    function test_modify_parameters_address() public {
        treasury = new MockTreasury(address(token));
        adjuster.modifyParameters("treasury", address(treasury));
        assertEq(address(adjuster.treasury()), address(treasury));

        oracleRelayer = new OracleRelayer(address(safeEngine));
        adjuster.modifyParameters("oracleRelayer", address(oracleRelayer));
        assertEq(address(adjuster.oracleRelayer()), address(oracleRelayer));

        gasPriceOracle = new OracleMock(1);
        adjuster.modifyParameters("gasPriceOracle", address(gasPriceOracle));
        assertEq(address(adjuster.gasPriceOracle()), address(gasPriceOracle));

        ethPriceOracle = new OracleMock(1);
        adjuster.modifyParameters("ethPriceOracle", address(ethPriceOracle));
        assertEq(address(adjuster.ethPriceOracle()), address(ethPriceOracle));
    }

    function testFail_modify_parameters_address_unrecognized() public {
        treasury = new MockTreasury(address(token));
        adjuster.modifyParameters("nononono", address(treasury));
    }

    function testFail_modify_parameters_address_unauthorized() public {
        treasury = new MockTreasury(address(token));
        keeper.doModifyParameters("treasury", address(treasury));
    }

    function test_modify_parameters_uint() public {
        adjuster.modifyParameters("baseUpdateCallerReward", 7 ether);
        assertEq(adjuster.baseUpdateCallerReward(), 7 ether);

        adjuster.modifyParameters("maxUpdateCallerReward", 8 ether);
        assertEq(adjuster.maxUpdateCallerReward(), 8 ether);

        adjuster.modifyParameters("perSecondCallerRewardIncrease", 10**27);
        assertEq(adjuster.perSecondCallerRewardIncrease(), 10**27);

        adjuster.modifyParameters("maxRewardIncreaseDelay", 1);
        assertEq(adjuster.maxRewardIncreaseDelay(), 1);

        adjuster.modifyParameters("updateDelay", 8 hours);
        assertEq(adjuster.updateDelay(), 8 hours);

        adjuster.modifyParameters("maxDebtFloor", maxDebtFloor + 1);
        assertEq(adjuster.maxDebtFloor(), maxDebtFloor + 1);

        adjuster.modifyParameters("minDebtFloor", minDebtFloor + 1);
        assertEq(adjuster.minDebtFloor(), minDebtFloor + 1);

        adjuster.modifyParameters("lastUpdateTime", now + 1);
        assertEq(adjuster.lastUpdateTime(), now + 1);

        adjuster.modifyParameters("gasAmountForLiquidation", 1);
        assertEq(adjuster.gasAmountForLiquidation(), 1);
    }

    function testFail_modify_parameters_uint_unrecognized() public {
        adjuster.modifyParameters("nononono", 7 ether);
    }

    function testFail_modify_parameters_uint_unauthorized() public {
        treasury = new MockTreasury(address(token));
        keeper.doModifyParameters("baseUpdateCallerReward", 7 ether);
    }

    function testFail_modify_parameters_uint_invalid_base_update_caller_reward() public {
        adjuster.modifyParameters("baseUpdateCallerReward", maxUpdateCallerReward + 1);
    }

    function testFail_modify_parameters_uint_invalid_max_update_caller_reward() public {
        adjuster.modifyParameters("maxUpdateCallerReward", baseUpdateCallerReward - 1);
    }

    function testFail_modify_parameters_uint_invalid_per_second_reward_increase() public {
        adjuster.modifyParameters("perSecondCallerRewardIncrease", 10**27 - 1);
    }

    function testFail_modify_parameters_uint_invalid_max_reward_increase_delay() public {
        adjuster.modifyParameters("maxRewardIncreaseDelay", 0);
    }

    function testFail_modify_parameters_uint_invalid_max_debt_floor() public {
        adjuster.modifyParameters("maxDebtFloor", minDebtFloor);
    }

    function testFail_modify_parameters_uint_invalid_min_debt_floor() public {
        adjuster.modifyParameters("minDebtFloor", maxDebtFloor);
    }

    function testFail_modify_parameters_uint_null_min_debt_floor() public {
        adjuster.modifyParameters("minDebtFloor", 0);
    }

    function testFail_modify_parameters_uint_invalid_last_update_time() public {
        adjuster.modifyParameters("lastUpdateTime", now);
    }

    function testFail_modify_parameters_uint_invalid_gas_amount_for_liquidation() public {
        adjuster.modifyParameters("gasAmountForLiquidation", block.gaslimit);
    }

    function testFail_modify_parameters_uint_null_gas_amount_for_liquidation() public {
        adjuster.modifyParameters("gasAmountForLiquidation", 0);
    }

    function test_recompute_collateral_debt_floor_max() public {
        adjuster.recomputeCollateralDebtFloor(address(0xfab));
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
        assertEq(adjuster.lastUpdateTime(), now);
        assertEq(debtFloor, maxDebtFloor);
    }

    function test_recompute_collateral_debt_floor_min() public {
        gasPriceOracle.setPrice(1);
        adjuster.modifyParameters("gasAmountForLiquidation", 1);

        adjuster.recomputeCollateralDebtFloor(address(0xfab));
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
        assertEq(adjuster.lastUpdateTime(), now);
        assertEq(debtFloor, minDebtFloor);
    }

    function test_recompute_collateral_debt_floor_fuzz(
        uint gasPrice,
        uint ethPrice,
        uint gasAmountForLiquidation,
        uint redemptionPrice
    ) public {
        gasPriceOracle.setPrice(notNull(gasPrice % 1000000000000)); // up to 1000 gwei
        ethPriceOracle.setPrice(notNull(ethPrice % 10000 ether));   // up to 10k
        adjuster.modifyParameters("gasAmountForLiquidation", notNull(gasAmountForLiquidation % (block.gaslimit / 2))); // up to half block
        oracleRelayer.modifyParameters("redemptionPrice", notNull(redemptionPrice % 10**33)); // up to 100k

        keeper.doRecomputeCollateralDebtFloor(address(keeper));
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);

        assertEq(adjuster.lastUpdateTime(), now);
        assertTrue(debtFloor >= minDebtFloor);
        assertTrue(debtFloor <= maxDebtFloor);
        assertEq(debtFloor, recalculateDebtFloor());
    }

    function test_manual_recompute() public {
        hevm.warp(now + 1);
        adjuster.manualRecomputeCollateralDebtFloor();
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);

        assertEq(adjuster.lastManualUpdateTime(), now);
        assertTrue(debtFloor >= minDebtFloor);
        assertTrue(debtFloor <= maxDebtFloor);
        assertEq(debtFloor, recalculateDebtFloor());
    }

    function testFail_manual_recompute_unauthorized() public {
        hevm.warp(now + 1);
        keeper.doManualRecomputeCollateralDebtFloor();
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
    }

    function recalculateDebtFloor() internal returns (uint) {
        (, , , uint256 debtCeiling, ,) = safeEngine.collateralTypes(collateralName);
        uint256 lowestPossibleFloor  = minimum(debtCeiling, adjuster.minDebtFloor());
        uint256 highestPossibleFloor = minimum(debtCeiling, adjuster.maxDebtFloor());

        uint256 debtFloorValue = (gasPriceOracle.read() * adjuster.gasAmountForLiquidation() * ethPriceOracle.read()) / 10**18; // in usd
        uint256 systemCoinDebtFloor = (debtFloorValue * 10**27) / oracleRelayer.redemptionPrice() * 10**27;                     // in rai

        // Check boundaries
        if (systemCoinDebtFloor <= lowestPossibleFloor) return lowestPossibleFloor;
        else if (systemCoinDebtFloor >= highestPossibleFloor) return highestPossibleFloor;
        else return systemCoinDebtFloor;
    }

    function notNull(uint val) internal returns (uint) {
        return val == 0 ? 1 : val;
    }

    function minimum(uint x, uint y) internal pure returns (uint z) {
        z = (x <= y) ? x : y;
    }

    function maximum(uint x, uint y) internal pure returns (uint z) {
        z = (x >= y) ? x : y;
    }
}