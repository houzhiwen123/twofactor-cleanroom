// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

interface IControllerRolloverProbe {
    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function owner() external view returns (address);
    function keeper() external view returns (address);
    function issuer() external view returns (address);
    function balancer() external view returns (address);
    function underlyingOracle() external view returns (address);
    function minMaturitySec() external view returns (uint32);
    function minCleanupVal() external view returns (uint256);
    function availPerpJrLiquidity() external view returns (uint256);
    function perpJrReservedUnderlyingAmt() external view returns (uint256);
    function perpJrReservedUnderlyingPerc() external view returns (uint64);
    function reservedPerpJrLiquidity() external view returns (uint256);
    function latestBondInfo() external view returns (BondInfo memory);
    function systemReserveState()
        external
        view
        returns (SystemState memory state, ReserveData memory perpSrRd, ReserveData memory perpJrRd);
    function upkeep() external;
    function rollover() external;
    function updateLiquidityThresholds(uint256 perpJrReservedUnderlyingAmt_, uint64 perpJrReservedUnderlyingPerc_)
        external;
}

interface IBalancerRolloverProbe {
    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
    }

    struct PerpSrRolloverState {
        uint256 staleUnderlyingBal;
        uint256 totalStaleVal;
        ReserveTrancheData[] staleSrTrs;
        ReserveTrancheData[] freshSrTrs;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct BondDepositParams {
        bytes32 bondID;
        uint256 underlyingAmt;
    }

    struct RolloverExecution {
        ReserveAmounts stale;
        BondDepositParams[] freshBondDepositAmts;
        TokenAmount[] freshSrTrAmts;
        uint256 underlyingValRolled;
    }

    function computePerpSrRolloverState(ReserveData memory reserves, uint32 minMaturitySec, address bondsManager)
        external
        pure
        returns (PerpSrRolloverState memory rolloverState);

    function computePerpJrLiquidity(
        ReserveData memory perpJrReserves,
        PerpSrRolloverState memory rolloverState,
        uint256 reservedPerpJrLiquidity
    ) external pure returns (uint256 freePerpJrLiquidity, uint256 unlockedPerpJrLiquidity, uint256[] memory unpaired);

    function computeRolloverPolicy(
        PerpSrRolloverState memory rolloverState,
        uint256[] memory unpairedStaleSrTrAmts,
        uint256 underlyingAmtAvail
    ) external pure returns (uint256 underlyingAmtToDeploy, RolloverExecution memory e);

    function computeBackupRolloverPolicy(PerpSrRolloverState memory rolloverState, uint256 underlyingAmtAvail)
        external
        pure
        returns (RolloverExecution memory e);

    function computePerpSrRolloverPlan(
        ReserveData memory perpSrReserveData,
        ReserveData memory perpJrReserveData,
        address bondsManager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external pure returns (RolloverExecution memory e);
}

interface IOracleRolloverProbe {
    function FEED() external view returns (address);
    function SEQUENCER_FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function cachePrice() external;
    function resetCache() external;
}

interface IPriceFeedRolloverProbe {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract RolloverProbeTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant KEEP_ORACLE_CALLER = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    uint256 private constant FIRST_ROLLOVER_TS = 1_794_510_001;
    uint256 private constant SECOND_ROLLOVER_TS = 1_795_436_234;

    struct CallResult {
        bool ok;
        string summary;
    }

    struct StateResult {
        bool ok;
        IBalancerRolloverProbe.PerpSrRolloverState state;
        string summary;
    }

    struct PolicyResults {
        CallResult liquidity;
        CallResult freePolicy;
        CallResult unlockedPolicy;
        CallResult combinedPolicy;
        CallResult freeBackup;
        CallResult unlockedBackup;
        CallResult combinedBackup;
        uint256 freeLiquidity;
        uint256 unlockedLiquidity;
        uint256 combinedLiquidity;
        uint256[] unpaired;
    }

    struct CaseInput {
        string label;
        IBalancerRolloverProbe.ReserveData sr;
        IBalancerRolloverProbe.ReserveData jr;
        uint32 minMaturity;
        uint256 reservedLiquidity;
    }

    struct CaseResults {
        CallResult plan;
        StateResult srState;
        StateResult jrState;
        PolicyResults policies;
    }

    IControllerRolloverProbe private controller;
    IBalancerRolloverProbe private balancer;
    IOracleRolloverProbe private oracle;
    address private priceFeed;
    address private sequencerFeed;
    uint80 private priceRoundId;
    int256 private priceAnswer;
    uint80 private priceAnsweredInRound;
    uint80 private sequencerRoundId;
    uint80 private sequencerAnsweredInRound;
    uint32 private sequencerGracePeriod;

    function setUp() public {
        controller = IControllerRolloverProbe(CONTROLLER);
        balancer = IBalancerRolloverProbe(BALANCER);
        assertEq(controller.balancer(), BALANCER);
        assertEq(controller.owner(), 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d);
        assertEq(controller.issuer(), 0xc56CCbF6219B780c879544FEe0404bD3B49fEBB0);
        oracle = IOracleRolloverProbe(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IPriceFeedRolloverProbe(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,, , sequencerAnsweredInRound) =
                IPriceFeedRolloverProbe(sequencerFeed).latestRoundData();
        }
    }

    function testRolloverFirstActualTrace() public {
        _prepareFirstRollover();
        _logControllerInputs("first_actual", FIRST_ROLLOVER_TS);
        vm.prank(controller.keeper());
        controller.rollover();
    }

    function testRolloverSecondActualTrace() public {
        _prepareSecondRollover();
        _logControllerInputs("second_actual", SECOND_ROLLOVER_TS);
        vm.prank(controller.keeper());
        controller.rollover();
    }

    function testRolloverFirstDirectFunctionsAndVariants() public {
        _prepareFirstRollover();
        (, IControllerRolloverProbe.ReserveData memory srController, IControllerRolloverProbe.ReserveData memory jrController)
        = controller.systemReserveState();
        _logControllerInputs("first_direct", FIRST_ROLLOVER_TS);

        IBalancerRolloverProbe.ReserveData memory sr = _toBalancerReserve(srController);
        IBalancerRolloverProbe.ReserveData memory jr = _toBalancerReserve(jrController);
        uint32 minMaturity = controller.minMaturitySec();
        uint256 reserved = controller.reservedPerpJrLiquidity();

        _runCase("01_baseline_first_rollover", sr, jr, minMaturity, reserved, 0);
        _runCase("02_jr_idle_zero", sr, jr, minMaturity, reserved, 1);
        _runCase("03_jr_idle_one_below_abs_floor", sr, jr, minMaturity, reserved, 2);
        _runCase("04_jr_idle_at_abs_floor", sr, jr, minMaturity, reserved, 3);
        _runCase("05_jr_idle_one_above_abs_floor", sr, jr, minMaturity, reserved, 4);
        _runCase("06_jr_idle_10m", sr, jr, minMaturity, reserved, 5);
        _runCase("07_jr_idle_1b", sr, jr, minMaturity, reserved, 6);
        _runCase("08_sr_idle_1m", sr, jr, minMaturity, reserved, 7);
        _runCase("09_sr_idle_100m", sr, jr, minMaturity, reserved, 8);
        _runCase("10_remove_matured_soon_bond_b", sr, jr, minMaturity, reserved, 9);
        _runCase("11_bond_b_seconds_604798", sr, jr, minMaturity, reserved, 10);
        _runCase("12_bond_b_seconds_exact_min_604800", sr, jr, minMaturity, reserved, 11);
        _runCase("13_bond_b_seconds_604801", sr, jr, minMaturity, reserved, 12);
        _runCase("14_bond_b_marked_mature", sr, jr, minMaturity, reserved, 13);
        _runCase("15_add_synthetic_stale_bond", sr, jr, minMaturity, reserved, 14);
        _runCase("16_add_synthetic_fresh_bond", sr, jr, minMaturity, reserved, 15);
        _runCase("17_equalize_a_balances_to_c", sr, jr, minMaturity, reserved, 16);
        _runCase("18_zero_bond_b_balances", sr, jr, minMaturity, reserved, 17);
        _runCase("19_unequal_jr_bond_b_balance", sr, jr, minMaturity, reserved, 18);
        _runCase("20_reserved_jr_liquidity_zero", sr, jr, minMaturity, 0, 0);
        _runCase("21_jr_idle_exact_free_plus_unlocked_budget", sr, jr, minMaturity, reserved, 19);
        _runCase("22_jr_idle_one_above_free_plus_unlocked_budget", sr, jr, minMaturity, reserved, 20);
    }

    function testRolloverSecondDirectFunctions() public {
        _prepareSecondRollover();
        (, IControllerRolloverProbe.ReserveData memory srController, IControllerRolloverProbe.ReserveData memory jrController)
        = controller.systemReserveState();
        _logControllerInputs("second_direct", SECOND_ROLLOVER_TS);
        _runCase(
            "second_rollover_baseline",
            _toBalancerReserve(srController),
            _toBalancerReserve(jrController),
            controller.minMaturitySec(),
            controller.reservedPerpJrLiquidity(),
            0
        );
    }

    function testAllocationRuleDiscriminatingCases() public {
        _prepareFirstRollover();
        (, IControllerRolloverProbe.ReserveData memory srController, IControllerRolloverProbe.ReserveData memory jrController)
        = controller.systemReserveState();
        IBalancerRolloverProbe.ReserveData memory sr = _toBalancerReserve(srController);
        IBalancerRolloverProbe.ReserveData memory jr = _toBalancerReserve(jrController);
        uint32 minMaturity = controller.minMaturitySec();
        uint256 reserved = controller.reservedPerpJrLiquidity();

        _runCase("allocation_A_above_C", sr, jr, minMaturity, reserved, 21);
        _runCase("allocation_A_below_C", sr, jr, minMaturity, reserved, 22);
        _runCase("allocation_partial_small_S", sr, jr, minMaturity, reserved, 23);
        _runCase("allocation_S_exact_A_gap", sr, jr, minMaturity, reserved, 24);
        _runCase("allocation_S_much_larger", sr, jr, minMaturity, reserved, 25);
        _runCase("allocation_four_fresh_partial_ascending", sr, jr, minMaturity, reserved, 26);
        _runCase("allocation_four_fresh_partial_reversed_maturities", sr, jr, minMaturity, reserved, 27);
        _runCase("allocation_zero_value_nonlatest", sr, jr, minMaturity, reserved, 28);
        _runCase("allocation_jr_idle_limited", sr, jr, minMaturity, reserved, 29);
        _runCase("allocation_odd_claim_ratio_rounding", sr, jr, minMaturity, reserved, 30);
    }

    function testRound3PriceShiftBackupCapAndStandardAllocation() public {
        assertEq(priceFeed, 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D);
        _prepareFirstRollover();
        uint256 baseline = vm.snapshotState();

        int256 lowerPrice = priceAnswer * 70 / 100;
        _runRound3PriceShiftScenario("price_minus_30_standard", lowerPrice, false);
        require(vm.revertToState(baseline), "failed to restore baseline after lower-price standard");
        baseline = vm.snapshotState();
        _runRound3PriceShiftScenario("price_minus_30_backup", lowerPrice, true);
        require(vm.revertToState(baseline), "failed to restore baseline after lower-price backup");
        baseline = vm.snapshotState();

        int256 higherPrice = priceAnswer * 130 / 100;
        _runRound3PriceShiftScenario("price_plus_30_standard", higherPrice, false);
        require(vm.revertToState(baseline), "failed to restore baseline after higher-price standard");
        baseline = vm.snapshotState();
        _runRound3PriceShiftScenario("price_plus_30_backup", higherPrice, true);
        require(vm.revertToState(baseline), "failed to restore baseline after higher-price backup");
    }

    function _runRound3PriceShiftScenario(string memory label, int256 answer, bool forceBackup) private {
        _setRound3PriceAndRefresh(label, answer);
        (, IControllerRolloverProbe.ReserveData memory srController, IControllerRolloverProbe.ReserveData memory jrController)
        = controller.systemReserveState();
        if (forceBackup) {
            uint256 targetFree = 3_000_000;
            uint256 reserved = jrController.underlyingBal > targetFree
                ? jrController.underlyingBal - targetFree
                : 0;
            vm.prank(controller.owner());
            controller.updateLiquidityThresholds(reserved, 0);
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"price_shift_backup_controls\",\"label\":\"",
                    label,
                    ",\"targetFree\":",
                    vm.toString(targetFree),
                    "}"
                )
            );
        }

        IBalancerRolloverProbe.ReserveData memory sr = _toBalancerReserve(srController);
        IBalancerRolloverProbe.ReserveData memory jr = _toBalancerReserve(jrController);
        uint256 reservedLiquidity = controller.reservedPerpJrLiquidity();
        _logRound3PriceShiftState(label, answer, sr, jr, reservedLiquidity);
        _runCase(label, sr, jr, controller.minMaturitySec(), reservedLiquidity, 0);
        _logRound3BackupCapComparison(label, sr, jr, reservedLiquidity);
        _logRound3StandardAllocationCheck(label, sr, jr, reservedLiquidity);

        _logRound3FullReserves(string.concat(label, "_before_rollover"));
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerRolloverProbe.rollover.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"actual_rollover\",\"label\":\"",
                label,
                "\",\"success\":",
                vm.toString(success),
                ",\"returnData\":\"",
                vm.toString(returnData),
                "\",\"logCount\":",
                vm.toString(logs.length),
                "}"
            )
        );
        require(success, string.concat(label, " rollover failed"));
        for (uint256 i; i < logs.length; ++i) _logRound3RawLog(label, logs[i]);
        _logRound3FullReserves(string.concat(label, "_after_rollover"));
    }

    function _setRound3PriceAndRefresh(string memory label, int256 answer) private {
        uint256 timestamp = block.timestamp;
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedRolloverProbe.latestRoundData.selector),
            abi.encode(priceRoundId, answer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedRolloverProbe.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(CONTROLLER);
        oracle.resetCache();
        oracle.cachePrice();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"price_shift_oracle\",\"label\":\"",
                label,
                "\",\"feed\":\"",
                vm.toString(priceFeed),
                "\",\"answer\":",
                vm.toString(answer),
                ",\"updatedAt\":",
                vm.toString(timestamp),
                ",\"sequencerFeed\":\"",
                vm.toString(sequencerFeed),
                "\",\"sequencerStatus\":0,\"sequencerStartedAt\":",
                vm.toString(timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0),
                ",\"gracePeriod\":",
                vm.toString(uint256(sequencerGracePeriod)),
                "}"
            )
        );
    }

    function _logRound3PriceShiftState(
        string memory label,
        int256 answer,
        IBalancerRolloverProbe.ReserveData memory sr,
        IBalancerRolloverProbe.ReserveData memory jr,
        uint256 reservedLiquidity
    ) private {
        IBalancerRolloverProbe.PerpSrRolloverState memory state =
            balancer.computePerpSrRolloverState(sr, controller.minMaturitySec(), BONDS_MANAGER);
        IControllerRolloverProbe.BondInfo memory latest = controller.latestBondInfo();
        uint256 latestValueRatio;
        for (uint256 i; i < state.freshSrTrs.length; ++i) {
            if (state.freshSrTrs[i].data.bondID == latest.bondID) {
                latestValueRatio = state.freshSrTrs[i].data.valueRatio;
                break;
            }
        }
        (uint256 free, uint256 unlocked,) =
            balancer.computePerpJrLiquidity(jr, state, reservedLiquidity);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"price_shift_inputs\",\"label\":\"",
                label,
                "\",\"rawPriceAnswer\":",
                vm.toString(answer),
                ",\"latestBondID\":\"",
                vm.toString(latest.bondID),
                "\",\"freshLatestSeniorValueRatio\":",
                vm.toString(latestValueRatio),
                ",\"totalStaleVal\":",
                vm.toString(state.totalStaleVal),
                ",\"staleUnderlyingBal\":",
                vm.toString(state.staleUnderlyingBal),
                ",\"jrReserved\":",
                vm.toString(reservedLiquidity),
                ",\"free\":",
                vm.toString(free),
                ",\"unlocked\":",
                vm.toString(unlocked),
                ",\"freshSrTrs\":",
                _trancheArraySummary(state.freshSrTrs),
                "}"
            )
        );
    }

    function _logRound3BackupCapComparison(
        string memory label,
        IBalancerRolloverProbe.ReserveData memory sr,
        IBalancerRolloverProbe.ReserveData memory jr,
        uint256 reservedLiquidity
    ) private {
        IBalancerRolloverProbe.PerpSrRolloverState memory state =
            balancer.computePerpSrRolloverState(sr, controller.minMaturitySec(), BONDS_MANAGER);
        IControllerRolloverProbe.BondInfo memory latest = controller.latestBondInfo();
        uint256 latestValueRatio;
        for (uint256 i; i < state.freshSrTrs.length; ++i) {
            if (state.freshSrTrs[i].data.bondID == latest.bondID) {
                latestValueRatio = state.freshSrTrs[i].data.valueRatio;
                break;
            }
        }
        (uint256 free,,) = balancer.computePerpJrLiquidity(jr, state, reservedLiquidity);
        uint256 twiceStale = state.totalStaleVal * 2;
        uint256 alternativeA = free < twiceStale ? free : twiceStale;
        uint256 numerator = state.totalStaleVal * 1e18;
        uint256 alternativeBFloor = numerator / latestValueRatio;
        uint256 alternativeBCeil = (numerator + latestValueRatio - 1) / latestValueRatio;
        IBalancerRolloverProbe.RolloverExecution memory backup =
            balancer.computeBackupRolloverPolicy(state, free);
        uint256 backupDepositTotal;
        bytes32 selectedBackupBondID;
        uint256 selectedBackupValueRatio;
        for (uint256 i; i < backup.freshBondDepositAmts.length; ++i) {
            backupDepositTotal += backup.freshBondDepositAmts[i].underlyingAmt;
            if (backup.freshBondDepositAmts[i].underlyingAmt != 0) {
                selectedBackupBondID = backup.freshBondDepositAmts[i].bondID;
            }
        }
        for (uint256 i; i < state.freshSrTrs.length; ++i) {
            if (state.freshSrTrs[i].data.bondID == selectedBackupBondID) {
                selectedBackupValueRatio = state.freshSrTrs[i].data.valueRatio;
                break;
            }
        }
        uint256 selectedNumerator = selectedBackupValueRatio == 0 ? 0 : numerator / selectedBackupValueRatio;
        uint256 selectedCeil = selectedBackupValueRatio == 0
            ? 0
            : (numerator + selectedBackupValueRatio - 1) / selectedBackupValueRatio;
        string memory json = string.concat(
            "OBS:{\"kind\":\"backup_cap_comparison\",\"label\":\"",
            label,
            "\",\"free\":",
            vm.toString(free),
            ",\"totalStaleVal\":",
            vm.toString(state.totalStaleVal)
        );
        json = string.concat(json, ",\"freshLatestSeniorValueRatio\":", vm.toString(latestValueRatio));
        json = string.concat(json, ",\"A_min_free_2S\":", vm.toString(alternativeA));
        json = string.concat(
            json,
            ",\"B_floor_min_free_S_over_vr\":",
            vm.toString(free < alternativeBFloor ? free : alternativeBFloor)
        );
        json = string.concat(
            json,
            ",\"B_ceil_min_free_S_over_vr\":",
            vm.toString(free < alternativeBCeil ? free : alternativeBCeil)
        );
        json = string.concat(json, ",\"selectedBackupBondID\":\"", vm.toString(selectedBackupBondID), "\"");
        json = string.concat(json, ",\"selectedBackupValueRatio\":", vm.toString(selectedBackupValueRatio));
        json = string.concat(
            json,
            ",\"B_floor_selected_ratio\":",
            vm.toString(free < selectedNumerator ? free : selectedNumerator)
        );
        json = string.concat(
            json,
            ",\"B_ceil_selected_ratio\":",
            vm.toString(free < selectedCeil ? free : selectedCeil)
        );
        json = string.concat(json, ",\"balancerBackupDeploy\":", vm.toString(backupDepositTotal));
        json = string.concat(json, ",\"backupExecution\":", _executionSummary(backup), "}");
        console2.log(json);
    }

    function _logRound3StandardAllocationCheck(
        string memory label,
        IBalancerRolloverProbe.ReserveData memory sr,
        IBalancerRolloverProbe.ReserveData memory jr,
        uint256 reservedLiquidity
    ) private {
        IBalancerRolloverProbe.PerpSrRolloverState memory state =
            balancer.computePerpSrRolloverState(sr, controller.minMaturitySec(), BONDS_MANAGER);
        (uint256 available, uint256[] memory unpaired) =
            _round3StandardAvailable(jr, state, reservedLiquidity);
        (, IBalancerRolloverProbe.RolloverExecution memory execution) =
            balancer.computeRolloverPolicy(state, unpaired, available);
        (uint256 sumFresh, uint256 averageTarget, uint256 target) = _round3AllocationTarget(state);
        (string memory predictions, bool allMatch) =
            _round3AllocationPredictions(state, execution, target);
        string memory json = string.concat(
            "OBS:{\"kind\":\"standard_allocation_check\",\"label\":\"",
            label,
            "\",\"available\":",
            vm.toString(available),
            ",\"totalStaleVal\":",
            vm.toString(state.totalStaleVal),
            ",\"sumFreshSrValues\":",
            vm.toString(sumFresh)
        );
        json = string.concat(json, ",\"averageTargetCeil\":", vm.toString(averageTarget));
        json = string.concat(json, ",\"target\":", vm.toString(target));
        json = string.concat(json, ",\"predictions\":", predictions);
        json = string.concat(json, ",\"allMatch\":", vm.toString(allMatch), "}");
        console2.log(json);
    }

    function _round3StandardAvailable(
        IBalancerRolloverProbe.ReserveData memory jr,
        IBalancerRolloverProbe.PerpSrRolloverState memory state,
        uint256 reservedLiquidity
    ) private view returns (uint256 available, uint256[] memory unpaired) {
        (uint256 free, uint256 unlocked, uint256[] memory unpaired_) =
            balancer.computePerpJrLiquidity(jr, state, reservedLiquidity);
        available = free + unlocked;
        unpaired = unpaired_;
    }

    function _round3AllocationTarget(IBalancerRolloverProbe.PerpSrRolloverState memory state)
        private
        pure
        returns (uint256 sumFresh, uint256 averageTarget, uint256 target)
    {
        uint256 count = state.freshSrTrs.length;
        for (uint256 i; i < count; ++i) sumFresh += state.freshSrTrs[i].value;
        averageTarget = count == 0 ? 0 : (state.totalStaleVal + sumFresh + count - 1) / count;
        target = averageTarget;
        for (uint256 i; i + 1 < count; ++i) {
            if (state.freshSrTrs[i].value > target) target = state.freshSrTrs[i].value;
        }
    }

    function _round3AllocationPredictions(
        IBalancerRolloverProbe.PerpSrRolloverState memory state,
        IBalancerRolloverProbe.RolloverExecution memory execution,
        uint256 target
    ) private view returns (string memory predictions, bool allMatch) {
        predictions = "[";
        allMatch = true;
        uint256 remaining = state.totalStaleVal;
        uint256 count = state.freshSrTrs.length;
        for (uint256 i; i < count; ++i) {
            uint256 topUp;
            if (i + 1 < count) {
                uint256 value = state.freshSrTrs[i].value;
                topUp = target > value ? target - value : 0;
                if (topUp > remaining) topUp = remaining;
                remaining -= topUp;
            } else {
                topUp = remaining;
            }
            uint256 ratio = state.freshSrTrs[i].data.valueRatio;
            uint256 predictedUnderlying = topUp == 0 ? 0 : (topUp * 1e18 + ratio - 1) / ratio;
            uint256 observedUnderlying =
                _round3ObservedDeposit(execution, state.freshSrTrs[i].data.bondID);
            if (predictedUnderlying != observedUnderlying) allMatch = false;
            if (i != 0) predictions = string.concat(predictions, ",");
            predictions = string.concat(
                predictions,
                "{\"bondID\":\"",
                vm.toString(state.freshSrTrs[i].data.bondID),
                "\",\"value\":",
                vm.toString(state.freshSrTrs[i].value),
                ",\"valueRatio\":",
                vm.toString(ratio),
                ",\"topUp\":",
                vm.toString(topUp),
                ",\"predictedUnderlying\":",
                vm.toString(predictedUnderlying),
                ",\"observedUnderlying\":",
                vm.toString(observedUnderlying),
                "}"
            );
        }
        predictions = string.concat(predictions, "]");
    }

    function _round3ObservedDeposit(
        IBalancerRolloverProbe.RolloverExecution memory execution,
        bytes32 bondID
    ) private pure returns (uint256) {
        for (uint256 i; i < execution.freshBondDepositAmts.length; ++i) {
            if (execution.freshBondDepositAmts[i].bondID == bondID) {
                return execution.freshBondDepositAmts[i].underlyingAmt;
            }
        }
        return 0;
    }

    function _logRound3FullReserves(string memory label) private {
        (, IControllerRolloverProbe.ReserveData memory sr, IControllerRolloverProbe.ReserveData memory jr) =
            controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round3_full_reserves\",\"label\":\"",
                label,
                "\",\"sr\":",
                _reserveSummary(_toBalancerReserve(sr)),
                ",\"jr\":",
                _reserveSummary(_toBalancerReserve(jr)),
                "}"
            )
        );
    }

    function _logRound3RawLog(string memory label, Vm.Log memory entry) private {
        string memory topics = "[";
        for (uint256 i; i < entry.topics.length; ++i) {
            if (i != 0) topics = string.concat(topics, ",");
            topics = string.concat(topics, "\"", vm.toString(entry.topics[i]), "\"");
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"actual_rollover_log\",\"label\":\"",
                label,
                "\",\"emitter\":\"",
                vm.toString(entry.emitter),
                "\",\"topics\":",
                topics,
                "],\"data\":\"",
                vm.toString(entry.data),
                "\"}"
            )
        );
    }

    function _prepareFirstRollover() private {
        vm.warp(FIRST_ROLLOVER_TS);
        _refreshOracle();
        vm.prank(controller.keeper());
        controller.upkeep();
    }

    function _prepareSecondRollover() private {
        _prepareFirstRollover();
        vm.prank(controller.keeper());
        controller.rollover();
        vm.warp(SECOND_ROLLOVER_TS);
        _refreshOracle();
        vm.prank(controller.keeper());
        controller.upkeep();
    }

    function _refreshOracle() private {
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedRolloverProbe.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, block.timestamp, block.timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt =
                block.timestamp > sequencerGracePeriod ? block.timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedRolloverProbe.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, block.timestamp, sequencerAnsweredInRound)
            );
        }
        oracle.cachePrice();
    }

    function _logControllerInputs(string memory label, uint256 timestamp) private {
        IControllerRolloverProbe.BondInfo memory latest = controller.latestBondInfo();
        (, IControllerRolloverProbe.ReserveData memory sr, IControllerRolloverProbe.ReserveData memory jr) =
            controller.systemReserveState();
        string memory json = string.concat(
            "OBS:{\"kind\":\"rollover_inputs\",\"label\":\"", label, "\",\"timestamp\":"
        );
        json = string.concat(json, vm.toString(timestamp), ",\"minMaturitySec\":");
        json = string.concat(json, vm.toString(uint256(controller.minMaturitySec())));
        json = string.concat(json, ",\"reservedPerpJrLiquidity\":");
        json = string.concat(json, vm.toString(controller.reservedPerpJrLiquidity()));
        json = string.concat(json, ",\"perpJrReservedUnderlyingAmt\":");
        json = string.concat(json, vm.toString(controller.perpJrReservedUnderlyingAmt()));
        json = string.concat(json, ",\"perpJrReservedUnderlyingPerc\":");
        json = string.concat(json, vm.toString(uint256(controller.perpJrReservedUnderlyingPerc())));
        json = string.concat(json, ",\"minCleanupVal\":");
        json = string.concat(json, vm.toString(controller.minCleanupVal()));
        console2.log(string.concat(json, "}"));

        json = string.concat("OBS:{\"kind\":\"latest_bond\",\"label\":\"", label, "\",\"manager\":\"");
        json = string.concat(json, vm.toString(latest.manager), "\",\"bondID\":\"");
        json = string.concat(json, vm.toString(latest.bondID), "\",\"srTranche\":\"");
        json = string.concat(json, vm.toString(latest.srTranche), "\",\"jrTranche\":\"");
        json = string.concat(json, vm.toString(latest.jrTranche), "\"}");
        console2.log(json);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"reserve_counts\",\"label\":\"",
                label,
                "\",\"srUnderlyingBal\":",
                vm.toString(sr.underlyingBal),
                ",\"srTrancheCount\":",
                vm.toString(sr.trancheData.length),
                ",\"jrUnderlyingBal\":",
                vm.toString(jr.underlyingBal),
                ",\"jrTrancheCount\":",
                vm.toString(jr.trancheData.length),
                "}"
            )
        );
    }

    function _toBalancerReserve(IControllerRolloverProbe.ReserveData memory reserve)
        private
        pure
        returns (IBalancerRolloverProbe.ReserveData memory)
    {
        return abi.decode(abi.encode(reserve), (IBalancerRolloverProbe.ReserveData));
    }

    function _runCase(
        string memory label,
        IBalancerRolloverProbe.ReserveData memory srBase,
        IBalancerRolloverProbe.ReserveData memory jrBase,
        uint32 minMaturity,
        uint256 reservedLiquidity,
        uint8 mutation
    ) private {
        IBalancerRolloverProbe.ReserveData memory sr = abi.decode(
            abi.encode(srBase), (IBalancerRolloverProbe.ReserveData)
        );
        IBalancerRolloverProbe.ReserveData memory jr = abi.decode(
            abi.encode(jrBase), (IBalancerRolloverProbe.ReserveData)
        );

        if (mutation == 1) jr.underlyingBal = 0;
        if (mutation == 2) jr.underlyingBal = 999_999;
        if (mutation == 3) jr.underlyingBal = 1_000_000;
        if (mutation == 4) jr.underlyingBal = 1_000_001;
        if (mutation == 5) jr.underlyingBal = 10_000_000;
        if (mutation == 6) jr.underlyingBal = 1_000_000_000;
        if (mutation == 7) sr.underlyingBal = 1_000_000;
        if (mutation == 8) sr.underlyingBal = 100_000_000;
        if (mutation == 9) {
            sr.trancheData = _removeIndex(sr.trancheData, 1);
            jr.trancheData = _removeIndex(jr.trancheData, 1);
        }
        if (mutation >= 10 && mutation <= 12) {
            uint64 secondsToMaturity = mutation == 10 ? 604_798 : mutation == 11 ? 604_800 : 604_801;
            sr.trancheData[1].data.secondsToMaturity = secondsToMaturity;
            jr.trancheData[1].data.secondsToMaturity = secondsToMaturity;
        }
        if (mutation == 13) {
            sr.trancheData[1].data.isMature = true;
            jr.trancheData[1].data.isMature = true;
        }
        if (mutation == 14) {
            sr.trancheData = _appendSynthetic(sr.trancheData, true);
            jr.trancheData = _appendSynthetic(jr.trancheData, false);
        }
        if (mutation == 15) {
            sr.trancheData = _appendSyntheticFresh(sr.trancheData, true);
            jr.trancheData = _appendSyntheticFresh(jr.trancheData, false);
        }
        if (mutation == 16) {
            sr.trancheData[0].balance = sr.trancheData[2].balance;
            jr.trancheData[0].balance = jr.trancheData[2].balance;
        }
        if (mutation == 17) {
            sr.trancheData[1].balance = 0;
            sr.trancheData[1].value = 0;
            jr.trancheData[1].balance = 0;
            jr.trancheData[1].value = 0;
        }
        if (mutation == 18) {
            jr.trancheData[1].balance /= 2;
        }
        if (mutation == 19) jr.underlyingBal = 10_288_161;
        if (mutation == 20) jr.underlyingBal = 10_288_162;
        if (mutation == 21) sr.trancheData[0].value = 60_000_000;
        if (mutation == 22) sr.trancheData[0].value = 30_000_000;
        if (mutation == 23) sr.trancheData[1].value = 1_000_000;
        if (mutation == 24) sr.trancheData[1].value = 3_253_276;
        if (mutation == 25) sr.underlyingBal = 300_000_000;
        if (mutation == 26 || mutation == 27) {
            sr.trancheData[0].value = 40_000_000;
            sr.trancheData[1].value = 15_000_000;
            sr.trancheData[2].value = 20_000_000;
            if (mutation == 27) {
                sr.trancheData[0].data.secondsToMaturity = 1_100_000;
                jr.trancheData[0].data.secondsToMaturity = 1_100_000;
                sr.trancheData[2].data.secondsToMaturity = 1_800_000;
                jr.trancheData[2].data.secondsToMaturity = 1_800_000;
            }
            bytes32 syntheticID = keccak256(abi.encode("allocation-fourth-fresh", mutation));
            sr.trancheData = _insertSyntheticFreshBeforeLatest(
                sr.trancheData, true, syntheticID, 1_500_000, 30_000_000
            );
            jr.trancheData = _insertSyntheticFreshBeforeLatest(
                jr.trancheData, false, syntheticID, 1_500_000, 30_000_000
            );
            sr.trancheData[1].value = 15_000_000;
            jr.trancheData[1].data.secondsToMaturity = sr.trancheData[1].data.secondsToMaturity;
        }
        if (mutation == 28) {
            sr.trancheData[1].value = 1_000_000;
            bytes32 syntheticID = keccak256(abi.encode("allocation-zero-nonlatest"));
            sr.trancheData = _insertSyntheticFreshBeforeLatest(
                sr.trancheData, true, syntheticID, 1_000_000, 0
            );
            jr.trancheData = _insertSyntheticFreshBeforeLatest(
                jr.trancheData, false, syntheticID, 1_000_000, 0
            );
        }
        if (mutation == 29) jr.underlyingBal = 10_000_000;
        if (mutation == 30) {
            sr.trancheData[0].balance = 3;
            sr.trancheData[0].value = 3;
            sr.trancheData[0].data.trancheSupply = 3;
            sr.trancheData[0].data.trancheClaim = 3;
            sr.trancheData[0].data.totalClaim = 7;
            sr.trancheData[0].data.valueRatio = uint64(uint256(3) * 1e18 / 7);
            sr.trancheData[1].value = 3;
            sr.trancheData[2].balance = 6;
            sr.trancheData[2].value = 6;
            sr.trancheData[2].data.trancheSupply = 6;
            sr.trancheData[2].data.trancheClaim = 6;
            sr.trancheData[2].data.totalClaim = 12;
            sr.trancheData[2].data.valueRatio = 500_000_000_000_000_000;
        }

        CaseInput memory input = CaseInput(label, sr, jr, minMaturity, reservedLiquidity);
        CaseResults memory result;
        result.plan = _callPlan(input);
        result.srState = _callState(sr, minMaturity);
        result.jrState = _callState(jr, minMaturity);
        if (result.srState.ok) {
            result.policies = _collectPolicy(jr, result.srState.state, reservedLiquidity);
        }
        _logCase(input, result);
    }

    function _callPlan(CaseInput memory input) private view returns (CallResult memory result) {
        bytes memory callData = abi.encodeWithSelector(
            IBalancerRolloverProbe.computePerpSrRolloverPlan.selector,
            input.sr,
            input.jr,
            BONDS_MANAGER,
            input.minMaturity,
            input.reservedLiquidity
        );
        bytes memory returnData;
        (result.ok, returnData) = BALANCER.staticcall(callData);
        if (result.ok) {
            result.summary =
                _executionSummary(abi.decode(returnData, (IBalancerRolloverProbe.RolloverExecution)));
        } else {
            result.summary = string.concat("{\"revert\":\"", vm.toString(returnData), "\"}");
        }
    }

    function _callState(IBalancerRolloverProbe.ReserveData memory reserve, uint32 minMaturity)
        private
        view
        returns (StateResult memory result)
    {
        bytes memory callData = abi.encodeWithSelector(
            IBalancerRolloverProbe.computePerpSrRolloverState.selector,
            reserve,
            minMaturity,
            BONDS_MANAGER
        );
        bytes memory returnData;
        (result.ok, returnData) = BALANCER.staticcall(callData);
        if (result.ok) {
            result.state = abi.decode(returnData, (IBalancerRolloverProbe.PerpSrRolloverState));
            result.summary = _rolloverStateSummary(result.state);
        } else {
            result.summary = string.concat("{\"revert\":\"", vm.toString(returnData), "\"}");
        }
    }

    function _collectPolicy(
        IBalancerRolloverProbe.ReserveData memory jr,
        IBalancerRolloverProbe.PerpSrRolloverState memory state,
        uint256 reservedLiquidity
    ) private view returns (PolicyResults memory result) {
        bytes memory callData = abi.encodeWithSelector(
            IBalancerRolloverProbe.computePerpJrLiquidity.selector, jr, state, reservedLiquidity
        );
        bytes memory returnData;
        (result.liquidity.ok, returnData) = BALANCER.staticcall(callData);
        if (!result.liquidity.ok) {
            result.liquidity.summary = string.concat("{\"revert\":\"", vm.toString(returnData), "\"}");
            return result;
        }

        (result.freeLiquidity, result.unlockedLiquidity, result.unpaired) =
            abi.decode(returnData, (uint256, uint256, uint256[]));
        result.liquidity.summary = _liquiditySummary(result);
        result.freePolicy = _callPolicy(state, result.unpaired, result.freeLiquidity);
        result.unlockedPolicy = _callPolicy(state, result.unpaired, result.unlockedLiquidity);
        result.combinedLiquidity = result.freeLiquidity + result.unlockedLiquidity;
        result.combinedPolicy = _callPolicy(state, result.unpaired, result.combinedLiquidity);
        result.freeBackup = _callBackup(state, result.freeLiquidity);
        result.unlockedBackup = _callBackup(state, result.unlockedLiquidity);
        result.combinedBackup = _callBackup(state, result.combinedLiquidity);
    }

    function _callPolicy(
        IBalancerRolloverProbe.PerpSrRolloverState memory state,
        uint256[] memory unpaired,
        uint256 underlyingAmtAvail
    ) private view returns (CallResult memory result) {
        bytes memory callData = abi.encodeWithSelector(
            IBalancerRolloverProbe.computeRolloverPolicy.selector, state, unpaired, underlyingAmtAvail
        );
        bytes memory returnData;
        (result.ok, returnData) = BALANCER.staticcall(callData);
        if (!result.ok) {
            result.summary = string.concat("{\"revert\":\"", vm.toString(returnData), "\"}");
            return result;
        }
        (uint256 amount, IBalancerRolloverProbe.RolloverExecution memory e) =
            abi.decode(returnData, (uint256, IBalancerRolloverProbe.RolloverExecution));
        result.summary = string.concat(
            "{\"underlyingAmtAvail\":", vm.toString(underlyingAmtAvail), ",\"underlyingAmtToDeploy\":"
        );
        result.summary = string.concat(result.summary, vm.toString(amount));
        result.summary = string.concat(result.summary, ",\"execution\":", _executionSummary(e), "}");
    }

    function _callBackup(
        IBalancerRolloverProbe.PerpSrRolloverState memory state,
        uint256 underlyingAmtAvail
    ) private view returns (CallResult memory result) {
        bytes memory callData = abi.encodeWithSelector(
            IBalancerRolloverProbe.computeBackupRolloverPolicy.selector, state, underlyingAmtAvail
        );
        bytes memory returnData;
        (result.ok, returnData) = BALANCER.staticcall(callData);
        if (result.ok) {
            result.summary = string.concat(
                "{\"underlyingAmtAvail\":",
                vm.toString(underlyingAmtAvail),
                ",\"execution\":",
                _executionSummary(abi.decode(returnData, (IBalancerRolloverProbe.RolloverExecution))),
                "}"
            );
        } else {
            result.summary = string.concat("{\"revert\":\"", vm.toString(returnData), "\"}");
        }
    }

    function _liquiditySummary(PolicyResults memory result) private view returns (string memory json) {
        json = string.concat("{\"freePerpJrLiquidity\":", vm.toString(result.freeLiquidity));
        json = string.concat(json, ",\"unlockedPerpJrLiquidity\":");
        json = string.concat(json, vm.toString(result.unlockedLiquidity));
        json = string.concat(json, ",\"unpairedStaleSrTrAmts\":");
        json = string.concat(json, _uintArrayJson(result.unpaired), "}");
    }

    function _logCase(CaseInput memory input, CaseResults memory result) private {
        string memory json = string.concat(
            "OBS:{\"kind\":\"balancer_case\",\"label\":\"",
            input.label,
            "\",\"timestamp\":",
            vm.toString(block.timestamp)
        );
        json = string.concat(json, ",\"minMaturitySec\":", vm.toString(uint256(input.minMaturity)));
        json = string.concat(json, ",\"reservedPerpJrLiquidity\":", vm.toString(input.reservedLiquidity));
        json = string.concat(json, ",\"input\":{\"sr\":", _reserveSummary(input.sr));
        json = string.concat(json, ",\"jr\":", _reserveSummary(input.jr));
        json = string.concat(json, "},\"calls\":{");
        json = string.concat(json, "\"computePerpSrRolloverPlan\":", _callResultJson(result.plan));
        json = string.concat(json, ",\"computePerpSrRolloverState_SR\":", _stateResultJson(result.srState));
        json = string.concat(json, ",\"computePerpSrRolloverState_JR\":", _stateResultJson(result.jrState));
        json = string.concat(json, ",\"computePerpJrLiquidity\":", _callResultJson(result.policies.liquidity));
        json = string.concat(json, ",\"computeRolloverPolicy_free\":", _callResultJson(result.policies.freePolicy));
        json = string.concat(
            json, ",\"computeRolloverPolicy_unlocked\":", _callResultJson(result.policies.unlockedPolicy)
        );
        json = string.concat(
            json, ",\"computeRolloverPolicy_combined\":", _callResultJson(result.policies.combinedPolicy)
        );
        json = string.concat(json, ",\"computeBackupRolloverPolicy_free\":");
        json = string.concat(json, _callResultJson(result.policies.freeBackup));
        json = string.concat(json, ",\"computeBackupRolloverPolicy_unlocked\":");
        json = string.concat(json, _callResultJson(result.policies.unlockedBackup));
        json = string.concat(json, ",\"computeBackupRolloverPolicy_combined\":");
        json = string.concat(json, _callResultJson(result.policies.combinedBackup), "}}");
        console2.log(json);
    }

    function _callResultJson(CallResult memory result) private view returns (string memory json) {
        json = string.concat("{\"ok\":", vm.toString(result.ok), ",\"decoded\":");
        json = string.concat(json, result.summary, "}");
    }

    function _stateResultJson(StateResult memory result) private view returns (string memory json) {
        json = string.concat("{\"ok\":", vm.toString(result.ok), ",\"decoded\":");
        json = string.concat(json, result.summary, "}");
    }

    function _reserveSummary(IBalancerRolloverProbe.ReserveData memory reserve)
        private
        view
        returns (string memory json)
    {
        json = string.concat("{\"underlyingBal\":", vm.toString(reserve.underlyingBal));
        json = string.concat(json, ",\"tranches\":[");
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, _reserveTrancheSummary(reserve.trancheData[i]));
        }
        json = string.concat(json, "]}");
    }

    function _reserveTrancheSummary(IBalancerRolloverProbe.ReserveTrancheData memory item)
        private
        view
        returns (string memory json)
    {
        json = string.concat("[\"", vm.toString(item.data.bondID));
        json = string.concat(json, "\",\"", vm.toString(item.data.tranche));
        json = string.concat(json, "\",", vm.toString(item.balance));
        json = string.concat(json, ",", vm.toString(item.value));
        json = string.concat(json, ",", vm.toString(uint256(item.data.secondsToMaturity)));
        json = string.concat(json, ",", vm.toString(item.data.isMature));
        json = string.concat(json, ",", vm.toString(item.data.isSenior));
        json = string.concat(json, ",", vm.toString(item.data.trancheSupply));
        json = string.concat(json, ",", vm.toString(item.data.trancheClaim));
        json = string.concat(json, ",", vm.toString(item.data.totalClaim));
        json = string.concat(json, ",", vm.toString(uint256(item.data.trancheRatio)));
        json = string.concat(json, ",", vm.toString(uint256(item.data.valueRatio)));
        json = string.concat(json, ",", vm.toString(item.data.underlyingOpenPrice), "]");
    }

    function _rolloverStateSummary(IBalancerRolloverProbe.PerpSrRolloverState memory state)
        private
        view
        returns (string memory)
    {
        string memory json = string.concat("{\"staleUnderlyingBal\":", vm.toString(state.staleUnderlyingBal));
        json = string.concat(json, ",\"totalStaleVal\":", vm.toString(state.totalStaleVal));
        json = string.concat(json, ",\"staleSrTrs\":", _trancheArraySummary(state.staleSrTrs));
        json = string.concat(json, ",\"freshSrTrs\":", _trancheArraySummary(state.freshSrTrs), "}");
        return json;
    }

    function _trancheArraySummary(IBalancerRolloverProbe.ReserveTrancheData[] memory tranches)
        private
        view
        returns (string memory json)
    {
        json = "[";
        for (uint256 i; i < tranches.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, _reserveTrancheSummary(tranches[i]));
        }
        json = string.concat(json, "]");
    }

    function _executionSummary(IBalancerRolloverProbe.RolloverExecution memory e)
        private
        view
        returns (string memory)
    {
        string memory json = string.concat("{\"stale\":{\"underlyingAmt\":", vm.toString(e.stale.underlyingAmt));
        json = string.concat(json, ",\"trancheAmts\":", _tokenAmountsJson(e.stale.trancheAmts), "}");
        json = string.concat(json, ",\"freshBondDepositAmts\":", _bondDepositsJson(e.freshBondDepositAmts));
        json = string.concat(json, ",\"freshSrTrAmts\":", _tokenAmountsJson(e.freshSrTrAmts));
        json = string.concat(json, ",\"underlyingValRolled\":", vm.toString(e.underlyingValRolled), "}");
        return json;
    }

    function _tokenAmountsJson(IBalancerRolloverProbe.TokenAmount[] memory amounts)
        private
        view
        returns (string memory json)
    {
        json = "[";
        for (uint256 i; i < amounts.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, "{\"token\":\"", vm.toString(amounts[i].token));
            json = string.concat(json, "\",\"amount\":", vm.toString(amounts[i].amount), "}");
        }
        json = string.concat(json, "]");
    }

    function _bondDepositsJson(IBalancerRolloverProbe.BondDepositParams[] memory deposits)
        private
        view
        returns (string memory json)
    {
        json = "[";
        for (uint256 i; i < deposits.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, "{\"bondID\":\"", vm.toString(deposits[i].bondID));
            json = string.concat(json, "\",\"underlyingAmt\":", vm.toString(deposits[i].underlyingAmt), "}");
        }
        json = string.concat(json, "]");
    }

    function _uintArrayJson(uint256[] memory values) private view returns (string memory json) {
        json = "[";
        for (uint256 i; i < values.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, vm.toString(values[i]));
        }
        json = string.concat(json, "]");
    }

    function _removeIndex(
        IBalancerRolloverProbe.ReserveTrancheData[] memory items,
        uint256 index
    ) private pure returns (IBalancerRolloverProbe.ReserveTrancheData[] memory result) {
        result = new IBalancerRolloverProbe.ReserveTrancheData[](items.length - 1);
        for (uint256 i; i < index; ++i) result[i] = items[i];
        for (uint256 i = index; i + 1 < items.length; ++i) result[i] = items[i + 1];
    }

    function _copyReserveTranche(IBalancerRolloverProbe.ReserveTrancheData memory item)
        private
        pure
        returns (IBalancerRolloverProbe.ReserveTrancheData memory)
    {
        return abi.decode(abi.encode(item), (IBalancerRolloverProbe.ReserveTrancheData));
    }

    function _insertSyntheticFreshBeforeLatest(
        IBalancerRolloverProbe.ReserveTrancheData[] memory items,
        bool isSenior,
        bytes32 bondID,
        uint64 secondsToMaturity,
        uint256 value
    ) private pure returns (IBalancerRolloverProbe.ReserveTrancheData[] memory result) {
        result = new IBalancerRolloverProbe.ReserveTrancheData[](items.length + 1);
        for (uint256 i; i + 1 < items.length; ++i) result[i] = items[i];
        IBalancerRolloverProbe.ReserveTrancheData memory item = _copyReserveTranche(items[items.length - 1]);
        item.data.bondID = bondID;
        item.data.tranche = address(uint160(isSenior ? 0x3333 : 0x4444));
        item.data.counterpart = address(uint160(isSenior ? 0x4444 : 0x3333));
        item.data.isSenior = isSenior;
        item.data.isMature = false;
        item.data.secondsToMaturity = secondsToMaturity;
        item.data.trancheRatio = 500_000_000_000_000_000;
        item.data.trancheSupply = value == 0 ? 0 : 1_000_000;
        item.data.trancheClaim = value;
        item.data.totalClaim = value * 2;
        item.data.valueRatio = 500_000_000_000_000_000;
        item.balance = value == 0 ? 0 : 1_000_000;
        item.value = value;
        result[items.length - 1] = item;
        result[items.length] = items[items.length - 1];
    }

    function _appendSynthetic(
        IBalancerRolloverProbe.ReserveTrancheData[] memory items,
        bool isSenior
    ) private pure returns (IBalancerRolloverProbe.ReserveTrancheData[] memory result) {
        result = new IBalancerRolloverProbe.ReserveTrancheData[](items.length + 1);
        for (uint256 i; i < items.length; ++i) result[i] = items[i];
        IBalancerRolloverProbe.ReserveTrancheData memory item = _copyReserveTranche(items[0]);
        item.data.bondID = keccak256(abi.encode("synthetic-stale-bond"));
        item.data.tranche = address(uint160(isSenior ? 0x1111 : 0x2222));
        item.data.counterpart = address(uint160(isSenior ? 0x2222 : 0x1111));
        item.data.isSenior = isSenior;
        item.data.isMature = false;
        item.data.secondsToMaturity = 600_000;
        item.data.trancheSupply = 1_000_000;
        item.data.trancheClaim = 1_000;
        item.data.totalClaim = 2_000;
        item.balance = 1_000_000;
        item.value = 1_000;
        result[items.length] = item;
    }

    function _appendSyntheticFresh(
        IBalancerRolloverProbe.ReserveTrancheData[] memory items,
        bool isSenior
    ) private pure returns (IBalancerRolloverProbe.ReserveTrancheData[] memory result) {
        result = new IBalancerRolloverProbe.ReserveTrancheData[](items.length + 1);
        for (uint256 i; i < items.length; ++i) result[i] = items[i];
        IBalancerRolloverProbe.ReserveTrancheData memory item =
            _copyReserveTranche(items[items.length - 1]);
        item.data.bondID = keccak256(abi.encode("synthetic-fresh-bond"));
        item.data.tranche = address(uint160(isSenior ? 0x3333 : 0x4444));
        item.data.counterpart = address(uint160(isSenior ? 0x4444 : 0x3333));
        item.data.isSenior = isSenior;
        item.data.isMature = false;
        item.data.secondsToMaturity = 2_000_000;
        item.data.trancheSupply = 0;
        item.data.trancheClaim = 0;
        item.data.totalClaim = 0;
        item.balance = 0;
        item.value = 0;
        result[items.length] = item;
    }
}
