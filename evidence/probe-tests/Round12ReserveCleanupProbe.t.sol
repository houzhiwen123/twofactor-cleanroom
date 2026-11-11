// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {
    IBondIssuerProbe,
    IBondsManagerProbe,
    IControllerProbe,
    IERC20Probe,
    IOracleProbe,
    IPriceFeedProbe
} from "./ControllerProbe.t.sol";

struct R12TokenAmount {
    address token;
    uint256 amount;
}

struct R12ReserveAmounts {
    uint256 underlyingAmt;
    R12TokenAmount[] trancheAmts;
}

struct R12ReserveTokens {
    uint256 underlyingBal;
    R12TokenAmount[] trancheTokens;
}

interface IR12Perp {
    function reserves() external view returns (R12ReserveTokens memory);
    function recover() external;
    function transferReservesTo(address to, R12ReserveAmounts calldata amounts) external;
    function handleTransferReservesIn(R12ReserveAmounts calldata amounts) external;
}

interface IR12ERC20 is IERC20Probe {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IR12ResetOracle {
    function resetCache() external;
}

interface IR12IssuerTiming {
    function owner() external view returns (address);
    function updateIssuanceTimingConfig(uint32 minIssueTimeIntervalSec, uint32 issueWindowOffsetSec) external;
}

interface IR12TrancheIdentity {
    function bondID() external view returns (bytes32);
    function manager() external view returns (address);
}

interface IR12MaturityManager {
    function bondsData(bytes32 bondID) external view returns (IBondsManagerProbe.BondData memory);
    function tryMature(bytes32 bondID) external returns (bool);
}

contract Round12ReserveCleanupProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant USER = address(0xBEEF);
    address private constant RECIPIENT = address(0xCAFE);
    uint256 private constant ISSUE_DUE_TS = 1_794_510_001;

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

    function testRound12PublicRolloverReserveArrays() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        _setJrFree(type(uint256).max);

        _logBoth("public_rollover_before");
        vm.recordLogs();
        vm.prank(controller.keeper());
        controller.rollover();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _logBoth("public_rollover_after");
        console2.log("OBS:R12_PUBLIC_ROLLOVER_EVENT_COUNT", logs.length);
    }

    function testRound12MaturityUpkeepReserveArrays() public {
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        IR12IssuerTiming issuerTiming = IR12IssuerTiming(address(issuer));
        uint32 extendedInterval = issuer.minIssueTimeIntervalSec() * 8;
        uint32 offset = issuer.issueWindowOffsetSec();

        vm.prank(issuerTiming.owner());
        issuerTiming.updateIssuanceTimingConfig(extendedInterval, offset);

        uint256 nextIssueWindow = ((block.timestamp - offset) / extendedInterval + 1) * extendedInterval + offset;
        if (nextIssueWindow <= issuer.lastIssueWindowTimestamp()) nextIssueWindow += extendedInterval;
        uint256 issueTimestamp = nextIssueWindow + 1;
        _refreshOracle(issueTimestamp);
        vm.prank(controller.keeper());
        controller.upkeep();

        IControllerProbe.BondInfo memory issued = controller.latestBondInfo();
        uint256 maturityTimestamp = IBondsManagerProbe(issued.manager).bondsData(issued.bondID).maturityDate;
        require(
            maturityTimestamp < uint256(issuer.lastIssueWindowTimestamp()) + extendedInterval, "issue overlaps maturity"
        );

        _refreshOracle(maturityTimestamp);
        _logBoth("maturity_upkeep_before");
        vm.recordLogs();
        vm.prank(controller.keeper());
        controller.upkeep();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _logBoth("maturity_upkeep_after");
        console2.log("OBS:R12_MATURITY_UPKEEP_EVENT_COUNT", logs.length);
    }

    function testRound12TransferFullBalanceUsesSwapPop() public {
        R12ReserveTokens memory beforeReserves = IR12Perp(PERP_SR).reserves();
        require(beforeReserves.trancheTokens.length >= 3, "need three target reserves");
        uint256 removedIndex = 1;
        R12TokenAmount memory removed = beforeReserves.trancheTokens[removedIndex];
        address lastToken = beforeReserves.trancheTokens[beforeReserves.trancheTokens.length - 1].token;

        _logReserves("full_transfer_before", "sr", PERP_SR);
        _transferOne(PERP_SR, removed.token, removed.amount, RECIPIENT);
        _logReserves("full_transfer_after", "sr", PERP_SR);

        R12ReserveTokens memory afterReserves = IR12Perp(PERP_SR).reserves();
        assertEq(afterReserves.trancheTokens.length, beforeReserves.trancheTokens.length - 1);
        assertFalse(_contains(afterReserves, removed.token));
        assertEq(afterReserves.trancheTokens[removedIndex].token, lastToken);
        assertEq(IR12ERC20(removed.token).balanceOf(RECIPIENT), removed.amount);
    }

    function testRound12ZeroTransferRemovesZeroBalanceRegistration() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        address zeroSr = controller.latestBondInfo().srTranche;
        R12ReserveTokens memory beforeReserves = IR12Perp(PERP_SR).reserves();
        require(_contains(beforeReserves, zeroSr), "new tranche not registered");
        assertEq(IR12ERC20(zeroSr).balanceOf(PERP_SR), 0);

        _logReserves("zero_transfer_before", "sr", PERP_SR);
        _transferOne(PERP_SR, zeroSr, 0, RECIPIENT);
        _logReserves("zero_transfer_after", "sr", PERP_SR);

        R12ReserveTokens memory afterReserves = IR12Perp(PERP_SR).reserves();
        assertEq(afterReserves.trancheTokens.length, beforeReserves.trancheTokens.length - 1);
        assertFalse(_contains(afterReserves, zeroSr));
    }

    function testRound12HandleTransferPairsAndRecovers() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        IControllerProbe.BondInfo memory latest = controller.latestBondInfo();

        deal(CBBTC, USER, 1_000);
        vm.prank(USER);
        IR12ERC20(CBBTC).approve(latest.manager, type(uint256).max);
        vm.prank(USER);
        (IBondsManagerProbe.TokenAmount memory sr, IBondsManagerProbe.TokenAmount memory jr) =
            IBondsManagerProbe(latest.manager).deposit(latest.bondID, 1_000);
        vm.prank(USER);
        IR12ERC20(sr.token).transfer(PERP_JR, sr.amount);
        vm.prank(USER);
        IR12ERC20(jr.token).transfer(PERP_JR, jr.amount);

        uint256 underlyingBefore = IR12ERC20(CBBTC).balanceOf(PERP_JR);
        _logReserves("handle_in_before", "jr", PERP_JR);
        R12TokenAmount[] memory tranches = new R12TokenAmount[](1);
        tranches[0] = R12TokenAmount(sr.token, sr.amount);
        R12ReserveAmounts memory amounts = R12ReserveAmounts(0, tranches);
        vm.prank(CONTROLLER);
        IR12Perp(PERP_JR).handleTransferReservesIn(amounts);
        _logReserves("handle_in_after", "jr", PERP_JR);

        uint256 underlyingAfter = IR12ERC20(CBBTC).balanceOf(PERP_JR);
        R12ReserveTokens memory afterReserves = IR12Perp(PERP_JR).reserves();
        console2.log("OBS:R12_HANDLE_UNDERLYING_DELTA", underlyingAfter - underlyingBefore);
        assertGt(underlyingAfter, underlyingBefore);
        assertEq(IR12ERC20(sr.token).balanceOf(PERP_JR), 0);
        assertEq(IR12ERC20(jr.token).balanceOf(PERP_JR), 0);
        assertFalse(_contains(afterReserves, sr.token));
        assertFalse(_contains(afterReserves, jr.token));
    }

    function testRound12HandleOneSidedTransferRegisters() public {
        _refreshOracle(ISSUE_DUE_TS);
        vm.prank(controller.keeper());
        controller.upkeep();
        IControllerProbe.BondInfo memory latest = controller.latestBondInfo();

        deal(CBBTC, USER, 1_000);
        vm.prank(USER);
        IR12ERC20(CBBTC).approve(latest.manager, type(uint256).max);
        vm.prank(USER);
        (IBondsManagerProbe.TokenAmount memory sr,) = IBondsManagerProbe(latest.manager).deposit(latest.bondID, 1_000);
        vm.prank(USER);
        IR12ERC20(sr.token).transfer(PERP_JR, sr.amount);

        R12ReserveTokens memory beforeReserves = IR12Perp(PERP_JR).reserves();
        assertFalse(_contains(beforeReserves, sr.token));
        R12TokenAmount[] memory tranches = new R12TokenAmount[](1);
        tranches[0] = R12TokenAmount(sr.token, sr.amount);
        vm.prank(CONTROLLER);
        IR12Perp(PERP_JR).handleTransferReservesIn(R12ReserveAmounts(0, tranches));
        _logReserves("handle_one_sided_after", "jr", PERP_JR);

        R12ReserveTokens memory afterReserves = IR12Perp(PERP_JR).reserves();
        assertEq(afterReserves.trancheTokens.length, beforeReserves.trancheTokens.length);
        assertTrue(_contains(afterReserves, sr.token));
        assertFalse(_contains(afterReserves, latest.jrTranche));
        assertEq(IR12ERC20(sr.token).balanceOf(PERP_JR), sr.amount);
    }

    function testRound12RecoverNoopReturnsFalse() public {
        vm.prank(CONTROLLER);
        (bool success, bytes memory returndata) = PERP_SR.call(abi.encodeWithSignature("recover()"));
        console2.log("OBS:R12_RECOVER_NOOP_SUCCESS", success);
        console2.log("OBS:R12_RECOVER_NOOP_RETURN_LENGTH", returndata.length);
        console2.log("OBS:R12_RECOVER_NOOP_RETURN_VALUE", returndata.length == 32 && abi.decode(returndata, (bool)));
        assertTrue(success);
        assertEq(returndata.length, 32);
        assertFalse(abi.decode(returndata, (bool)));
    }

    function testRound12RecoverMatureReturnsTrueAndRemoves() public {
        R12ReserveTokens memory beforeReserves = IR12Perp(PERP_SR).reserves();
        require(beforeReserves.trancheTokens.length >= 2, "need target reserve");
        address tranche = beforeReserves.trancheTokens[1].token;
        bytes32 bondID = IR12TrancheIdentity(tranche).bondID();
        address manager = IR12TrancheIdentity(tranche).manager();
        uint256 maturity = IR12MaturityManager(manager).bondsData(bondID).maturityDate;
        _refreshOracle(maturity);
        assertTrue(IR12MaturityManager(manager).tryMature(bondID));

        uint256 underlyingBefore = IR12ERC20(CBBTC).balanceOf(PERP_SR);
        _logReserves("direct_recover_before", "sr", PERP_SR);
        vm.prank(CONTROLLER);
        (bool success, bytes memory returndata) = PERP_SR.call(abi.encodeWithSignature("recover()"));
        _logReserves("direct_recover_after", "sr", PERP_SR);
        uint256 underlyingAfter = IR12ERC20(CBBTC).balanceOf(PERP_SR);
        console2.log("OBS:R12_RECOVER_MATURE_SUCCESS", success);
        console2.log("OBS:R12_RECOVER_MATURE_RETURN_LENGTH", returndata.length);
        console2.log("OBS:R12_RECOVER_MATURE_RETURN_VALUE", returndata.length == 32 && abi.decode(returndata, (bool)));
        console2.log("OBS:R12_RECOVER_MATURE_UNDERLYING_DELTA", underlyingAfter - underlyingBefore);

        assertTrue(success);
        assertEq(returndata.length, 32);
        assertTrue(abi.decode(returndata, (bool)));
        assertGt(underlyingAfter, underlyingBefore);
        assertFalse(_contains(IR12Perp(PERP_SR).reserves(), tranche));
    }

    function _transferOne(address perp, address token, uint256 amount, address recipient) private {
        R12TokenAmount[] memory tranches = new R12TokenAmount[](1);
        tranches[0] = R12TokenAmount(token, amount);
        R12ReserveAmounts memory amounts = R12ReserveAmounts(0, tranches);
        vm.prank(CONTROLLER);
        IR12Perp(perp).transferReservesTo(recipient, amounts);
    }

    function _setJrFree(uint256 desiredFree) private {
        (,, IControllerProbe.ReserveData memory jr) = controller.systemReserveState();
        uint256 reserved = jr.underlyingBal > desiredFree ? jr.underlyingBal - desiredFree : 0;
        vm.prank(controller.owner());
        controller.updateLiquidityThresholds(reserved, 0);
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
        IR12ResetOracle(address(oracle)).resetCache();
        oracle.cachePrice();
    }

    function _logBoth(string memory phase) private view {
        _logReserves(phase, "sr", PERP_SR);
        _logReserves(phase, "jr", PERP_JR);
    }

    function _logReserves(string memory phase, string memory side, address perp) private view {
        R12ReserveTokens memory data = IR12Perp(perp).reserves();
        console2.log(
            string.concat(
                "OBS:R12_RESERVE_HEAD {\"phase\":\"",
                phase,
                "\",\"side\":\"",
                side,
                "\",\"underlying\":",
                vm.toString(data.underlyingBal),
                ",\"count\":",
                vm.toString(data.trancheTokens.length),
                "}"
            )
        );
        for (uint256 i; i < data.trancheTokens.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R12_RESERVE_ROW {\"phase\":\"",
                    phase,
                    "\",\"side\":\"",
                    side,
                    "\",\"index\":",
                    vm.toString(i),
                    ",\"token\":\"",
                    vm.toString(data.trancheTokens[i].token),
                    "\",\"amount\":",
                    vm.toString(data.trancheTokens[i].amount),
                    "}"
                )
            );
        }
    }

    function _contains(R12ReserveTokens memory reserves_, address token) private pure returns (bool) {
        for (uint256 i; i < reserves_.trancheTokens.length; ++i) {
            if (reserves_.trancheTokens[i].token == token) return true;
        }
        return false;
    }
}
