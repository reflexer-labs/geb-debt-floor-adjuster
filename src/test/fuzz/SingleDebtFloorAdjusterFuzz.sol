pragma solidity 0.6.7;

import {SAFEEngine} from "../../../lib/geb/src/SAFEEngine.sol";
import {OracleRelayer} from "../../../lib/geb/src/OracleRelayer.sol";
import "../Mock/MockTreasury.sol";

import "./SingleDebtFloorAdjusterMock.sol";
import {SingleSpotDebtCeilingSetterMock} from "./SingleSpotDebtCeilingSetterMock.sol";

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

contract TokenMock {
    uint constant maxUint = uint(0) - 1;
    mapping (address => uint256) public received;
    mapping (address => uint256) public sent;

    function totalSupply() public view returns (uint) {
        return maxUint;
    }
    function balanceOf(address src) public view returns (uint) {
        return maxUint;
    }
    function allowance(address src, address guy) public view returns (uint) {
        return maxUint;
    }

    function transfer(address dst, uint wad) public returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }

    function transferFrom(address src, address dst, uint wad)
        public
        returns (bool)
    {
        received[dst] += wad;
        sent[src]     += wad;
        return true;
    }

    function approve(address guy, uint wad) virtual public returns (bool) {
        return true;
    }
}

// @notice Fuzz the whole thing, failures will show bounds (run with checkAsserts: on)
contract FuzzBounds is SingleDebtFloorAdjusterMock {

    constructor() SingleDebtFloorAdjusterMock(
            address(new SAFEEngine()),
            address(new OracleRelayer(address(0x1))),
            address(0x0),
            address(new OracleMock(120000000000)),
            address(new OracleMock(5000 * 10**18)),
            "ETH",
            5 ether,
            10 ether,
            1000192559420674483977255848,
            1 hours,
            600000,
            1000 * 10**45,
            100 * 10**45
    ) public {
        TokenMock token = new TokenMock();
        oracleRelayer = OracleRelayerLike(address(new OracleRelayer(address(safeEngine))));
        treasury = StabilityFeeTreasuryLike(address(new MockTreasury(address(token))));

        safeEngine.modifyParameters(collateralName, "debtCeiling", 1000000 * 10**45);
        OracleRelayer(address (oracleRelayer)).modifyParameters("redemptionPrice", 3.14 ether);

        maxRewardIncreaseDelay = 5 hours;
    }

    function fuzzParams(uint ethPrice, uint gasPrice, uint _gasAmountForLiquidation, uint redemptionPrice) public {
        OracleMock(address(ethPriceOracle)).setPrice(notNull(ethPrice % 1000 ether)); // up to 100k
        OracleMock(address(gasPriceOracle)).setPrice(notNull(gasPrice % 10000000000000)); // up to 10000 gwei
        gasAmountForLiquidation = notNull(_gasAmountForLiquidation % (block.gaslimit * 4)); // up to block.gaslimit * 4 (50mm)
        OracleRelayer(address(oracleRelayer)).modifyParameters("redemptionPrice", maximum(redemptionPrice % 10**39, 10**24));
    }

    function notNull(uint val) internal returns (uint) {
        return val == 0 ? 1 : val;
    }

    function maximum(uint a, uint b) internal returns (uint) {
        return (b >= a) ? b : a;
    }

}

// @notice Fuzz the contracts testing properties
contract Fuzz is SingleDebtFloorAdjusterMock {

    constructor() SingleDebtFloorAdjusterMock(
            address(new SAFEEngine()),
            address(new OracleRelayer(address(0x1))),
            address(0x0),
            address(new OracleMock(120000000000)),
            address(new OracleMock(5000 * 10**18)),
            "ETH",
            5 ether,
            10 ether,
            1000192559420674483977255848,
            1 hours,
            600000,
            1000 * 10**45,
            100 * 10**45
    ) public {
        TokenMock token = new TokenMock();
        oracleRelayer = OracleRelayerLike(address(new OracleRelayer(address(safeEngine))));
        treasury = StabilityFeeTreasuryLike(address(new MockTreasury(address(token))));

        safeEngine.modifyParameters(collateralName, "debtCeiling", 1000000 * 10**45);
        OracleRelayer(address (oracleRelayer)).modifyParameters("redemptionPrice", 3.14 ether);

        maxRewardIncreaseDelay = 5 hours;
    }

    modifier recompute() {
        _;
        recomputeCollateralDebtFloor(address(0xfab));
    }

    function notNull(uint val) internal returns (uint) {
        return val == 0 ? 1 : val;
    }

    function maximum(uint a, uint b) internal returns (uint) {
        return (b >= a) ? b : a;
    }

    function fuzzEthPrice(uint ethPrice) public recompute {
        OracleMock(address(ethPriceOracle)).setPrice(notNull(ethPrice % 1000 ether)); // up to 100k
    }

    function fuzzGasPrice(uint gasPrice) public recompute {
        OracleMock(address(gasPriceOracle)).setPrice(notNull(gasPrice % 10000000000000)); // up to 10000 gwei
    }

    function fuzzGasAmountForLiquidation(uint _gasAmountForLiquidation) public recompute {
        gasAmountForLiquidation = notNull(_gasAmountForLiquidation % block.gaslimit); // up to block gas limit
    }

    function fuzzRedemptionPrice(uint redemptionPrice) public recompute {
        OracleRelayer(address(oracleRelayer)).modifyParameters("redemptionPrice", maximum(redemptionPrice % 10**39, 10**24));
    }

    // properties
    function echidna_debt_floor() public returns (bool) {
        (,,,, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        return (debtFloor == getNextCollateralFloor() || lastUpdateTime == 0);
    }

    function echidna_debt_floor_bounds() public returns (bool) {
        (,,,, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        return (debtFloor >= minDebtFloor && debtFloor <= maxDebtFloor) || lastUpdateTime == 0;
    }
}

contract SAFEEngineMock is SAFEEngine {
    function modifyFuzzParameters(
        bytes32 collateralType,
        bytes32 parameter,
        uint256 data
    ) external isAuthorized {
        if (parameter == "debtAmount") collateralTypes[collateralType].debtAmount = data;
        else if (parameter == "accumulatedRate") collateralTypes[collateralType].accumulatedRate = data;
        else revert();
    }
}

// Integration Fuzz
contract IntegrationFuzz {
    TokenMock token;
    SAFEEngineMock safeEngine;
    OracleRelayer oracleRelayer;
    MockTreasury treasury;
    OracleMock gasPriceOracle;
    OracleMock ethPriceOracle;
    SingleDebtFloorAdjusterMock floorAdjuster;

    bytes32 collateralName = "ETH";
    uint baseUpdateCallerReward          = 5 ether;
    uint maxUpdateCallerReward           = 10 ether;
    uint perSecondCallerRewardIncrease   = 1000192559420674483977255848; // 100% per hour;
    uint updateDelay                     = 1 hours;
    uint maxRewardIncreaseDelay          = 6 hours;
    uint gasAmountForLiquidation         = 6000000;
    uint maxDebtFloor                    = 1000    * 10**45; // 1k
    uint minDebtFloor                    = 100     * 10**45; // 100
    uint debtCeiling                     = 10000   * 10**45; // 10k
    uint debtFloor                       = 800     * 10**45;

    SingleSpotDebtCeilingSetterMock ceilingSetter;
    uint256 ceilingPercentageChange      = 120;
    uint256 maxCollateralCeiling         = 10000   * 10**45; // 10k
    uint256 minCollateralCeiling         = 1       * 10**45; // 1

    constructor() public {

        token = new TokenMock();
        safeEngine = new SAFEEngineMock();
        oracleRelayer = new OracleRelayer(address(safeEngine));
        treasury = new MockTreasury(address(token));
        gasPriceOracle = new OracleMock(120000000000);  // 120 gwei
        ethPriceOracle = new OracleMock(5000 * 10**18); // 5k

        floorAdjuster = new SingleDebtFloorAdjusterMock(
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

        ceilingSetter = new SingleSpotDebtCeilingSetterMock(
            address(safeEngine),
            address(oracleRelayer),
            address(treasury),
            collateralName,
            baseUpdateCallerReward,
            maxUpdateCallerReward,
            perSecondCallerRewardIncrease,
            updateDelay,
            ceilingPercentageChange,
            maxCollateralCeiling,
            minCollateralCeiling
        );

        safeEngine.modifyParameters(collateralName, "debtCeiling", debtCeiling);
        safeEngine.modifyParameters(collateralName, "debtFloor", debtFloor);


        safeEngine.initializeCollateralType(collateralName);
        safeEngine.addAuthorization(address(floorAdjuster));
        safeEngine.addAuthorization(address(ceilingSetter));
        oracleRelayer.modifyParameters("redemptionPrice", 3.14 ether);
        floorAdjuster.modifyParameters("maxRewardIncreaseDelay", 5 hours);
        ceilingSetter.modifyParameters("maxRewardIncreaseDelay", 5 hours);
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

    function fuzzEthPrice(uint ethPrice) public {
        OracleMock(address(ethPriceOracle)).setPrice(notNull(ethPrice % 1000000 ether)); // up to 1mm
    }

    function fuzzGasPrice(uint gasPrice) public {
        OracleMock(address(gasPriceOracle)).setPrice(notNull(gasPrice % 10000000000000)); // up to 10000 gwei
    }

    function fuzzGasAmountForLiquidation(uint gasAmountForLiquidation) public {
        floorAdjuster.modifyParameters("gasAmountForLiquidation", notNull(gasAmountForLiquidation % block.gaslimit)); // up to block gas limit
    }

    function fuzzRedemptionPrice(uint redemptionPrice) public {
        OracleRelayer(address(oracleRelayer)).modifyParameters("redemptionPrice", maximum(redemptionPrice % 10**39, 10**24)); // from 0.001 to 1t
    }

    function fuzzDebtAmount(uint debtAmount) public {
        safeEngine.modifyFuzzParameters(collateralName, "debtAmount", debtAmount % 10000000000000 * 10**18); // up to 10t coin
    }

    function fuzzAccumulatedRate(uint accumulatedRate) public {
        safeEngine.modifyFuzzParameters(collateralName, "accumulatedRate", accumulatedRate % 10**30); // up to 1000x
    }

    // properties
    function echidna_debt_floor() public returns (bool) {
        floorAdjuster.recomputeCollateralDebtFloor(address(0xfab));
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
        return (debtFloor == floorAdjuster.getNextCollateralFloor());
    }

    function echidna_debt_floor_bounds() public returns (bool) {
        (,,,, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
        return (debtFloor >= floorAdjuster.minDebtFloor() && debtFloor <= floorAdjuster.maxDebtFloor());
    }

    function echidna_debt_floor_lower_than_debt_ceiling() public returns (bool) {
        (,,, uint256 debtCeiling, uint256 debtFloor,) = safeEngine.collateralTypes(collateralName);
        return (debtCeiling >= debtFloor);
    }

    function echidna_debt_ceiling() public returns (bool) {
        ceilingSetter.autoUpdateCeiling(address(0xfab));
        (,,,uint256 debtCeiling ,,) = safeEngine.collateralTypes(collateralName);
        return (debtCeiling == ceilingSetter.getNextCollateralCeiling());
    }

    function echidna_debt_ceiling_bounds() public returns (bool) {
        (,,,uint256 debtCeiling ,,) = safeEngine.collateralTypes(collateralName);
        return (debtCeiling >= ceilingSetter.minCollateralCeiling() && debtCeiling <= ceilingSetter.maxCollateralCeiling());
    }
}