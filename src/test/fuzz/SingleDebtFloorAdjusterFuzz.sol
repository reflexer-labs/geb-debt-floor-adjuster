pragma solidity 0.6.7;

import {SAFEEngine} from "../../../lib/geb/src/SAFEEngine.sol";
import {OracleRelayer} from "../../../lib/geb/src/OracleRelayer.sol";
import "../Mock/MockTreasury.sol";

import "./SingleDebtFloorAdjusterMock.sol";

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