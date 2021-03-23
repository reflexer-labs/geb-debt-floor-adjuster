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
    rmultiply(10,11878073311176165570034889156264605665638622269524920863125510254613159172896)

assertion in ray: failed!💥
  Call sequence:
    ray(115908322801185052593715166036547792649176109893689552612609066156716)

assertion in multiply: failed!💥
  Call sequence:
    multiply(20284864702687109823681519207111366900,5963924741505427569128308457276696154022)

assertion in baseUpdateCallerReward: passed! 🎉
assertion in maxRewardIncreaseDelay: passed! 🎉
assertion in authorizedAccounts: passed! 🎉
assertion in recomputeCollateralDebtFloor: failed!💥
  Call sequence:
    recomputeCollateralDebtFloor(0x0) from: 0x0000000000000000000000000000000000010000
    *wait* Time delay: 280147 seconds Block delay: 1
    recomputeCollateralDebtFloor(0x0) from: 0x0000000000000000000000000000000000010000

assertion in treasuryAllowance: passed! 🎉
assertion in addAuthorization: passed! 🎉
assertion in wmultiply: failed!💥
  Call sequence:
    wmultiply(219352246868582790064461574595495495,531356677715175895590274009776977870524953)

assertion in subtract: failed!💥
  Call sequence:
    subtract(0,1)

assertion in perSecondCallerRewardIncrease: passed! 🎉
assertion in rad: failed!💥
  Call sequence:
    rad(115890160058241162287579200047718654490303517348764)

assertion in oracleRelayer: passed! 🎉
assertion in addition: failed!💥
  Call sequence:
    addition(65895742371972199160340240403652966719197523371016570500714154000763269119724,51663453205179106736573770082721497311695667380448256191190573288590875950039)

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
    rdivide(115899769392952946130453507072213386193783104893275,70030232432027941987360487978592051105915793)

assertion in manualRecomputeCollateralDebtFloor: passed! 🎉
assertion in ethPriceOracle: passed! 🎉
assertion in lastManualUpdateTime: passed! 🎉
assertion in addManualSetter: passed! 🎉
assertion in lastUpdateTime: passed! 🎉
assertion in manualSetters: passed! 🎉
assertion in rpower: failed!💥
  Call sequence:
    rpower(340953406973632187442259559251142076810,3249852374806480520605965920319,0)

assertion in minimum: passed! 🎉
assertion in gasAmountForLiquidation: passed! 🎉
assertion in removeManualSetter: passed! 🎉
assertion in getCallerReward: failed!💥
  Call sequence:
    getCallerReward(1,0)

assertion in wdivide: failed!💥
  Call sequence:
    wdivide(116115775748065387252487754879519715091961438764866907725486,464954351996555578179881381232514158042794710343567147038)

assertion in modifyParameters: passed! 🎉

Seed: -7196134968007201111
```
TBD

#### Conclusion: TBD


### Fuzz Properties (Fuzz)

In this case we setup the setter, and check properties.

Here we are not looking for bounds, but instead checking the properties that either should remain constant, or that move as the auction evolves:

- debtFloor bunds and value

These properties are verified in between all calls.

```
Analyzing contract: /Users/fabio/Documents/reflexer/geb-debt-floor-adjuster/src/test/fuzz/SingleDebtFloorAdjusterFuzz.sol:Fuzz
echidna_debt_floor_bounds: passed! 🎉
echidna_debt_floor: failed!💥
  Call sequence:
    *wait* Time delay: 1605 seconds Block delay: 3936435
    fuzzGasAmountForLiquidation(0) from: 0x0000000000000000000000000000000000010000 Time delay: 2001 seconds Block delay: 30319291


Seed: 283288701020023378
```

#### Conclusion: TBD
