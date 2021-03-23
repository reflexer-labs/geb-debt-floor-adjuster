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
    uint256 public totalSupply = 1E24;
    uint256 public burnedBalance;

    function balanceOf(address) public returns (uint) {
        return burnedBalance;
    }

    function setParams(uint256 _totalSupply) public {
        totalSupply = _totalSupply;
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

        recomputeCollateralDebtFloor(address(0xfab));

        maxRewardIncreaseDelay = 3600;
    }

    modifier recompute() {
        _;
        recomputeCollateralDebtFloor(address(0xfab));
    }

    function notNull(uint val) internal returns (uint) {
        return val == 0 ? 1 : val;
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
        OracleRelayer(address(oracleRelayer)).modifyParameters("redemptionPrice", notNull(redemptionPrice % 10**39));
    }

    function recalculateDebtFloor() internal returns (uint) {
        (, , , uint256 debtCeiling ,) = safeEngine.collateralTypes(collateralName);
        uint256 lowestPossibleFloor  = minimum(debtCeiling, minDebtFloor);
        uint256 highestPossibleFloor = minimum(debtCeiling, maxDebtFloor);

        uint256 debtFloorValue = (gasPriceOracle.read() * gasAmountForLiquidation * ethPriceOracle.read()) / 10**18; // in usd
        uint256 systemCoinDebtFloor = (debtFloorValue * 10**27) / oracleRelayer.redemptionPrice() * 10**27;          // in rai

        // Check boundaries
        if (systemCoinDebtFloor <= lowestPossibleFloor) return lowestPossibleFloor;
        else if (systemCoinDebtFloor >= highestPossibleFloor) return highestPossibleFloor;
        else return systemCoinDebtFloor;
    }

    // properties
    function echidna_debt_floor() public returns (bool) {
        (,,,, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        return (debtFloor == recalculateDebtFloor());
    }

    function echidna_debt_floor_bounds() public returns (bool) {
        (,,,, uint256 debtFloor) = safeEngine.collateralTypes(collateralName);
        return (debtFloor >= minDebtFloor && debtFloor <= maxDebtFloor);
    }
}

// // @notice Will create several different ThresholdSetters.
// // goal is to fuzz minAmountToBurn and supplyPercentageToBurn
// contract ExternalFuzz {
//     ESMThresholdSetterMock setter;
//     ESMMock esm;
//     TokenMock token;

//     uint256 lastUpdateTotalSupply;

//     constructor() public  {
//         token = new TokenMock();
//         esm = new ESMMock(1E18);
//         createNewSetter(1E18, 65);
//     }

//     function fuzzTotalSupply(uint256 totalSupply) public {
//         token.setParams(totalSupply);
//     }

//     function createNewSetter(uint256 minAmountToBurn, uint256 supplyPercentageToBurn) public {
//         setter = new ESMThresholdSetterMock(
//             address(token),
//             minAmountToBurn + 1,
//             (supplyPercentageToBurn % 999) + 1 // ensuring valid setter params
//         );
//         setter.modifyParameters("esm", address(esm));
//         recomputeThreshold();
//     }

//     function recomputeThreshold() public {
//         lastUpdateTotalSupply = token.totalSupply();
//         setter.recomputeThreshold();
//     }

//     // properties
//     function echidna_threshold() public returns (bool) {
//         uint threshold = esm.triggerThreshold();
//         if (threshold < setter.minAmountToBurn()) return false;
//         if (threshold == setter.minAmountToBurn()) return true;
//         if (
//              threshold != (lastUpdateTotalSupply * setter.supplyPercentageToBurn()) / 1000 // burned tokens are always 0
//         ) return false;
//         return true;
//     }
// }

