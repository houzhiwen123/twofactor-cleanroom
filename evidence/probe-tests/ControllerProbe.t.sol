// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

interface IERC20Probe {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IBondsManagerProbe {
    struct BondData {
        address underlying;
        uint64 srTrancheRatio;
        bool isMature;
        uint64 maturityDate;
        address senior;
        address junior;
        uint256 openPrice;
        uint256 underlyingBal;
        uint256 srClaim;
        uint256 jrClaim;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    function bondsData(bytes32 bondID) external view returns (BondData memory);
    function deposit(bytes32 bondID, uint256 underlyingAmt)
        external
        returns (TokenAmount memory srTrAmt, TokenAmount memory jrTrAmt);
}

interface IBondIssuerProbe {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function latestBondInfo() external view returns (BondInfo memory);
    function issueWindowOffsetSec() external view returns (uint32);
    function lastIssueWindowTimestamp() external view returns (uint64);
    function minIssueTimeIntervalSec() external view returns (uint32);
}

interface IPriceFeedProbe {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IOracleProbe {
    function FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function SEQUENCER_FEED() external view returns (address);
    function cachePrice() external;
}

interface IFeePolicyProbe {
    struct Point {
        uint256 x;
        uint256 y;
    }

    struct Curve {
        Point p1;
        Point p2;
        Point p3;
        Point p4;
    }

    struct PerpFeeParams {
        Curve subDRUp;
        Curve subDRDown;
        Curve vmDRUp;
        Curve vmDRDown;
        uint64 basePerc;
        uint64 flashBasePerc;
    }

    function perpJrFees() external view returns (PerpFeeParams memory);
    function perpSrFees() external view returns (PerpFeeParams memory);
    function protocolFeeCollector() external view returns (address);
    function updateFeeParams(PerpFeeParams calldata perpSrFees_, PerpFeeParams calldata perpJrFees_) external;
}

interface IControllerProbe {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
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

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function availPerpJrLiquidity() external view returns (uint256);
    function balancer() external view returns (address);
    function collectedFeeBal(address token) external view returns (uint256);
    function flashMint2(uint256 underlyingAmtIntoPerpSr, uint256 underlyingAmtIntoPerpJr, uint256 minPerpSrAmtOut, uint256 minPerpJrAmtOut)
        external
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
    function flashRedeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minUnderlyingAmtOut)
        external
        returns (uint256 underlyingAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
    function issuer() external view returns (address);
    function keeper() external view returns (address);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function latestBondInfo() external view returns (BondInfo memory);
    function minCleanupVal() external view returns (uint256);
    function minMaturitySec() external view returns (uint32);
    function mint2(TokenAmount calldata srTrAmtIn, TokenAmount calldata jrTrAmtIn, uint256 minPerpSrAmtOut, uint256 minPerpJrAmtOut)
        external
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
    function owner() external view returns (address);
    function pauseSystemOps(bool paused) external;
    function pauseUserOps(bool paused) external;
    function perpJr() external view returns (address);
    function perpJrReservedUnderlyingAmt() external view returns (uint256);
    function perpJrReservedUnderlyingPerc() external view returns (uint64);
    function perpSr() external view returns (address);
    function protocolFeeBals(address token) external view returns (uint256);
    function rebalance() external;
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceWindow(uint256 blockTs) external view returns (uint64 windowStart, uint64 windowEnd);
    function rebalanceWindowLengthSec() external view returns (uint32);
    function rebalanceWindowOffsetSec() external view returns (uint32);
    function redeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minValOut)
        external
        returns (
            ReserveAmounts memory returnedPerpSrReserveAmounts,
            ReserveAmounts memory returnedPerpJrReserveAmounts,
            FeePerc memory perpSrFeePerc,
            FeePerc memory perpJrFeePerc
        );
    function reservedPerpJrLiquidity() external view returns (uint256);
    function rollover() external;
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function systemOpsPaused() external view returns (bool);
    function systemReserveState()
        external
        view
        returns (SystemState memory state, ReserveData memory perpSrRd, ReserveData memory perpJrRd);
    function upkeep() external;
    function underlyingOracle() external view returns (address);
    function updateValueCap(uint256 valueCap_) external;
    function updateLiquidityThresholds(uint256 perpJrReservedUnderlyingAmt_, uint64 perpJrReservedUnderlyingPerc_)
        external;
    function updateMinCleanupVal(uint256 minCleanupVal_) external;
    function updateRolloverEligibility(uint32 minMaturitySec_) external;
    function pullProtocolFees(address token, address to, uint256 amount) external;
    function userOpsPaused() external view returns (bool);
    function valueCap() external view returns (uint256);
}

interface IBalancerRebalanceProbe {
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

    function computeSystemRebalancePlan(ReserveData calldata reserves, uint256 rebalVal)
        external
        pure
        returns (ReserveAmounts memory reserveOut);
}

contract ControllerProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant BOND_ISSUER = 0xc56CCbF6219B780c879544FEe0404bD3B49fEBB0;
    address private constant BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant OWNER_SAFE = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant USER = address(0xBEEF);

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant APPROVAL_TOPIC = keccak256("Approval(address,address,uint256)");
    bytes32 private constant OP_FEES_TOPIC = keccak256("OpFees(address,uint256,uint256)");
    bytes32 private constant AUM_FEES_TOPIC = keccak256("AumFees(address,uint256)");
    bytes32 private constant RESERVE_SYNCED_TOPIC = 0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939;
    bytes32 private constant REBALANCE_TOPIC = keccak256("Rebalance(uint256,bool)");
    bytes4 private constant COMPUTE_REBALANCE_VAL_SELECTOR =
        bytes4(keccak256("computeRebalanceVal(uint256,uint256,uint256)"));
    bytes32 private constant BOND_CREATED_TOPIC =
        keccak256("BondCreated(bytes32,address,uint64,uint64,address,address,uint256)");
    bytes32 private constant BOND_DEPOSIT_TOPIC = keccak256("BondDeposit(bytes32,uint256,uint256,uint256)");
    bytes32 private constant BOND_MATURE_TOPIC = keccak256("BondMature(bytes32,uint256,uint256,uint256)");
    bytes32 private constant TRANCHES_REDEEMED_TOPIC =
        keccak256("TranchesRedeemed(bytes32,uint256,uint256,uint256)");
    bytes32 private constant OWNERSHIP_TRANSFERRED_TOPIC =
        keccak256("OwnershipTransferred(address,address)");
    bytes32 private constant OWNERSHIP_TRANSFER_STARTED_TOPIC =
        keccak256("OwnershipTransferStarted(address,address)");

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
        controller = IControllerProbe(CONTROLLER);
        assertEq(controller.owner(), OWNER_SAFE);
        assertEq(controller.issuer(), BOND_ISSUER);
        assertEq(controller.balancer(), BALANCER);
        oracle = IOracleProbe(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,, , priceAnsweredInRound) =
            IPriceFeedProbe(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,, , sequencerAnsweredInRound) =
                IPriceFeedProbe(sequencerFeed).latestRoundData();
        }
    }

    function testFlashMintSrOnlyPoint01() public {
        _probeFlashMint("flashMint2_SR_only_0.01_cbBTC", 1_000_000, 0);
    }

    function testFlashMintJrOnlyPoint01() public {
        _probeFlashMint("flashMint2_JR_only_0.01_cbBTC", 0, 1_000_000);
    }

    function testFlashMintBothSides() public {
        _probeFlashMint("flashMint2_both_0.01_SR_0.02_JR_cbBTC", 1_000_000, 2_000_000);
    }

    function testFlashMintTinySr() public {
        _probeFlashMint("flashMint2_tiny_SR_1000_sats", 1_000, 0);
    }

    function testFlashMintTinyJr() public {
        _probeFlashMint("flashMint2_tiny_JR_1000_sats", 0, 1_000);
    }

    function testFlashMintBothTiny() public {
        _probeFlashMint("flashMint2_tiny_both_1000_sats_each", 1_000, 1_000);
    }

    function testFlashRedeemSrOnly() public {
        (uint256 srOut,) = _probeFlashMint("flashMint2_primer_for_SR_redeem", 1_000_000, 0);
        _probeFlashRedeem("flashRedeem2_SR_only", srOut, 0);
    }

    function testFlashRedeemJrOnly() public {
        (, uint256 jrOut) = _probeFlashMint("flashMint2_primer_for_JR_redeem", 0, 1_000_000);
        _probeFlashRedeem("flashRedeem2_JR_only", 0, jrOut);
    }

    function testFlashRedeemBothSides() public {
        (uint256 srOut, uint256 jrOut) =
            _probeFlashMint("flashMint2_primer_for_both_side_redeem", 1_000_000, 2_000_000);
        _probeFlashRedeem("flashRedeem2_both_sides", srOut, jrOut);
    }

    function testFlashRedeemJrReserveFloor() public {
        uint256 jrSupply = IERC20Probe(PERP_JR).totalSupply();
        deal(PERP_JR, USER, jrSupply);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"local_balance_setup\",\"label\":\"jr_reserve_floor\",\"token\":\"",
                vm.toString(PERP_JR),
                "\",\"user\":\"",
                vm.toString(USER),
                "\",\"amount\":",
                vm.toString(jrSupply),
                ",\"totalSupply\":",
                vm.toString(IERC20Probe(PERP_JR).totalSupply()),
                "}"
            )
        );
        _probeFlashRedeem("flashRedeem2_JR_reserve_floor_probe", 0, jrSupply);
    }

    function testFlashRedeemJrReserveFloorBoundary() public {
        uint256 jrSupply = IERC20Probe(PERP_JR).totalSupply();
        uint256 available = controller.availPerpJrLiquidity();
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 boundaryAmount = (jrSupply * available) / state.perpJr.reserveValue + 1;
        deal(PERP_JR, USER, jrSupply);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"local_balance_setup\",\"label\":\"jr_reserve_floor_boundary\",\"token\":\"",
                vm.toString(PERP_JR),
                "\",\"user\":\"",
                vm.toString(USER),
                "\",\"amount\":",
                vm.toString(jrSupply),
                ",\"totalSupply\":",
                vm.toString(IERC20Probe(PERP_JR).totalSupply()),
                ",\"boundaryRedeemAmount\":",
                vm.toString(boundaryAmount),
                ",\"availablePerpJrLiquidity\":",
                vm.toString(available),
                ",\"perpJrReserveValue\":",
                vm.toString(state.perpJr.reserveValue),
                "}"
            )
        );
        _probeFlashRedeem("flashRedeem2_JR_reserve_floor_boundary_probe", 0, boundaryAmount);
    }

    function testMint2AndRedeem2() public {
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"deposit_input\",\"manager\":\"",
                vm.toString(info.manager),
                "\",\"bondID\":\"",
                vm.toString(info.bondID),
                "\",\"underlyingAmt\":1000000}"
            )
        );
        _snapshot("before_BondsManager.deposit", USER);
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        bytes memory depositCall = abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000);
        (bool deposited, bytes memory depositRet) = _execute(
            "BondsManager.deposit_latest_bond_0.01_cbBTC", USER, BONDS_MANAGER, depositCall
        );
        IBondsManagerProbe.TokenAmount memory srTranche;
        IBondsManagerProbe.TokenAmount memory jrTranche;
        if (deposited) {
            (srTranche, jrTranche) = abi.decode(
                depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount)
            );
            _observeTokenAmount("deposit_sr_tranche", srTranche);
            _observeTokenAmount("deposit_jr_tranche", jrTranche);
        }
        _snapshot("after_BondsManager.deposit", USER);

        if (!deposited) return;
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);

        _snapshot("before_mint2", USER);
        string memory mintInput = string.concat(
            "{\"operation\":\"mint2\",\"srToken\":\"",
            vm.toString(srTranche.token),
            "\",\"srAmount\":",
            vm.toString(srTranche.amount),
            ",\"jrToken\":\"",
            vm.toString(jrTranche.token),
            "\",\"jrAmount\":",
            vm.toString(jrTranche.amount),
            ",\"minSrOut\":0,\"minJrOut\":0}"
        );
        console2.log(string.concat("OBS:", mintInput));
        bytes memory mintCall = abi.encodeWithSelector(
            IControllerProbe.mint2.selector,
            IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
            IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
            0,
            0
        );
        (bool minted, bytes memory mintRet) =
            _execute("mint2_latest_bond_tranches", USER, CONTROLLER, mintCall);
        uint256 srPerpOut;
        uint256 jrPerpOut;
        if (minted) {
            IControllerProbe.FeePerc memory srFee;
            IControllerProbe.FeePerc memory jrFee;
            (srPerpOut, jrPerpOut, srFee, jrFee) = abi.decode(
                mintRet, (uint256, uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc)
            );
            _observeMintReturns("mint2", srPerpOut, jrPerpOut, srFee, jrFee);
        }
        _snapshot("after_mint2", USER);

        if (!minted) return;
        _snapshot("before_redeem2", USER);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"redeem2_input\",\"perpSrAmt\":",
                vm.toString(srPerpOut),
                ",\"perpJrAmt\":",
                vm.toString(jrPerpOut),
                ",\"minValOut\":0}"
            )
        );
        bytes memory redeemCall =
            abi.encodeWithSelector(IControllerProbe.redeem2.selector, srPerpOut, jrPerpOut, 0);
        (bool redeemed, bytes memory redeemRet) =
            _execute("redeem2_minted_perps", USER, CONTROLLER, redeemCall);
        if (redeemed) _observeRedeem2Returns(redeemRet);
        _snapshot("after_redeem2", USER);
    }

    function testRebalanceWindowTimestampSamples() public {
        uint256 last = controller.lastRebalanceTimestampSec();
        uint256 next = last + controller.rebalanceFreqSec();
        uint256[6] memory samples = [last - 1, last, last + 1, next - 1, next, next + 1];
        _snapshot("before_rebalanceWindow_samples", USER);
        for (uint256 i; i < samples.length; ++i) {
            (uint64 start, uint64 end) = controller.rebalanceWindow(samples[i]);
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"rebalanceWindow\",\"inputTs\":",
                    vm.toString(samples[i]),
                    ",\"windowStart\":",
                    vm.toString(uint256(start)),
                    ",\"windowEnd\":",
                    vm.toString(uint256(end)),
                    "}"
                )
            );
        }
        _snapshot("after_rebalanceWindow_samples", USER);
    }

    function testRebalanceOutsideWindowAttempt() public {
        uint256 last = controller.lastRebalanceTimestampSec();
        uint256 originalTimestamp = block.timestamp;
        uint256 outsideTs = last > 1 ? last - 1 : 1;
        _snapshot("before_rebalance_outside_window_attempt", USER);
        vm.warp(outsideTs);
        (uint64 windowStart, uint64 windowEnd) = controller.rebalanceWindow(outsideTs);
        bool candidateInsideWindow = outsideTs >= windowStart && outsideTs < windowEnd;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"rebalance_call_time\",\"label\":\"candidate_near_last_rebalance\",\"timestamp\":",
                vm.toString(outsideTs),
                ",\"windowStart\":",
                vm.toString(uint256(windowStart)),
                ",\"windowEnd\":",
                vm.toString(uint256(windowEnd)),
                ",\"candidateInsideWindow\":",
                vm.toString(candidateInsideWindow),
                "}"
            )
        );
        _execute(
            "rebalance_candidate_near_last_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        vm.warp(originalTimestamp);
        _snapshot("after_rebalance_outside_window_attempt", USER);
    }

    function testRebalanceInsideWindowThenImmediatelyAgain() public {
        uint256 last = controller.lastRebalanceTimestampSec();
        uint256 freq = controller.rebalanceFreqSec();
        uint256 offset = controller.rebalanceWindowOffsetSec();
        uint256 nowTs = block.timestamp;
        uint256 next = ((nowTs - offset) / freq + 1) * freq + offset;
        if (next <= nowTs) next += freq;
        (uint64 start, uint64 end) = controller.rebalanceWindow(next);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"rebalance_schedule\",\"last\":",
                vm.toString(last),
                ",\"candidateTs\":",
                vm.toString(next),
                ",\"windowStart\":",
                vm.toString(uint256(start)),
                ",\"windowEnd\":",
                vm.toString(uint256(end)),
                "}"
            )
        );
        vm.warp(next);
        _refreshOracleForWarpedTimestamp("rebalance_inside_window");
        _snapshot("before_rebalance_inside_window", USER);
        _execute("rebalance_inside_window", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.rebalance.selector));
        _snapshot("after_rebalance_inside_window", USER);
        _execute("rebalance_immediately_again", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.rebalance.selector));
        _snapshot("after_rebalance_immediately_again", USER);
    }

    function testUpkeepRolloverMaturityAndLazyIssuance() public {
        _snapshot("before_upkeep_rollover_group", USER);
        (, IControllerProbe.ReserveData memory srBefore, IControllerProbe.ReserveData memory jrBefore) =
            controller.systemReserveState();
        uint256 nearestMaturity = _nearestMaturity(srBefore, jrBefore);
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"rollover_schedule\",\"now\":",
                vm.toString(nowTs),
                ",\"nextIssueWindow\":",
                vm.toString(nextIssue),
                ",\"nearestMaturitySeconds\":",
                vm.toString(nearestMaturity),
                ",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                "}"
            )
        );

        vm.warp(nextIssue + 1);
        _refreshOracleForWarpedTimestamp("upkeep_after_next_issue_window");
        _snapshot("before_upkeep_after_next_issue_window", USER);
        _execute(
            "upkeep_after_next_issue_window",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.upkeep.selector)
        );
        _snapshot("after_upkeep_after_next_issue_window", USER);
        _execute(
            "rollover_after_next_issue_window",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        _snapshot("after_rollover_after_next_issue_window", USER);

        if (nearestMaturity != type(uint256).max) {
            vm.warp(block.timestamp + nearestMaturity + 1);
            _refreshOracleForWarpedTimestamp("upkeep_after_nearest_maturity");
        }
        _snapshot("before_upkeep_after_nearest_maturity", USER);
        _execute(
            "upkeep_after_nearest_maturity",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.upkeep.selector)
        );
        _snapshot("after_upkeep_after_nearest_maturity", USER);
        _execute(
            "rollover_after_nearest_maturity",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        _snapshot("after_rollover_after_nearest_maturity", USER);

        deal(CBBTC, USER, 1_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _probeFlashMint("flashMint2_after_upkeep_rollover_lazy_path_1000_sats", 1_000, 0);
    }

    function testFlashMintLazyIssueAndMaturity() public {
        _snapshot("before_lazy_issue_maturity_group", USER);
        (, IControllerProbe.ReserveData memory srBefore, IControllerProbe.ReserveData memory jrBefore) =
            controller.systemReserveState();
        uint256 nearestMaturity = _nearestMaturity(srBefore, jrBefore);
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        uint256 nextMaturity = nearestMaturity == type(uint256).max
            ? nowTs
            : nowTs + nearestMaturity + 1;
        uint256 targetTs = nextIssue + 1;
        if (nextMaturity > targetTs) targetTs = nextMaturity;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"lazy_issue_maturity_schedule\",\"now\":",
                vm.toString(nowTs),
                ",\"nextIssueWindow\":",
                vm.toString(nextIssue),
                ",\"nearestMaturitySeconds\":",
                vm.toString(nearestMaturity),
                ",\"targetTimestamp\":",
                vm.toString(targetTs),
                "}"
            )
        );
        vm.warp(targetTs);
        _refreshOracleForWarpedTimestamp("lazy_flashMint_after_issue_and_maturity");
        _snapshot("before_lazy_flashMint_after_issue_and_maturity", USER);
        _probeFlashMint("flashMint2_lazy_issue_and_maturity_1000_sats", 1_000, 0);
    }

    function testReviewMint2AfterIssueWindowWithoutUpkeep() public {
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        vm.warp(nextIssue + 1);
        _refreshOracleForWarpedTimestamp("review_mint2_after_issue_window");
        _snapshot("review_mint2_after_issue_window_before", USER);

        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            "review_mint2_after_issue_window_deposit",
            USER,
            BONDS_MANAGER,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        _execute(
            "review_mint2_after_issue_window",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.mint2.selector,
                IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
                IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
                0,
                0
            )
        );
        _snapshot("review_mint2_after_issue_window_after", USER);
    }

    function testRound2Mint2RegisteredLatestBeforeIssueWindow() public {
        _mint2FromRegisteredBond("round2_mint2_registered_latest", controller.latestBondInfo(), 1_000_000);
    }

    function testRound2Mint2RegisteredNonLatestBeforeIssueWindow() public {
        IControllerProbe.BondInfo memory latest = controller.latestBondInfo();
        (, IControllerProbe.ReserveData memory sr,) = controller.systemReserveState();
        IControllerProbe.BondInfo memory older;
        for (uint256 i; i < sr.trancheData.length; ++i) {
            IControllerProbe.TrancheData memory data = sr.trancheData[i].data;
            if (data.bondID != latest.bondID) {
                older = IControllerProbe.BondInfo(data.manager, data.bondID, data.tranche, data.counterpart);
                break;
            }
        }
        require(older.bondID != bytes32(0), "no registered non-latest senior tranche");
        _mint2FromRegisteredBond("round2_mint2_registered_nonlatest", older, 1_000_000);
    }

    function testRound2Mint2RegisteredTrancheAcrossIssueWindow() public {
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        vm.warp(nextIssue + 1);
        _refreshOracleForWarpedTimestamp("round2_mint2_issue_window");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"issue_window_case\",\"label\":\"round2_mint2_registered_tranche\",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"lastIssueWindowTimestamp\":",
                vm.toString(uint256(issuer.lastIssueWindowTimestamp())),
                ",\"nextIssueWindow\":",
                vm.toString(nextIssue),
                ",\"upkeepCalled\":false}"
            )
        );
        _mint2FromRegisteredBond("round2_mint2_issue_window", info, 1_000_000);
    }

    function _mint2FromRegisteredBond(string memory label, IControllerProbe.BondInfo memory info, uint256 amount)
        private
    {
        _snapshot(string.concat(label, "_before_deposit"), USER);
        deal(CBBTC, USER, amount);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(info.manager, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            string.concat(label, "_deposit_registered_bond"),
            USER,
            info.manager,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, amount)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        _observeTokenAmount(string.concat(label, "_sr_input"), srTranche);
        _observeTokenAmount(string.concat(label, "_jr_input"), jrTranche);
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        _snapshot(string.concat(label, "_before_mint2"), USER);
        _execute(
            label,
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.mint2.selector,
                IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
                IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
                0,
                0
            )
        );
        _snapshot(string.concat(label, "_after_mint2"), USER);
    }

    function testReviewLazyFlashMintSrWithStaleBond() public {
        _warpPastIssueAndNearestMaturity("review_lazy_sr_stale");
        _snapshot("review_lazy_sr_stale_before", USER);
        _probeFlashMint("review_lazy_sr_stale_flash_mint", 2_000_000, 0);
        _snapshot("review_lazy_sr_stale_after", USER);
    }

    function testReviewLazyFlashMintJrWithStaleBond() public {
        _warpPastIssueAndNearestMaturity("review_lazy_jr_stale");
        _snapshot("review_lazy_jr_stale_before", USER);
        _probeFlashMint("review_lazy_jr_stale_flash_mint", 0, 2_000_000);
        _snapshot("review_lazy_jr_stale_after", USER);
    }

    function testReviewLazyFlashMintSrAfterIssueWindowBeforeMaturity() public {
        _execute(
            "review_lazy_sr_issue_only_lower_maturity_threshold",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateRolloverEligibility.selector, uint32(1))
        );
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        uint256 nearestMaturity = _nearestMaturity(sr, jr);
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        assertLt(nextIssue + 1 - nowTs, nearestMaturity);
        vm.warp(nextIssue + 1);
        _refreshOracleForWarpedTimestamp("review_lazy_sr_issue_only");
        _snapshot("review_lazy_sr_issue_only_before", USER);
        _probeFlashMint("review_lazy_sr_issue_only_flash_mint", 2_000_000, 0);
        _snapshot("review_lazy_sr_issue_only_after", USER);
    }

    function testReviewAumGrossUp10Pct1d() public {
        _runReviewAumGrossUpCase(86_400, 1e17);
    }

    function testReviewAumGrossUp10Pct7d() public {
        _runReviewAumGrossUpCase(604_800, 1e17);
    }

    function testReviewAumGrossUp5Pct1d() public {
        _runReviewAumGrossUpCase(86_400, 5e16);
    }

    function testReviewAumGrossUp5Pct7d() public {
        _runReviewAumGrossUpCase(604_800, 5e16);
    }

    function _runReviewAumGrossUpCase(uint256 elapsed, uint64 rate) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_aum_grossup_case\",\"elapsedSec\":",
                vm.toString(elapsed),
                ",\"rateSr\":",
                vm.toString(uint256(rate)),
                ",\"rateJr\":",
                vm.toString(uint256(rate)),
                "}"
            )
        );
        _snapshot("review_aum_grossup_before", USER);
        _execute(
            "review_aum_grossup_update_rates",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateAumFeePerc(uint64,uint64)", rate, rate)
        );
        vm.warp(block.timestamp + elapsed);
        _refreshOracleForWarpedTimestamp("review_aum_grossup_elapsed");
        _snapshot("review_aum_grossup_before_rebalance", USER);
        _execute(
            "review_aum_grossup_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot("review_aum_grossup_after_rebalance", USER);
    }

    function _warpPastIssueAndNearestMaturity(string memory label) private {
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        uint256 nearestMaturity = _nearestMaturity(sr, jr);
        IBondIssuerProbe issuer = IBondIssuerProbe(controller.issuer());
        uint256 nowTs = block.timestamp;
        uint256 interval = issuer.minIssueTimeIntervalSec();
        uint256 offset = issuer.issueWindowOffsetSec();
        uint256 nextIssue = ((nowTs - offset) / interval + 1) * interval + offset;
        if (nextIssue <= nowTs) nextIssue += interval;
        uint256 targetTs = nextIssue + 1;
        if (nearestMaturity != type(uint256).max && nowTs + nearestMaturity + 1 > targetTs) {
            targetTs = nowTs + nearestMaturity + 1;
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_lazy_schedule\",\"label\":\"",
                label,
                "\",\"nextIssue\":",
                vm.toString(nextIssue),
                ",\"nearestMaturitySeconds\":",
                vm.toString(nearestMaturity),
                ",\"targetTimestamp\":",
                vm.toString(targetTs),
                "}"
            )
        );
        vm.warp(targetTs);
        _refreshOracleForWarpedTimestamp(label);
    }

    function testPauseUserAndSystemOperations() public {
        (uint256 srOut, uint256 jrOut) = _probeFlashMint("flashMint2_pause_setup", 1_000_000, 1_000_000);
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        _snapshot("before_pause_setup_BondsManager.deposit", USER);
        (bool deposited, bytes memory depositRet) = _execute(
            "BondsManager.deposit_pause_setup",
            USER,
            BONDS_MANAGER,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        _observeTokenAmount("pause_setup_sr_tranche", srTranche);
        _observeTokenAmount("pause_setup_jr_tranche", jrTranche);
        _snapshot("after_pause_setup_BondsManager.deposit", USER);
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);

        IControllerProbe.TokenAmount memory srTokenIn =
            IControllerProbe.TokenAmount(srTranche.token, srTranche.amount);
        IControllerProbe.TokenAmount memory jrTokenIn =
            IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount);
        bytes memory mintArgs = abi.encode(srTokenIn, jrTokenIn, uint256(0), uint256(0));
        bytes memory redeemArgs = abi.encode(srOut, jrOut, uint256(0));

        _snapshot("before_pauseUserOps", USER);
        _execute(
            "pauseUserOps(true)",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pauseUserOps.selector, true)
        );
        _snapshot("after_pauseUserOps_true", USER);
        _probePausedCall(
            "flashMint2_while_user_paused",
            USER,
            IControllerProbe.flashMint2.selector,
            abi.encode(uint256(1_000_000), uint256(0), uint256(0), uint256(0))
        );
        _probePausedCall("flashRedeem2_while_user_paused", USER, IControllerProbe.flashRedeem2.selector, redeemArgs);
        _probePausedCall(
            "mint2_while_user_paused",
            USER,
            IControllerProbe.mint2.selector,
            mintArgs
        );
        _probePausedCall("redeem2_while_user_paused", USER, IControllerProbe.redeem2.selector, redeemArgs);
        _execute(
            "pauseUserOps(false)",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pauseUserOps.selector, false)
        );
        _snapshot("after_pauseUserOps_false", USER);

        uint256 originalTimestamp = block.timestamp;
        uint256 frequency = controller.rebalanceFreqSec();
        uint256 offset = controller.rebalanceWindowOffsetSec();
        uint256 windowTs = ((originalTimestamp - offset) / frequency + 1) * frequency + offset;
        if (windowTs <= originalTimestamp) windowTs += frequency;
        vm.warp(windowTs);
        _refreshOracleForWarpedTimestamp("pause_system_operations");
        (uint64 windowStart, uint64 windowEnd) = controller.rebalanceWindow(windowTs);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"pause_system_window\",\"timestamp\":",
                vm.toString(windowTs),
                ",\"windowStart\":",
                vm.toString(uint256(windowStart)),
                ",\"windowEnd\":",
                vm.toString(uint256(windowEnd)),
                "}"
            )
        );
        _snapshot("before_pauseSystemOps", USER);
        _execute(
            "pauseSystemOps(true)",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pauseSystemOps.selector, true)
        );
        _snapshot("after_pauseSystemOps_true", USER);
        _probePausedCall(
            "rebalance_while_system_paused",
            controller.keeper(),
            IControllerProbe.rebalance.selector,
            bytes("")
        );
        _probePausedCall(
            "upkeep_while_system_paused",
            controller.keeper(),
            IControllerProbe.upkeep.selector,
            bytes("")
        );
        _probePausedCall(
            "rollover_while_system_paused",
            controller.keeper(),
            IControllerProbe.rollover.selector,
            bytes("")
        );
        _execute(
            "pauseSystemOps(false)",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pauseSystemOps.selector, false)
        );
        _snapshot("after_pauseSystemOps_false", USER);
        vm.warp(originalTimestamp);
    }

    function testFollowupFeeLifecycle() public {
        _snapshot("fee_lifecycle_before", USER);
        _execute(
            "fee_lifecycle_update_protocol_fee_config",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(1e17), OWNER_SAFE)
        );
        (uint256 srOut, uint256 jrOut) = _probeFlashMint("fee_lifecycle_flash_mint", 1_000_000, 2_000_000);
        _probeFlashRedeem("fee_lifecycle_flash_redeem", srOut, jrOut);

        _snapshot("fee_lifecycle_before_upkeep", USER);
        _execute("fee_lifecycle_upkeep", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        _snapshot("fee_lifecycle_after_upkeep", USER);

        uint256 nextWindow = 1794247200;
        vm.warp(nextWindow);
        _refreshOracleForWarpedTimestamp("fee_lifecycle_rebalance");
        _snapshot("fee_lifecycle_before_rebalance", USER);
        _execute("fee_lifecycle_rebalance", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.rebalance.selector));
        _snapshot("fee_lifecycle_after_rebalance", USER);

        vm.warp(1794510001);
        _refreshOracleForWarpedTimestamp("fee_lifecycle_rollover");
        _snapshot("fee_lifecycle_before_upkeep_rollover", USER);
        _execute("fee_lifecycle_issue_upkeep", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.upkeep.selector));
        _snapshot("fee_lifecycle_after_issue_upkeep", USER);
        _execute("fee_lifecycle_rollover", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.rollover.selector));
        _snapshot("fee_lifecycle_after_rollover", USER);

        uint256 srProtocolFees = controller.protocolFeeBals(PERP_SR);
        uint256 jrProtocolFees = controller.protocolFeeBals(PERP_JR);
        uint256 underlyingProtocolFees = controller.protocolFeeBals(CBBTC);
        _execute(
            "fee_lifecycle_pull_protocol_sr",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, PERP_SR, USER, srProtocolFees)
        );
        _execute(
            "fee_lifecycle_pull_protocol_jr",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, PERP_JR, USER, jrProtocolFees)
        );
        _execute(
            "fee_lifecycle_pull_protocol_cbBTC",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, CBBTC, USER, underlyingProtocolFees)
        );
        _snapshot("fee_lifecycle_after_pull_protocol", USER);
        _probeFlashMint("fee_lifecycle_next_user_op", 1_000_000, 0);
    }

    function testReviewCollectedFeesAcrossSuccessfulRebalance() public {
        _execute(
            "review_collected_set_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(0), OWNER_SAFE)
        );
        _probeFlashMint("review_collected_fee_flash_mint", 1_000_000, 2_000_000);
        _snapshot("review_collected_fee_before_rebalance", USER);

        vm.warp(1794247200);
        _refreshOracleForWarpedTimestamp("review_collected_fee_rebalance");
        _execute(
            "review_collected_fee_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot("review_collected_fee_after_rebalance", USER);
    }

    function testRound2RebalanceSettlementDistinctiveSrFeeAndPlan() public {
        _setRound2FeeParams(50_000_000_000_000_000, 20_000_000_000_000_000);
        _execute(
            "round2_rebalance_fee_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(50_000_000_000_000), USER)
        );
        _probeFlashMint("round2_distinctive_fee_seed", 1_000_000, 0);
        _snapshot("round2_distinctive_fee_before_rebalance", USER);
        _warpToNextRebalanceWindow("round2_distinctive_fee_rebalance");
        _snapshot("round2_distinctive_fee_before_rebalance_call", USER);
        _callRebalanceAndLogPlan("round2_distinctive_fee_rebalance");
        _snapshot("round2_distinctive_fee_after_rebalance", USER);
    }

    function testRound2RebalanceZeroValueSettlement() public {
        _setRound2FeeParams(50_000_000_000_000_000, 20_000_000_000_000_000);
        _execute(
            "round2_zero_value_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(0), OWNER_SAFE)
        );
        _probeFlashMint("round2_zero_value_fee_seed", 1_000_000, 0);
        _snapshot("round2_zero_value_before_rebalance", USER);
        _warpToNextRebalanceWindow("round2_zero_value_rebalance");
        vm.mockCall(
            FEE_POLICY,
            abi.encodeWithSelector(COMPUTE_REBALANCE_VAL_SELECTOR),
            abi.encode(uint256(0), false)
        );
        console2.log(
            "OBS:{\"kind\":\"mock\",\"label\":\"round2_zero_value_computeRebalanceVal\",\"returnRebalanceValue\":0,\"isPerpSrPayer\":false}"
        );
        _snapshot("round2_zero_value_before_rebalance_call", USER);
        _callRebalanceAndLogPlan("round2_zero_value_rebalance");
        _snapshot("round2_zero_value_after_rebalance", USER);
    }

    function testRound2ProtocolFeeOwnerAndCollectorBounds() public {
        _execute(
            "round2_protocol_fee_config",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(50_000_000_000_000), USER)
        );
        (uint256 srOut, uint256 jrOut) =
            _probeFlashMint("round2_protocol_fee_seed_mint", 50_000_000, 100_000_000);
        _probeFlashRedeem("round2_protocol_fee_seed_redeem", srOut, jrOut);
        uint256 srProtocolBefore = controller.protocolFeeBals(PERP_SR);
        uint256 jrProtocolBefore = controller.protocolFeeBals(PERP_JR);
        require(srProtocolBefore > 0 && jrProtocolBefore > 0, "protocol fee seed must accrue both sides");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"protocol_fee_bounds_before\",\"srProtocolFeeBals\":",
                vm.toString(srProtocolBefore),
                ",\"jrProtocolFeeBals\":",
                vm.toString(jrProtocolBefore),
                ",\"pullSignature\":\"pullProtocolFees(address,address,uint256)\"}"
            )
        );
        _snapshot("round2_protocol_fee_before_withdrawals", USER);
        _execute(
            "round2_protocol_fee_owner_positive",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, PERP_SR, USER, srProtocolBefore)
        );
        uint256 jrBeforeOverwithdraw = controller.protocolFeeBals(PERP_JR);
        _execute(
            "round2_protocol_fee_collector_overdraw",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.pullProtocolFees.selector, PERP_JR, USER, jrBeforeOverwithdraw + 1
            )
        );
        uint256 jrBeforeExactPull = controller.protocolFeeBals(PERP_JR);
        _execute(
            "round2_protocol_fee_collector_exact",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.pullProtocolFees.selector, PERP_JR, USER, jrBeforeExactPull
            )
        );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"protocol_fee_bounds_after\",\"srProtocolFeeBals\":",
                vm.toString(controller.protocolFeeBals(PERP_SR)),
                ",\"jrProtocolFeeBals\":",
                vm.toString(controller.protocolFeeBals(PERP_JR)),
                ",\"jrPulledExact\":",
                vm.toString(jrBeforeExactPull),
                "}"
            )
        );
        _snapshot("round2_protocol_fee_after_withdrawals", USER);
    }

    function testRound2PublicRolloverShortfall() public {
        _prepareRound2StaleRollover();
        uint256 baseline = vm.snapshotState();
        _runRound2ShortfallRollover("below_min_cleanup", 100_000_000, 0);
        require(vm.revertToState(baseline), "failed to restore stale rollover baseline");
        _runRound2ShortfallRollover("partial_above_min_cleanup", 10_000_000, 20_000_000);
    }

    function testRound2SrLazyRolloverMinCleanupThreshold() public {
        _prepareRound2StaleRollover();
        uint256 baseline = vm.snapshotState();
        _execute(
            "round2_sr_lazy_below_cleanup_threshold",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 100_000_000)
        );
        _snapshot("round2_sr_lazy_below_cleanup_before", USER);
        _probeFlashMint("round2_sr_lazy_below_cleanup", 2_000_000, 0);
        _snapshot("round2_sr_lazy_below_cleanup_after", USER);
        require(vm.revertToState(baseline), "failed to restore stale rollover baseline");
        _execute(
            "round2_sr_lazy_above_cleanup_threshold",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 1_000_000)
        );
        _snapshot("round2_sr_lazy_above_cleanup_before", USER);
        _probeFlashMint("round2_sr_lazy_above_cleanup", 2_000_000, 0);
        _snapshot("round2_sr_lazy_above_cleanup_after", USER);
    }

    function testRound2JrPayerRebalanceWithNoFreeRolloverLiquidity() public {
        _prepareRound2StaleRollover();
        _execute(
            "round2_jr_payer_rebalance_set_min_cleanup",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 1_000_000)
        );
        (, , IControllerProbe.ReserveData memory jrReserve) = controller.systemReserveState();
        _execute(
            "round2_jr_payer_rebalance_set_liquidity_floor",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.updateLiquidityThresholds.selector, jrReserve.underlyingBal, uint64(0)
            )
        );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"jr_payer_shortfall_controls\",\"jrIdle\":",
                vm.toString(jrReserve.underlyingBal),
                ",\"reserved\":",
                vm.toString(controller.reservedPerpJrLiquidity()),
                ",\"available\":",
                vm.toString(controller.availPerpJrLiquidity()),
                ",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                "}"
            )
        );
        _snapshot("round2_jr_payer_before_rebalance", USER);
        _warpToNextRebalanceWindow("round2_jr_payer_rebalance");
        _snapshot("round2_jr_payer_before_rebalance_call", USER);
        _callRebalanceAndLogPlan("round2_jr_payer_rebalance");
        _snapshot("round2_jr_payer_after_rebalance", USER);
    }

    function testRound3ValueCapSrMintBoundary() public {
        _requireRound3NoStaleRows();
        vm.prank(controller.keeper());
        controller.updateValueCap(1);
        (uint256 subDRPre,) = controller.systemDeviations();
        require(subDRPre > 1e18, "SR corrective boundary requires subDR above one");
        _logRound3ValueCapSetup(subDRPre);
        uint256 crossingAmount = _searchRound3SrMintBoundary();
        _constructRound3JrCorrectionState(10_000_000);
        _searchRound3JrMintBoundary();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"value_cap_mirrored_setup\",\"srCrossingAmount\":",
                vm.toString(crossingAmount),
                ",\"jrCorrectionSetupMint\":10000000}"
            )
        );
    }

    function _searchRound3SrMintBoundary() private returns (uint256 crossingAmount) {
        uint256 low = 100_000;
        uint256 high = 4_000_000;
        (bool lowOk, uint256 lowSubDR,) = _attemptRound3SrMint(low, 0);
        (bool highOk, uint256 highSubDR, bytes4 highSelector) = _attemptRound3SrMint(high, 0);
        require(lowOk, "small corrective mint did not succeed");
        while (highOk) {
            low = high;
            lowSubDR = highSubDR;
            require(high < 1e15, "could not bracket value-cap crossing below 1e15");
            high *= 2;
            (highOk, highSubDR, highSelector) = _attemptRound3SrMint(high, 0);
        }
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            (bool success, uint256 postSubDR, bytes4 selector) = _attemptRound3SrMint(middle, 0);
            if (success) {
                low = middle;
                lowSubDR = postSubDR;
            } else {
                high = middle;
                highSelector = selector;
            }
        }

        (bool highControlSuccess, uint256 highWouldBeSubDR, bytes4 highControlSelector) =
            _attemptRound3SrMint(high, type(uint256).max);
        string memory result = string.concat(
            "OBS:{\"kind\":\"value_cap_boundary_result\",\"largestSuccess\":",
            vm.toString(low),
            ",\"largestSuccessPostSubDR\":",
            vm.toString(lowSubDR),
            ",\"smallestFail\":",
            vm.toString(high),
            ",\"capFailSelector\":\"",
            _selectorHex(highSelector),
            "\""
        );
        result = string.concat(
            result,
            ",\"capDisabledWouldBeSuccess\":",
            vm.toString(highControlSuccess),
            ",\"capDisabledWouldBeSubDR\":",
            vm.toString(highWouldBeSubDR),
            ",\"capDisabledSelector\":\"",
            _selectorHex(highControlSelector),
            "\""
        );
        result = string.concat(
            result,
            ",\"boundaryGap\":",
            vm.toString(high - low),
            ",\"equalsOneAllowed\":",
            vm.toString(lowSubDR == 1e18),
            "}"
        );
        console2.log(result);
        crossingAmount = high;
    }

    function _constructRound3JrCorrectionState(uint256 srAmount) private {
        vm.prank(controller.keeper());
        controller.updateValueCap(type(uint256).max);
        deal(CBBTC, USER, srAmount);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        controller.flashMint2(srAmount, 0, 0, 0);
        (uint256 subDR,) = controller.systemDeviations();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"value_cap_mirrored_state\",\"srMint\":",
                vm.toString(srAmount),
                ",\"subDR\":",
                vm.toString(subDR),
                "}"
            )
        );
        require(subDR < 1e18, "failed to construct subDR below one");
        vm.prank(controller.keeper());
        controller.updateValueCap(1);
    }

    function _searchRound3JrMintBoundary() private {
        (uint256 subDRPre,) = controller.systemDeviations();
        require(subDRPre < 1e18, "JR correction requires subDR below one");
        uint256 low = 100_000;
        uint256 high = 4_000_000;
        (bool lowOk, uint256 lowSubDR,) = _attemptRound3JrMint(low, 0);
        (bool highOk, uint256 highSubDR, bytes4 highSelector) = _attemptRound3JrMint(high, 0);
        require(lowOk, "small JR corrective mint did not succeed");
        while (highOk) {
            low = high;
            lowSubDR = highSubDR;
            require(high < 1e15, "could not bracket JR value-cap crossing below 1e15");
            high *= 2;
            (highOk, highSubDR, highSelector) = _attemptRound3JrMint(high, 0);
        }
        while (low + 1 < high) {
            uint256 middle = (low + high) / 2;
            (bool success, uint256 postSubDR, bytes4 selector) = _attemptRound3JrMint(middle, 0);
            if (success) {
                low = middle;
                lowSubDR = postSubDR;
            } else {
                high = middle;
                highSelector = selector;
            }
        }
        (bool controlSuccess, uint256 wouldBePost, bytes4 controlSelector) =
            _attemptRound3JrMint(high, type(uint256).max);
        string memory result = string.concat(
            "OBS:{\"kind\":\"value_cap_jr_boundary_result\",\"largestSuccess\":",
            vm.toString(low),
            ",\"largestSuccessPostSubDR\":",
            vm.toString(lowSubDR),
            ",\"smallestFail\":",
            vm.toString(high),
            ",\"capFailSelector\":\"",
            _selectorHex(highSelector),
            "\""
        );
        result = string.concat(
            result,
            ",\"capDisabledWouldBeSuccess\":",
            vm.toString(controlSuccess),
            ",\"capDisabledWouldBeSubDR\":",
            vm.toString(wouldBePost),
            ",\"capDisabledSelector\":\"",
            _selectorHex(controlSelector),
            "\""
        );
        result = string.concat(
            result,
            ",\"boundaryGap\":",
            vm.toString(high - low),
            ",\"equalsOneAllowed\":",
            vm.toString(lowSubDR == 1e18),
            "}"
        );
        console2.log(result);
    }

    function _requireRound3NoStaleRows() private view {
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        uint32 minMaturity = controller.minMaturitySec();
        for (uint256 i; i < sr.trancheData.length; ++i) {
            require(
                !sr.trancheData[i].data.isMature && sr.trancheData[i].data.secondsToMaturity > minMaturity,
                "SR stale row would interfere with boundary search"
            );
        }
        for (uint256 i; i < jr.trancheData.length; ++i) {
            require(
                !jr.trancheData[i].data.isMature && jr.trancheData[i].data.secondsToMaturity > minMaturity,
                "JR stale row would interfere with boundary search"
            );
        }
    }

    function _logRound3ValueCapSetup(uint256 subDRPre) private view {
        (IControllerProbe.SystemState memory setupState,,) = controller.systemReserveState();
        string memory setup = string.concat(
            "OBS:{\"kind\":\"value_cap_boundary_setup\",\"valueCap\":",
            vm.toString(controller.valueCap()),
            ",\"preSubDR\":",
            vm.toString(subDRPre)
        );
        setup = string.concat(
            setup,
            ",\"totalReserveValue\":",
            vm.toString(setupState.perpSr.reserveValue + setupState.perpJr.reserveValue),
            ",\"staleRows\":0}"
        );
        console2.log(setup);
    }

    function testRound3SrLazyRolloverCleanupThresholdEdges() public {
        _prepareRound2StaleRollover();
        uint256 baseline = vm.snapshotState();
        _runRound3LazyThresholdCase("threshold_minus_1", 999_999);
        require(vm.revertToState(baseline), "failed to restore threshold-minus-one baseline");
        baseline = vm.snapshotState();
        _runRound3LazyThresholdCase("threshold_exact", 1_000_000);
        require(vm.revertToState(baseline), "failed to restore exact-threshold baseline");
        baseline = vm.snapshotState();
        _runRound3LazyThresholdCase("threshold_plus_1", 1_000_001);
        require(vm.revertToState(baseline), "failed to restore threshold-plus-one baseline");
        baseline = vm.snapshotState();
        _runRound3LazyThresholdWithPreexistingIdle();
        require(vm.revertToState(baseline), "failed to restore preexisting-idle baseline");
    }

    function testRound3PublicRolloverPartialAndNonzeroBelowMinCleanup() public {
        _prepareRound2StaleRollover();
        uint256 baseline = vm.snapshotState();
        _runRound3PublicShortfallCase("nonzero_free_below_min", 20_000_000, 10_000_000, 10);
        require(vm.revertToState(baseline), "failed to restore nonzero-shortfall baseline");
        baseline = vm.snapshotState();
        _runRound3PublicShortfallCase("partial_completable_candidate", 10_000_000, 30_000_000, 65);
        require(vm.revertToState(baseline), "failed to restore partial-rollover baseline");
    }

    function testRound3SrLazyRolloverInsufficientLiquidity() public {
        _prepareRound2StaleRollover();
        _execute(
            "round3_lazy_insufficient_set_min_cleanup",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 1_000_000)
        );
        deal(CBBTC, PERP_JR, 0);
        _execute(
            "round3_lazy_insufficient_set_liquidity_thresholds",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(0), uint64(0))
        );
        (, , IControllerProbe.ReserveData memory jr) = controller.systemReserveState();
        for (uint256 i; i < jr.trancheData.length; ++i) {
            if (jr.trancheData[i].data.isMature || jr.trancheData[i].data.secondsToMaturity <= controller.minMaturitySec()) {
                deal(jr.trancheData[i].data.tranche, PERP_JR, 0);
                break;
            }
        }
        (, , jr) = controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"sr_lazy_insufficient_controls\",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                ",\"jrIdle\":",
                vm.toString(jr.underlyingBal),
                ",\"jrAvailable\":",
                vm.toString(controller.availPerpJrLiquidity()),
                ",\"srInput\":2000000}"
            )
        );
        _snapshot("round3_lazy_insufficient_before_mint", USER);
        _probeFlashMint("round3_lazy_input_above_completable_candidate", 2_000_000, 0);
        _snapshot("round3_lazy_insufficient_after_mint", USER);
    }

    function testReviewCollectedFeesAcrossJrFlashMint() public {
        _execute(
            "review_jr_flash_set_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(0), OWNER_SAFE)
        );
        _probeFlashMint("review_jr_flash_fee_seed", 1_000_000, 2_000_000);
        _snapshot("review_jr_flash_fee_before", USER);
        _probeFlashMint("review_jr_flash_fee_settlement_candidate", 0, 1_000_000);
        _snapshot("review_jr_flash_fee_after", USER);
    }

    function testReviewCollectedFeesAcrossJrMint2() public {
        _execute(
            "review_jr_mint_set_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(0), OWNER_SAFE)
        );
        _probeFlashMint("review_jr_mint_fee_seed", 1_000_000, 2_000_000);
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            "review_jr_mint_fee_deposit",
            USER,
            BONDS_MANAGER,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        _snapshot("review_jr_mint_fee_before", USER);
        _execute(
            "review_jr_mint_fee_settlement_candidate",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.mint2.selector,
                IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
                IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
                0,
                0
            )
        );
        _snapshot("review_jr_mint_fee_after", USER);
    }

    function testReviewCbBtcFeesAcrossSuccessfulRebalance() public {
        _execute(
            "review_cbbtc_fee_set_protocol_max_zero",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(0), OWNER_SAFE)
        );
        (uint256 srOut, uint256 jrOut) = _probeFlashMint("review_cbbtc_fee_seed_mint", 1_000_000, 2_000_000);
        _probeFlashRedeem("review_cbbtc_fee_seed_redeem", srOut, jrOut);
        _snapshot("review_cbbtc_fee_before_rebalance", USER);
        vm.warp(1794247200);
        _refreshOracleForWarpedTimestamp("review_cbbtc_fee_rebalance");
        _execute(
            "review_cbbtc_fee_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot("review_cbbtc_fee_after_rebalance", USER);
    }

    function testReviewPerSideFeePolicyCalls() public {
        IFeePolicyProbe feePolicy = IFeePolicyProbe(FEE_POLICY);
        IFeePolicyProbe.PerpFeeParams memory srParams = feePolicy.perpSrFees();
        IFeePolicyProbe.PerpFeeParams memory jrParams = feePolicy.perpJrFees();
        srParams.basePerc = 10_000_000_000_000;
        srParams.flashBasePerc = 100_000_000_000_000;
        jrParams.basePerc = 20_000_000_000_000;
        jrParams.flashBasePerc = 200_000_000_000_000;
        _execute(
            "review_update_per_side_fee_params",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSelector(IFeePolicyProbe.updateFeeParams.selector, srParams, jrParams)
        );
        _probeFlashMint("review_both_sided_per_side_fee_flash_mint", 1_000_000, 2_000_000);

        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            "review_mint2_tranche_deposit",
            USER,
            BONDS_MANAGER,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        _snapshot("review_mint2_per_side_fee_before", USER);
        bytes memory mintCall = abi.encodeWithSelector(
            IControllerProbe.mint2.selector,
            IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
            IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
            0,
            0
        );
        (bool minted, bytes memory mintRet) = _execute("review_mint2_per_side_fee", USER, CONTROLLER, mintCall);
        if (minted) {
            (uint256 srOut, uint256 jrOut, IControllerProbe.FeePerc memory srFee, IControllerProbe.FeePerc memory jrFee) =
                abi.decode(mintRet, (uint256, uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc));
            _observeMintReturns("review_mint2_per_side_fee", srOut, jrOut, srFee, jrFee);
        }
        _snapshot("review_mint2_per_side_fee_after", USER);
    }

    function testReviewProtocolFeeSplitAndPullCallers() public {
        _execute(
            "review_protocol_split_config",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateProtocolFeeConfig(uint64,address)", uint64(50_000_000_000_000), USER)
        );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_protocol_collector\",\"address\":\"",
                vm.toString(IFeePolicyProbe(FEE_POLICY).protocolFeeCollector()),
                "\"}"
            )
        );
        (uint256 srOut, uint256 jrOut) =
            _probeFlashMint("review_protocol_split_seed_mint", 50_000_000, 100_000_000);
        _probeFlashRedeem("review_protocol_split_seed_redeem", srOut, jrOut);
        _snapshot("review_protocol_split_before_pull", USER);
        uint256 srProtocol = controller.protocolFeeBals(PERP_SR);
        uint256 jrProtocol = controller.protocolFeeBals(PERP_JR);
        uint256 underlyingProtocol = controller.protocolFeeBals(CBBTC);
        _execute(
            "review_protocol_pull_as_collector",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, PERP_SR, USER, srProtocol)
        );
        _execute(
            "review_protocol_pull_as_random",
            address(0xCAFE),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.pullProtocolFees.selector, PERP_JR, USER, jrProtocol)
        );
        _execute(
            "review_protocol_pull_as_owner",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.pullProtocolFees.selector, CBBTC, USER, underlyingProtocol
            )
        );
        _snapshot("review_protocol_split_after_pull", USER);
    }

    function testReviewJrRedeemLiquidityFailureBelowWadFee() public {
        (IControllerProbe.SystemState memory state,, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        uint256 availableTarget = 1_000;
        _execute(
            "review_jr_liquidity_set_absolute_floor",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.updateLiquidityThresholds.selector, jr.underlyingBal - availableTarget, uint64(0)
            )
        );
        uint256 available = controller.availPerpJrLiquidity();
        uint256 perpIn = (available + 1) * state.perpJr.totalSupply / state.perpJr.reserveValue;
        while (perpIn * state.perpJr.reserveValue / state.perpJr.totalSupply <= available) ++perpIn;
        uint256 grossUnderlying = perpIn * state.perpJr.reserveValue / state.perpJr.totalSupply;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_jr_liquidity_case\",\"available\":",
                vm.toString(available),
                ",\"reserveValue\":",
                vm.toString(state.perpJr.reserveValue),
                ",\"supply\":",
                vm.toString(state.perpJr.totalSupply),
                ",\"perpIn\":",
                vm.toString(perpIn),
                ",\"grossUnderlyingFloor\":",
                vm.toString(grossUnderlying),
                "}"
            )
        );
        deal(PERP_JR, USER, perpIn);
        _probeFlashRedeem("review_jr_redeem_over_available_below_wad_fee", 0, perpIn);
    }

    function testReviewJrRedeemWithFeeAtWadWithinLiquidity() public {
        IFeePolicyProbe feePolicy = IFeePolicyProbe(FEE_POLICY);
        IFeePolicyProbe.PerpFeeParams memory srParams = feePolicy.perpSrFees();
        IFeePolicyProbe.PerpFeeParams memory jrParams = feePolicy.perpJrFees();
        jrParams.basePerc = uint64(1e18);
        jrParams.flashBasePerc = uint64(1e18);
        _execute(
            "review_jr_fee_set_at_wad",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSelector(IFeePolicyProbe.updateFeeParams.selector, srParams, jrParams)
        );
        uint256 perpIn = 100_000;
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 grossUnderlying = perpIn * state.perpJr.reserveValue / state.perpJr.totalSupply;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_jr_high_fee_case\",\"perpIn\":",
                vm.toString(perpIn),
                ",\"grossUnderlyingFloor\":",
                vm.toString(grossUnderlying),
                ",\"available\":",
                vm.toString(controller.availPerpJrLiquidity()),
                "}"
            )
        );
        deal(PERP_JR, USER, perpIn);
        _probeFlashRedeem("review_jr_redeem_fee_at_wad", 0, perpIn);
    }

    function testReviewPublicRolloverWithHighCleanupThreshold() public {
        _execute(
            "review_rollover_raise_min_cleanup",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 100_000_000)
        );
        _snapshot("review_rollover_high_cleanup_before", USER);
        _execute(
            "review_rollover_high_cleanup",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        _snapshot("review_rollover_high_cleanup_after", USER);
    }

    function testReviewSrLazyFlashMintAboveRaisedCleanupThreshold() public {
        _execute(
            "review_sr_lazy_raise_min_cleanup_above_input",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 100_000_000)
        );
        _warpPastIssueAndNearestMaturity("review_sr_lazy_high_cleanup");
        _snapshot("review_sr_lazy_high_cleanup_before", USER);
        _probeFlashMint("review_sr_lazy_high_cleanup_flash_mint", 2_000_000, 0);
        _snapshot("review_sr_lazy_high_cleanup_after", USER);
    }

    function testReviewRedeem2FeeAndBasketRounding() public {
        IFeePolicyProbe feePolicy = IFeePolicyProbe(FEE_POLICY);
        IFeePolicyProbe.PerpFeeParams memory srParams = feePolicy.perpSrFees();
        IFeePolicyProbe.PerpFeeParams memory jrParams = feePolicy.perpJrFees();
        srParams.basePerc = 10_000_000_000_000;
        jrParams.basePerc = 20_000_000_000_000;
        _execute(
            "review_redeem2_set_per_side_fee_params",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSelector(IFeePolicyProbe.updateFeeParams.selector, srParams, jrParams)
        );
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, USER, 1_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(BONDS_MANAGER, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            "review_redeem2_deposit_latest",
            USER,
            BONDS_MANAGER,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, 1_000_000)
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        (bool minted, bytes memory mintRet) = _execute(
            "review_redeem2_seed_mint",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.mint2.selector,
                IControllerProbe.TokenAmount(srTranche.token, srTranche.amount),
                IControllerProbe.TokenAmount(jrTranche.token, jrTranche.amount),
                0,
                0
            )
        );
        if (!minted) return;
        (uint256 srOut, uint256 jrOut,,) =
            abi.decode(mintRet, (uint256, uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc));
        uint256 firstSrIn = srOut / 2;
        uint256 firstJrIn = jrOut / 2;
        _snapshot("review_redeem2_first_before", USER);
        bytes memory firstCall = abi.encodeWithSelector(
            IControllerProbe.redeem2.selector, firstSrIn, firstJrIn, uint256(0)
        );
        (bool firstSuccess, bytes memory firstRet) =
            _execute("review_redeem2_first_partial", USER, CONTROLLER, firstCall);
        if (firstSuccess) _observeRedeem2Returns(firstRet);
        _snapshot("review_redeem2_first_after", USER);

        _snapshot("review_redeem2_second_before", USER);
        bytes memory secondCall = abi.encodeWithSelector(
            IControllerProbe.redeem2.selector, srOut - firstSrIn, jrOut - firstJrIn, uint256(0)
        );
        (bool secondSuccess, bytes memory secondRet) =
            _execute("review_redeem2_second_remainder", USER, CONTROLLER, secondCall);
        if (secondSuccess) _observeRedeem2Returns(secondRet);
        _snapshot("review_redeem2_second_after", USER);
    }

    function testReviewRebalanceWindowStartMinus1() public {
        _runReviewRebalanceEdge(0);
    }

    function testReviewRebalanceWindowStart() public {
        _runReviewRebalanceEdge(1);
    }

    function testReviewRebalanceWindowEndMinus1() public {
        _runReviewRebalanceEdge(2);
    }

    function testReviewRebalanceWindowEnd() public {
        _runReviewRebalanceEdge(3);
    }

    function testReviewRebalanceWindowEndPlus1() public {
        _runReviewRebalanceEdge(4);
    }

    function _runReviewRebalanceEdge(uint8 edge) private {
        uint256 freq = controller.rebalanceFreqSec();
        uint256 base = uint256(controller.lastRebalanceTimestampSec()) + 2 * freq;
        (uint64 start, uint64 end) = controller.rebalanceWindow(base);
        if (edge == 0) _reviewRebalanceEdge("window_start_minus_1", uint256(start) - 1);
        else if (edge == 1) _reviewRebalanceEdge("window_start", start);
        else if (edge == 2) _reviewRebalanceEdge("window_end_minus_1", uint256(end) - 1);
        else if (edge == 3) _reviewRebalanceEdge("window_end", end);
        else _reviewRebalanceEdge("window_end_plus_1", uint256(end) + 1);
    }

    function _reviewRebalanceEdge(string memory label, uint256 timestamp) private {
        (uint64 start, uint64 end) = controller.rebalanceWindow(timestamp);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"review_rebalance_edge\",\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(timestamp),
                ",\"windowStart\":",
                vm.toString(uint256(start)),
                ",\"windowEnd\":",
                vm.toString(uint256(end)),
                ",\"lastRebalance\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                "}"
            )
        );
        vm.warp(timestamp);
        _refreshOracleForWarpedTimestamp(string.concat("review_rebalance_", label));
        _snapshot(string.concat("review_rebalance_", label, "_before"), USER);
        _execute(
            string.concat("review_rebalance_", label),
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot(string.concat("review_rebalance_", label, "_after"), USER);
    }

    function testFollowupAumFee1h() public {
        _runAumFeeCase(3600);
    }

    function testFollowupAumFee1d() public {
        _runAumFeeCase(86400);
    }

    function testFollowupAumFee7d() public {
        _runAumFeeCase(604800);
    }

    function _runAumFeeCase(uint256 elapsed) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"aum_fee_case\",\"elapsedSec\":",
                vm.toString(elapsed),
                ",\"rateSr\":1000000000,\"rateJr\":1000000000}"
            )
        );
        _snapshot("aum_fee_before", USER);
        _execute(
            "aum_fee_update_rates",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSignature("updateAumFeePerc(uint64,uint64)", uint64(1_000_000_000), uint64(1_000_000_000))
        );
        vm.warp(block.timestamp + elapsed);
        _refreshOracleForWarpedTimestamp("aum_fee_elapsed");
        _snapshot("aum_fee_elapsed_before_op", USER);
        _execute(
            "aum_fee_elapsed_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot("aum_fee_after_rebalance", USER);
        _probeFlashMint("aum_fee_triggering_flash_mint", 1_000_000, 0);
        _snapshot("aum_fee_after_op", USER);
    }

    function testFollowupLiquidityCapAndRolloverEligibility() public {
        _snapshot("followup_controls_before", USER);
        _execute(
            "rollover_default_eligibility_default_liquidity",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        (IControllerProbe.SystemState memory state, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr)
        = controller.systemReserveState();
        uint256 reserveValue = state.perpJr.reserveValue;
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"liquidity_formula_input\",\"jrReserveValue\":",
                vm.toString(reserveValue),
                ",\"jrIdleUnderlying\":",
                vm.toString(jr.underlyingBal),
                ",\"absFloor\":",
                vm.toString(controller.perpJrReservedUnderlyingAmt()),
                ",\"percFloor\":",
                vm.toString(uint256(controller.perpJrReservedUnderlyingPerc())),
                ",\"reservedObserved\":",
                vm.toString(controller.reservedPerpJrLiquidity()),
                ",\"availableObserved\":",
                vm.toString(controller.availPerpJrLiquidity()),
                "}"
            )
        );
        _execute(
            "liquidity_thresholds_10pct",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(50_000_000), uint64(1e17))
        );
        _snapshot("liquidity_thresholds_10pct_after", USER);
        _execute(
            "liquidity_thresholds_50pct",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(0), uint64(5e17))
        );
        _snapshot("liquidity_thresholds_50pct_after", USER);
        _execute(
            "liquidity_thresholds_above_reserve",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(500_000_000), uint64(5e17))
        );
        _snapshot("liquidity_thresholds_above_reserve_after", USER);
        _execute(
            "liquidity_thresholds_restore_baseline",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(1_000_000), uint64(1e16))
        );
        _snapshot("liquidity_thresholds_restored", USER);

        _execute(
            "rollover_eligibility_raise_to_1m",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateRolloverEligibility.selector, uint32(1_000_000))
        );
        _snapshot("rollover_eligibility_after", USER);
        _execute("rollover_eligibility_rollover", controller.keeper(), CONTROLLER, abi.encodeWithSelector(IControllerProbe.rollover.selector));
        _snapshot("rollover_eligibility_after_rollover", USER);

        (state,,) = controller.systemReserveState();
        uint256 cap = state.perpSr.reserveValue + state.perpJr.reserveValue;
        _execute(
            "value_cap_set_to_current_tvl",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, cap)
        );
        deal(CBBTC, USER, 1_100_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _snapshot("value_cap_current_tvl", USER);
        _execute(
            "value_cap_double_sided_over",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, uint256(1_000_000), uint256(1_000_000), uint256(0), uint256(0))
        );
        _snapshot("value_cap_after_double_sided", USER);
        _execute(
            "value_cap_sr_only_corrective",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, uint256(1_000_000), uint256(0), uint256(0), uint256(0))
        );
        _snapshot("value_cap_after_sr_only", USER);
        _execute(
            "value_cap_jr_only_worsening",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, uint256(0), uint256(1_000_000), uint256(0), uint256(0))
        );
        _snapshot("value_cap_after_jr_only", USER);
        _execute(
            "value_cap_sr_only_large_crossing_candidate",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, uint256(1_000_000_000), uint256(0), uint256(0), uint256(0))
        );
        _snapshot("value_cap_after_large_sr_only", USER);
    }

    function testFollowupValueCapLargeSrMintUncapped() public {
        _snapshot("large_sr_mint_uncapped_before", USER);
        _execute(
            "large_sr_mint_uncapped_raise_value_cap",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, uint256(10_000_000_000))
        );
        deal(CBBTC, USER, 1_000_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _probeFlashMint("large_sr_mint_uncapped", 1_000_000_000, 0);
        _snapshot("large_sr_mint_uncapped_after", USER);
    }

    function testFollowupValueCapLargeSrMintAtCurrentCap() public {
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 currentTvl = state.perpSr.reserveValue + state.perpJr.reserveValue;
        _snapshot("large_sr_mint_at_cap_before", USER);
        _execute(
            "large_sr_mint_set_cap_just_above_current_tvl",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, currentTvl + 1)
        );
        deal(CBBTC, USER, 1_000_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        _probeFlashMint("large_sr_mint_at_cap", 1_000_000_000, 0);
        _snapshot("large_sr_mint_at_cap_after", USER);
    }

    function testFollowupSrPayerRebalance() public {
        _execute(
            "sr_payer_rebalance_raise_value_cap",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, uint256(10_000_000_000))
        );
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, USER, 1_000_000_000);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(info.manager, type(uint256).max);
        (bool deposited, bytes memory depositRet) = _execute(
            "sr_payer_rebalance_deposit",
            USER,
            info.manager,
            abi.encodeWithSignature("deposit(bytes32,uint256)", info.bondID, uint256(1_000_000_000))
        );
        if (!deposited) return;
        (IBondsManagerProbe.TokenAmount memory srTranche,) =
            abi.decode(depositRet, (IBondsManagerProbe.TokenAmount, IBondsManagerProbe.TokenAmount));
        _observeTokenAmount("sr_payer_rebalance_sr_tranche", srTranche);
        vm.prank(USER);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        IControllerProbe.TokenAmount memory srIn = IControllerProbe.TokenAmount(srTranche.token, srTranche.amount);
        IControllerProbe.TokenAmount memory jrIn = IControllerProbe.TokenAmount(info.jrTranche, 0);
        _execute(
            "sr_payer_rebalance_mint2_sr_only",
            USER,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.mint2.selector, srIn, jrIn, uint256(0), uint256(0))
        );
        _snapshot("sr_payer_rebalance_after_mint2", USER);
        uint256 rebalanceTs = uint256(controller.lastRebalanceTimestampSec()) + controller.rebalanceFreqSec();
        if (rebalanceTs <= block.timestamp) rebalanceTs += controller.rebalanceFreqSec();
        vm.warp(rebalanceTs);
        _refreshOracleForWarpedTimestamp("sr_payer_rebalance");
        _snapshot("sr_payer_rebalance_before", USER);
        _execute(
            "sr_payer_rebalance",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rebalance.selector)
        );
        _snapshot("sr_payer_rebalance_after", USER);
    }

    function testFlashRedeemJrReserveFloorJustBelowBoundary() public {
        uint256 jrSupply = IERC20Probe(PERP_JR).totalSupply();
        uint256 available = controller.availPerpJrLiquidity();
        (IControllerProbe.SystemState memory state,,) = controller.systemReserveState();
        uint256 boundaryAmount = jrSupply * available / state.perpJr.reserveValue;
        deal(PERP_JR, USER, jrSupply);
        _snapshot("jr_floor_just_below_before", USER);
        _probeFlashRedeem("jr_floor_just_below", 0, boundaryAmount);
    }

    function _probeFlashMint(string memory label, uint256 srUnderlyingIn, uint256 jrUnderlyingIn)
        private
        returns (uint256 srOut, uint256 jrOut)
    {
        deal(CBBTC, USER, srUnderlyingIn + jrUnderlyingIn);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"flashMint2_input\",\"label\":\"",
                label,
                "\",\"srUnderlying\":",
                vm.toString(srUnderlyingIn),
                ",\"jrUnderlying\":",
                vm.toString(jrUnderlyingIn),
                ",\"minSrOut\":0,\"minJrOut\":0}"
            )
        );
        _snapshot(string.concat(label, "_before"), USER);
        bytes memory callData = abi.encodeWithSelector(
            IControllerProbe.flashMint2.selector, srUnderlyingIn, jrUnderlyingIn, 0, 0
        );
        (bool success, bytes memory ret) = _execute(label, USER, CONTROLLER, callData);
        if (!success && ret.length >= 4 && bytes4(ret) == bytes4(keccak256("ValueCapExceeded()"))) {
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"value_cap_blocked_probe\",\"label\":\"",
                    label,
                    "\",\"oldValueCap\":",
                    vm.toString(controller.valueCap()),
                    ",\"raisedValueCap\":1000000000000000000000000000000}"
                )
            );
            _snapshot(string.concat(label, "_before_owner_valueCap_raise"), USER);
            _execute(
                "owner_raise_valueCap_to_1e30",
                OWNER_SAFE,
                CONTROLLER,
                abi.encodeWithSelector(IControllerProbe.updateValueCap.selector, 1e30)
            );
            _snapshot(string.concat(label, "_after_owner_valueCap_raise"), USER);
            (success, ret) = _execute(string.concat(label, "_retry_after_valueCap_raise"), USER, CONTROLLER, callData);
        }
        if (success) {
            IControllerProbe.FeePerc memory srFee;
            IControllerProbe.FeePerc memory jrFee;
            (srOut, jrOut, srFee, jrFee) = abi.decode(
                ret, (uint256, uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc)
            );
            _observeMintReturns(label, srOut, jrOut, srFee, jrFee);
        }
        _snapshot(string.concat(label, "_after"), USER);
    }

    function _probeFlashRedeem(string memory label, uint256 srAmt, uint256 jrAmt) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"flashRedeem2_input\",\"label\":\"",
                label,
                "\",\"perpSrAmt\":",
                vm.toString(srAmt),
                ",\"perpJrAmt\":",
                vm.toString(jrAmt),
                ",\"minUnderlyingOut\":0}"
            )
        );
        _snapshot(string.concat(label, "_before"), USER);
        bytes memory callData = abi.encodeWithSelector(IControllerProbe.flashRedeem2.selector, srAmt, jrAmt, 0);
        (bool success, bytes memory ret) = _execute(label, USER, CONTROLLER, callData);
        if (success) {
            (uint256 underlyingOut, IControllerProbe.FeePerc memory srFee, IControllerProbe.FeePerc memory jrFee) =
                abi.decode(ret, (uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc));
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"flashRedeem2_return\",\"label\":\"",
                    label,
                    "\",\"underlyingOut\":",
                    vm.toString(underlyingOut),
                    ",\"perpSrFeePerc\":{\"total\":",
                    vm.toString(srFee.totalFeePerc),
                    ",\"protocol\":",
                    vm.toString(srFee.protocolFeePerc),
                    "},\"perpJrFeePerc\":{\"total\":",
                    vm.toString(jrFee.totalFeePerc),
                    ",\"protocol\":",
                    vm.toString(jrFee.protocolFeePerc),
                    "}}"
                )
            );
        }
        _snapshot(string.concat(label, "_after"), USER);
    }

    function _probePausedCall(string memory label, address caller, bytes4 selector, bytes memory args) private {
        _snapshot(string.concat(label, "_before"), USER);
        _execute(label, caller, CONTROLLER, abi.encodePacked(selector, args));
        _snapshot(string.concat(label, "_after"), USER);
    }

    function _execute(string memory label, address caller, address target, bytes memory callData)
        private
        returns (bool success, bytes memory ret)
    {
        vm.recordLogs();
        vm.prank(caller);
        (success, ret) = target.call(callData);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        string memory result = string.concat(
            "OBS:{\"kind\":\"call\",\"label\":\"",
            label,
            "\",\"timestamp\":",
            vm.toString(block.timestamp),
            ",\"caller\":\"",
            vm.toString(caller),
            "\",\"target\":\"",
            vm.toString(target),
            "\",\"calldata\":\"",
            vm.toString(callData),
            "\",\"success\":",
            vm.toString(success),
            ",\"returnData\":\"",
            vm.toString(ret),
            "\"}"
        );
        console2.log(result);
        if (!success && ret.length >= 4) {
            bytes4 selector;
            assembly ("memory-safe") {
                selector := mload(add(ret, 32))
            }
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"revert_selector\",\"label\":\"",
                    label,
                    "\",\"selector\":\"",
                    _selectorHex(selector),
                    "\"}"
                )
            );
        }
        for (uint256 i; i < logs.length; ++i) _observeEvent(logs[i]);
    }

    function _setRound2FeeParams(uint64 srFlashFee, uint64 jrFlashFee) private {
        IFeePolicyProbe feePolicy = IFeePolicyProbe(FEE_POLICY);
        IFeePolicyProbe.PerpFeeParams memory srParams = feePolicy.perpSrFees();
        IFeePolicyProbe.PerpFeeParams memory jrParams = feePolicy.perpJrFees();
        srParams.flashBasePerc = srFlashFee;
        jrParams.flashBasePerc = jrFlashFee;
        _execute(
            "round2_set_distinctive_flash_fee_params",
            OWNER_SAFE,
            FEE_POLICY,
            abi.encodeWithSelector(IFeePolicyProbe.updateFeeParams.selector, srParams, jrParams)
        );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"distinctive_fee_settings\",\"srFlashBasePerc\":",
                vm.toString(uint256(srFlashFee)),
                ",\"jrFlashBasePerc\":",
                vm.toString(uint256(jrFlashFee)),
                "}"
            )
        );
    }

    function _attemptRound3SrMint(uint256 amount, uint256 capOverride)
        private
        returns (bool success, uint256 postSubDR, bytes4 selector)
    {
        uint256 snapshot = vm.snapshotState();
        if (capOverride != 0) {
            vm.prank(controller.keeper());
            controller.updateValueCap(capOverride);
        }
        deal(CBBTC, USER, amount);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        bytes memory returnData;
        (success, returnData) = CONTROLLER.call(
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, amount, uint256(0), uint256(0), uint256(0))
        );
        if (success) {
            (postSubDR,) = controller.systemDeviations();
        } else if (returnData.length >= 4) {
            assembly {
                selector := mload(add(returnData, 32))
            }
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"value_cap_boundary_attempt\",\"amount\":",
                vm.toString(amount),
                ",\"capOverride\":",
                vm.toString(capOverride),
                ",\"success\":",
                vm.toString(success),
                ",\"postSubDR\":",
                vm.toString(postSubDR),
                ",\"selector\":\"",
                _selectorHex(selector),
                "\"}"
            )
        );
        require(vm.revertToState(snapshot), "failed to restore cap-boundary snapshot");
    }

    function _attemptRound3JrMint(uint256 amount, uint256 capOverride)
        private
        returns (bool success, uint256 postSubDR, bytes4 selector)
    {
        uint256 snapshot = vm.snapshotState();
        if (capOverride != 0) {
            vm.prank(controller.keeper());
            controller.updateValueCap(capOverride);
        }
        deal(CBBTC, USER, amount);
        vm.prank(USER);
        IERC20Probe(CBBTC).approve(CONTROLLER, type(uint256).max);
        vm.prank(USER);
        bytes memory returnData;
        (success, returnData) = CONTROLLER.call(
            abi.encodeWithSelector(IControllerProbe.flashMint2.selector, uint256(0), amount, uint256(0), uint256(0))
        );
        if (success) {
            (postSubDR,) = controller.systemDeviations();
        } else if (returnData.length >= 4) {
            assembly {
                selector := mload(add(returnData, 32))
            }
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"value_cap_jr_boundary_attempt\",\"amount\":",
                vm.toString(amount),
                ",\"capOverride\":",
                vm.toString(capOverride),
                ",\"success\":",
                vm.toString(success),
                ",\"postSubDR\":",
                vm.toString(postSubDR),
                ",\"selector\":\"",
                _selectorHex(selector),
                "\"}"
            )
        );
        require(vm.revertToState(snapshot), "failed to restore JR cap-boundary snapshot");
    }

    function _prepareRound2StaleRollover() private {
        vm.warp(1_794_510_001);
        _refreshOracleForWarpedTimestamp("round2_stale_rollover_upkeep");
        _execute(
            "round2_stale_rollover_upkeep",
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.upkeep.selector)
        );
        _snapshot("round2_stale_rollover_after_upkeep", USER);
    }

    function _runRound3LazyThresholdCase(string memory label, uint256 srInput) private {
        _execute(
            string.concat("round3_", label, "_set_min_cleanup"),
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 1_000_000)
        );
        (, IControllerProbe.ReserveData memory srBefore,) = controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"sr_lazy_threshold_case\",\"label\":\"",
                label,
                "\",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                ",\"preInputSrIdle\":",
                vm.toString(srBefore.underlyingBal),
                ",\"srInput\":",
                vm.toString(srInput),
                ",\"postInputSrIdleCandidate\":",
                vm.toString(srBefore.underlyingBal + srInput),
                "}"
            )
        );
        _snapshot(string.concat("round3_", label, "_before_mint"), USER);
        _probeFlashMint(string.concat("round3_", label), srInput, 0);
        _snapshot(string.concat("round3_", label, "_after_mint"), USER);
    }

    function _runRound3LazyThresholdWithPreexistingIdle() private {
        deal(CBBTC, PERP_SR, 500_000);
        _execute(
            "round3_idle_vs_input_set_min_cleanup",
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, 1_000_000)
        );
        (, IControllerProbe.ReserveData memory srBefore,) = controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"sr_lazy_idle_vs_input_case\",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                ",\"preInputSrIdle\":",
                vm.toString(srBefore.underlyingBal),
                ",\"srInput\":500001,\"postInputSrIdleCandidate\":",
                vm.toString(srBefore.underlyingBal + 500_001),
                "}"
            )
        );
        _snapshot("round3_idle_vs_input_before_mint", USER);
        _probeFlashMint("round3_idle_vs_input", 500_001, 0);
        _snapshot("round3_idle_vs_input_after_mint", USER);
    }

    function _runRound3PublicShortfallCase(
        string memory label,
        uint256 minCleanup,
        uint256 jrIdle,
        uint256 staleJrPercent
    ) private {
        _execute(
            string.concat("round3_", label, "_set_min_cleanup"),
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, minCleanup)
        );
        deal(CBBTC, PERP_JR, jrIdle);
        _execute(
            string.concat("round3_", label, "_set_liquidity_thresholds"),
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateLiquidityThresholds.selector, uint256(0), uint64(0))
        );
        (, IControllerProbe.ReserveData memory sr, IControllerProbe.ReserveData memory jr) =
            controller.systemReserveState();
        address staleJrTranche;
        uint256 staleJrBalance;
        for (uint256 i; i < jr.trancheData.length; ++i) {
            if (jr.trancheData[i].data.isMature || jr.trancheData[i].data.secondsToMaturity <= controller.minMaturitySec()) {
                staleJrTranche = jr.trancheData[i].data.tranche;
                staleJrBalance = jr.trancheData[i].balance;
                break;
            }
        }
        require(staleJrTranche != address(0), "stale JR tranche not found");
        uint256 reducedStaleJrBalance = staleJrBalance * staleJrPercent / 100;
        deal(staleJrTranche, PERP_JR, reducedStaleJrBalance);
        (, sr, jr) = controller.systemReserveState();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"public_rollover_shortfall_controls\",\"label\":\"",
                label,
                "\",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                ",\"staleUnderlyingVal\":",
                vm.toString(sr.trancheData.length > 1 ? sr.trancheData[1].value : 0),
                ",\"jrIdle\":",
                vm.toString(jr.underlyingBal),
                ",\"staleJrOriginalBalance\":",
                vm.toString(staleJrBalance),
                ",\"staleJrReducedBalance\":",
                vm.toString(reducedStaleJrBalance),
                ",\"staleJrPercent\":",
                vm.toString(staleJrPercent),
                ",\"reserved\":",
                vm.toString(controller.reservedPerpJrLiquidity()),
                ",\"available\":",
                vm.toString(controller.availPerpJrLiquidity()),
                "}"
            )
        );
        _snapshot(string.concat("round3_", label, "_before_rollover"), USER);
        _execute(
            string.concat("round3_", label, "_rollover"),
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        _snapshot(string.concat("round3_", label, "_after_rollover"), USER);
    }

    function _runRound2ShortfallRollover(string memory label, uint256 minCleanup, uint256 requestedFree) private {
        _execute(
            string.concat("round2_", label, "_set_min_cleanup"),
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.updateMinCleanupVal.selector, minCleanup)
        );
        (, , IControllerProbe.ReserveData memory jrReserve) = controller.systemReserveState();
        uint256 desiredFree = requestedFree > jrReserve.underlyingBal ? jrReserve.underlyingBal : requestedFree;
        uint256 reservedAmt = jrReserve.underlyingBal - desiredFree;
        _execute(
            string.concat("round2_", label, "_set_liquidity_floor"),
            OWNER_SAFE,
            CONTROLLER,
            abi.encodeWithSelector(
                IControllerProbe.updateLiquidityThresholds.selector, reservedAmt, uint64(0)
            )
        );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"rollover_shortfall_controls\",\"label\":\"",
                label,
                "\",\"minCleanupVal\":",
                vm.toString(minCleanup),
                ",\"jrIdle\":",
                vm.toString(jrReserve.underlyingBal),
                ",\"reservedAmt\":",
                vm.toString(controller.reservedPerpJrLiquidity()),
                ",\"availPerpJrLiquidity\":",
                vm.toString(controller.availPerpJrLiquidity()),
                ",\"requestedFree\":",
                vm.toString(desiredFree),
                "}"
            )
        );
        _snapshot(string.concat("round2_", label, "_before_rollover"), USER);
        _execute(
            string.concat("round2_", label, "_rollover"),
            controller.keeper(),
            CONTROLLER,
            abi.encodeWithSelector(IControllerProbe.rollover.selector)
        );
        _snapshot(string.concat("round2_", label, "_after_rollover"), USER);
    }

    function _warpToNextRebalanceWindow(string memory label) private {
        uint256 timestamp = block.timestamp + controller.rebalanceFreqSec();
        uint256 afterCooldown = uint256(controller.lastRebalanceTimestampSec()) + controller.rebalanceFreqSec();
        if (timestamp < afterCooldown) timestamp = afterCooldown;
        vm.warp(timestamp);
        (uint64 windowStart, uint64 windowEnd) = controller.rebalanceWindow(timestamp);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"rebalance_schedule\",\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(timestamp),
                ",\"windowStart\":",
                vm.toString(uint256(windowStart)),
                ",\"windowEnd\":",
                vm.toString(uint256(windowEnd)),
                ",\"lastRebalance\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                "}"
            )
        );
        _refreshOracleForWarpedTimestamp(label);
    }

    function _callRebalanceAndLogPlan(string memory label) private {
        (, IControllerProbe.ReserveData memory srBefore, IControllerProbe.ReserveData memory jrBefore) =
            controller.systemReserveState();
        vm.recordLogs();
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerProbe.rebalance.selector));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"call\",\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"caller\":\"",
                vm.toString(controller.keeper()),
                "\",\"target\":\"",
                vm.toString(CONTROLLER),
                "\",\"calldata\":\"",
                vm.toString(abi.encodeWithSelector(IControllerProbe.rebalance.selector)),
                "\",\"success\":",
                vm.toString(success),
                ",\"returnData\":\"",
                vm.toString(returnData),
                "\"}"
            )
        );
        uint256 rebalanceValue;
        bool isSrPayer;
        bool foundRebalanceEvent;
        for (uint256 i; i < logs.length; ++i) {
            _observeEvent(logs[i]);
            if (
                logs[i].emitter == CONTROLLER && logs[i].topics.length != 0
                    && logs[i].topics[0] == REBALANCE_TOPIC
            ) {
                (rebalanceValue, isSrPayer) = abi.decode(logs[i].data, (uint256, bool));
                foundRebalanceEvent = true;
            }
        }
        if (success && foundRebalanceEvent) {
            IControllerProbe.ReserveData memory payerReserve = isSrPayer ? srBefore : jrBefore;
            IBalancerRebalanceProbe.ReserveData memory balancerReserve =
                abi.decode(abi.encode(payerReserve), (IBalancerRebalanceProbe.ReserveData));
            IBalancerRebalanceProbe.ReserveAmounts memory plan =
                IBalancerRebalanceProbe(BALANCER).computeSystemRebalancePlan(balancerReserve, rebalanceValue);
            _logRebalancePlan(label, rebalanceValue, isSrPayer, plan);
        } else {
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"rebalance_plan_unavailable\",\"label\":\"",
                    label,
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"foundRebalanceEvent\":",
                    vm.toString(foundRebalanceEvent),
                    "}"
                )
            );
        }
    }

    function _logRebalancePlan(
        string memory label,
        uint256 rebalanceValue,
        bool isSrPayer,
        IBalancerRebalanceProbe.ReserveAmounts memory plan
    ) private {
        string memory payerSide = isSrPayer ? "perpSr" : "perpJr";
        string memory json = string.concat(
            "OBS:{\"kind\":\"computeSystemRebalancePlan\",\"label\":\"",
            label,
            "\",\"rebalanceValue\":",
            vm.toString(rebalanceValue),
            ",\"isPerpSrPayer\":",
            vm.toString(isSrPayer),
            ",\"payerSide\":\"",
            payerSide,
            "\",\"reserveOut\":{\"underlyingAmt\":",
            vm.toString(plan.underlyingAmt),
            ",\"trancheAmts\":["
        );
        for (uint256 i; i < plan.trancheAmts.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(
                json,
                "{\"token\":\"",
                vm.toString(plan.trancheAmts[i].token),
                "\",\"amount\":",
                vm.toString(plan.trancheAmts[i].amount),
                "}"
            );
        }
        console2.log(string.concat(json, "]}}"));
    }

    function _selectorHex(bytes4 selector) private pure returns (string memory) {
        bytes16 symbols = "0123456789abcdef";
        bytes memory result = new bytes(10);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i; i < 4; ++i) {
            uint8 value = uint8(selector[i]);
            result[2 + i * 2] = symbols[value >> 4];
            result[3 + i * 2] = symbols[value & 0x0f];
        }
        return string(result);
    }

    function _refreshOracleForWarpedTimestamp(string memory label) private {
        uint256 timestamp = block.timestamp;
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 sequencerStartedAt = timestamp > sequencerGracePeriod
                ? timestamp - sequencerGracePeriod - 1
                : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IPriceFeedProbe.latestRoundData.selector),
                abi.encode(
                    sequencerRoundId,
                    int256(0),
                    sequencerStartedAt,
                    timestamp,
                    sequencerAnsweredInRound
                )
            );
        }
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"local_oracle_refresh\",\"label\":\"",
                label,
                "\",\"feed\":\"",
                vm.toString(priceFeed),
                "\",\"sequencerFeed\":\"",
                vm.toString(sequencerFeed),
                "\",\"answer\":",
                vm.toString(priceAnswer),
                ",\"timestamp\":",
                vm.toString(timestamp),
                ",\"sequencerGracePeriod\":",
                vm.toString(uint256(sequencerGracePeriod)),
                "}"
            )
        );
        _execute(
            string.concat("oracle.cachePrice_for_", label),
            USER,
            address(oracle),
            abi.encodeWithSelector(IOracleProbe.cachePrice.selector)
        );
    }

    function _observeMintReturns(
        string memory label,
        uint256 srOut,
        uint256 jrOut,
        IControllerProbe.FeePerc memory srFee,
        IControllerProbe.FeePerc memory jrFee
    ) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"mint_return\",\"label\":\"",
                label,
                "\",\"perpSrAmt\":",
                vm.toString(srOut),
                ",\"perpJrAmt\":",
                vm.toString(jrOut),
                ",\"perpSrFeePerc\":{\"total\":",
                vm.toString(srFee.totalFeePerc),
                ",\"protocol\":",
                vm.toString(srFee.protocolFeePerc),
                "},\"perpJrFeePerc\":{\"total\":",
                vm.toString(jrFee.totalFeePerc),
                ",\"protocol\":",
                vm.toString(jrFee.protocolFeePerc),
                "}}"
            )
        );
    }

    function _observeRedeem2Returns(bytes memory ret) private {
        (
            IControllerProbe.ReserveAmounts memory sr,
            IControllerProbe.ReserveAmounts memory jr,
            IControllerProbe.FeePerc memory srFee,
            IControllerProbe.FeePerc memory jrFee
        ) = abi.decode(
                ret,
                (
                    IControllerProbe.ReserveAmounts,
                    IControllerProbe.ReserveAmounts,
                    IControllerProbe.FeePerc,
                    IControllerProbe.FeePerc
                )
            );
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"redeem2_return\",\"srUnderlying\":",
                vm.toString(sr.underlyingAmt),
                ",\"srTranches\":",
                _controllerTokenAmountsJson(sr.trancheAmts),
                ",\"jrUnderlying\":",
                vm.toString(jr.underlyingAmt),
                ",\"jrTranches\":",
                _controllerTokenAmountsJson(jr.trancheAmts),
                ",\"perpSrFeePerc\":{\"total\":",
                vm.toString(srFee.totalFeePerc),
                ",\"protocol\":",
                vm.toString(srFee.protocolFeePerc),
                "},\"perpJrFeePerc\":{\"total\":",
                vm.toString(jrFee.totalFeePerc),
                ",\"protocol\":",
                vm.toString(jrFee.protocolFeePerc),
                "}}"
            )
        );
    }

    function _controllerTokenAmountsJson(IControllerProbe.TokenAmount[] memory amounts)
        private
        view
        returns (string memory json)
    {
        json = "[";
        for (uint256 i; i < amounts.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(
                json,
                "{\"token\":\"",
                vm.toString(amounts[i].token),
                "\",\"amount\":",
                vm.toString(amounts[i].amount),
                "}"
            );
        }
        json = string.concat(json, "]");
    }

    function _observeTokenAmount(string memory label, IBondsManagerProbe.TokenAmount memory amount) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"token_amount\",\"label\":\"",
                label,
                "\",\"token\":\"",
                vm.toString(amount.token),
                "\",\"amount\":",
                vm.toString(amount.amount),
                "}"
            )
        );
    }

    function _snapshot(string memory label, address user) private {
        (
            IControllerProbe.SystemState memory state,
            IControllerProbe.ReserveData memory srReserve,
            IControllerProbe.ReserveData memory jrReserve
        ) = controller.systemReserveState();
        IControllerProbe.BondInfo memory latest = controller.latestBondInfo();
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"snapshot\",\"label\":\"",
                label,
                "\",\"block\":",
                vm.toString(block.number),
                ",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"user\":\"",
                vm.toString(user),
                "\"}"
            )
        );
        console2.log(_systemStateJson(label, state));
        console2.log(_reserveSnapshotJson(label, "perpSr", srReserve, user));
        console2.log(_reserveSnapshotJson(label, "perpJr", jrReserve, user));
        console2.log(_tokenBalancesSnapshotJson(label, user, srReserve, jrReserve, latest));
        console2.log(_metricsSnapshotJson(label));
        console2.log(_latestBondSnapshotJson(label, latest));
    }

    function _systemStateJson(string memory label, IControllerProbe.SystemState memory state)
        private
        returns (string memory json)
    {
        json = string.concat("OBS:{\"kind\":\"system_state\",\"label\":\"", label, "\",\"perpSr\":");
        json = string.concat(json, _perpStateJson(state.perpSr));
        json = string.concat(json, ",\"perpJr\":", _perpStateJson(state.perpJr), "}");
    }

    function _perpStateJson(IControllerProbe.PerpState memory state) private view returns (string memory json) {
        json = "{\"totalSupply\":";
        json = string.concat(json, vm.toString(state.totalSupply));
        json = string.concat(json, ",\"reserveValue\":", vm.toString(state.reserveValue));
        json = string.concat(json, ",\"vm\":", vm.toString(state.vm), "}");
    }

    function _reserveSnapshotJson(
        string memory label,
        string memory side,
        IControllerProbe.ReserveData memory reserve,
        address user
    ) private view returns (string memory json) {
        json = string.concat(
            "OBS:{\"kind\":\"reserve_data\",\"label\":\"", label, "\",\"side\":\"", side, "\",\"underlyingBal\":"
        );
        json = string.concat(json, vm.toString(reserve.underlyingBal), ",\"trancheData\":[");
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, _reserveTrancheJson(reserve.trancheData[i], user));
        }
        json = string.concat(json, "]}");
    }

    function _reserveTrancheJson(IControllerProbe.ReserveTrancheData memory item, address user)
        private
        view
        returns (string memory json)
    {
        uint256 userBalance;
        if (item.data.tranche != address(0)) userBalance = IERC20Probe(item.data.tranche).balanceOf(user);
        json = string.concat("{\"data\":", _trancheDataJson(item.data));
        json = string.concat(json, ",\"balance\":", vm.toString(item.balance));
        json = string.concat(json, ",\"value\":", vm.toString(item.value));
        json = string.concat(json, ",\"vm\":", vm.toString(item.data.volatilityMultiplier));
        json = string.concat(json, ",\"secondsToMaturity\":", vm.toString(uint256(item.data.secondsToMaturity)));
        json = string.concat(json, ",\"userBalance\":", vm.toString(userBalance), "}");
    }

    function _trancheDataJson(IControllerProbe.TrancheData memory d)
        private
        view
        returns (string memory json)
    {
        json = "{\"trancheSupply\":";
        json = string.concat(json, vm.toString(d.trancheSupply));
        json = string.concat(json, ",\"trancheClaim\":", vm.toString(d.trancheClaim));
        json = string.concat(json, ",\"totalClaim\":", vm.toString(d.totalClaim));
        json = string.concat(json, ",\"volatilityMultiplier\":", vm.toString(d.volatilityMultiplier));
        json = string.concat(json, ",\"underlyingOpenPrice\":", vm.toString(d.underlyingOpenPrice));
        json = string.concat(json, ",\"isMature\":", vm.toString(d.isMature));
        json = string.concat(json, ",\"secondsToMaturity\":", vm.toString(uint256(d.secondsToMaturity)));
        json = string.concat(json, ",\"trancheRatio\":", vm.toString(uint256(d.trancheRatio)));
        json = string.concat(json, ",\"valueRatio\":", vm.toString(uint256(d.valueRatio)));
        json = string.concat(json, ",\"bondID\":\"", vm.toString(d.bondID), "\"");
        json = string.concat(json, ",\"isSenior\":", vm.toString(d.isSenior));
        json = string.concat(json, ",\"tranche\":\"", vm.toString(d.tranche), "\"");
        json = string.concat(json, ",\"counterpart\":\"", vm.toString(d.counterpart), "\"");
        json = string.concat(json, ",\"manager\":\"", vm.toString(d.manager), "\"}");
    }

    function _tokenBalancesSnapshotJson(
        string memory label,
        address user,
        IControllerProbe.ReserveData memory srReserve,
        IControllerProbe.ReserveData memory jrReserve,
        IControllerProbe.BondInfo memory latest
    ) private view returns (string memory json) {
        address[64] memory tokens;
        uint256 count = _remember(tokens, 0, CBBTC);
        count = _remember(tokens, count, PERP_SR);
        count = _remember(tokens, count, PERP_JR);
        count = _rememberReserveTokens(tokens, count, srReserve);
        count = _rememberReserveTokens(tokens, count, jrReserve);
        count = _remember(tokens, count, latest.srTranche);
        count = _remember(tokens, count, latest.jrTranche);
        json = string.concat("OBS:{\"kind\":\"token_balances\",\"label\":\"", label, "\",\"tokens\":[");
        for (uint256 i; i < count; ++i) {
            if (i != 0) json = string.concat(json, ",");
            json = string.concat(json, _tokenJson(tokens[i], user));
        }
        json = string.concat(json, "]}");
    }

    function _tokenJson(address token, address user) private view returns (string memory json) {
        json = string.concat("{\"token\":\"", vm.toString(token), "\"");
        json = string.concat(json, ",\"userBalance\":", vm.toString(IERC20Probe(token).balanceOf(user)));
        json = string.concat(json, ",\"controllerBalance\":", vm.toString(IERC20Probe(token).balanceOf(CONTROLLER)));
        json = string.concat(json, ",\"totalSupply\":", vm.toString(IERC20Probe(token).totalSupply()));
        json = string.concat(json, ",\"collectedFeeBal\":", vm.toString(controller.collectedFeeBal(token)));
        json = string.concat(json, ",\"protocolFeeBals\":", vm.toString(controller.protocolFeeBals(token)), "}");
    }

    function _metricsSnapshotJson(string memory label) private view returns (string memory json) {
        (uint256 subDR, uint256 vmDR) = controller.systemDeviations();
        json = string.concat("OBS:{\"kind\":\"metrics\",\"label\":\"", label, "\"");
        json = string.concat(json, ",\"systemDeviations\":{\"subDR\":", vm.toString(subDR));
        json = string.concat(json, ",\"vmDR\":", vm.toString(vmDR), "}");
        json = string.concat(json, ",\"availPerpJrLiquidity\":", vm.toString(controller.availPerpJrLiquidity()));
        json = string.concat(json, ",\"reservedPerpJrLiquidity\":", vm.toString(controller.reservedPerpJrLiquidity()));
        json = string.concat(
            json, ",\"perpJrReservedUnderlyingAmt\":", vm.toString(controller.perpJrReservedUnderlyingAmt())
        );
        json = string.concat(
            json, ",\"perpJrReservedUnderlyingPerc\":", vm.toString(uint256(controller.perpJrReservedUnderlyingPerc()))
        );
        json = string.concat(json, ",\"minMaturitySec\":", vm.toString(uint256(controller.minMaturitySec())));
        json = string.concat(json, ",\"valueCap\":", vm.toString(controller.valueCap()));
        json = string.concat(json, ",\"minCleanupVal\":", vm.toString(controller.minCleanupVal()));
        json = string.concat(json, ",\"userOpsPaused\":", vm.toString(controller.userOpsPaused()));
        json = string.concat(json, ",\"systemOpsPaused\":", vm.toString(controller.systemOpsPaused()));
        json = string.concat(json, ",\"balancer\":\"", vm.toString(controller.balancer()), "\"");
        json = string.concat(json, ",\"issuer\":\"", vm.toString(controller.issuer()), "\"");
        json = string.concat(json, ",\"keeper\":\"", vm.toString(controller.keeper()), "\"");
        json = string.concat(json, ",\"feePolicyAddress\":\"", vm.toString(FEE_POLICY), "\"}");
    }

    function _latestBondSnapshotJson(string memory label, IControllerProbe.BondInfo memory latest)
        private
        view
        returns (string memory json)
    {
        json = string.concat("OBS:{\"kind\":\"latest_bond\",\"label\":\"", label, "\",\"controller\":");
        json = string.concat(json, _controllerBondInfoJson(latest));
        string memory issuerInfo = "null";
        try IBondIssuerProbe(controller.issuer()).latestBondInfo() returns (IBondIssuerProbe.BondInfo memory info) {
            issuerInfo = _issuerBondInfoJson(info);
        } catch {}
        json = string.concat(json, ",\"issuer\":", issuerInfo, ",\"bondData\":");
        string memory bondData = "null";
        if (latest.manager != address(0) && latest.bondID != bytes32(0)) {
            try IBondsManagerProbe(latest.manager).bondsData(latest.bondID) returns (
                IBondsManagerProbe.BondData memory bond
            ) {
                bondData = _bondJson(bond);
            } catch (bytes memory reason) {
                bondData = string.concat("{\"error\":\"", vm.toString(reason), "\"}");
            }
        }
        json = string.concat(json, bondData, "}");
    }

    function _controllerBondInfoJson(IControllerProbe.BondInfo memory info)
        private
        view
        returns (string memory json)
    {
        json = string.concat("{\"manager\":\"", vm.toString(info.manager), "\"");
        json = string.concat(json, ",\"bondID\":\"", vm.toString(info.bondID), "\"");
        json = string.concat(json, ",\"srTranche\":\"", vm.toString(info.srTranche), "\"");
        json = string.concat(json, ",\"jrTranche\":\"", vm.toString(info.jrTranche), "\"}");
    }

    function _issuerBondInfoJson(IBondIssuerProbe.BondInfo memory info)
        private
        view
        returns (string memory json)
    {
        json = string.concat("{\"manager\":\"", vm.toString(info.manager), "\"");
        json = string.concat(json, ",\"bondID\":\"", vm.toString(info.bondID), "\"");
        json = string.concat(json, ",\"srTranche\":\"", vm.toString(info.srTranche), "\"");
        json = string.concat(json, ",\"jrTranche\":\"", vm.toString(info.jrTranche), "\"}");
    }

    function _bondJson(IBondsManagerProbe.BondData memory bond) private view returns (string memory json) {
        json = string.concat("{\"underlying\":\"", vm.toString(bond.underlying), "\"");
        json = string.concat(json, ",\"srTrancheRatio\":", vm.toString(uint256(bond.srTrancheRatio)));
        json = string.concat(json, ",\"isMature\":", vm.toString(bond.isMature));
        json = string.concat(json, ",\"maturityDate\":", vm.toString(uint256(bond.maturityDate)));
        json = string.concat(json, ",\"senior\":\"", vm.toString(bond.senior), "\"");
        json = string.concat(json, ",\"junior\":\"", vm.toString(bond.junior), "\"");
        json = string.concat(json, ",\"openPrice\":", vm.toString(bond.openPrice));
        json = string.concat(json, ",\"underlyingBal\":", vm.toString(bond.underlyingBal));
        json = string.concat(json, ",\"srClaim\":", vm.toString(bond.srClaim));
        json = string.concat(json, ",\"jrClaim\":", vm.toString(bond.jrClaim), "}");
    }

    function _rememberReserveTokens(
        address[64] memory tokens,
        uint256 count,
        IControllerProbe.ReserveData memory reserve
    ) private pure returns (uint256) {
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            count = _remember(tokens, count, reserve.trancheData[i].data.tranche);
        }
        return count;
    }

    function _remember(address[64] memory tokens, uint256 count, address token) private pure returns (uint256) {
        if (token == address(0)) return count;
        for (uint256 i; i < count; ++i) {
            if (tokens[i] == token) return count;
        }
        if (count < tokens.length) {
            tokens[count] = token;
            return count + 1;
        }
        return count;
    }

    function _observeEvent(Vm.Log memory entry) private view {
        string memory name = "UNKNOWN";
        string memory decoded = "{}";
        if (entry.topics.length != 0) {
            bytes32 topic = entry.topics[0];
            if (topic == TRANSFER_TOPIC && entry.topics.length == 3) {
                name = "Transfer";
                decoded = string.concat(
                    "{\"from\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"to\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[2])))),
                    "\",\"value\":",
                    vm.toString(abi.decode(entry.data, (uint256))),
                    "}"
                );
            } else if (topic == APPROVAL_TOPIC && entry.topics.length == 3) {
                name = "Approval";
                decoded = string.concat(
                    "{\"owner\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"spender\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[2])))),
                    "\",\"value\":",
                    vm.toString(abi.decode(entry.data, (uint256))),
                    "}"
                );
            } else if (topic == RESERVE_SYNCED_TOPIC) {
                name = "ReserveSynced";
                (address token, uint256 balance) = abi.decode(entry.data, (address, uint256));
                decoded = string.concat(
                    "{\"token\":\"", vm.toString(token), "\",\"balance\":", vm.toString(balance), "}"
                );
            } else if (topic == OP_FEES_TOPIC && entry.topics.length == 2) {
                name = "OpFees";
                (uint256 totalFee, uint256 protocolFee) = abi.decode(entry.data, (uint256, uint256));
                decoded = string.concat(
                    "{\"token\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"totalFeeAmt\":",
                    vm.toString(totalFee),
                    ",\"protocolFeeAmt\":",
                    vm.toString(protocolFee),
                    "}"
                );
            } else if (topic == AUM_FEES_TOPIC && entry.topics.length == 2) {
                name = "AumFees";
                decoded = string.concat(
                    "{\"token\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"amount\":",
                    vm.toString(abi.decode(entry.data, (uint256))),
                    "}"
                );
            } else if (topic == REBALANCE_TOPIC) {
                name = "Rebalance";
                (uint256 value, bool isSrPayer) = abi.decode(entry.data, (uint256, bool));
                decoded = string.concat(
                    "{\"rebalanceValue\":",
                    vm.toString(value),
                    ",\"isPerpSrPayer\":",
                    vm.toString(isSrPayer),
                    "}"
                );
            } else if (topic == BOND_CREATED_TOPIC && entry.topics.length == 2) {
                name = "BondCreated";
                (address underlying, uint64 ratio, uint64 maturity, address sr, address jr, uint256 openPrice) =
                    abi.decode(entry.data, (address, uint64, uint64, address, address, uint256));
                decoded = string.concat(
                    "{\"bondID\":\"",
                    vm.toString(entry.topics[1]),
                    "\",\"underlying\":\"",
                    vm.toString(underlying),
                    "\",\"srTrancheRatio\":",
                    vm.toString(uint256(ratio)),
                    ",\"maturityDate\":",
                    vm.toString(uint256(maturity)),
                    ",\"senior\":\"",
                    vm.toString(sr),
                    "\",\"junior\":\"",
                    vm.toString(jr),
                    "\",\"openPrice\":",
                    vm.toString(openPrice),
                    "}"
                );
            } else if (topic == BOND_DEPOSIT_TOPIC && entry.topics.length == 2) {
                name = "BondDeposit";
                (uint256 inAmt, uint256 srMint, uint256 jrMint) =
                    abi.decode(entry.data, (uint256, uint256, uint256));
                decoded = string.concat(
                    "{\"bondID\":\"",
                    vm.toString(entry.topics[1]),
                    "\",\"underlyingAmtIn\":",
                    vm.toString(inAmt),
                    ",\"srAmtMint\":",
                    vm.toString(srMint),
                    ",\"jrAmtMint\":",
                    vm.toString(jrMint),
                    "}"
                );
            } else if (topic == BOND_MATURE_TOPIC && entry.topics.length == 2) {
                name = "BondMature";
                (uint256 srClaim, uint256 jrClaim, uint256 closePrice) =
                    abi.decode(entry.data, (uint256, uint256, uint256));
                decoded = string.concat(
                    "{\"bondID\":\"",
                    vm.toString(entry.topics[1]),
                    "\",\"srClaim\":",
                    vm.toString(srClaim),
                    ",\"jrClaim\":",
                    vm.toString(jrClaim),
                    ",\"closePrice\":",
                    vm.toString(closePrice),
                    "}"
                );
            } else if (topic == TRANCHES_REDEEMED_TOPIC && entry.topics.length == 2) {
                name = "TranchesRedeemed";
                (uint256 srBurn, uint256 jrBurn, uint256 underlyingOut) =
                    abi.decode(entry.data, (uint256, uint256, uint256));
                decoded = string.concat(
                    "{\"bondID\":\"",
                    vm.toString(entry.topics[1]),
                    "\",\"srAmtRedeemed\":",
                    vm.toString(srBurn),
                    ",\"jrAmtRedeemed\":",
                    vm.toString(jrBurn),
                    ",\"underlyingAmtReturned\":",
                    vm.toString(underlyingOut),
                    "}"
                );
            } else if (topic == OWNERSHIP_TRANSFERRED_TOPIC && entry.topics.length == 3) {
                name = "OwnershipTransferred";
                decoded = string.concat(
                    "{\"previousOwner\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"newOwner\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[2])))),
                    "\"}"
                );
            } else if (topic == OWNERSHIP_TRANSFER_STARTED_TOPIC && entry.topics.length == 3) {
                name = "OwnershipTransferStarted";
                decoded = string.concat(
                    "{\"previousOwner\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[1])))),
                    "\",\"newOwner\":\"",
                    vm.toString(address(uint160(uint256(entry.topics[2])))),
                    "\"}"
                );
            }
        }
        string memory topicsJson = "[";
        for (uint256 i; i < entry.topics.length; ++i) {
            if (i != 0) topicsJson = string.concat(topicsJson, ",");
            topicsJson = string.concat(topicsJson, "\"", vm.toString(entry.topics[i]), "\"");
        }
        topicsJson = string.concat(topicsJson, "]");
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"event\",\"name\":\"",
                name,
                "\",\"emitter\":\"",
                vm.toString(entry.emitter),
                "\",\"decoded\":",
                decoded,
                ",\"topics\":",
                topicsJson,
                ",\"data\":\"",
                vm.toString(entry.data),
                "\"}"
            )
        );
    }

    function _nearestMaturity(
        IControllerProbe.ReserveData memory sr,
        IControllerProbe.ReserveData memory jr
    ) private pure returns (uint256 nearest) {
        nearest = type(uint256).max;
        for (uint256 i; i < sr.trancheData.length; ++i) {
            uint256 secondsToMaturity = sr.trancheData[i].data.secondsToMaturity;
            if (secondsToMaturity != 0 && secondsToMaturity < nearest) nearest = secondsToMaturity;
        }
        for (uint256 i; i < jr.trancheData.length; ++i) {
            uint256 secondsToMaturity = jr.trancheData[i].data.secondsToMaturity;
            if (secondsToMaturity != 0 && secondsToMaturity < nearest) nearest = secondsToMaturity;
        }
    }
}
