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
import {IBalancerRound4Selection} from "./Round4RolloverProbe.t.sol";

interface IBalancerRound5Plan {
    function computePerpSrRolloverState(
        IControllerProbe.ReserveData calldata reserves,
        uint32 minMaturitySec,
        address bondsManager
    ) external pure returns (IBalancerRound4Selection.PerpSrRolloverState memory);

    function computePerpSrRolloverPlan(
        IControllerProbe.ReserveData calldata perpSrRd,
        IControllerProbe.ReserveData calldata perpJrRd,
        address bondsManager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external pure returns (IBalancerRound4Selection.RolloverExecution memory);
}

interface ITrancheTransferRound5 {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IPerpArraysRound5 {
    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct ReserveData {
        uint256 underlyingBal;
        address[] trancheTokens;
    }

    function reserves() external view returns (ReserveData memory);
    function transferReservesTo(address to, ReserveAmounts calldata amounts) external;
}

contract Round5IndependentPriceSelectionTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant OWNER = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant USER = address(0xBEEF);
    bytes32 private constant BOND_CREATED_TOPIC =
        keccak256("BondCreated(bytes32,address,uint64,uint64,address,address,uint256)");

    IControllerProbe private controller;
    IOracleProbe private oracle;
    address private priceFeed;
    address private sequencerFeed;
    uint80 private priceRoundId;
    int256 private basePrice;
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
        (priceRoundId, basePrice,,, priceAnsweredInRound) = IPriceFeedProbe(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IPriceFeedProbe(sequencerFeed).latestRoundData();
        }
    }

    function testRound5IndependentIssuePricesAndBackupSelection() public {
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((block.timestamp - offset) / interval + 1) * interval + offset;
        if (nextIssue <= block.timestamp) nextIssue += interval;
        bytes32[3] memory bondIDs;
        uint256[3] memory openPrices;
        int256[3] memory issuePrices = [basePrice * 80 / 100, basePrice, basePrice * 125 / 100];
        uint256[3] memory deposits = [uint256(1_000_000), 2_000_000, 3_000_000];

        deal(CBBTC, USER, 6_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);

        for (uint256 i; i < 3; ++i) {
            if (i != 0) nextIssue += interval;
            vm.warp(nextIssue + 1);
            _setAndCachePrice(issuePrices[i]);
            vm.recordLogs();
            vm.prank(controller.keeper());
            controller.upkeep();
            Vm.Log[] memory issueLogs = vm.getRecordedLogs();

            IControllerProbe.BondInfo memory info = controller.latestBondInfo();
            IBondsManagerProbe.BondData memory bond = IBondsManagerProbe(BONDS_MANAGER).bondsData(info.bondID);
            bondIDs[i] = info.bondID;
            openPrices[i] = bond.openPrice;

            vm.prank(USER);
            (IBondsManagerProbe.TokenAmount memory srAmount, IBondsManagerProbe.TokenAmount memory jrAmount) =
                IBondsManagerProbe(BONDS_MANAGER).deposit(info.bondID, deposits[i]);
            vm.prank(USER);
            ITrancheTransferRound5(info.srTranche).transfer(PERP_SR, srAmount.amount);
            vm.prank(USER);
            ITrancheTransferRound5(info.jrTranche).transfer(PERP_JR, jrAmount.amount);
            _logIssue(i, issuePrices[i], info, bond, issueLogs, deposits[i]);
        }

        _setAndCachePrice(basePrice);
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();

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
        require(minFreshMaturity != type(uint256).max && minFreshMaturity > 1, "issued rows missing");
        uint32 maturityCutoff = uint32(minFreshMaturity - 1);
        vm.prank(OWNER);
        controller.updateRolloverEligibility(maturityCutoff);
        vm.prank(OWNER);
        controller.updateMinCleanupVal(1);
        vm.prank(OWNER);
        controller.updateLiquidityThresholds(0, 0);
        deal(CBBTC, PERP_JR, 10_000_000);
        (, sr, jr) = controller.systemReserveState();

        IBalancerRound4Selection.PerpSrRolloverState memory rolloverState =
            IBalancerRound5Plan(BALANCER).computePerpSrRolloverState(sr, maturityCutoff, BONDS_MANAGER);
        uint256 available = controller.availPerpJrLiquidity();
        IBalancerRound4Selection.RolloverExecution memory backup =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(rolloverState, available);
        IBalancerRound4Selection.RolloverExecution memory plan = IBalancerRound5Plan(BALANCER)
            .computePerpSrRolloverPlan(sr, jr, BONDS_MANAGER, maturityCutoff, controller.reservedPerpJrLiquidity());

        _logSelectionState(rolloverState, available, backup, plan, openPrices);
        _logPermutedSelection(rolloverState, available);
        _logMaturityAndValuePermutations(rolloverState, available);
        _probeEquidistantTie(bondIDs, maturityCutoff, available);
        _setAndCachePrice(basePrice);

        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.rollover.selector));
        Vm.Log[] memory rolloverLogs = vm.getRecordedLogs();
        (, sr, jr) = controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_independent_price_actual_rollover\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returnData)),
                "\",\"recordedLogs\":",
                vm.toString(rolloverLogs.length),
                ",\"srIdleAfter\":",
                vm.toString(sr.underlyingBal),
                ",\"jrIdleAfter\":",
                vm.toString(jr.underlyingBal),
                ",\"backupSelectedBond\":\"",
                vm.toString(
                    backup.freshBondDepositAmts.length == 0 ? bytes32(0) : backup.freshBondDepositAmts[0].bondID
                ),
                "\",\"backupDeposit\":",
                vm.toString(backup.freshBondDepositAmts.length == 0 ? 0 : backup.freshBondDepositAmts[0].underlyingAmt),
                ",\"bondIDs\":[\"",
                vm.toString(bondIDs[0]),
                "\",\"",
                vm.toString(bondIDs[1]),
                "\",\"",
                vm.toString(bondIDs[2]),
                "\"]}"
            )
        );
        _logRelevantEvents(rolloverLogs);
    }

    function testRound5PerpRecoverAssetMatrix() public {
        IControllerProbe.BondInfo memory latest = controller.latestBondInfo();
        address[2] memory perps = [PERP_SR, PERP_JR];
        address[2] memory registered = [latest.srTranche, latest.jrTranche];
        address unregistered = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        for (uint256 i; i < perps.length; ++i) {
            address perp = perps[i];
            address tranche = registered[i];
            deal(CBBTC, perp, 101);
            deal(tranche, perp, 202);
            deal(unregistered, perp, 303);
            deal(perp, perp, 404);
            uint256 underlyingBefore = IERC20Probe(CBBTC).balanceOf(perp);
            uint256 trancheBefore = IERC20Probe(tranche).balanceOf(perp);
            uint256 unregisteredBefore = IERC20Probe(unregistered).balanceOf(perp);
            uint256 ownPerpBefore = IERC20Probe(perp).balanceOf(perp);
            uint256 ownerUnderlyingBefore = IERC20Probe(CBBTC).balanceOf(OWNER);
            uint256 controllerUnderlyingBefore = IERC20Probe(CBBTC).balanceOf(CONTROLLER);
            vm.recordLogs();
            vm.prank(CONTROLLER);
            (bool success, bytes memory returnData) = perp.call(abi.encodeWithSignature("recover()"));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round5_recover_asset_matrix\",\"perp\":\"",
                    vm.toString(perp),
                    "\",\"signature\":\"recover()\",\"selector\":\"",
                    vm.toString(bytes4(keccak256("recover()"))),
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"returnSelector\":\"",
                    vm.toString(_selector(returnData)),
                    "\",\"underlyingBefore\":",
                    vm.toString(underlyingBefore),
                    ",\"underlyingAfter\":",
                    vm.toString(IERC20Probe(CBBTC).balanceOf(perp)),
                    ",\"registeredTranche\":\"",
                    vm.toString(tranche),
                    "\",\"registeredBefore\":",
                    vm.toString(trancheBefore),
                    ",\"registeredAfter\":",
                    vm.toString(IERC20Probe(tranche).balanceOf(perp)),
                    ",\"unregisteredBefore\":",
                    vm.toString(unregisteredBefore),
                    ",\"unregisteredAfter\":",
                    vm.toString(IERC20Probe(unregistered).balanceOf(perp)),
                    ",\"ownPerpBefore\":",
                    vm.toString(ownPerpBefore),
                    ",\"ownPerpAfter\":",
                    vm.toString(IERC20Probe(perp).balanceOf(perp)),
                    ",\"ownerUnderlyingDelta\":",
                    vm.toString(IERC20Probe(CBBTC).balanceOf(OWNER) - ownerUnderlyingBefore),
                    ",\"controllerUnderlyingDelta\":",
                    vm.toString(IERC20Probe(CBBTC).balanceOf(CONTROLLER) - controllerUnderlyingBefore),
                    ",\"events\":",
                    vm.toString(logs.length),
                    "}"
                )
            );
        }
    }

    function testRound5PerpReserveArrayRemovalOrder() public {
        _probePerpReserveArray(PERP_SR, true);
        _probePerpReserveArray(PERP_JR, false);
    }

    function _probePerpReserveArray(address perp, bool senior) private {
        uint256 snapshot = vm.snapshotState();
        address[] memory initial = _reserveTokens(perp);
        (address[3] memory marked, uint256 liveCount) = _selectLiveTranches(initial);
        _logReserveArrayStep(perp, "existing_A_B_C", initial);
        console2.log(
            string.concat("OBS:round5_live_tranche_count=", vm.toString(perp), ",count=", vm.toString(liveCount))
        );
        _exerciseReserveTransfers(perp, marked, liveCount);
        if (liveCount != 0) _tryMockedMaturityUpkeep(perp, marked[0]);
        _issueNextTranche(perp, senior);
        require(vm.revertToState(snapshot), "reserve array snapshot restore failed");
    }

    function _selectLiveTranches(address[] memory tokens)
        private
        view
        returns (address[3] memory marked, uint256 count)
    {
        for (uint256 i; i < tokens.length && count < marked.length; ++i) {
            if (tokens[i].code.length != 0) marked[count++] = tokens[i];
        }
    }

    function _exerciseReserveTransfers(address perp, address[3] memory marked, uint256 count) private {
        if (count == 0) return;
        deal(marked[0], perp, 0);
        _transferTranche(perp, marked[0], 0);
        _logReserveArrayStep(perp, "zero_transfer_A", _reserveTokens(perp));

        if (count > 1) {
            deal(marked[1], perp, 300);
            _transferTranche(perp, marked[1], 100);
            _logReserveArrayStep(perp, "partial_transfer_B", _reserveTokens(perp));
            deal(marked[1], perp, 300);
            address[] memory beforeFull = _reserveTokens(perp);
            _transferTranche(perp, marked[1], 300);
            address[] memory afterFull = _reserveTokens(perp);
            _logReserveArrayStep(perp, "full_transfer_B", afterFull);
            console2.log(
                string.concat(
                    "OBS:round5_full_transfer_removed=",
                    vm.toString(!_contains(afterFull, marked[1])),
                    ",before=",
                    vm.toString(_contains(beforeFull, marked[1])),
                    ",token=",
                    vm.toString(marked[1])
                )
            );
        }

        if (count > 2) {
            deal(marked[2], perp, 300);
            _transferTranche(perp, marked[2], 300);
            _logReserveArrayStep(perp, "full_transfer_C", _reserveTokens(perp));
        } else {
            console2.log("OBS:round5_C_unavailable_in_live_reserve_array");
        }
    }

    function _tryMockedMaturityUpkeep(address perp, address tranche) private {
        vm.mockCall(tranche, abi.encodeWithSignature("isMature()"), abi.encode(true));
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(
            string.concat(
                "OBS:round5_maturity_upkeep=",
                vm.toString(perp),
                ",success=",
                vm.toString(success),
                ",selector=",
                vm.toString(_selector(returnData)),
                ",events=",
                vm.toString(logs.length)
            )
        );
        _logReserveArrayStep(perp, "after_mocked_maturity_upkeep", _reserveTokens(perp));
    }

    function _issueNextTranche(address perp, bool senior) private {
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((block.timestamp - offset) / interval + 1) * interval + offset;
        if (nextIssue <= block.timestamp) nextIssue += interval;
        vm.warp(nextIssue + 1);
        _setAndCachePrice(basePrice);
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        IControllerProbe.BondInfo memory newBond = controller.latestBondInfo();
        address newToken = senior ? newBond.srTranche : newBond.jrTranche;
        if (success) {
            deal(CBBTC, USER, 1_000_000);
            vm.prank(USER);
            IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
            vm.prank(USER);
            (IBondsManagerProbe.TokenAmount memory srAmount, IBondsManagerProbe.TokenAmount memory jrAmount) =
                IBondsManagerProbe(BONDS_MANAGER).deposit(newBond.bondID, 1_000_000);
            vm.prank(USER);
            ITrancheTransferRound5(newBond.srTranche).transfer(PERP_SR, srAmount.amount);
            vm.prank(USER);
            ITrancheTransferRound5(newBond.jrTranche).transfer(PERP_JR, jrAmount.amount);
        }
        address[] memory afterIssue = _reserveTokens(perp);
        _logReserveArrayStep(perp, "after_new_issue_D", afterIssue);
        console2.log(
            string.concat(
                "OBS:round5_new_D_success=",
                vm.toString(success),
                ",selector=",
                vm.toString(_selector(returnData)),
                ",events=",
                vm.toString(logs.length)
            )
        );
        console2.log(
            string.concat(
                "OBS:round5_new_D_bond=",
                vm.toString(newBond.bondID),
                ",token=",
                vm.toString(newToken),
                ",present=",
                vm.toString(_contains(afterIssue, newToken))
            )
        );
    }

    function _transferTranche(address perp, address token, uint256 amount) private {
        IPerpArraysRound5.TokenAmount[] memory tranches = new IPerpArraysRound5.TokenAmount[](1);
        tranches[0] = IPerpArraysRound5.TokenAmount({token: token, amount: amount});
        IPerpArraysRound5.ReserveAmounts memory reserveAmounts =
            IPerpArraysRound5.ReserveAmounts({underlyingAmt: 0, trancheAmts: tranches});
        vm.recordLogs();
        vm.prank(CONTROLLER);
        (bool success, bytes memory returnData) =
            perp.call(abi.encodeWithSelector(IPerpArraysRound5.transferReservesTo.selector, USER, reserveAmounts));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_reserve_array_transfer\",\"perp\":\"",
                vm.toString(perp),
                "\",\"token\":\"",
                vm.toString(token),
                "\",\"amount\":",
                vm.toString(amount),
                ",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returnData)),
                "\",\"events\":",
                vm.toString(logs.length),
                "}"
            )
        );
    }

    function _logReserveArrayStep(address perp, string memory step, address[] memory tokens) private view {
        string memory json = "[";
        for (uint256 i; i < tokens.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, "\"", vm.toString(tokens[i]), "\"");
        }
        json = string.concat(json, "]");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_reserve_array_step\",\"perp\":\"",
                vm.toString(perp),
                "\",\"step\":\"",
                step,
                "\",\"tokens\":",
                json,
                "}"
            )
        );
    }

    function _reserveTokens(address perp) private view returns (address[] memory tokens) {
        tokens = IPerpArraysRound5(perp).reserves().trancheTokens;
    }

    function _contains(address[] memory tokens, address target) private pure returns (bool) {
        for (uint256 i; i < tokens.length; ++i) {
            if (tokens[i] == target) return true;
        }
        return false;
    }

    function _setAndCachePrice(int256 answer) private {
        uint256 timestamp = block.timestamp;
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(priceRoundId, answer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(USER);
        oracle.cachePrice();
    }

    function _logIssue(
        uint256 index,
        int256 issuePrice,
        IControllerProbe.BondInfo memory info,
        IBondsManagerProbe.BondData memory bond,
        Vm.Log[] memory logs,
        uint256 deposit
    ) private {
        uint256 bondCreatedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == BOND_CREATED_TOPIC) ++bondCreatedCount;
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_independent_issue\",\"index\":",
                vm.toString(index),
                ",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"issuePriceAnswer\":",
                vm.toString(uint256(issuePrice)),
                ",\"bondID\":\"",
                vm.toString(info.bondID),
                "\",\"srTranche\":\"",
                vm.toString(info.srTranche),
                "\",\"jrTranche\":\"",
                vm.toString(info.jrTranche),
                "\",\"openPrice\":",
                vm.toString(bond.openPrice),
                ",\"srTrancheRatio\":",
                vm.toString(uint256(bond.srTrancheRatio)),
                ",\"secondsToMaturity\":",
                vm.toString(
                    uint256(bond.maturityDate) > block.timestamp ? uint256(bond.maturityDate) - block.timestamp : 0
                ),
                ",\"deposit\":",
                vm.toString(deposit),
                ",\"bondCreatedEvents\":",
                vm.toString(bondCreatedCount),
                "}"
            )
        );
    }

    function _logSelectionState(
        IBalancerRound4Selection.PerpSrRolloverState memory state,
        uint256 available,
        IBalancerRound4Selection.RolloverExecution memory backup,
        IBalancerRound4Selection.RolloverExecution memory plan,
        uint256[3] memory issueOpenPrices
    ) private {
        string memory rows = "[";
        for (uint256 i; i < state.freshSrTrs.length; ++i) {
            IBalancerRound4Selection.ReserveTrancheData memory row = state.freshSrTrs[i];
            if (i != 0) rows = string.concat(rows, ",");
            rows = string.concat(
                rows,
                "{\"bondID\":\"",
                vm.toString(row.data.bondID),
                "\",\"value\":",
                vm.toString(row.value),
                ",\"valueRatio\":",
                vm.toString(uint256(row.data.valueRatio)),
                ",\"secondsToMaturity\":",
                vm.toString(uint256(row.data.secondsToMaturity)),
                ",\"openPrice\":",
                vm.toString(row.data.underlyingOpenPrice),
                ",\"balance\":",
                vm.toString(row.balance),
                "}"
            );
        }
        rows = string.concat(rows, "]");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_independent_price_policy\",\"staleCount\":",
                vm.toString(state.staleSrTrs.length),
                ",\"staleUnderlyingBal\":",
                vm.toString(state.staleUnderlyingBal),
                ",\"totalStaleVal\":",
                vm.toString(state.totalStaleVal),
                ",\"available\":",
                vm.toString(available),
                ",\"freshCount\":",
                vm.toString(state.freshSrTrs.length),
                ",\"issueOpenPrices\":[",
                vm.toString(issueOpenPrices[0]),
                ",",
                vm.toString(issueOpenPrices[1]),
                ",",
                vm.toString(issueOpenPrices[2]),
                "],\"freshRows\":",
                rows,
                ",\"backupDepositCount\":",
                vm.toString(backup.freshBondDepositAmts.length),
                ",\"backupSelectedBond\":\"",
                vm.toString(
                    backup.freshBondDepositAmts.length == 0 ? bytes32(0) : backup.freshBondDepositAmts[0].bondID
                ),
                "\",\"backupUnderlying\":",
                vm.toString(backup.freshBondDepositAmts.length == 0 ? 0 : backup.freshBondDepositAmts[0].underlyingAmt),
                ",\"planRolledValue\":",
                vm.toString(plan.underlyingValRolled),
                ",\"planFreshDeposits\":",
                vm.toString(plan.freshBondDepositAmts.length),
                "}"
            )
        );
    }

    function _logPermutedSelection(IBalancerRound4Selection.PerpSrRolloverState memory state, uint256 available)
        private
    {
        IBalancerRound4Selection.PerpSrRolloverState memory reversed;
        reversed.staleUnderlyingBal = state.staleUnderlyingBal;
        reversed.totalStaleVal = state.totalStaleVal;
        reversed.staleSrTrs = state.staleSrTrs;
        reversed.freshSrTrs = new IBalancerRound4Selection.ReserveTrancheData[](state.freshSrTrs.length);
        for (uint256 i; i < state.freshSrTrs.length; ++i) {
            reversed.freshSrTrs[i] = state.freshSrTrs[state.freshSrTrs.length - 1 - i];
        }
        IBalancerRound4Selection.RolloverExecution memory backup =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(reversed, available);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_reversed_array_policy\",\"freshCount\":",
                vm.toString(reversed.freshSrTrs.length),
                ",\"selectedBond\":\"",
                vm.toString(
                    backup.freshBondDepositAmts.length == 0 ? bytes32(0) : backup.freshBondDepositAmts[0].bondID
                ),
                "\",\"underlying\":",
                vm.toString(backup.freshBondDepositAmts.length == 0 ? 0 : backup.freshBondDepositAmts[0].underlyingAmt),
                "}"
            )
        );
    }

    function _logMaturityAndValuePermutations(
        IBalancerRound4Selection.PerpSrRolloverState memory state,
        uint256 available
    ) private {
        IBalancerRound4Selection.PerpSrRolloverState memory maturityPermuted = _copyState(state);
        uint64 maturity = maturityPermuted.freshSrTrs[0].data.secondsToMaturity;
        maturityPermuted.freshSrTrs[0].data.secondsToMaturity = maturityPermuted.freshSrTrs[2].data.secondsToMaturity;
        maturityPermuted.freshSrTrs[2].data.secondsToMaturity = maturity;
        IBalancerRound4Selection.RolloverExecution memory maturityPlan =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(maturityPermuted, available);

        IBalancerRound4Selection.PerpSrRolloverState memory valuePermuted = _copyState(state);
        uint256 value = valuePermuted.freshSrTrs[0].value;
        valuePermuted.freshSrTrs[0].value = valuePermuted.freshSrTrs[2].value;
        valuePermuted.freshSrTrs[2].value = value;
        IBalancerRound4Selection.RolloverExecution memory valuePlan =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(valuePermuted, available);

        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_independent_selection_permutations\",\"baseSelected\":\"",
                vm.toString(
                    IBalancerRound4Selection(BALANCER)
                        .computeBackupRolloverPolicy(state, available)
                        .freshBondDepositAmts[0].bondID
                ),
                "\",\"maturityPermutedSelected\":\"",
                vm.toString(maturityPlan.freshBondDepositAmts[0].bondID),
                "\",\"valuePermutedSelected\":\"",
                vm.toString(valuePlan.freshBondDepositAmts[0].bondID),
                "\",\"maturityOrderChanged\":true,\"existingValuesChanged\":true}"
            )
        );
    }

    function _probeEquidistantTie(bytes32[3] memory bondIDs, uint32 maturityCutoff, uint256 available) private {
        _setAndCachePrice(basePrice * 41 / 40);
        (, IControllerProbe.ReserveData memory sr,) = controller.systemReserveState();
        IBalancerRound4Selection.PerpSrRolloverState memory fullState =
            IBalancerRound5Plan(BALANCER).computePerpSrRolloverState(sr, maturityCutoff, BONDS_MANAGER);
        IBalancerRound4Selection.PerpSrRolloverState memory tiedState;
        tiedState.staleUnderlyingBal = fullState.staleUnderlyingBal;
        tiedState.totalStaleVal = fullState.totalStaleVal;
        tiedState.staleSrTrs = fullState.staleSrTrs;
        tiedState.freshSrTrs = new IBalancerRound4Selection.ReserveTrancheData[](2);
        uint256 found;
        for (uint256 i; i < fullState.freshSrTrs.length; ++i) {
            bytes32 id = fullState.freshSrTrs[i].data.bondID;
            if (id == bondIDs[0] || id == bondIDs[2]) tiedState.freshSrTrs[found++] = fullState.freshSrTrs[i];
        }
        require(found == 2, "tie candidates missing");
        uint256 lowRatio = tiedState.freshSrTrs[0].data.valueRatio;
        uint256 highRatio = tiedState.freshSrTrs[1].data.valueRatio;
        if (lowRatio > highRatio) {
            IBalancerRound4Selection.ReserveTrancheData memory row = tiedState.freshSrTrs[0];
            tiedState.freshSrTrs[0] = tiedState.freshSrTrs[1];
            tiedState.freshSrTrs[1] = row;
            (lowRatio, highRatio) = (highRatio, lowRatio);
        }
        IBalancerRound4Selection.RolloverExecution memory forward =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(tiedState, available);
        IBalancerRound4Selection.ReserveTrancheData memory first = tiedState.freshSrTrs[0];
        tiedState.freshSrTrs[0] = tiedState.freshSrTrs[1];
        tiedState.freshSrTrs[1] = first;
        IBalancerRound4Selection.RolloverExecution memory reversed =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(tiedState, available);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_equidistant_ratio_tie\",\"lowRatio\":",
                vm.toString(lowRatio),
                ",\"highRatio\":",
                vm.toString(highRatio),
                ",\"lowDistance\":",
                vm.toString(500_000_000_000_000_000 - lowRatio),
                ",\"highDistance\":",
                vm.toString(highRatio - 500_000_000_000_000_000),
                ",\"forwardSelected\":\"",
                vm.toString(forward.freshBondDepositAmts[0].bondID),
                "\",\"reversedSelected\":\"",
                vm.toString(reversed.freshBondDepositAmts[0].bondID),
                "\",\"atOrAboveHalfWinner\":\"",
                vm.toString(
                    tiedState.freshSrTrs[0].data.valueRatio >= 500_000_000_000_000_000
                        ? tiedState.freshSrTrs[0].data.bondID
                        : tiedState.freshSrTrs[1].data.bondID
                ),
                "\"}"
            )
        );
        _probeExactEquidistantTie(tiedState, available);
    }

    function _probeExactEquidistantTie(IBalancerRound4Selection.PerpSrRolloverState memory state, uint256 available)
        private
    {
        state.freshSrTrs[0].data.valueRatio = 600_000_000_000_000_000;
        state.freshSrTrs[1].data.valueRatio = 400_000_000_000_000_000;
        bytes32 upperRatioBond = state.freshSrTrs[0].data.bondID;
        IBalancerRound4Selection.RolloverExecution memory forward =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(state, available);
        IBalancerRound4Selection.ReserveTrancheData memory row = state.freshSrTrs[0];
        state.freshSrTrs[0] = state.freshSrTrs[1];
        state.freshSrTrs[1] = row;
        IBalancerRound4Selection.RolloverExecution memory reversed =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(state, available);
        bytes32 forwardWinner = forward.freshBondDepositAmts[0].bondID;
        bytes32 reversedWinner = reversed.freshBondDepositAmts[0].bondID;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_exact_equidistant_ratio_tie\",\"lowRatio\":400000000000000000",
                ",\"highRatio\":600000000000000000,\"lowDistance\":100000000000000000",
                ",\"highDistance\":100000000000000000,\"forwardWinner\":\"",
                vm.toString(forwardWinner),
                "\",\"reversedWinner\":\"",
                vm.toString(reversedWinner),
                "\",\"upperRatioBond\":\"",
                vm.toString(upperRatioBond),
                "\",\"upperTieMatches\":",
                vm.toString(forwardWinner == upperRatioBond && reversedWinner == upperRatioBond),
                "}"
            )
        );
    }

    function _copyState(IBalancerRound4Selection.PerpSrRolloverState memory source)
        private
        pure
        returns (IBalancerRound4Selection.PerpSrRolloverState memory copy)
    {
        copy.staleUnderlyingBal = source.staleUnderlyingBal;
        copy.totalStaleVal = source.totalStaleVal;
        copy.staleSrTrs = source.staleSrTrs;
        copy.freshSrTrs = new IBalancerRound4Selection.ReserveTrancheData[](source.freshSrTrs.length);
        for (uint256 i; i < source.freshSrTrs.length; ++i) {
            copy.freshSrTrs[i] = source.freshSrTrs[i];
        }
    }

    function _logRelevantEvents(Vm.Log[] memory logs) private view {
        uint256 count;
        string memory events = "[";
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0) continue;
            bytes32 topic = logs[i].topics[0];
            if (
                topic != BOND_CREATED_TOPIC && topic != keccak256("BondDeposit(bytes32,uint256,uint256,uint256)")
                    && topic != keccak256("ReserveSynced(address,uint256)")
                    && topic != keccak256("Rebalance(uint256,bool)")
            ) continue;
            if (count != 0) events = string.concat(events, ",");
            events = string.concat(
                events,
                "{\"emitter\":\"",
                vm.toString(logs[i].emitter),
                "\",\"topic\":\"",
                vm.toString(topic),
                "\",\"topics\":\"",
                _topicsJson(logs[i].topics),
                "\",\"data\":\"",
                vm.toString(logs[i].data),
                "\"}"
            );
            ++count;
        }
        events = string.concat(events, "]");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round5_rollover_events\",\"count\":", vm.toString(count), ",\"events\":", events, "}"
            )
        );
    }

    function _topicsJson(bytes32[] memory topics) private view returns (string memory result) {
        result = "[";
        for (uint256 i; i < topics.length; ++i) {
            if (i != 0) result = string.concat(result, ",");
            result = string.concat(result, "\"", vm.toString(topics[i]), "\"");
        }
        result = string.concat(result, "]");
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }
    }
}
