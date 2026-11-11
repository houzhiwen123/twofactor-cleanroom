// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

library R13Types {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

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

    struct PerpSrRolloverState {
        uint256 staleUnderlyingBal;
        uint256 totalStaleVal;
        ReserveTrancheData[] staleSrTrs;
        ReserveTrancheData[] freshSrTrs;
    }

    struct RolloverExecution {
        ReserveAmounts stale;
        BondDepositParams[] freshBondDepositAmts;
        TokenAmount[] freshSrTrAmts;
        uint256 underlyingValRolled;
    }
}

interface IR13Controller {
    function availPerpJrLiquidity() external view returns (uint256);
    function issuer() external view returns (address);
    function keeper() external view returns (address);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function latestBondInfo() external view returns (R13Types.BondInfo memory);
    function minCleanupVal() external view returns (uint256);
    function minMaturitySec() external view returns (uint32);
    function owner() external view returns (address);
    function perpJr() external view returns (address);
    function perpSr() external view returns (address);
    function underlyingOracle() external view returns (address);
    function updateLiquidityThresholds(uint256 reservedAmount, uint64 reservedPercentage) external;
}

interface IR13Perp {
    function reserveData() external view returns (R13Types.ReserveData memory);
}

interface IR13Issuer {
    function bondsManager() external view returns (address);
    function issueWindowOffsetSec() external view returns (uint32);
    function lastIssueWindowTimestamp() external view returns (uint64);
    function minIssueTimeIntervalSec() external view returns (uint32);
    function owner() external view returns (address);
    function updateIssuanceTimingConfig(uint32 minIssueTimeIntervalSec, uint32 issueWindowOffsetSec) external;
}

interface IR13OracleRegistry {
    function oracleOf(address asset) external view returns (address);
}

interface IR13Oracle {
    function FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function SEQUENCER_FEED() external view returns (address);
    function cachePrice() external;
    function resetCache() external;
}

interface IR13Feed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IR13ERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IR13Balancer {
    function computeBackupRolloverPolicy(R13Types.PerpSrRolloverState memory state, uint256 underlyingAvailable)
        external
        pure
        returns (R13Types.RolloverExecution memory execution);
}

contract Round13SystemGapProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant RANDOM = address(0xBEEF);
    address private constant DISTINCT_KEEPER = address(0xCA11);
    address private constant MOCK_ORACLE = address(0xA11CE);
    uint256 private constant ISSUE_DUE_TS = 1_794_510_001;
    uint256 private constant NOOP_TS = 1_794_160_799;
    uint256 private constant FIRST_BOND_MATURITY_TS = 1_795_114_800;

    struct LazyObservation {
        bool success;
        bytes4 selector;
        uint8 status;
        uint256 actualFree;
        uint256 staleBefore;
        uint256 staleAfter;
        uint256 eventCount;
    }

    struct UpkeepObservation {
        bytes32 latestBefore;
        bytes32 latestAfter;
        bool success;
        bytes4 selector;
        uint256 eventCount;
        uint256 srUnderlyingBefore;
        uint256 srUnderlyingAfter;
        uint256 jrUnderlyingBefore;
        uint256 jrUnderlyingAfter;
        uint256 srRowsBefore;
        uint256 srRowsAfter;
        uint256 jrRowsBefore;
        uint256 jrRowsAfter;
        uint64 rebalanceBefore;
        uint64 rebalanceAfter;
    }

    IR13Controller private controller;
    IR13Oracle private oracle;
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
        controller = IR13Controller(CONTROLLER);
        oracle = IR13Oracle(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IR13Feed(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IR13Feed(sequencerFeed).latestRoundData();
        }
    }

    function testRound13UpkeepNoWork() public {
        _observeUpkeep("no_work", NOOP_TS);
    }

    function testRound13UpkeepIssueOnly() public {
        _observeUpkeep("issue_only", ISSUE_DUE_TS);
    }

    function testRound13UpkeepMaturityAndIssue() public {
        _observeUpkeep("combined_setup_issue", ISSUE_DUE_TS);
        _observeUpkeep("maturity_plus_issue", FIRST_BOND_MATURITY_TS + 1);
    }

    function testRound13UpkeepMaturityOnly() public {
        IR13Issuer issuer = IR13Issuer(controller.issuer());
        uint32 extendedInterval = issuer.minIssueTimeIntervalSec() * 8;
        uint32 offset = issuer.issueWindowOffsetSec();
        vm.prank(issuer.owner());
        issuer.updateIssuanceTimingConfig(extendedInterval, offset);

        uint256 nextIssue = ((block.timestamp - offset) / extendedInterval + 1) * extendedInterval + offset;
        if (nextIssue <= issuer.lastIssueWindowTimestamp()) nextIssue += extendedInterval;
        uint256 issueTimestamp = nextIssue + 1;
        _observeUpkeep("maturity_only_first_cleanup", issueTimestamp);

        bytes32 issuedBond = controller.latestBondInfo().bondID;
        R13Types.ReserveData memory sr = IR13Perp(controller.perpSr()).reserveData();
        uint256 secondsToMaturity;
        for (uint256 i; i < sr.trancheData.length; ++i) {
            if (sr.trancheData[i].data.bondID == issuedBond) {
                secondsToMaturity = sr.trancheData[i].data.secondsToMaturity;
                break;
            }
        }
        require(secondsToMaturity != 0, "issued bond maturity missing");
        uint256 maturityTimestamp = issueTimestamp + secondsToMaturity;
        require(maturityTimestamp < uint256(issuer.lastIssueWindowTimestamp()) + extendedInterval, "not maturity-only");
        _observeUpkeep("maturity_only", maturityTimestamp);
    }

    function testRound13LazyNoProgressToPartialBoundary() public {
        _refreshOracle(ISSUE_DUE_TS);
        uint256 amountIn = controller.minCleanupVal() + 1_000_000;
        deal(CBBTC, RANDOM, amountIn);
        vm.prank(RANDOM);
        IR13ERC20(CBBTC).approve(CONTROLLER, type(uint256).max);

        uint256 noProgressLow = 4_000_000;
        _setJrFree(type(uint256).max);
        uint256 progressHigh = controller.availPerpJrLiquidity();
        require(_probeLazy(noProgressLow, amountIn, false).status == 4, "expected no-progress endpoint");
        uint8 highStatus = _probeLazy(progressHigh, amountIn, false).status;
        require(highStatus == 1 || highStatus == 2, "expected progress endpoint");

        while (progressHigh - noProgressLow > 1) {
            uint256 mid = noProgressLow + (progressHigh - noProgressLow) / 2;
            uint8 status = _probeLazy(mid, amountIn, false).status;
            if (status == 4) noProgressLow = mid;
            else progressHigh = mid;
        }

        LazyObservation memory below = _probeLazy(noProgressLow, amountIn, true);
        LazyObservation memory at = _probeLazy(progressHigh, amountIn, true);
        console2.log(
            string.concat(
                "OBS:R13_LAZY_PROGRESS_EDGE {\"noProgressAt\":",
                vm.toString(noProgressLow),
                ",\"noProgressStatus\":",
                vm.toString(below.status),
                ",\"progressAt\":",
                vm.toString(progressHigh),
                ",\"progressStatus\":",
                vm.toString(at.status),
                ",\"amountIn\":",
                vm.toString(amountIn),
                "}"
            )
        );
    }

    function testRound13BackupRatioDecisionGrid() public view {
        uint256 lower = 390_244_000_000_000_000;
        uint256[7] memory uppers = [
            uint256(609_755_999_999_999_999),
            609_756_000_000_000_000,
            609_756_000_000_000_001,
            609_756_000_999_999_999,
            609_756_001_000_000_000,
            609_756_333_333_333_332,
            609_756_333_333_333_333
        ];
        for (uint256 i; i < uppers.length; ++i) {
            _probeBackupPair(lower, uppers[i], false);
            _probeBackupPair(lower, uppers[i], true);
        }
        _probeBackupPair(490_000_000_000_000_000, 900_000_000_000_000_000, false);
        _probeBackupPair(490_000_000_000_000_000, 900_000_000_000_000_000, true);
        _probeBackupPair(100_000_000_000_000_000, 490_000_000_000_000_000, false);
        _probeBackupPair(100_000_000_000_000_000, 490_000_000_000_000_000, true);
        _probeBackupPair(510_000_000_000_000_000, 900_000_000_000_000_000, false);
        _probeBackupPair(510_000_000_000_000_000, 900_000_000_000_000_000, true);
        _probeBackupPair(500_000_000_000_000_000, 990_000_000_000_000_000, false);
        _probeBackupPair(500_000_000_000_000_000, 990_000_000_000_000_000, true);
        _probeBackupCrossover(lower, false);
        _probeBackupCrossover(lower, true);
        _probeBackupCrossover(400_000_000_000_000_000, false);
        _probeBackupCrossover(400_000_000_000_000_000, true);
        _probeBackupCrossover(450_000_000_000_000_000, false);
        _probeBackupCrossover(450_000_000_000_000_000, true);
    }

    function testRound13BackupDerivedSelectorMatchesGrid() public view {
        uint256[6] memory lows = [
            uint256(260_000_000_000_000_000),
            300_000_000_000_000_000,
            350_000_000_000_000_000,
            400_000_000_000_000_000,
            450_000_000_000_000_000,
            490_000_000_000_000_000
        ];
        uint256[6] memory highs = [
            uint256(500_000_000_000_000_000),
            550_000_000_000_000_000,
            600_000_000_000_000_000,
            700_000_000_000_000_000,
            800_000_000_000_000_000,
            950_000_000_000_000_000
        ];
        uint256 matched;
        for (uint256 i; i < lows.length; ++i) {
            for (uint256 j; j < highs.length; ++j) {
                bytes32 expectedForward = _modelSelected(lows[i], highs[j], false);
                bytes32 expectedReversed = _modelSelected(lows[i], highs[j], true);
                require(_backupSelected(lows[i], highs[j], false) == expectedForward, "forward model mismatch");
                require(_backupSelected(lows[i], highs[j], true) == expectedReversed, "reverse model mismatch");
                matched += 2;
            }
        }
        console2.log(
            string.concat(
                "OBS:R13_BACKUP_MODEL_GRID {\"pairs\":36,\"orderings\":72,\"matched\":",
                vm.toString(matched),
                ",\"metric\":\"abs(floor(1e36/valueRatio)-2e18)\",\"tieBreak\":\"first_candidate\"}"
            )
        );
    }

    function testRound13OracleEntryMatrixAndEffects() public {
        address owner = controller.owner();
        vm.prank(owner);
        (bool keeperUpdated,) = CONTROLLER.call(abi.encodeWithSignature("updateKeeper(address)", DISTINCT_KEEPER));
        require(keeperUpdated && controller.keeper() == DISTINCT_KEEPER, "distinct keeper setup failed");

        _probeOracleEntry("set", "random", RANDOM, abi.encodeWithSignature("setUnderlyingOracle()"));
        _probeOracleEntry("set", "keeper", DISTINCT_KEEPER, abi.encodeWithSignature("setUnderlyingOracle()"));
        _probeOracleEntry("set", "owner", owner, abi.encodeWithSignature("setUnderlyingOracle()"));
        _probeOracleEntry("reset", "random", RANDOM, abi.encodeWithSignature("resetUnderlyingOracle()"));
        _probeOracleEntry("reset", "keeper", DISTINCT_KEEPER, abi.encodeWithSignature("resetUnderlyingOracle()"));
        _probeOracleEntry("reset", "owner", owner, abi.encodeWithSignature("resetUnderlyingOracle()"));

        address manager = IR13Issuer(controller.issuer()).bondsManager();
        address registryBefore = IR13OracleRegistry(manager).oracleOf(CBBTC);
        vm.mockCall(
            manager, abi.encodeWithSelector(IR13OracleRegistry.oracleOf.selector, CBBTC), abi.encode(MOCK_ORACLE)
        );
        vm.prank(owner);
        (bool setSuccess,) = CONTROLLER.call(abi.encodeWithSignature("setUnderlyingOracle()"));
        console2.log(
            string.concat(
                "OBS:R13_ORACLE_REGISTRY {\"registryBefore\":\"",
                vm.toString(registryBefore),
                "\",\"mockRegistry\":\"",
                vm.toString(MOCK_ORACLE),
                "\",\"success\":",
                vm.toString(setSuccess),
                ",\"controllerAfter\":\"",
                vm.toString(controller.underlyingOracle()),
                "\"}"
            )
        );
        vm.clearMockedCalls();
        vm.prank(owner);
        (bool resetSuccess,) = CONTROLLER.call(abi.encodeWithSignature("resetUnderlyingOracle()"));
        console2.log(
            string.concat(
                "OBS:R13_ORACLE_RESET {\"success\":",
                vm.toString(resetSuccess),
                ",\"controllerAfter\":\"",
                vm.toString(controller.underlyingOracle()),
                "\"}"
            )
        );
    }

    function _observeUpkeep(string memory label, uint256 timestamp) private {
        _refreshOracle(timestamp);
        UpkeepObservation memory observation;
        observation.latestBefore = controller.latestBondInfo().bondID;
        observation.rebalanceBefore = controller.lastRebalanceTimestampSec();
        {
            R13Types.ReserveData memory srBefore = IR13Perp(controller.perpSr()).reserveData();
            observation.srUnderlyingBefore = srBefore.underlyingBal;
            observation.srRowsBefore = srBefore.trancheData.length;
        }
        {
            R13Types.ReserveData memory jrBefore = IR13Perp(controller.perpJr()).reserveData();
            observation.jrUnderlyingBefore = jrBefore.underlyingBal;
            observation.jrRowsBefore = jrBefore.trancheData.length;
        }
        vm.recordLogs();
        vm.prank(controller.keeper());
        bytes memory returnData;
        (observation.success, returnData) = CONTROLLER.call(abi.encodeWithSignature("upkeep()"));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.selector = _selector(returnData);
        observation.eventCount = logs.length;
        observation.latestAfter = controller.latestBondInfo().bondID;
        observation.rebalanceAfter = controller.lastRebalanceTimestampSec();
        {
            R13Types.ReserveData memory srAfter = IR13Perp(controller.perpSr()).reserveData();
            observation.srUnderlyingAfter = srAfter.underlyingBal;
            observation.srRowsAfter = srAfter.trancheData.length;
        }
        {
            R13Types.ReserveData memory jrAfter = IR13Perp(controller.perpJr()).reserveData();
            observation.jrUnderlyingAfter = jrAfter.underlyingBal;
            observation.jrRowsAfter = jrAfter.trancheData.length;
        }
        _logUpkeepResult(label, timestamp, observation);
    }

    function _logUpkeepResult(string memory label, uint256 timestamp, UpkeepObservation memory observation)
        private
        view
    {
        console2.log(
            string.concat(
                "OBS:R13_UPKEEP {\"state\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(timestamp),
                ",\"success\":",
                vm.toString(observation.success),
                ",\"selector\":\"",
                vm.toString(observation.selector),
                "\",\"traceLogs\":",
                vm.toString(observation.eventCount),
                ",\"latestBefore\":\"",
                vm.toString(observation.latestBefore),
                "\",\"latestAfter\":\"",
                vm.toString(observation.latestAfter),
                "\"}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R13_UPKEEP_RESERVES {\"state\":\"",
                label,
                "\",\"srUnderlyingBefore\":",
                vm.toString(observation.srUnderlyingBefore),
                ",\"srUnderlyingAfter\":",
                vm.toString(observation.srUnderlyingAfter),
                ",\"jrUnderlyingBefore\":",
                vm.toString(observation.jrUnderlyingBefore),
                ",\"jrUnderlyingAfter\":",
                vm.toString(observation.jrUnderlyingAfter),
                ",\"srRowsBefore\":",
                vm.toString(observation.srRowsBefore),
                ",\"srRowsAfter\":",
                vm.toString(observation.srRowsAfter),
                ",\"jrRowsBefore\":",
                vm.toString(observation.jrRowsBefore),
                ",\"jrRowsAfter\":",
                vm.toString(observation.jrRowsAfter),
                ",\"lastRebalanceBefore\":",
                vm.toString(uint256(observation.rebalanceBefore)),
                ",\"lastRebalanceAfter\":",
                vm.toString(uint256(observation.rebalanceAfter)),
                "}"
            )
        );
    }

    function _probeLazy(uint256 desiredFree, uint256 amountIn, bool emitResult)
        private
        returns (LazyObservation memory observation)
    {
        _setJrFree(desiredFree);
        observation.actualFree = controller.availPerpJrLiquidity();
        observation.staleBefore = _staleSrValue();
        uint256 snapshot = vm.snapshotState();
        vm.recordLogs();
        vm.prank(RANDOM);
        bytes memory returnData;
        (observation.success, returnData) =
            CONTROLLER.call(abi.encodeWithSignature("flashMint2(uint256,uint256,uint256,uint256)", amountIn, 0, 0, 0));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        observation.staleAfter = _staleSrValue();
        observation.selector = _selector(returnData);
        observation.status = _status(observation.success, observation.staleBefore, observation.staleAfter);
        observation.eventCount = logs.length;
        if (emitResult) {
            console2.log(
                string.concat(
                    "OBS:R13_LAZY_SAMPLE {\"requestedFree\":",
                    vm.toString(desiredFree),
                    ",\"actualFree\":",
                    vm.toString(observation.actualFree),
                    ",\"success\":",
                    vm.toString(observation.success),
                    ",\"selector\":\"",
                    vm.toString(observation.selector),
                    "\",\"status\":",
                    vm.toString(observation.status),
                    ",\"staleBefore\":",
                    vm.toString(observation.staleBefore),
                    ",\"staleAfter\":",
                    vm.toString(observation.staleAfter),
                    ",\"events\":",
                    vm.toString(observation.eventCount),
                    "}"
                )
            );
        }
        require(vm.revertToState(snapshot), "lazy snapshot restore failed");
    }

    function _probeBackupPair(uint256 lower, uint256 upper, bool reversed) private view {
        bytes32 selected = _backupSelected(lower, upper, reversed);
        console2.log(
            string.concat(
                "OBS:R13_BACKUP_GRID {\"lower\":",
                vm.toString(lower),
                ",\"upper\":",
                vm.toString(upper),
                ",\"lowerDistance\":",
                vm.toString(_distanceFromHalf(lower)),
                ",\"upperDistance\":",
                vm.toString(_distanceFromHalf(upper)),
                ",\"reversed\":",
                vm.toString(reversed),
                ",\"selected\":\"",
                vm.toString(selected),
                "\",\"selectedUpper\":",
                vm.toString(selected == bytes32(uint256(2))),
                "}"
            )
        );
    }

    function _probeBackupCrossover(uint256 lower, bool reversed) private view {
        uint256 upperWins = 500_000_000_000_000_000;
        uint256 lowerWins = 900_000_000_000_000_000;
        require(_backupSelected(lower, upperWins, reversed) == bytes32(uint256(2)), "upper endpoint mismatch");
        require(_backupSelected(lower, lowerWins, reversed) == bytes32(uint256(1)), "lower endpoint mismatch");
        while (lowerWins - upperWins > 1) {
            uint256 mid = upperWins + (lowerWins - upperWins) / 2;
            if (_backupSelected(lower, mid, reversed) == bytes32(uint256(2))) upperWins = mid;
            else lowerWins = mid;
        }
        console2.log(
            string.concat(
                "OBS:R13_BACKUP_CROSSOVER {\"lower\":",
                vm.toString(lower),
                ",\"reversed\":",
                vm.toString(reversed),
                ",\"upperWinsThrough\":",
                vm.toString(upperWins),
                ",\"lowerWinsFrom\":",
                vm.toString(lowerWins),
                ",\"upperWinningDistance\":",
                vm.toString(_distanceFromHalf(upperWins)),
                ",\"lowerWinningDistance\":",
                vm.toString(_distanceFromHalf(lowerWins)),
                ",\"reciprocalMirrorFloor\":",
                vm.toString(_reciprocalMirrorFloor(lower)),
                "}"
            )
        );
    }

    function _backupSelected(uint256 lower, uint256 upper, bool reversed) private view returns (bytes32 selected) {
        R13Types.PerpSrRolloverState memory state;
        state.staleUnderlyingBal = 1_000_000;
        state.totalStaleVal = 1_000_000;
        state.staleSrTrs = new R13Types.ReserveTrancheData[](0);
        state.freshSrTrs = new R13Types.ReserveTrancheData[](2);
        state.freshSrTrs[0] = _candidate(bytes32(uint256(1)), address(0x101), uint64(lower));
        state.freshSrTrs[1] = _candidate(bytes32(uint256(2)), address(0x202), uint64(upper));
        if (reversed) {
            R13Types.ReserveTrancheData memory temp = state.freshSrTrs[0];
            state.freshSrTrs[0] = state.freshSrTrs[1];
            state.freshSrTrs[1] = temp;
        }
        R13Types.RolloverExecution memory plan = IR13Balancer(BALANCER).computeBackupRolloverPolicy(state, 3_000_000);
        selected = plan.freshBondDepositAmts[0].bondID;
    }

    function _distanceFromHalf(uint256 ratio) private pure returns (uint256) {
        uint256 half = 500_000_000_000_000_000;
        return ratio >= half ? ratio - half : half - ratio;
    }

    function _modelSelected(uint256 lower, uint256 upper, bool reversed) private pure returns (bytes32) {
        uint256 wad = 1e18;
        uint256 lowerMultiplier = wad * wad / lower;
        uint256 upperMultiplier = wad * wad / upper;
        uint256 lowerDistance = lowerMultiplier >= 2 * wad ? lowerMultiplier - 2 * wad : 2 * wad - lowerMultiplier;
        uint256 upperDistance = upperMultiplier >= 2 * wad ? upperMultiplier - 2 * wad : 2 * wad - upperMultiplier;
        if (lowerDistance < upperDistance) return bytes32(uint256(1));
        if (upperDistance < lowerDistance) return bytes32(uint256(2));
        return reversed ? bytes32(uint256(2)) : bytes32(uint256(1));
    }

    function _reciprocalMirrorFloor(uint256 lower) private pure returns (uint256) {
        uint256 wad = 1e18;
        uint256 lowerMultiplier = wad * wad / lower;
        return wad * wad / (4 * wad - lowerMultiplier);
    }

    function _candidate(bytes32 bondID, address token, uint64 valueRatio)
        private
        pure
        returns (R13Types.ReserveTrancheData memory row)
    {
        row.data.trancheSupply = 1e18;
        row.data.trancheClaim = valueRatio;
        row.data.totalClaim = 1e18;
        row.data.secondsToMaturity = 1_000_000;
        row.data.trancheRatio = 500_000_000_000_000_000;
        row.data.valueRatio = valueRatio;
        row.data.bondID = bondID;
        row.data.isSenior = true;
        row.data.tranche = token;
        row.value = uint256(valueRatio) / 1e12;
    }

    function _probeOracleEntry(string memory entry, string memory role, address caller, bytes memory callData) private {
        uint256 snapshot = vm.snapshotState();
        address beforeOracle = controller.underlyingOracle();
        vm.recordLogs();
        vm.prank(caller);
        (bool success, bytes memory returnData) = CONTROLLER.call(callData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(
            string.concat(
                "OBS:R13_ORACLE_ENTRY {\"entry\":\"",
                entry,
                "\",\"role\":\"",
                role,
                "\",\"caller\":\"",
                vm.toString(caller),
                "\",\"before\":\"",
                vm.toString(beforeOracle),
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returnData)),
                "\",\"after\":\"",
                vm.toString(controller.underlyingOracle()),
                "\",\"events\":",
                vm.toString(logs.length),
                "}"
            )
        );
        require(vm.revertToState(snapshot), "oracle snapshot restore failed");
    }

    function _refreshOracle(uint256 timestamp) private {
        vm.warp(timestamp);
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IR13Feed.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IR13Feed.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(CONTROLLER);
        oracle.resetCache();
        oracle.cachePrice();
    }

    function _setJrFree(uint256 desiredFree) private {
        uint256 jrUnderlying = IR13Perp(controller.perpJr()).reserveData().underlyingBal;
        uint256 reserved = jrUnderlying > desiredFree ? jrUnderlying - desiredFree : 0;
        vm.prank(controller.owner());
        controller.updateLiquidityThresholds(reserved, 0);
    }

    function _staleSrValue() private view returns (uint256 total) {
        R13Types.ReserveData memory sr = IR13Perp(controller.perpSr()).reserveData();
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

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }
    }
}
