// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {
    IBondIssuerProbe,
    IBondsManagerProbe,
    IControllerProbe,
    IERC20Probe,
    IOracleProbe,
    IPriceFeedProbe
} from "./ControllerProbe.t.sol";

interface IRound10ResetOracle {
    function resetCache() external;
}

interface IRound10IssuerTimingProbe {
    function owner() external view returns (address);
    function updateIssuanceTimingConfig(uint32 minIssueTimeIntervalSec, uint32 issueWindowOffsetSec) external;
}

interface IRound10BalancerProbe {
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

interface IRound10TransferToken {
    function transfer(address recipient, uint256 amount) external returns (bool);
}

contract Round10ProbeTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant RANDOM = address(0xBEEF);
    uint256 private constant ISSUE_DUE_TS = 1_794_510_001;
    uint256 private constant NOOP_TS = 1_794_160_799;
    uint256 private constant DEFAULT_REBALANCE_TS = 1_794_247_201;
    uint256 private constant FIRST_BOND_MATURITY_TS = 1_795_114_800;

    struct FundsObservation {
        string phase;
        uint256 requestedFree;
        uint256 actualFree;
        bool success;
        bytes4 selector;
        uint8 status;
        uint256 staleBefore;
        uint256 staleAfter;
        uint256 events;
    }

    IControllerProbe private controller;
    IOracleProbe private oracle;
    address private priceFeed;
    address private sequencerFeed;
    uint80 private priceRoundId;
    int256 private priceAnswer;
    uint80 private priceAnsweredInRound;
    uint80 private sequencerRoundId;
    uint80 private sequencerAnsweredInRound;
    uint32 private sequencerGracePeriod;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
        controller = IControllerProbe(CONTROLLER);
        oracle = IOracleProbe(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IPriceFeedProbe(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IPriceFeedProbe(sequencerFeed).latestRoundData();
        }
    }

    function testBCallerMatrixWorkAndNoopSnapshots() public {
        uint256 initial = vm.snapshotState();
        _refreshOracle(ISSUE_DUE_TS);
        _probeCallers("issue_due", IControllerProbe.upkeep.selector);

        require(vm.revertToState(initial), "restore issue state");
        initial = vm.snapshotState();
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        _probeCallers("rollover_work", IControllerProbe.rollover.selector);

        require(vm.revertToState(initial), "restore noop state");
        initial = vm.snapshotState();
        _refreshOracle(NOOP_TS);
        _probeCallers("noop", IControllerProbe.upkeep.selector);
        require(vm.revertToState(initial), "restore noop rollover state");
        initial = vm.snapshotState();
        _refreshOracle(NOOP_TS);
        _probeCallers("noop", IControllerProbe.rollover.selector);
    }

    function testBDefaultWindowUpkeep() public {
        uint256 timestamp = DEFAULT_REBALANCE_TS;
        _refreshOracle(timestamp);
        (uint64 windowStart, uint64 windowEnd) = controller.rebalanceWindow(timestamp);
        string memory windowContext = string.concat(
            "OBS:R10_DEFAULT_WINDOW {\"timestamp\":",
            vm.toString(timestamp),
            ",\"windowStart\":",
            vm.toString(uint256(windowStart)),
            ",\"windowEnd\":",
            vm.toString(uint256(windowEnd))
        );
        string memory windowState = string.concat(
            ",\"lastRebalance\":",
            vm.toString(uint256(controller.lastRebalanceTimestampSec())),
            ",\"frequency\":",
            vm.toString(uint256(controller.rebalanceFreqSec())),
            ",\"offset\":",
            vm.toString(uint256(controller.rebalanceWindowOffsetSec())),
            ",\"length\":",
            vm.toString(uint256(controller.rebalanceWindowLengthSec())),
            "}"
        );
        console2.log(string.concat(windowContext, windowState));
        _attempt("default_window", "upkeep", controller.keeper(), "configured_keeper");
    }

    function testBMaturedBeforeNextIssueWindow() public {
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        IRound10IssuerTimingProbe issuerTiming = IRound10IssuerTimingProbe(address(issuer));
        uint32 extendedInterval = issuer.minIssueTimeIntervalSec() * 8;
        uint32 offset = issuer.issueWindowOffsetSec();
        address issuerOwner = issuerTiming.owner();

        vm.prank(issuerOwner);
        (bool configSuccess, bytes memory configReturn) = address(issuerTiming)
            .call(abi.encodeWithSelector(issuerTiming.updateIssuanceTimingConfig.selector, extendedInterval, offset));
        bytes4 configSelector = configReturn.length >= 4 ? bytes4(configReturn) : bytes4(0);
        console2.log(
            string.concat(
                "OBS:R10_ISSUE_TIMING_CONFIG {\"owner\":\"",
                vm.toString(issuerOwner),
                "\",\"success\":",
                vm.toString(configSuccess),
                ",\"selector\":\"",
                vm.toString(configSelector),
                "\",\"interval\":",
                vm.toString(issuer.minIssueTimeIntervalSec()),
                ",\"offset\":",
                vm.toString(issuer.issueWindowOffsetSec()),
                "}"
            )
        );
        require(configSuccess, "issuer timing config rejected");

        uint256 nowTs = block.timestamp;
        uint256 nextIssueWindow = ((nowTs - offset) / extendedInterval + 1) * extendedInterval + offset;
        if (nextIssueWindow <= issuer.lastIssueWindowTimestamp()) nextIssueWindow += extendedInterval;
        uint256 issueTimestamp = nextIssueWindow + 1;
        _refreshOracle(issueTimestamp);
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool issueSuccess, bytes memory issueReturn) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        Vm.Log[] memory issueLogs = vm.getRecordedLogs();
        bytes4 issueSelector = issueReturn.length >= 4 ? bytes4(issueReturn) : bytes4(0);
        require(issueSuccess, "upkeep did not issue at configured window");

        bytes32 issuedBondID = controller.latestBondInfo().bondID;
        uint64 issueMaturity;
        bool found;
        (, IControllerProbe.ReserveData memory sr,) = controller.systemReserveState();
        for (uint256 i; i < sr.trancheData.length; ++i) {
            if (sr.trancheData[i].data.bondID == issuedBondID) {
                issueMaturity = sr.trancheData[i].data.secondsToMaturity;
                found = true;
                break;
            }
        }
        require(found && issueMaturity != 0, "new bond maturity missing");
        uint256 maturityTimestamp = issueTimestamp + issueMaturity;
        uint256 nextIssueAfterCurrent = uint256(issuer.lastIssueWindowTimestamp()) + extendedInterval;
        require(maturityTimestamp < nextIssueAfterCurrent, "maturity not before next issue");
        string memory maturitySetup = string.concat(
            "OBS:R10_MATURED_BEFORE_ISSUE_SETUP {\"issueTimestamp\":",
            vm.toString(issueTimestamp),
            ",\"issueSelector\":\"",
            vm.toString(issueSelector),
            "\",\"issueEventCount\":",
            vm.toString(issueLogs.length),
            ",\"bond\":\"",
            vm.toString(issuedBondID)
        );
        string memory maturityWindow = string.concat(
            "\",\"secondsToMaturity\":",
            vm.toString(issueMaturity),
            ",\"maturityTimestamp\":",
            vm.toString(maturityTimestamp),
            ",\"nextIssueWindow\":",
            vm.toString(nextIssueAfterCurrent),
            "}"
        );
        console2.log(string.concat(maturitySetup, maturityWindow));

        _refreshOracle(maturityTimestamp);
        bytes32 latestBefore = controller.latestBondInfo().bondID;
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool maturitySuccess, bytes memory maturityReturn) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        Vm.Log[] memory maturityLogs = vm.getRecordedLogs();
        bytes4 maturitySelector = maturityReturn.length >= 4 ? bytes4(maturityReturn) : bytes4(0);
        bytes32 latestAfter = controller.latestBondInfo().bondID;
        string memory maturityResult = string.concat(
            "OBS:R10_MATURED_BEFORE_ISSUE_RESULT {\"timestamp\":",
            vm.toString(maturityTimestamp),
            ",\"success\":",
            vm.toString(maturitySuccess),
            ",\"selector\":\"",
            vm.toString(maturitySelector),
            "\",\"eventCount\":",
            vm.toString(maturityLogs.length)
        );
        string memory latestResult = string.concat(
            ",\"latestBefore\":\"", vm.toString(latestBefore), "\",\"latestAfter\":\"", vm.toString(latestAfter), "\"}"
        );
        console2.log(string.concat(maturityResult, latestResult));
        require(maturitySuccess && latestBefore == latestAfter, "matured-before-issue upkeep mismatch");
    }

    function testBMaturityAndNextIssueAtFollowingSecond() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        _refreshOracle(FIRST_BOND_MATURITY_TS + 1);
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        console2.log(
            string.concat(
                "OBS:R10_MATURITY_NEXT_SECOND {\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"lastIssueWindow\":",
                vm.toString(issuer.lastIssueWindowTimestamp()),
                ",\"nextIssueWindow\":",
                vm.toString(uint256(issuer.lastIssueWindowTimestamp()) + issuer.minIssueTimeIntervalSec()),
                "}"
            )
        );
        _attempt("maturity_and_issue_due", "upkeep", controller.keeper(), "configured_keeper");
    }

    function testDPublicRolloverBoundaryScan() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        uint256 staleBefore = _staleSrValue();
        uint256 minCleanup = controller.minCleanupVal();
        _setJrFree(type(uint256).max);
        uint256 maxFree = controller.availPerpJrLiquidity();
        console2.log(
            string.concat(
                "OBS:R10_PUBLIC_BOUNDARY_SETUP {\"staleValue\":",
                vm.toString(staleBefore),
                ",\"minCleanup\":",
                vm.toString(minCleanup),
                ",\"maxFree\":",
                vm.toString(maxFree),
                "}"
            )
        );

        uint256[] memory samples = new uint256[](8);
        samples[0] = maxFree;
        samples[1] = maxFree * 3 / 4;
        samples[2] = maxFree / 2;
        samples[3] = maxFree / 4;
        samples[4] = minCleanup + 1;
        samples[5] = minCleanup;
        samples[6] = minCleanup == 0 ? 0 : minCleanup - 1;
        samples[7] = 0;
        for (uint256 i; i < samples.length; ++i) {
            _probeRolloverAtFree(samples[i], "coarse", true);
        }

        uint8 lowStatus = _probeRolloverAtFree(0, "binary_endpoint", false);
        uint8 highStatus = _probeRolloverAtFree(maxFree, "binary_endpoint", false);
        if (highStatus == 2) {
            uint256 low;
            uint256 high = maxFree;
            while (high - low > 1) {
                uint256 mid = low + (high - low) / 2;
                if (_probeRolloverAtFree(mid, "binary_full", false) == 2) high = mid;
                else low = mid;
            }
            console2.log(
                string.concat(
                    "OBS:R10_PUBLIC_FULL_EDGE {\"below\":",
                    vm.toString(high - 1),
                    ",\"belowStatus\":",
                    vm.toString(_probeRolloverAtFree(high - 1, "edge", false)),
                    ",\"at\":",
                    vm.toString(high),
                    ",\"atStatus\":",
                    vm.toString(_probeRolloverAtFree(high, "edge", false)),
                    "}"
                )
            );
            if (lowStatus == 0) {
                low = 0;
                uint256 successHigh = high;
                while (successHigh - low > 1) {
                    uint256 mid = low + (successHigh - low) / 2;
                    if (_probeRolloverAtFree(mid, "binary_success", false) == 0) low = mid;
                    else successHigh = mid;
                }
                console2.log(
                    string.concat(
                        "OBS:R10_PUBLIC_SUCCESS_EDGE {\"revertAt\":",
                        vm.toString(low),
                        ",\"revertSelector\":\"",
                        vm.toString(_probeRolloverSelectorAt(low)),
                        "\",\"successAt\":",
                        vm.toString(successHigh),
                        ",\"successStatus\":",
                        vm.toString(_probeRolloverAtFree(successHigh, "edge", false)),
                        "}"
                    )
                );
            }
        } else {
            if (lowStatus == 0 && highStatus == 1) {
                uint256 low;
                uint256 high = maxFree;
                while (high - low > 1) {
                    uint256 mid = low + (high - low) / 2;
                    if (_probeRolloverAtFree(mid, "binary_success", false) == 0) low = mid;
                    else high = mid;
                }
                console2.log(
                    string.concat(
                        "OBS:R10_PUBLIC_PARTIAL_EDGE {\"revertAt\":",
                        vm.toString(low),
                        ",\"selector\":\"0x",
                        vm.toString(_probeRolloverSelectorAt(low)),
                        "\",\"partialAt\":",
                        vm.toString(high),
                        ",\"status\":",
                        vm.toString(_probeRolloverAtFree(high, "edge", false)),
                        "}"
                    )
                );
            } else {
                console2.log(
                    string.concat(
                        "OBS:R10_PUBLIC_NO_FULL_EDGE {\"lowStatus\":",
                        vm.toString(lowStatus),
                        ",\"highStatus\":",
                        vm.toString(highStatus),
                        "}"
                    )
                );
            }
        }
    }

    function testDPublicRolloverTraceAtHighLiquidity() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        _setJrFree(type(uint256).max);
        uint256 highFree = controller.availPerpJrLiquidity();
        _probeRolloverAtFree(highFree, "trace_high", true);
    }

    function testDLazyFlashMint2TraceAtHighLiquidity() public {
        _refreshOracle(ISSUE_DUE_TS);
        uint256 amountIn = controller.minCleanupVal() + 1_000_000;
        deal(CBBTC, RANDOM, amountIn);
        vm.prank(RANDOM);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _setJrFree(type(uint256).max);
        _probeFlashAtFree(controller.availPerpJrLiquidity(), "trace_high", true, amountIn);
    }

    function testDLazyFlashMint2BoundaryScan() public {
        _refreshOracle(ISSUE_DUE_TS);
        uint256 amountIn = controller.minCleanupVal() + 1_000_000;
        deal(CBBTC, RANDOM, amountIn);
        vm.prank(RANDOM);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _setJrFree(type(uint256).max);
        uint256 maxFree = controller.availPerpJrLiquidity();
        uint256 staleBefore = _staleSrValue();
        console2.log(
            string.concat(
                "OBS:R10_LAZY_BOUNDARY_SETUP {\"amountIn\":",
                vm.toString(amountIn),
                ",\"minCleanup\":",
                vm.toString(controller.minCleanupVal()),
                ",\"staleValue\":",
                vm.toString(staleBefore),
                ",\"maxFree\":",
                vm.toString(maxFree),
                "}"
            )
        );

        uint256 minCleanup = controller.minCleanupVal();
        uint256[] memory samples = new uint256[](8);
        samples[0] = maxFree;
        samples[1] = maxFree * 3 / 4;
        samples[2] = maxFree / 2;
        samples[3] = maxFree / 4;
        samples[4] = minCleanup + 1;
        samples[5] = minCleanup;
        samples[6] = minCleanup == 0 ? 0 : minCleanup - 1;
        samples[7] = 0;
        for (uint256 i; i < samples.length; ++i) {
            _probeFlashAtFree(samples[i], "coarse", true, amountIn);
        }

        uint8 lowStatus = _probeFlashAtFree(0, "binary_endpoint", false, amountIn);
        uint8 highStatus = _probeFlashAtFree(maxFree, "binary_endpoint", false, amountIn);
        if (highStatus == 2) {
            _logLazyFullBoundary(maxFree, lowStatus, amountIn);
        } else {
            if (lowStatus == 0 && highStatus == 1) {
                _logLazyPartialBoundary(maxFree, amountIn);
            } else {
                console2.log(
                    string.concat(
                        "OBS:R10_LAZY_NO_FULL_EDGE {\"lowStatus\":",
                        vm.toString(lowStatus),
                        ",\"highStatus\":",
                        vm.toString(highStatus),
                        "}"
                    )
                );
            }
        }
    }

    function _logLazyFullBoundary(uint256 maxFree, uint8 lowStatus, uint256 amountIn) private {
        uint256 low;
        uint256 high = maxFree;
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_probeFlashAtFree(mid, "binary_full", false, amountIn) == 2) high = mid;
            else low = mid;
        }
        uint8 belowStatus = _probeFlashAtFree(high - 1, "edge", false, amountIn);
        uint8 atStatus = _probeFlashAtFree(high, "edge", false, amountIn);
        console2.log(
            string.concat(
                "OBS:R10_LAZY_FULL_EDGE {\"below\":",
                vm.toString(high - 1),
                ",\"belowStatus\":",
                vm.toString(belowStatus),
                ",\"at\":",
                vm.toString(high),
                ",\"atStatus\":",
                vm.toString(atStatus),
                "}"
            )
        );
        if (lowStatus == 0) _logLazySuccessBoundary(high, amountIn);
    }

    function _logLazySuccessBoundary(uint256 successHigh, uint256 amountIn) private {
        uint256 low;
        while (successHigh - low > 1) {
            uint256 mid = low + (successHigh - low) / 2;
            if (_probeFlashAtFree(mid, "binary_success", false, amountIn) == 0) low = mid;
            else successHigh = mid;
        }
        bytes4 revertSelector = _probeFlashSelectorAt(low, amountIn);
        uint8 successStatus = _probeFlashAtFree(successHigh, "edge", false, amountIn);
        console2.log(
            string.concat(
                "OBS:R10_LAZY_SUCCESS_EDGE {\"revertAt\":",
                vm.toString(low),
                ",\"revertSelector\":\"",
                vm.toString(revertSelector),
                "\",\"successAt\":",
                vm.toString(successHigh),
                ",\"successStatus\":",
                vm.toString(successStatus),
                "}"
            )
        );
    }

    function _logLazyPartialBoundary(uint256 maxFree, uint256 amountIn) private {
        uint256 low;
        uint256 high = maxFree;
        while (high - low > 1) {
            uint256 mid = low + (high - low) / 2;
            if (_probeFlashAtFree(mid, "binary_success", false, amountIn) == 0) low = mid;
            else high = mid;
        }
        bytes4 revertSelector = _probeFlashSelectorAt(low, amountIn);
        uint8 partialStatus = _probeFlashAtFree(high, "edge", false, amountIn);
        console2.log(
            string.concat(
                "OBS:R10_LAZY_PARTIAL_EDGE {\"revertAt\":",
                vm.toString(low),
                ",\"selector\":\"",
                vm.toString(revertSelector),
                "\",\"partialAt\":",
                vm.toString(high),
                ",\"status\":",
                vm.toString(partialStatus),
                "}"
            )
        );
    }

    function testDUpkeepAtMaturityBeforeIssueDue() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        _refreshOracle(FIRST_BOND_MATURITY_TS);
        _setJrFree(type(uint256).max);
        uint256 maxFree = controller.availPerpJrLiquidity();
        uint256 minCleanup = controller.minCleanupVal();
        uint256[] memory samples = new uint256[](5);
        samples[0] = maxFree;
        samples[1] = maxFree / 2;
        samples[2] = minCleanup + 1;
        samples[3] = minCleanup;
        samples[4] = minCleanup == 0 ? 0 : minCleanup - 1;
        for (uint256 i; i < samples.length; ++i) {
            _probeUpkeepAtFree(samples[i], "mature_before_issue", true);
        }
        uint8 lowStatus = _probeUpkeepAtFree(0, "binary_endpoint", false);
        uint8 highStatus = _probeUpkeepAtFree(maxFree, "binary_endpoint", false);
        if (highStatus == 2 && lowStatus == 0) {
            uint256 low;
            uint256 high = maxFree;
            while (high - low > 1) {
                uint256 mid = low + (high - low) / 2;
                if (_probeUpkeepAtFree(mid, "binary_full", false) == 2) high = mid;
                else low = mid;
            }
            console2.log(
                string.concat(
                    "OBS:R10_UPKEEP_FULL_EDGE {\"below\":",
                    vm.toString(high - 1),
                    ",\"belowStatus\":",
                    vm.toString(_probeUpkeepAtFree(high - 1, "edge", false)),
                    ",\"at\":",
                    vm.toString(high),
                    ",\"atStatus\":",
                    vm.toString(_probeUpkeepAtFree(high, "edge", false)),
                    "}"
                )
            );
            uint256 lowSuccess;
            uint256 highSuccess = high;
            while (highSuccess - lowSuccess > 1) {
                uint256 mid = lowSuccess + (highSuccess - lowSuccess) / 2;
                if (_probeUpkeepAtFree(mid, "binary_success", false) == 0) lowSuccess = mid;
                else highSuccess = mid;
            }
            console2.log(
                string.concat(
                    "OBS:R10_UPKEEP_SUCCESS_EDGE {\"revertAt\":",
                    vm.toString(lowSuccess),
                    ",\"selector\":\"",
                    vm.toString(_probeUpkeepSelectorAt(lowSuccess)),
                    "\",\"successAt\":",
                    vm.toString(highSuccess),
                    ",\"successStatus\":",
                    vm.toString(_probeUpkeepAtFree(highSuccess, "edge", false)),
                    "}"
                )
            );
        } else if (highStatus == 1 && lowStatus == 0) {
            uint256 low;
            uint256 high = maxFree;
            while (high - low > 1) {
                uint256 mid = low + (high - low) / 2;
                if (_probeUpkeepAtFree(mid, "binary_success", false) == 0) low = mid;
                else high = mid;
            }
            console2.log(
                string.concat(
                    "OBS:R10_UPKEEP_PARTIAL_EDGE {\"revertAt\":",
                    vm.toString(low),
                    ",\"selector\":\"",
                    vm.toString(_probeUpkeepSelectorAt(low)),
                    "\",\"partialAt\":",
                    vm.toString(high),
                    ",\"status\":",
                    vm.toString(_probeUpkeepAtFree(high, "edge", false)),
                    "}"
                )
            );
        } else {
            console2.log(
                string.concat(
                    "OBS:R10_UPKEEP_NO_FULL_EDGE {\"lowStatus\":",
                    vm.toString(lowStatus),
                    ",\"highStatus\":",
                    vm.toString(highStatus),
                    "}"
                )
            );
        }
    }

    function _probeCallers(string memory stateName, bytes4 selector) private {
        address keeper = controller.keeper();
        address owner = controller.owner();
        _probeCaller(stateName, selector, RANDOM, "random");
        _probeCaller(stateName, selector, keeper, "configured_keeper");
        _probeCaller(stateName, selector, owner, "owner");
    }

    function _probeCaller(string memory stateName, bytes4 selector, address caller, string memory role) private {
        uint256 snapshot = vm.snapshotState();
        string memory operation = selector == IControllerProbe.upkeep.selector ? "upkeep" : "rollover";
        _attempt(stateName, operation, caller, role);
        require(vm.revertToState(snapshot), "restore caller snapshot");
    }

    function _attempt(string memory stateName, string memory operation, address caller, string memory role) private {
        bytes memory data = keccak256(bytes(operation)) == keccak256("upkeep")
            ? abi.encodeWithSelector(IControllerProbe.upkeep.selector)
            : abi.encodeWithSelector(IControllerProbe.rollover.selector);
        vm.recordLogs();
        vm.prank(caller);
        (bool success, bytes memory returnData) = CONTROLLER.call(data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes4 resultSelector = returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        string memory callContext = string.concat(
            "OBS:R10_CALL {\"state\":\"", stateName, "\",\"operation\":\"", operation, "\",\"role\":\"", role
        );
        string memory callResult = string.concat(
            "\",\"caller\":\"",
            vm.toString(caller),
            "\",\"success\":",
            vm.toString(success),
            ",\"selector\":\"",
            vm.toString(resultSelector),
            "\",\"eventCount\":",
            vm.toString(logs.length),
            "}"
        );
        console2.log(string.concat(callContext, callResult));
    }

    function _refreshOracle(uint256 timestamp) private {
        vm.warp(timestamp);
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(CONTROLLER);
        IRound10ResetOracle(address(oracle)).resetCache();
        oracle.cachePrice();
    }

    function _setJrFree(uint256 desiredFree) private {
        (,, IControllerProbe.ReserveData memory jr) = controller.systemReserveState();
        uint256 reserved = jr.underlyingBal > desiredFree ? jr.underlyingBal - desiredFree : 0;
        vm.prank(controller.owner());
        controller.updateLiquidityThresholds(reserved, 0);
    }

    function _probeRolloverAtFree(uint256 desiredFree, string memory phase, bool emitResult)
        private
        returns (uint8 status)
    {
        _setJrFree(desiredFree);
        FundsObservation memory observation;
        observation.phase = phase;
        observation.requestedFree = desiredFree;
        observation.actualFree = controller.availPerpJrLiquidity();
        observation.staleBefore = _staleSrValue();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(controller.keeper());
        bytes memory returnData;
        (observation.success, returnData) = CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.rollover.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.staleAfter = _staleSrValue();
        observation.selector = returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        observation.status = _status(observation.success, observation.staleBefore, observation.staleAfter);
        observation.events = logs.length;
        status = observation.status;
        if (emitResult) _logFundsObservation("OBS:R10_PUBLIC_FUNDS", observation);
        require(vm.revertToState(snapshot), "restore public funds probe");
    }

    function _probeRolloverSelectorAt(uint256 desiredFree) private returns (bytes4 resultSelector) {
        _setJrFree(desiredFree);
        uint256 snapshot = vm.snapshotState();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.rollover.selector));
        resultSelector = !success && returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        require(vm.revertToState(snapshot), "restore public selector probe");
    }

    function _probeFlashAtFree(uint256 desiredFree, string memory phase, bool emitResult, uint256 amountIn)
        private
        returns (uint8 status)
    {
        _setJrFree(desiredFree);
        FundsObservation memory observation;
        observation.phase = phase;
        observation.requestedFree = desiredFree;
        observation.actualFree = controller.availPerpJrLiquidity();
        observation.staleBefore = _staleSrValue();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(RANDOM);
        bytes memory returnData;
        (observation.success, returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.flashMint2.selector, amountIn, 0, 0, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.staleAfter = _staleSrValue();
        observation.selector = returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        observation.status = _status(observation.success, observation.staleBefore, observation.staleAfter);
        observation.events = logs.length;
        status = observation.status;
        if (emitResult) _logFundsObservation("OBS:R10_LAZY_FUNDS", observation);
        require(vm.revertToState(snapshot), "restore lazy funds probe");
    }

    function _logFundsObservation(string memory label, FundsObservation memory observation) private {
        string memory context = string.concat(
            label,
            " {\"phase\":\"",
            observation.phase,
            "\",\"requestedFree\":",
            vm.toString(observation.requestedFree),
            ",\"actualFree\":",
            vm.toString(observation.actualFree)
        );
        string memory result = string.concat(
            ",\"success\":",
            vm.toString(observation.success),
            ",\"selector\":\"",
            vm.toString(observation.selector),
            "\",\"status\":",
            vm.toString(observation.status)
        );
        string memory values = string.concat(
            ",\"staleBefore\":",
            vm.toString(observation.staleBefore),
            ",\"staleAfter\":",
            vm.toString(observation.staleAfter),
            ",\"events\":",
            vm.toString(observation.events),
            "}"
        );
        console2.log(string.concat(context, result, values));
    }

    function _probeFlashSelectorAt(uint256 desiredFree, uint256 amountIn) private returns (bytes4 resultSelector) {
        _setJrFree(desiredFree);
        uint256 snapshot = vm.snapshotState();
        vm.prank(RANDOM);
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.flashMint2.selector, amountIn, 0, 0, 0));
        resultSelector = !success && returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        require(vm.revertToState(snapshot), "restore flash selector probe");
    }

    function _probeUpkeepAtFree(uint256 desiredFree, string memory phase, bool emitResult)
        private
        returns (uint8 status)
    {
        _setJrFree(desiredFree);
        FundsObservation memory observation;
        observation.phase = phase;
        observation.requestedFree = desiredFree;
        observation.actualFree = controller.availPerpJrLiquidity();
        observation.staleBefore = _staleSrValue();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(controller.keeper());
        bytes memory returnData;
        (observation.success, returnData) = CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.staleAfter = _staleSrValue();
        observation.selector = returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        observation.status = _status(observation.success, observation.staleBefore, observation.staleAfter);
        observation.events = logs.length;
        status = observation.status;
        if (emitResult) _logFundsObservation("OBS:R10_UPKEEP_FUNDS", observation);
        require(vm.revertToState(snapshot), "restore upkeep funds probe");
    }

    function _probeUpkeepSelectorAt(uint256 desiredFree) private returns (bytes4 resultSelector) {
        _setJrFree(desiredFree);
        uint256 snapshot = vm.snapshotState();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        resultSelector = !success && returnData.length >= 4 ? bytes4(returnData) : bytes4(0);
        require(vm.revertToState(snapshot), "restore upkeep selector probe");
    }

    function _staleSrValue() private view returns (uint256 total) {
        (, IControllerProbe.ReserveData memory sr,) = controller.systemReserveState();
        uint32 minMaturity = controller.minMaturitySec();
        for (uint256 i; i < sr.trancheData.length; ++i) {
            if (sr.trancheData[i].data.secondsToMaturity < minMaturity) total += sr.trancheData[i].value;
        }
    }

    function _status(bool success, uint256 beforeValue, uint256 afterValue) private pure returns (uint8) {
        if (!success) return 0;
        if (beforeValue == 0) return 3;
        if (afterValue == 0) return 2;
        if (afterValue < beforeValue) return 1;
        return 4;
    }
}

contract Round10BackupSelectionTest is Test {
    struct SelectionContext {
        IControllerProbe controller;
        IOracleProbe oracle;
        address priceFeed;
        address sequencerFeed;
        uint80 priceRoundId;
        int256 priceAnswer;
        uint80 priceAnsweredInRound;
        uint80 sequencerRoundId;
        uint80 sequencerAnsweredInRound;
    }

    address private constant R10_CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant R10_BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant R10_BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant R10_CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant R10_PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant R10_PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant R10_USER = address(0xBEEF);
    uint256 private constant NO_RATIO_MUTATION = 3;
    bytes32[3] private issuedBondIDs;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testCSelectionFromThreeRealIssuePrices() public {
        SelectionContext memory context = _selectionContext();
        uint256 basePrice = uint256(context.priceAnswer);
        _prepareThreeRealIssues(context, basePrice);
        context = _selectionContext();
        _runSelectionCases(context, basePrice);
    }

    function _prepareThreeRealIssues(SelectionContext memory context, uint256 basePrice) private {
        IControllerProbe controller = context.controller;
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((block.timestamp - offset) / interval + 1) * interval + offset;
        if (nextIssue <= block.timestamp) nextIssue += interval;
        uint256[3] memory deposits = [uint256(1_000_000), 2_000_000, 3_000_000];
        int256[3] memory issuePrices = [int256(basePrice * 80 / 100), int256(basePrice), int256(basePrice * 125 / 100)];
        bytes32[3] memory bondIDs;

        deal(R10_CBBTC, R10_USER, 6_000_000);
        vm.prank(R10_USER);
        IERC20Probe(R10_CBBTC).approve(R10_BONDS_MANAGER, type(uint256).max);
        for (uint256 i; i < 3; ++i) {
            if (i != 0) nextIssue += interval;
            bondIDs[i] = _issueSelectionBond(context, nextIssue + 1, issuePrices[i], deposits[i]);
            issuedBondIDs[i] = bondIDs[i];
        }

        (, IControllerProbe.ReserveData memory sr,) = controller.systemReserveState();
        uint256 minFreshMaturity = type(uint256).max;
        for (uint256 i; i < sr.trancheData.length; ++i) {
            for (uint256 j; j < bondIDs.length; ++j) {
                if (
                    sr.trancheData[i].data.bondID == bondIDs[j]
                        && sr.trancheData[i].data.secondsToMaturity < minFreshMaturity
                ) {
                    minFreshMaturity = sr.trancheData[i].data.secondsToMaturity;
                }
            }
        }
        require(minFreshMaturity > 1, "issued reserve rows missing");
        vm.prank(controller.owner());
        controller.updateRolloverEligibility(uint32(minFreshMaturity - 1));
        vm.prank(controller.owner());
        controller.updateMinCleanupVal(1);
        vm.prank(controller.owner());
        controller.updateLiquidityThresholds(0, 0);
        deal(R10_CBBTC, R10_PERP_JR, 10_000_000);
        string memory bondIDsJson = string.concat(
            "OBS:R10_SELECTION_ISSUANCE_SETUP {\"bondIDs\":[\"",
            vm.toString(bondIDs[0]),
            "\",\"",
            vm.toString(bondIDs[1]),
            "\",\"",
            vm.toString(bondIDs[2]),
            "\"]"
        );
        string memory issuePricesJson = string.concat(
            ",\"issuePrices\":[",
            vm.toString(uint256(issuePrices[0])),
            ",",
            vm.toString(uint256(issuePrices[1])),
            ",",
            vm.toString(uint256(issuePrices[2])),
            "]"
        );
        string memory cutoffJson =
            string.concat(",\"maturityCutoff\":", vm.toString(uint256(controller.minMaturitySec())), "}");
        console2.log(string.concat(bondIDsJson, issuePricesJson, cutoffJson));
    }

    function _issueSelectionBond(SelectionContext memory context, uint256 timestamp, int256 answer, uint256 deposit)
        private
        returns (bytes32 bondID)
    {
        vm.warp(timestamp);
        _refreshSelectionPrice(context, timestamp, answer);
        IControllerProbe controller = context.controller;
        vm.prank(controller.keeper());
        controller.upkeep();
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        bondID = info.bondID;
        IBondsManagerProbe.BondData memory bond = IBondsManagerProbe(R10_BONDS_MANAGER).bondsData(bondID);
        vm.prank(R10_USER);
        (IBondsManagerProbe.TokenAmount memory srAmount, IBondsManagerProbe.TokenAmount memory jrAmount) =
            IBondsManagerProbe(R10_BONDS_MANAGER).deposit(bondID, deposit);
        vm.prank(R10_USER);
        IRound10TransferToken(info.srTranche).transfer(R10_PERP_SR, srAmount.amount);
        vm.prank(R10_USER);
        IRound10TransferToken(info.jrTranche).transfer(R10_PERP_JR, jrAmount.amount);
        string memory issueContext = string.concat(
            "OBS:R10_REAL_ISSUE {\"timestamp\":",
            vm.toString(timestamp),
            ",\"priceAnswer\":",
            vm.toString(uint256(answer)),
            ",\"bond\":\"",
            vm.toString(bondID)
        );
        string memory issueData = string.concat(
            "\",\"openPrice\":",
            vm.toString(bond.openPrice),
            ",\"valueRatio\":",
            vm.toString(uint256(bond.srTrancheRatio)),
            ",\"deposit\":",
            vm.toString(deposit),
            "}"
        );
        console2.log(string.concat(issueContext, issueData));
    }

    function _refreshSelectionPrice(SelectionContext memory context, uint256 timestamp, int256 answer) private {
        vm.mockCall(
            context.priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(context.priceRoundId, answer, timestamp, timestamp, context.priceAnsweredInRound)
        );
        if (context.sequencerFeed != address(0)) {
            vm.mockCall(
                context.sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(
                    context.sequencerRoundId,
                    int256(0),
                    timestamp > 3600 ? timestamp - 3601 : 0,
                    timestamp,
                    context.sequencerAnsweredInRound
                )
            );
        }
        vm.prank(R10_CONTROLLER);
        IRound10ResetOracle(address(context.oracle)).resetCache();
        context.oracle.cachePrice();
    }

    function _selectionContext() private view returns (SelectionContext memory context) {
        context.controller = IControllerProbe(R10_CONTROLLER);
        context.oracle = IOracleProbe(context.controller.underlyingOracle());
        context.priceFeed = context.oracle.FEED();
        context.sequencerFeed = context.oracle.SEQUENCER_FEED();
        (context.priceRoundId, context.priceAnswer,,, context.priceAnsweredInRound) =
            IPriceFeedProbe(context.priceFeed).latestRoundData();
        if (context.sequencerFeed != address(0)) {
            (context.sequencerRoundId,,,, context.sequencerAnsweredInRound) =
                IPriceFeedProbe(context.sequencerFeed).latestRoundData();
        }
    }

    function _runSelectionCases(SelectionContext memory context, uint256 basePrice) private {
        uint256 baseline = vm.snapshotState();
        console2.log(
            string.concat(
                "OBS:R10_SELECTION_SETUP {\"threeRealIssuePrices\":[",
                vm.toString(basePrice * 80 / 100),
                ",",
                vm.toString(basePrice),
                ",",
                vm.toString(basePrice * 125 / 100),
                "],\"currentAnswer\":",
                vm.toString(basePrice),
                "}"
            )
        );

        _selectionCase(context, "base", int256(basePrice), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection base");
        baseline = vm.snapshotState();
        _selectionCase(context, "price_minus_30", int256(basePrice * 70 / 100), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection minus30");
        baseline = vm.snapshotState();
        _selectionCase(context, "price_minus_10", int256(basePrice * 90 / 100), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection minus10");
        baseline = vm.snapshotState();
        _selectionCase(context, "price_plus_10", int256(basePrice * 110 / 100), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection plus10");
        baseline = vm.snapshotState();
        _selectionCase(context, "price_plus_30", int256(basePrice * 130 / 100), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection plus30");
        baseline = vm.snapshotState();
        _selectionCase(context, "near_tie", int256(basePrice * 40 / 41), 0, 0, false, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore selection near-tie");
        baseline = vm.snapshotState();
        _selectionCase(context, "maturity_order_permuted", int256(basePrice), 0, 0, true, false, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore maturity order");
        baseline = vm.snapshotState();
        _selectionCase(context, "value_ratio_A_plus_1pct", int256(basePrice), 0, 0, false, false, 0);
        require(vm.revertToState(baseline), "restore value ratio A");
        baseline = vm.snapshotState();
        _selectionCase(context, "value_ratio_B_plus_1pct", int256(basePrice), 0, 0, false, false, 1);
        require(vm.revertToState(baseline), "restore value ratio B");
        baseline = vm.snapshotState();
        _selectionCase(context, "value_ratio_C_plus_1pct", int256(basePrice), 0, 0, false, false, 2);
        require(vm.revertToState(baseline), "restore value ratio C");
        baseline = vm.snapshotState();
        _selectionCase(
            context, "existing_balance_A_plus_1m", int256(basePrice), 1_000_000, 0, false, false, NO_RATIO_MUTATION
        );
        require(vm.revertToState(baseline), "restore balance A");
        baseline = vm.snapshotState();
        _selectionCase(
            context, "existing_balance_B_plus_1m", int256(basePrice), 1_000_000, 1, false, false, NO_RATIO_MUTATION
        );
        require(vm.revertToState(baseline), "restore balance B");
        baseline = vm.snapshotState();
        _selectionCase(
            context, "existing_balance_C_plus_1m", int256(basePrice), 1_000_000, 2, false, false, NO_RATIO_MUTATION
        );
        require(vm.revertToState(baseline), "restore balance C");
        baseline = vm.snapshotState();
        _selectionCase(context, "candidate_order_reversed", int256(basePrice), 0, 0, false, true, NO_RATIO_MUTATION);
        require(vm.revertToState(baseline), "restore reversed order");
        baseline = vm.snapshotState();
        _selectionCase(context, "near_tie_reversed", int256(basePrice * 40 / 41), 0, 0, false, true, NO_RATIO_MUTATION);
    }

    function _selectionCase(
        SelectionContext memory context,
        string memory label,
        int256 answer,
        uint256 extraDeposit,
        uint256 depositRow,
        bool permuteMaturity,
        bool reverseOrder,
        uint256 valueRatioRow
    ) private {
        IControllerProbe controller = context.controller;
        uint256 timestamp = block.timestamp;
        vm.mockCall(
            context.priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(context.priceRoundId, answer, timestamp, timestamp, context.priceAnsweredInRound)
        );
        if (context.sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > 3600 ? timestamp - 3601 : 0;
            vm.mockCall(
                context.sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(context.sequencerRoundId, int256(0), startedAt, timestamp, context.sequencerAnsweredInRound)
            );
        }
        vm.prank(R10_CONTROLLER);
        IRound10ResetOracle(address(context.oracle)).resetCache();
        context.oracle.cachePrice();

        if (extraDeposit != 0) _addReserveDeposit(controller, issuedBondIDs[depositRow], extraDeposit);
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        if (permuteMaturity && sr.trancheData.length >= 2) {
            uint64 first = sr.trancheData[0].data.secondsToMaturity;
            sr.trancheData[0].data.secondsToMaturity = sr.trancheData[1].data.secondsToMaturity;
            sr.trancheData[1].data.secondsToMaturity = first;
            uint64 jrFirst = jr.trancheData[0].data.secondsToMaturity;
            jr.trancheData[0].data.secondsToMaturity = jr.trancheData[1].data.secondsToMaturity;
            jr.trancheData[1].data.secondsToMaturity = jrFirst;
        }
        if (reverseOrder) {
            _reverse(sr.trancheData);
            _reverse(jr.trancheData);
        }
        if (valueRatioRow < 3) {
            bool found;
            for (uint256 i; i < sr.trancheData.length; ++i) {
                if (sr.trancheData[i].data.bondID == issuedBondIDs[valueRatioRow]) {
                    sr.trancheData[i].data.valueRatio += 1e16;
                    found = true;
                    break;
                }
            }
            require(found, "value-ratio candidate missing");
        }

        uint256 desiredFree = 3_000_000;
        if (jr.underlyingBal > desiredFree) {
            vm.prank(controller.owner());
            controller.updateLiquidityThresholds(jr.underlyingBal - desiredFree, 0);
        }
        IRound10BalancerProbe.ReserveData memory balancerSr =
            abi.decode(abi.encode(sr), (IRound10BalancerProbe.ReserveData));
        IRound10BalancerProbe.ReserveData memory balancerJr =
            abi.decode(abi.encode(jr), (IRound10BalancerProbe.ReserveData));
        IRound10BalancerProbe.PerpSrRolloverState memory state = IRound10BalancerProbe(R10_BALANCER)
            .computePerpSrRolloverState(balancerSr, controller.minMaturitySec(), R10_BONDS_MANAGER);
        (uint256 free,,) = IRound10BalancerProbe(R10_BALANCER)
            .computePerpJrLiquidity(balancerJr, state, controller.reservedPerpJrLiquidity());
        IRound10BalancerProbe.RolloverExecution memory backup =
            IRound10BalancerProbe(R10_BALANCER).computeBackupRolloverPolicy(state, free);
        IRound10BalancerProbe.RolloverExecution memory plan = IRound10BalancerProbe(R10_BALANCER)
            .computePerpSrRolloverPlan(
                balancerSr,
                balancerJr,
                R10_BONDS_MANAGER,
                controller.minMaturitySec(),
                controller.reservedPerpJrLiquidity()
            );
        string memory contextHead =
            string.concat("OBS:R10_PLAN_CALL_CONTEXT {\"case\":\"", label, "\",\"timestamp\":", vm.toString(timestamp));
        string memory contextMiddle = string.concat(
            ",\"bondsManager\":\"",
            vm.toString(R10_BONDS_MANAGER),
            "\",\"minMaturitySec\":",
            vm.toString(controller.minMaturitySec()),
            ",\"reservedPerpJrLiquidity\":",
            vm.toString(controller.reservedPerpJrLiquidity())
        );
        string memory contextTail = string.concat(
            ",\"jrFree\":",
            vm.toString(free),
            ",\"permuteMaturity\":",
            vm.toString(permuteMaturity),
            ",\"reverseOrder\":",
            vm.toString(reverseOrder),
            ",\"valueRatioRow\":",
            vm.toString(valueRatioRow),
            ",\"valueRatioDelta\":",
            vm.toString(valueRatioRow < 3 ? 1e16 : 0),
            "}"
        );
        console2.log(string.concat(contextHead, contextMiddle, contextTail));
        _logCandidateFeatures(label, "SR", sr);
        _logCandidateFeatures(label, "JR", jr);
        _logSelectionReturn(label, free, backup, plan);
    }

    function _addReserveDeposit(IControllerProbe controller, bytes32 bondID, uint256 amount) private {
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        uint256 srSelected;
        bool srFound;
        for (uint256 i; i < sr.trancheData.length; ++i) {
            if (sr.trancheData[i].data.bondID == bondID) {
                srSelected = i;
                srFound = true;
                break;
            }
        }
        require(srFound, "matching SR row missing");
        uint256 jrSelected;
        bool jrFound;
        for (uint256 i; i < jr.trancheData.length; ++i) {
            if (jr.trancheData[i].data.bondID == bondID) {
                jrSelected = i;
                jrFound = true;
                break;
            }
        }
        require(jrFound, "matching JR row missing");
        deal(R10_CBBTC, R10_USER, amount);
        vm.prank(R10_USER);
        IERC20Probe(R10_CBBTC).approve(R10_BONDS_MANAGER, type(uint256).max);
        vm.prank(R10_USER);
        (IBondsManagerProbe.TokenAmount memory srAmount, IBondsManagerProbe.TokenAmount memory jrAmount) =
            IBondsManagerProbe(R10_BONDS_MANAGER).deposit(bondID, amount);
        vm.prank(R10_USER);
        IRound10TransferToken(sr.trancheData[srSelected].data.tranche).transfer(R10_PERP_SR, srAmount.amount);
        vm.prank(R10_USER);
        IRound10TransferToken(jr.trancheData[jrSelected].data.tranche).transfer(R10_PERP_JR, jrAmount.amount);
    }

    function _reverse(IControllerProbe.ReserveTrancheData[] memory rows) private pure {
        for (uint256 i; i < rows.length / 2; ++i) {
            IControllerProbe.ReserveTrancheData memory temp = rows[i];
            rows[i] = rows[rows.length - 1 - i];
            rows[rows.length - 1 - i] = temp;
        }
    }

    function _logCandidateFeatures(string memory label, string memory side, IControllerProbe.ReserveData memory reserve)
        private
        view
    {
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            IControllerProbe.ReserveTrancheData memory row = reserve.trancheData[i];
            string memory prefix = string.concat(
                "OBS:R10_PLAN_INPUT {\"case\":\"", label, "\",\"side\":\"", side, "\",\"index\":", vm.toString(i)
            );
            console2.log(
                string.concat(
                    prefix,
                    ",\"bond\":\"",
                    vm.toString(row.data.bondID),
                    "\",\"valueRatio\":",
                    vm.toString(row.data.valueRatio),
                    ",\"secondsToMaturity\":",
                    vm.toString(row.data.secondsToMaturity),
                    ",\"openPrice\":",
                    vm.toString(row.data.underlyingOpenPrice),
                    "}"
                )
            );
            console2.log(
                string.concat(
                    prefix,
                    ",\"supply\":",
                    vm.toString(row.data.trancheSupply),
                    ",\"claim\":",
                    vm.toString(row.data.trancheClaim),
                    ",\"totalClaim\":",
                    vm.toString(row.data.totalClaim),
                    "}"
                )
            );
            console2.log(
                string.concat(
                    prefix,
                    ",\"volatilityMultiplier\":",
                    vm.toString(row.data.volatilityMultiplier),
                    ",\"isMature\":",
                    vm.toString(row.data.isMature),
                    ",\"trancheRatio\":",
                    vm.toString(row.data.trancheRatio),
                    ",\"isSenior\":",
                    vm.toString(row.data.isSenior),
                    "}"
                )
            );
            console2.log(
                string.concat(
                    prefix,
                    ",\"tranche\":\"",
                    vm.toString(row.data.tranche),
                    "\",\"counterpart\":\"",
                    vm.toString(row.data.counterpart),
                    "\",\"manager\":\"",
                    vm.toString(row.data.manager),
                    "\",\"balance\":",
                    vm.toString(row.balance),
                    ",\"value\":",
                    vm.toString(row.value),
                    "}"
                )
            );
        }
        console2.log(
            string.concat(
                "OBS:R10_PLAN_INPUT_HEAD {\"case\":\"",
                label,
                "\",\"side\":\"",
                side,
                "\",\"underlying\":",
                vm.toString(reserve.underlyingBal),
                "}"
            )
        );
    }

    function _logSelectionReturn(
        string memory label,
        uint256 free,
        IRound10BalancerProbe.RolloverExecution memory backup,
        IRound10BalancerProbe.RolloverExecution memory plan
    ) private view {
        console2.log(
            string.concat(
                "OBS:R10_SELECTION_RETURN {\"case\":\"",
                label,
                "\",\"free\":",
                vm.toString(free),
                ",\"backupMatchesPlan\":",
                vm.toString(keccak256(abi.encode(backup)) == keccak256(abi.encode(plan))),
                ",\"staleUnderlying\":",
                vm.toString(plan.stale.underlyingAmt),
                ",\"underlyingValRolled\":",
                vm.toString(plan.underlyingValRolled),
                "}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R10_BACKUP_RETURN {\"case\":\"",
                label,
                "\",\"staleUnderlying\":",
                vm.toString(backup.stale.underlyingAmt),
                ",\"underlyingValRolled\":",
                vm.toString(backup.underlyingValRolled),
                "}"
            )
        );
        for (uint256 i; i < backup.stale.trancheAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_BACKUP_STALE_TRANSFER {\"case\":\"",
                    label,
                    "\",\"token\":\"",
                    vm.toString(backup.stale.trancheAmts[i].token),
                    "\",\"amount\":",
                    vm.toString(backup.stale.trancheAmts[i].amount),
                    "}"
                )
            );
        }
        for (uint256 i; i < plan.stale.trancheAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_STALE_TRANSFER {\"case\":\"",
                    label,
                    "\",\"token\":\"",
                    vm.toString(plan.stale.trancheAmts[i].token),
                    "\",\"amount\":",
                    vm.toString(plan.stale.trancheAmts[i].amount),
                    "}"
                )
            );
        }
        for (uint256 i; i < backup.freshBondDepositAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_BACKUP_DEPOSIT {\"case\":\"",
                    label,
                    "\",\"bond\":\"",
                    vm.toString(backup.freshBondDepositAmts[i].bondID),
                    "\",\"amount\":",
                    vm.toString(backup.freshBondDepositAmts[i].underlyingAmt),
                    "}"
                )
            );
        }
        for (uint256 i; i < plan.freshBondDepositAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_SELECTED_DEPOSIT {\"case\":\"",
                    label,
                    "\",\"bond\":\"",
                    vm.toString(plan.freshBondDepositAmts[i].bondID),
                    "\",\"amount\":",
                    vm.toString(plan.freshBondDepositAmts[i].underlyingAmt),
                    "}"
                )
            );
        }
        for (uint256 i; i < plan.freshSrTrAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_SELECTED_SR_TRANCHE {\"case\":\"",
                    label,
                    "\",\"token\":\"",
                    vm.toString(plan.freshSrTrAmts[i].token),
                    "\",\"amount\":",
                    vm.toString(plan.freshSrTrAmts[i].amount),
                    "}"
                )
            );
        }
        for (uint256 i; i < backup.freshSrTrAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R10_BACKUP_SR_TRANCHE {\"case\":\"",
                    label,
                    "\",\"token\":\"",
                    vm.toString(backup.freshSrTrAmts[i].token),
                    "\",\"amount\":",
                    vm.toString(backup.freshSrTrAmts[i].amount),
                    "}"
                )
            );
        }
    }
}
