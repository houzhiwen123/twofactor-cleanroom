// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IControllerProbe, IFeePolicyProbe, IERC20Probe, IOracleProbe, IPriceFeedProbe} from "./ControllerProbe.t.sol";

interface IRound6Controller is IControllerProbe {
    function targetSystemRatio() external view returns (uint256);
    function targetPerpJrVM() external view returns (uint256);
    function updateDRTargets(uint256 targetSystemRatio_, uint256 targetPerpJrVM_) external;
    function updateKeeper(address keeper_) external;
    function updateRebalanceWindow(uint32 freqSec, uint32 windowOffsetSec, uint32 windowLengthSec) external;
}

interface IRound6FeePolicy is IFeePolicyProbe {
    function updateAumFeePerc(uint64 srPerc, uint64 jrPerc) external;
}

contract Round6ControllerProbe is Test {
    struct AumObservation {
        uint256 eventCount;
        uint256 srAmount;
        uint256 jrAmount;
        uint256 zeroMintTransferCount;
    }

    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant OWNER = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant RANDOM = address(0xBEEF);
    address private constant TEST_KEEPER = address(0xCA11);
    uint256 private constant WAD = 1e18;
    bytes32 private constant AUM_FEES_TOPIC = keccak256("AumFees(address,uint256)");

    IRound6Controller private controller;
    IRound6FeePolicy private feePolicy;
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
        controller = IRound6Controller(CONTROLLER);
        feePolicy = IRound6FeePolicy(FEE_POLICY);
        oracle = IOracleProbe(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IPriceFeedProbe(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IPriceFeedProbe(sequencerFeed).latestRoundData();
        }
        assertEq(block.chainid, 8453);
    }

    function testR6RebalanceRandomCaller() public {
        _setTestKeeper();
        _warpAndRefresh(_nextWindowStart(2), "auth_random");
        _call("rebalance_random", RANDOM, CONTROLLER, abi.encodeWithSelector(IControllerProbe.rebalance.selector));
    }

    function testR6RebalanceOwnerCaller() public {
        _setTestKeeper();
        _warpAndRefresh(_nextWindowStart(2), "auth_owner");
        _call("rebalance_owner", OWNER, CONTROLLER, abi.encodeWithSelector(IControllerProbe.rebalance.selector));
    }

    function testR6RebalanceConfiguredKeeperCaller() public {
        _setTestKeeper();
        _warpAndRefresh(_nextWindowStart(2), "auth_keeper");
        _call(
            "rebalance_configured_keeper",
            TEST_KEEPER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
    }

    function _setTestKeeper() private {
        _call(
            "set_distinct_keeper",
            OWNER,
            CONTROLLER,
            abi.encodeWithSelector(IRound6Controller.updateKeeper.selector, TEST_KEEPER)
        );
    }

    function testR6CooldownNextWindowStart() public {
        _probeCooldownCase(0);
    }

    function testR6CooldownNextWindowStartPlus1() public {
        _probeCooldownCase(1);
    }

    function testR6CooldownLastPlusFreqMinus1() public {
        _probeCooldownCase(2);
    }

    function testR6CooldownLastPlusFreq() public {
        _probeCooldownCase(3);
    }

    function _probeCooldownCase(uint8 probeCase) private {
        uint256 start = _nextWindowStart(2);
        (, uint64 end) = controller.rebalanceWindow(start);
        uint256 firstTimestamp = uint256(end) - 1;
        _warpAndRefresh(firstTimestamp, "cooldown_first");
        _call(
            "rebalance_at_window_end_minus_1",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        uint256 last = controller.lastRebalanceTimestampSec();
        uint256 freq = controller.rebalanceFreqSec();
        uint256 nextStart = uint256(start) + freq;
        uint256 timestamp = probeCase == 0
            ? nextStart
            : probeCase == 1 ? nextStart + 1 : probeCase == 2 ? last + freq - 1 : last + freq;
        string memory label = probeCase == 0
            ? "next_window_start"
            : probeCase == 1 ? "next_window_start_plus_1" : probeCase == 2 ? "last_plus_freq_minus_1" : "last_plus_freq";
        _logSchedule(label, last, nextStart, nextStart + 1, last + freq - 1, last + freq);
        _warpAndRefresh(timestamp, string.concat("cooldown_", label));
        _call(
            string.concat("rebalance_", label),
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
    }

    function testR6WindowStartMinus1() public {
        _probeWindowEdge("start_minus_1", 0);
    }

    function testR6WindowStart() public {
        _probeWindowEdge("start", 1);
    }

    function testR6WindowEndMinus1() public {
        _probeWindowEdge("end_minus_1", 2);
    }

    function testR6WindowEnd() public {
        _probeWindowEdge("end", 3);
    }

    function testR6WindowEndPlus1() public {
        _probeWindowEdge("end_plus_1", 4);
    }

    function testR6FlashMintSrOnlyHighJrFee() public {
        _setFeePercs(false);
        _fundUnderlying();
        _call(
            "sr_only_flashMint_jr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, 1_000_000, 0, 0, 0)
        );
    }

    function testR6FlashRedeemSrOnlyHighJrFee() public {
        _setFeePercs(false);
        _fundPerp(PERP_SR);
        _call(
            "sr_only_flashRedeem_jr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashRedeem2.selector, 1_000_000, 0, 0)
        );
    }

    function testR6RedeemSrOnlyHighJrFee() public {
        _setFeePercs(false);
        _fundPerp(PERP_SR);
        _call(
            "sr_only_redeem2_jr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.redeem2.selector, 1_000_000, 0, 0)
        );
    }

    function testR6FlashMintJrOnlyHighSrFee() public {
        _setFeePercs(true);
        _fundUnderlying();
        _call(
            "jr_only_flashMint_sr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, 0, 1_000_000, 0, 0)
        );
    }

    function testR6FlashRedeemJrOnlyHighSrFee() public {
        _setFeePercs(true);
        _fundPerp(PERP_JR);
        _call(
            "jr_only_flashRedeem_sr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashRedeem2.selector, 0, 1_000_000, 0)
        );
    }

    function testR6RedeemJrOnlyHighSrFee() public {
        _setFeePercs(true);
        _fundPerp(PERP_JR);
        _call(
            "jr_only_redeem2_sr_fee_high",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.redeem2.selector, 0, 1_000_000, 0)
        );
    }

    function testR6AumPositiveRateRoundsToZero() public {
        _probeAumFee(1);
    }

    function testR6AumZeroRate() public {
        _probeAumFee(0);
    }

    function _fundUnderlying() private {
        deal(CBBTC, RANDOM, 2_000_000);
        vm.prank(RANDOM);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
    }

    function _fundPerp(address perp) private {
        deal(perp, RANDOM, 1_000_000);
        vm.prank(RANDOM);
        IERC20Probe(perp).approve(CONTROLLER, type(uint256).max);
    }

    function testR6ValueCapPreSubExactlyWadAboveCap() public {
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 totalValue = state.perpSr.reserveValue + state.perpJr.reserveValue;
        uint256 exactTarget = state.perpJr.reserveValue * WAD / state.perpSr.reserveValue;
        _call(
            "set_target_for_exact_subDR",
            OWNER,
            CONTROLLER,
            abi.encodeWithSelector(IRound6Controller.updateDRTargets.selector, exactTarget, controller.targetPerpJrVM())
        );
        (uint256 preSub,) = controller.systemDeviations();
        _call(
            "set_value_cap_one_below_pre",
            OWNER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, totalValue - 1)
        );
        _logValueCap("exact_pre_sub", totalValue, totalValue - 1, preSub);
        deal(CBBTC, RANDOM, 1_000_000);
        vm.prank(RANDOM);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _call(
            "value_cap_pre_sub_exactly_wad_above_cap",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, 1_000, 0, 0, 0)
        );
    }

    function testR6ValueCapUnderCapPostOverCap() public {
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 totalValue = state.perpSr.reserveValue + state.perpJr.reserveValue;
        (uint256 preSub,) = controller.systemDeviations();
        _call(
            "set_value_cap_equal_pre",
            OWNER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, totalValue)
        );
        deal(CBBTC, RANDOM, 1_000_000);
        vm.prank(RANDOM);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _logValueCap("worsening_jr_input", totalValue, totalValue, preSub);
        _call(
            "value_cap_jr_worsening_post_over_cap",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, 0, 1, 0, 0)
        );
        _logValueCap("corrective_sr_input", totalValue, totalValue, preSub);
        _call(
            "value_cap_sr_corrective_post_over_cap",
            RANDOM,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, 1, 0, 0, 0)
        );
    }

    function _setShortWindow() private {
        _call(
            "set_rebalance_window_86400_64800_3600",
            OWNER,
            CONTROLLER,
            abi.encodeWithSelector(
                IRound6Controller.updateRebalanceWindow.selector, uint32(86_400), uint32(64_800), uint32(3_600)
            )
        );
    }

    function _probeWindowEdge(string memory label, uint8 edge) private {
        _setShortWindow();
        uint256 start = _nextWindowStart(2);
        (, uint64 end) = controller.rebalanceWindow(start);
        uint256 timestamp = edge == 0
            ? start - 1
            : edge == 1 ? start : edge == 2 ? uint256(end) - 1 : edge == 3 ? end : uint256(end) + 1;
        (uint64 actualStart, uint64 actualEnd) = controller.rebalanceWindow(timestamp);
        console2.log(
            string.concat(
                "OBS:R6_WINDOW {\"case\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(timestamp),
                ",\"windowStart\":",
                vm.toString(uint256(actualStart)),
                ",\"windowEnd\":",
                vm.toString(uint256(actualEnd)),
                ",\"lastRebalance\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                "}"
            )
        );
        _warpAndRefresh(timestamp, string.concat("window_", label));
        _call(
            string.concat("rebalance_window_", label),
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
    }

    function _probeAumFee(uint64 rate) private {
        _call(
            "set_aum_fee_rate",
            OWNER,
            FEE_POLICY,
            abi.encodeWithSelector(IRound6FeePolicy.updateAumFeePerc.selector, rate, rate)
        );
        uint256 srSupply = IERC20Probe(PERP_SR).totalSupply();
        uint256 jrSupply = IERC20Probe(PERP_JR).totalSupply();
        uint256 srAmount = rate == 0 ? 0 : srSupply * rate / (WAD - rate);
        uint256 jrAmount = rate == 0 ? 0 : jrSupply * rate / (WAD - rate);
        uint256 timestamp = _nextWindowStart(2);
        _warpAndRefresh(timestamp, rate == 0 ? "aum_zero_rate" : "aum_positive_rounds_zero");
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory ret) = CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.rebalance.selector));
        AumObservation memory observed = _aumObservation(vm.getRecordedLogs());
        console2.log(
            string.concat(
                "OBS:R6_AUM_INPUT {\"rate\":",
                vm.toString(uint256(rate)),
                ",\"srSupply\":",
                vm.toString(srSupply),
                ",\"jrSupply\":",
                vm.toString(jrSupply),
                ",\"expectedSrAmount\":",
                vm.toString(srAmount),
                ",\"expectedJrAmount\":",
                vm.toString(jrAmount),
                "}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R6_AUM_EVENTS {\"count\":",
                vm.toString(observed.eventCount),
                ",\"srAmount\":",
                vm.toString(observed.srAmount),
                ",\"jrAmount\":",
                vm.toString(observed.jrAmount),
                ",\"zeroMintTransferCount\":",
                vm.toString(observed.zeroMintTransferCount),
                "}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R6_AUM_CALL {\"success\":", vm.toString(success), ",\"returnData\":\"", vm.toString(ret), "\"}"
            )
        );
        assertTrue(success);
    }

    function _aumObservation(Vm.Log[] memory logs) private pure returns (AumObservation memory observed) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == CONTROLLER && logs[i].topics.length != 0 && logs[i].topics[0] == AUM_FEES_TOPIC) {
                ++observed.eventCount;
                address perp;
                uint256 amount;
                if (logs[i].topics.length > 1) {
                    perp = address(uint160(uint256(logs[i].topics[1])));
                    amount = abi.decode(logs[i].data, (uint256));
                } else {
                    (perp, amount) = abi.decode(logs[i].data, (address, uint256));
                }
                if (perp == PERP_SR) observed.srAmount = amount;
                if (perp == PERP_JR) observed.jrAmount = amount;
            }
            if (
                (logs[i].emitter == PERP_SR || logs[i].emitter == PERP_JR) && logs[i].topics.length == 3
                    && logs[i].topics[0] == transferTopic && address(uint160(uint256(logs[i].topics[1]))) == address(0)
            ) {
                ++observed.zeroMintTransferCount;
            }
        }
    }

    function _setFeePercs(bool srHigh) private {
        IFeePolicyProbe.PerpFeeParams memory sr = feePolicy.perpSrFees();
        IFeePolicyProbe.PerpFeeParams memory jr = feePolicy.perpJrFees();
        sr = _zeroFeeCurves(sr);
        jr = _zeroFeeCurves(jr);
        sr.basePerc = srHigh ? uint64(WAD) : 0;
        sr.flashBasePerc = srHigh ? uint64(WAD) : 0;
        jr.basePerc = srHigh ? 0 : uint64(WAD);
        jr.flashBasePerc = srHigh ? 0 : uint64(WAD);
        _call(
            "set_zero_input_side_fee_to_wad",
            OWNER,
            FEE_POLICY,
            abi.encodeWithSelector(IFeePolicyProbe.updateFeeParams.selector, sr, jr)
        );
        console2.log(
            string.concat(
                "OBS:R6_FEE_SETTINGS {\"srBase\":",
                vm.toString(uint256(sr.basePerc)),
                ",\"srFlashBase\":",
                vm.toString(uint256(sr.flashBasePerc)),
                ",\"jrBase\":",
                vm.toString(uint256(jr.basePerc)),
                ",\"jrFlashBase\":",
                vm.toString(uint256(jr.flashBasePerc)),
                "}"
            )
        );
    }

    function _zeroFeeCurves(IFeePolicyProbe.PerpFeeParams memory p)
        private
        pure
        returns (IFeePolicyProbe.PerpFeeParams memory)
    {
        p.subDRUp = _zeroCurve(p.subDRUp);
        p.subDRDown = _zeroCurve(p.subDRDown);
        p.vmDRUp = _zeroCurve(p.vmDRUp);
        p.vmDRDown = _zeroCurve(p.vmDRDown);
        return p;
    }

    function _zeroCurve(IFeePolicyProbe.Curve memory c) private pure returns (IFeePolicyProbe.Curve memory) {
        c.p1.y = 0;
        c.p2.y = 0;
        c.p3.y = 0;
        c.p4.y = 0;
        return c;
    }

    function _nextWindowStart(uint256 windowsAhead) private view returns (uint256 start) {
        uint256 freq = controller.rebalanceFreqSec();
        uint256 base = block.timestamp + windowsAhead * freq;
        uint256 last = uint256(controller.lastRebalanceTimestampSec()) + windowsAhead * freq;
        if (base < last) base = last;
        (uint64 windowStart,) = controller.rebalanceWindow(base);
        start = windowStart;
        while (start < uint256(controller.lastRebalanceTimestampSec()) + freq) start += freq;
    }

    function _warpAndRefresh(uint256 timestamp, string memory label) private {
        vm.warp(timestamp);
        uint256 nowTs = block.timestamp;
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, nowTs, nowTs, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = nowTs > sequencerGracePeriod ? nowTs - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, nowTs, sequencerAnsweredInRound)
            );
        }
        _call(
            string.concat("refresh_oracle_", label),
            RANDOM,
            address(oracle),
            abi.encodeWithSelector(IOracleProbe.cachePrice.selector)
        );
        console2.log(
            string.concat(
                "OBS:R6_TIME {\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(nowTs),
                ",\"lastRebalance\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                "}"
            )
        );
    }

    function _call(string memory label, address caller, address target, bytes memory data)
        private
        returns (bool success, bytes memory ret)
    {
        vm.prank(caller);
        (success, ret) = target.call(data);
        console2.log(
            string.concat(
                "OBS:R6_CALL {\"label\":\"",
                label,
                "\",\"caller\":\"",
                vm.toString(caller),
                "\",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"calldata\":\"",
                vm.toString(data),
                "\",\"success\":",
                vm.toString(success),
                ",\"returnData\":\"",
                vm.toString(ret),
                "\"}"
            )
        );
    }

    function _logSchedule(
        string memory label,
        uint256 last,
        uint256 nextStart,
        uint256 nextStartPlus1,
        uint256 lastPlusFreqMinus1,
        uint256 lastPlusFreq
    ) private view {
        console2.log(
            string.concat(
                "OBS:R6_COOLDOWN {\"label\":\"",
                label,
                "\",\"last\":",
                vm.toString(last),
                ",\"freq\":",
                vm.toString(uint256(controller.rebalanceFreqSec())),
                ",\"nextStart\":",
                vm.toString(nextStart),
                ",\"nextStartPlus1\":",
                vm.toString(nextStartPlus1),
                ",\"lastPlusFreqMinus1\":",
                vm.toString(lastPlusFreqMinus1),
                ",\"lastPlusFreq\":",
                vm.toString(lastPlusFreq),
                "}"
            )
        );
    }

    function _logValueCap(string memory label, uint256 preValue, uint256 cap, uint256 subDR) private view {
        console2.log(
            string.concat(
                "OBS:R6_VALUE_CAP {\"label\":\"",
                label,
                "\",\"preTotalValue\":",
                vm.toString(preValue),
                ",\"valueCap\":",
                vm.toString(cap),
                ",\"preSubDR\":",
                vm.toString(subDR),
                "}"
            )
        );
    }
}
