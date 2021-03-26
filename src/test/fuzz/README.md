# Security Tests

The contracts in this folder are the fuzz scripts for the ESM Threshold Setter.

To run the fuzzer, set up Echidna (https://github.com/crytic/echidna) on your machine.

Then run
```
echidna-test src/test/fuzz/<name of file>.sol --contract <Name of contract> --config src/test/fuzz/echidna.yaml
```

Configs are in this folder (echidna.yaml).

The contracts in this folder are modified versions of the originals in the _src_ folder. They have assertions added to test for invariants, visibility of functions modified. Running the Fuzz against modified versions without the assertions is still possible, general properties on the Fuzz contract can be executed against unmodified contracts.

Tests should be run one at a time because they interfere with each other.

For all contracts being fuzzed, we tested the following:

1. Writing assertions and/or turning "requires" into "asserts" within the smart contract itself. This will cause echidna to fail fuzzing, and upon failures echidna finds the lowest value that causes the assertion to fail. This is useful to test bounds of functions (i.e.: modifying safeMath functions to assertions will cause echidna to fail on overflows, giving insight on the bounds acceptable). This is useful to find out when these functions revert. Although reverting will not impact the contract's state, it could cause a denial of service (or the contract not updating state when necessary and getting stuck). We check the found bounds against the expected usage of the system.
2. For contracts that have state, we also force the contract into common states and fuzz common actions.

Echidna will generate random values and call all functions failing either for violated assertions, or for properties (functions starting with echidna_) that return false. Sequence of calls is limited by seqLen in the config file. Calls are also spaced over time (both block number and timestamp) in random ways. Once the fuzzer finds a new execution path, it will explore it by trying execution with values close to the ones that opened the new path.

# Results

### 1. Fuzzing for overflows (FuzzBounds)

In this test we want failures, as they will show us what are the bounds in which the contract operates safely.

Failures flag where overflows happen, and should be compared to expected inputs (to avoid overflows frm causing DoS).

```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-debt-floor-adjuster/src/test/fuzz/SingleDebtFloorAdjusterFuzz.sol:FuzzBounds
assertion in rmultiply: failed!💥
  Call sequence:
    rmultiply(332921093094338577030744198535523240856704353483568126421802148408814269370,348)

assertion in ray: failed!💥
  Call sequence:
    ray(115812648077840646829345304368052060451846300843089180408138616160518)

assertion in multiply: failed!💥
  Call sequence:
    multiply(4165,27838755570577492995663440370365549945073429008406087208836364988134218004)

assertion in baseUpdateCallerReward: passed! 🎉
assertion in maxRewardIncreaseDelay: passed! 🎉
assertion in authorizedAccounts: passed! 🎉
assertion in recomputeCollateralDebtFloor: passed! 🎉
assertion in treasuryAllowance: passed! 🎉
assertion in addAuthorization: passed! 🎉
assertion in wmultiply: failed!💥
  Call sequence:
    wmultiply(203493213005984198459721542916147321788,575291077567137410960219008005515362524)

assertion in subtract: failed!💥
  Call sequence:
    subtract(0,1)

assertion in perSecondCallerRewardIncrease: passed! 🎉
assertion in rad: failed!💥
  Call sequence:
    rad(115795943725679882077277979345418798110609245556460)

assertion in oracleRelayer: passed! 🎉
assertion in addition: failed!💥
  Call sequence:
    addition(58681716500677413755800075851094420641776907601571323736916992931906599422584,57213209650390704597336471413886422947431147611184191737496348348345682319906)

assertion in RAY: passed! 🎉
assertion in updateDelay: passed! 🎉
assertion in maxDebtFloor: passed! 🎉
assertion in treasury: passed! 🎉
assertion in modifyParameters: passed! 🎉
assertion in safeEngine: passed! 🎉
assertion in maxUpdateCallerReward: passed! 🎉
assertion in WAD: passed! 🎉
assertion in gasPriceOracle: passed! 🎉
assertion in minDebtFloor: passed! 🎉
assertion in removeAuthorization: passed! 🎉
assertion in collateralName: passed! 🎉
assertion in getNextCollateralFloor: passed! 🎉
assertion in rdivide: failed!💥
  Call sequence:
    rdivide(0,0)

assertion in manualRecomputeCollateralDebtFloor: passed! 🎉
assertion in ethPriceOracle: passed! 🎉
assertion in lastManualUpdateTime: passed! 🎉
assertion in addManualSetter: passed! 🎉
assertion in lastUpdateTime: passed! 🎉
assertion in manualSetters: passed! 🎉
assertion in rpower: failed!💥
  Call sequence:
    rpower(137490,15,1)

assertion in minimum: passed! 🎉
assertion in gasAmountForLiquidation: passed! 🎉
assertion in removeManualSetter: passed! 🎉
assertion in getCallerReward: passed! 🎉
assertion in wdivide: failed!💥
  Call sequence:
    wdivide(115865900777289161980450011454377227429765625273902118131960,594930460211338354869264009965854726534657655809423260)

assertion in modifyParameters: passed! 🎉

Seed: 8895570422632348356
```
#### Conclusion: No exceptions found, all overflows are expected (from teh public functions in GebMath). A previous detailed analysis was also made for rPow, due to it's lower bound (geb repo, branch echidna).


### Fuzz Properties (Fuzz)

In this case we setup the setter, and check properties.

Here we are not looking for bounds, but instead checking the properties that either should remain constant, or that move as the auction evolves:

- debtFloor bounds and value

These properties are verified in between all calls.

```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-debt-floor-adjuster/src/test/fuzz/SingleDebtFloorAdjusterFuzz.sol:Fuzz
echidna_debt_floor_bounds: passed! 🎉
echidna_debt_floor: passed! 🎉

Seed: 8817236648426374032
```

#### Conclusion: No exceptions noted


# Integration fuzz (fuzz both debt floor and ceiling adjusters)
In this case, we are deploying both a debt floor adjuter and a debt ceiling setter.

We fuzz all the parameters for both of the setters:
- Eth price up to 1mm USD
- Gas price up to 10k gwei
- gasAmountForLiquidation up to the block gas limit
- Redemption price from 0.001 to 1t
- Debt amount up to 10t
- accumulatedRate up to 1000x

Properties checked:
- debt floor (in SAFEEngine) matches the correct debt floor
- debt floor bounds
- debt floor is equal or lower than the debt ceiling
- debt ceiling (in SAFEEngine) matches the correct debt ceiling
- debt ceiling bounds

These properties are verified in between all calls.

```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-debt-floor-adjuster/src/test/fuzz/SingleDebtFloorAdjusterFuzz.sol:IntegrationFuzz
echidna_debt_floor_lower_than_debt_ceiling: passed! 🎉
echidna_debt_ceiling_bounds: passed! 🎉
echidna_debt_floor_bounds: passed! 🎉
echidna_debt_floor: passed! 🎉
echidna_debt_ceiling: passed! 🎉

Seed: 2730218574612219821
```

#### Conclusion: No exceptions noted