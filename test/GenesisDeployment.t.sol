// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract GenesisDeploymentTest is Test {
    using SafeERC20 for IERC20;

    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    address private constant RECEIVER = address(0xBEEF);
    address private constant OUTSIDER = address(0xCAFE);

    struct LocalSystem {
        MockERC20 underlying;
        MockPriceOracle oracle;
        BondsManager manager;
        BondIssuer issuer;
        PerpToken perpSr;
        PerpToken perpJr;
        PerpController controller;
        FeePolicy feePolicy;
        PerpBalancer balancer;
        GenesisSeeder seeder;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
        uint256 srAmount;
        uint256 jrAmount;
        uint256 maxJrUnderlyingTopUp;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function testLocalGenesisCreatesFirstBondAndLocksMinimumShares() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);

        (uint256 srShares, uint256 jrShares) = _bootstrap(s, RECEIVER);

        assertEq(srShares, s.srAmount);
        assertGt(jrShares, s.jrAmount);
        assertEq(s.perpSr.totalSupply(), srShares);
        assertEq(s.perpJr.totalSupply(), jrShares);
        assertEq(s.perpSr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpSr.balanceOf(RECEIVER), srShares - s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(RECEIVER), jrShares - s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpSr.balanceOf(address(s.controller)), 0);
        assertEq(s.perpJr.balanceOf(address(s.controller)), 0);
        assertTrue(s.controller.userOpsPaused());
        assertTrue(s.seeder.used());

        bytes32[] memory active = s.issuer.activeBondIDs();
        assertEq(active.length, 1);
        assertEq(active[0], s.bondID);

        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
        assertFalse(s.controller.userOpsPaused());
    }

    function testControllerStartsPausedAndBlocksPublicFirstMint() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        vm.prank(OUTSIDER);
        vm.expectRevert(PerpController.UserOpsPaused.selector);
        s.controller
            .mint2(
                PerpController.TokenAmount(s.srTranche, s.srAmount),
                PerpController.TokenAmount(s.jrTranche, s.jrAmount),
                0,
                0
            );
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
    }

    function testFlashMintCannotEstablishInitialPrice() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
        s.underlying.mint(OUTSIDER, 2_000_000);

        vm.startPrank(OUTSIDER);
        s.underlying.approve(address(s.controller), type(uint256).max);
        vm.expectRevert(PerpController.ZeroSupply.selector);
        s.controller.flashMint2(1_000_000, 1_000_000, 0, 0);
        vm.stopPrank();

        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
        assertEq(s.underlying.balanceOf(OUTSIDER), 2_000_000);
    }

    function testOneSidedTrancheBootstrapIsRejected() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        vm.expectRevert(PerpController.ZeroSupply.selector);
        s.controller
            .mint2(PerpController.TokenAmount(s.srTranche, s.srAmount), PerpController.TokenAmount(address(0), 0), 0, 0);
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
    }

    function testDonationBeforeBootstrapIsRejected() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        s.underlying.mint(address(s.perpSr), 1);

        vm.expectRevert(GenesisSeeder.NonEmptyReserve.selector);
        _bootstrap(s, RECEIVER);

        assertFalse(s.seeder.used());
        assertTrue(s.controller.userOpsPaused());
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
    }

    function testLateBootstrapFailureRollsBackPauseAndAllBalances() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        s.controller.updateKeeper(address(this));
        s.controller.updateValueCap(1);
        s.controller.updateKeeper(address(s.seeder));

        uint256 srBefore = IERC20(s.srTranche).balanceOf(address(s.seeder));
        uint256 jrBefore = IERC20(s.jrTranche).balanceOf(address(s.seeder));
        vm.expectRevert(PerpController.ValueCapExceeded.selector);
        _bootstrap(s, RECEIVER);

        assertFalse(s.seeder.used());
        assertTrue(s.controller.userOpsPaused());
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
        assertEq(IERC20(s.srTranche).balanceOf(address(s.seeder)), srBefore);
        assertEq(IERC20(s.jrTranche).balanceOf(address(s.seeder)), jrBefore);
        assertEq(IERC20(s.srTranche).allowance(address(s.seeder), address(s.controller)), 0);
        assertEq(IERC20(s.jrTranche).allowance(address(s.seeder), address(s.controller)), 0);
    }

    function testGenesisSeederCannotBeReused() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);

        vm.expectRevert(GenesisSeeder.AlreadyBootstrapped.selector);
        _bootstrap(s, RECEIVER);
    }

    function testGenesisSharesRemainOutsideNormalUserControl() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        address lockedLiquidity = s.seeder.LOCKED_LIQUIDITY();
        vm.startPrank(RECEIVER);
        vm.expectRevert();
        s.perpSr.transferFrom(lockedLiquidity, RECEIVER, 1);
        vm.expectRevert();
        s.perpJr.transferFrom(lockedLiquidity, RECEIVER, 1);
        vm.stopPrank();

        assertEq(s.perpSr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
    }

    function testGenesisDirectRedeemTenPercentSucceeds() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        uint256 srInput = s.perpSr.balanceOf(RECEIVER) / 10;
        uint256 jrInput = s.perpJr.balanceOf(RECEIVER) / 10;
        (uint256 preSubDr, uint256 preVmDr) = s.controller.systemDeviations();
        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), srInput);
        s.perpJr.approve(address(s.controller), jrInput);
        (,, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
            s.controller.redeem2(srInput, jrInput, 0);
        vm.stopPrank();
        (uint256 postSubDr, uint256 postVmDr) = s.controller.systemDeviations();

        emit log_named_uint("direct sr redeem input", srInput);
        emit log_named_uint("direct jr redeem input", jrInput);
        emit log_named_uint("direct pre subDR", preSubDr);
        emit log_named_uint("direct post subDR", postSubDr);
        emit log_named_uint("direct pre vmDR", preVmDr);
        emit log_named_uint("direct post vmDR", postVmDr);
        emit log_named_uint("direct sr total fee", srFee.totalFeePerc);
        emit log_named_uint("direct jr total fee", jrFee.totalFeePerc);
        assertLt(srFee.totalFeePerc, 1e18);
        assertLt(jrFee.totalFeePerc, 1e18);
    }

    function testGenesisLifecycleRebalancePartialAndFullExit() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        (uint256 initialSubDr, uint256 initialVmDr) = s.controller.systemDeviations();
        s.controller.rebalance();

        uint256 srInput = s.perpSr.balanceOf(RECEIVER) / 10;
        uint256 jrInput = s.perpJr.balanceOf(RECEIVER) / 10;
        (PerpController.SystemState memory pre,,) = s.controller.systemReserveState();
        (uint256 preSubDr, uint256 preVmDr) =
            s.controller.computeDRs(pre, s.controller.targetSystemRatio(), s.controller.targetPerpJrVM());
        uint256 srGross = srInput * pre.perpSr.reserveValue / pre.perpSr.totalSupply;
        uint256 jrGross = jrInput * pre.perpJr.reserveValue / pre.perpJr.totalSupply;
        PerpController.SystemState memory post = pre;
        post.perpSr.totalSupply -= srInput;
        post.perpSr.reserveValue -= srGross;
        post.perpJr.totalSupply -= jrInput;
        post.perpJr.reserveValue -= jrGross;
        (uint256 postSubDr, uint256 postVmDr) =
            s.controller.computeDRs(post, s.controller.targetSystemRatio(), s.controller.targetPerpJrVM());
        FeePolicy.OpSystemChange memory change = FeePolicy.OpSystemChange(preSubDr, postSubDr, preVmDr, postVmDr);
        FeePolicy.OpFees memory srFee = s.feePolicy.computeOpFees(FeePolicy.OpFeeInput(true, false, change));
        FeePolicy.OpFees memory jrFee = s.feePolicy.computeOpFees(FeePolicy.OpFeeInput(false, false, change));

        emit log_named_uint("sr redeem input", srInput);
        emit log_named_uint("jr redeem input", jrInput);
        emit log_named_uint("initial subDR", initialSubDr);
        emit log_named_uint("initial vmDR", initialVmDr);
        emit log_named_uint("pre subDR", preSubDr);
        emit log_named_uint("post subDR", postSubDr);
        emit log_named_uint("pre vmDR", preVmDr);
        emit log_named_uint("post vmDR", postVmDr);
        emit log_named_uint("sr total fee", srFee.totalFeePerc);
        emit log_named_uint("jr total fee", jrFee.totalFeePerc);

        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), srInput);
        s.perpJr.approve(address(s.controller), jrInput);
        (,, PerpController.FeePerc memory actualSrFee, PerpController.FeePerc memory actualJrFee) =
            s.controller.redeem2(srInput, jrInput, 0);
        vm.stopPrank();

        assertEq(actualSrFee.totalFeePerc, srFee.totalFeePerc);
        assertEq(actualJrFee.totalFeePerc, jrFee.totalFeePerc);
        assertLt(actualSrFee.totalFeePerc, 1e18);
        assertLt(actualJrFee.totalFeePerc, 1e18);
        (uint256 actualPostSubDr, uint256 actualPostVmDr) = s.controller.systemDeviations();
        emit log_named_uint("actual post subDR", actualPostSubDr);
        emit log_named_uint("actual post vmDR", actualPostVmDr);
        assertApproxEqAbs(actualPostSubDr, postSubDr, 1e11);
        assertApproxEqAbs(actualPostVmDr, postVmDr, 1e11);

        uint256 remainingSr = s.perpSr.balanceOf(RECEIVER);
        uint256 remainingJr = s.perpJr.balanceOf(RECEIVER);
        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), remainingSr);
        s.perpJr.approve(address(s.controller), remainingJr);
        s.controller.redeem2(remainingSr, remainingJr, 0);
        vm.stopPrank();
        assertEq(s.perpSr.balanceOf(RECEIVER), 0);
        assertEq(s.perpJr.balanceOf(RECEIVER), 0);
        assertEq(s.perpSr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
    }

    function testUpgradeableInitializersCannotBeReplayed() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        address underlyingBefore = s.controller.underlying();
        address trancheImplBefore = s.manager.trancheImpl();
        address managerBefore = s.issuer.bondsManager();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        s.controller.init(address(1), address(2), address(3));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        s.manager.init(address(1));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        s.issuer.init(address(1), address(2));
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        s.feePolicy.init();

        assertEq(s.controller.underlying(), underlyingBefore);
        assertEq(s.manager.trancheImpl(), trancheImplBefore);
        assertEq(s.issuer.bondsManager(), managerBefore);
        assertTrue(s.controller.userOpsPaused());
    }

    function testSeedBelowMinimumIsRejectedWithoutStateChange() public {
        LocalSystem memory s = _deployPausedSystem(1);

        vm.expectRevert(GenesisSeeder.InsufficientSeed.selector);
        _bootstrap(s, RECEIVER);

        assertFalse(s.seeder.used());
        assertTrue(s.controller.userOpsPaused());
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
    }

    function testTopUpExactMaximumAndOneUnitShortBoundary() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        IBondsManager.TrancheData memory jrData = s.manager.trancheData(s.bondID, false);
        uint256 jrReserveValue = Math.mulDiv(s.jrAmount, jrData.trancheClaim, jrData.trancheSupply);
        uint256 required = s.seeder
        .computeJrUnderlyingTopUp(jrReserveValue, jrData.volatilityMultiplier, s.controller.targetPerpJrVM());
        assertGt(required, 0);
        assertLe(required, s.maxJrUnderlyingTopUp);

        vm.expectRevert(GenesisSeeder.InsufficientSeed.selector);
        s.seeder.bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, required - 1, RECEIVER);

        assertFalse(s.seeder.used());
        assertTrue(s.controller.userOpsPaused());
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);

        s.seeder.bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, required, RECEIVER);
        assertTrue(s.seeder.used());
        assertGt(s.perpSr.totalSupply(), s.seeder.MIN_LOCKED_SHARES());
        assertGt(s.perpJr.totalSupply(), s.seeder.MIN_LOCKED_SHARES());
        emit log_named_uint("exact JR idle top-up", required);
    }

    function testTopUpRejectsUnreachableTargetAtomically() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        s.controller.updateDRTargets(s.controller.targetSystemRatio(), 1e18);

        vm.expectRevert(GenesisSeeder.InvalidParamDefn.selector);
        _bootstrap(s, RECEIVER);

        assertFalse(s.seeder.used());
        assertTrue(s.controller.userOpsPaused());
        assertEq(s.perpSr.totalSupply(), 0);
        assertEq(s.perpJr.totalSupply(), 0);
        assertEq(s.perpSr.balanceOf(RECEIVER), 0);
        assertEq(s.perpJr.balanceOf(RECEIVER), 0);
    }

    function testTopUpNearUnderlyingVmAndCeilingRounding() public {
        GenesisSeeder calculator = new GenesisSeeder(address(this));
        assertEq(calculator.computeJrUnderlyingTopUp(1, 1e18 + 2, 1e18 + 1), 1);

        uint256 nearUnderlying = calculator.computeJrUnderlyingTopUp(1e8, 2e18, 1e18 + 1);
        assertGt(nearUnderlying, 1e24);
        assertEq(calculator.computeJrUnderlyingTopUp(1e8, 12e17, 13e17), 0);
        assertEq(calculator.computeJrUnderlyingTopUp(1e8, 9e17, 1e18), 0);
        emit log_named_uint("near-underlying target top-up", nearUnderlying);
    }

    function testGenesisBothDeviationRatiosInsideOperationalLaunchRange() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        (uint256 subDr, uint256 vmDr) = s.controller.systemDeviations();
        uint256 srInput = s.perpSr.balanceOf(RECEIVER) / 10;
        uint256 jrInput = s.perpJr.balanceOf(RECEIVER) / 10;
        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), type(uint256).max);
        s.perpJr.approve(address(s.controller), type(uint256).max);
        (,, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
            s.controller.redeem2(srInput, jrInput, 0);
        vm.stopPrank();

        emit log_named_uint("launch subDR", subDr);
        emit log_named_uint("launch vmDR", vmDr);
        assertLt(srFee.totalFeePerc, 1e18);
        assertLt(jrFee.totalFeePerc, 1e18);
    }

    function testGenesisSingleSideExitBoundaries() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), type(uint256).max);
        s.perpJr.approve(address(s.controller), type(uint256).max);
        vm.stopPrank();

        _logExitBoundary(s, false, true, "SR basket", PerpController.OpDisabled.selector);
        _logExitBoundary(s, false, false, "JR basket", bytes4(0));
        _logExitBoundary(s, true, true, "SR underlying", bytes4(0xe450d38c));
        _logExitBoundary(s, true, false, "JR underlying", PerpController.OpDisabled.selector);
    }

    function testGenesisStatefulFourEpochPriceRolloversAndSingleSideFlows() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
        _assertUnderlyingAccounted(s);

        BondIssuer.BondInfo memory epochOne = _advanceIssueAndBalancedMint(s, 88_000e18, 12_000_000);
        _jrOnlyUnderlyingMint(s, 500_000);
        _srOnlyBasketRedeem(s, s.perpSr.balanceOf(RECEIVER) / 1_000);
        _assertUnderlyingAccounted(s);

        BondIssuer.BondInfo memory epochTwo = _advanceIssueAndBalancedMint(s, 72_000e18, 12_000_000);
        _assertUnderlyingAccounted(s);

        BondIssuer.BondInfo memory epochThree = _advanceIssueAndBalancedMint(s, 96_000e18, 12_000_000);
        uint256 firstStaleBefore = IERC20(s.srTranche).balanceOf(address(s.perpSr));
        assertGt(firstStaleBefore, 0);
        s.controller.rollover();
        uint256 firstStaleAfter = IERC20(s.srTranche).balanceOf(address(s.perpSr));
        assertEq(firstStaleAfter, 0);
        _assertUnderlyingAccounted(s);

        BondIssuer.BondInfo memory epochFour = _advanceIssue(s, 76_000e18);
        _assertBalancedMintDisabledAtSnapshot(s, epochFour, 12_000_000);
        uint256 secondStaleBefore = IERC20(epochOne.srTranche).balanceOf(address(s.perpSr));
        assertGt(secondStaleBefore, 0);
        s.controller.rollover();
        uint256 secondStaleAfter = IERC20(epochOne.srTranche).balanceOf(address(s.perpSr));
        assertEq(secondStaleAfter, 0);
        _assertUnderlyingAccounted(s);

        assertTrue(epochOne.bondID != epochTwo.bondID);
        assertTrue(epochTwo.bondID != epochThree.bondID);
        assertTrue(epochThree.bondID != epochFour.bondID);
        assertEq(s.issuer.activeBondIDs().length, 5);
        assertEq(s.perpSr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());

        (uint256 finalSubDr, uint256 finalVmDr) = s.controller.systemDeviations();
        emit log_named_uint("stateful final subDR", finalSubDr);
        emit log_named_uint("stateful final vmDR", finalVmDr);
        emit log_named_uint("stateful first stale before", firstStaleBefore);
        emit log_named_uint("stateful first stale after", firstStaleAfter);
        emit log_named_uint("stateful second stale before", secondStaleBefore);
        emit log_named_uint("stateful second stale after", secondStaleAfter);
    }

    function testGenesisMultiEpochRolloversPreserveFullUserExit() public {
        LocalSystem memory s = _deployPausedSystem(INITIAL_UNDERLYING);
        _bootstrap(s, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);

        BondIssuer.BondInfo memory epochOne = _advanceIssueAndBalancedMint(s, 82_000e18, 10_000_000);
        _advanceIssueAndBalancedMint(s, 79_000e18, 10_000_000);
        _advanceIssueAndBalancedMint(s, 84_000e18, 10_000_000);
        s.controller.rollover();
        assertEq(IERC20(s.srTranche).balanceOf(address(s.perpSr)), 0);

        _advanceIssueAndBalancedMint(s, 80_000e18, 10_000_000);
        s.controller.rollover();
        assertEq(IERC20(epochOne.srTranche).balanceOf(address(s.perpSr)), 0);
        _assertUnderlyingAccounted(s);

        uint256 srExit = s.perpSr.balanceOf(RECEIVER);
        uint256 jrExit = s.perpJr.balanceOf(RECEIVER);
        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), type(uint256).max);
        s.perpJr.approve(address(s.controller), type(uint256).max);
        (,, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
            s.controller.redeem2(srExit, jrExit, 0);
        vm.stopPrank();

        assertLt(srFee.totalFeePerc, 1e18);
        assertLt(jrFee.totalFeePerc, 1e18);
        assertEq(s.perpSr.balanceOf(RECEIVER), 0);
        assertEq(s.perpJr.balanceOf(RECEIVER), 0);
        assertEq(s.perpSr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        assertEq(s.perpJr.balanceOf(s.seeder.LOCKED_LIQUIDITY()), s.seeder.MIN_LOCKED_SHARES());
        _assertUnderlyingAccounted(s);

        (uint256 finalSubDr, uint256 finalVmDr) = s.controller.systemDeviations();
        emit log_named_uint("full-exit SR shares", srExit);
        emit log_named_uint("full-exit JR shares", jrExit);
        emit log_named_uint("full-exit SR fee", srFee.totalFeePerc);
        emit log_named_uint("full-exit JR fee", jrFee.totalFeePerc);
        emit log_named_uint("full-exit remaining subDR", finalSubDr);
        emit log_named_uint("full-exit remaining vmDR", finalVmDr);
    }

    function _bootstrap(LocalSystem memory s, address receiver) private returns (uint256, uint256) {
        return s.seeder
            .bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, s.maxJrUnderlyingTopUp, receiver);
    }

    function _logExitBoundary(
        LocalSystem memory s,
        bool flash,
        bool srSide,
        string memory label,
        bytes4 expectedNextSelector
    ) private {
        uint256 balance = srSide ? s.perpSr.balanceOf(RECEIVER) : s.perpJr.balanceOf(RECEIVER);
        uint256 low;
        uint256 high = balance;
        while (low < high) {
            uint256 mid = low + (high - low + 1) / 2;
            (bool success,,) = _probeExit(s, flash, srSide, mid);
            if (success) low = mid;
            else high = mid - 1;
        }

        assertGt(low, 0);
        (bool boundarySuccess, uint256 boundaryFee,) = _probeExit(s, flash, srSide, low);
        assertTrue(boundarySuccess);
        assertLt(boundaryFee, 1e18);
        bytes4 nextSelector;
        if (low < balance) {
            (bool nextSuccess,, bytes4 selector) = _probeExit(s, flash, srSide, low + 1);
            assertFalse(nextSuccess);
            nextSelector = selector;
        }
        assertEq(nextSelector, expectedNextSelector);

        emit log_named_uint(string.concat(label, " balance"), balance);
        emit log_named_uint(string.concat(label, " max successful input"), low);
        emit log_named_uint(string.concat(label, " boundary fee"), boundaryFee);
        emit log_named_bytes32(string.concat(label, " next failure selector"), bytes32(nextSelector));
    }

    function _probeExit(LocalSystem memory s, bool flash, bool srSide, uint256 amount)
        private
        returns (bool success, uint256 sideFee, bytes4 selector)
    {
        uint256 snapshot = vm.snapshotState();
        bytes memory callData = flash
            ? abi.encodeCall(PerpController.flashRedeem2, (srSide ? amount : 0, srSide ? 0 : amount, 0))
            : abi.encodeCall(PerpController.redeem2, (srSide ? amount : 0, srSide ? 0 : amount, 0));
        vm.prank(RECEIVER);
        bytes memory result;
        (success, result) = address(s.controller).call(callData);
        if (success) {
            if (flash) {
                (, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
                    abi.decode(result, (uint256, PerpController.FeePerc, PerpController.FeePerc));
                sideFee = srSide ? srFee.totalFeePerc : jrFee.totalFeePerc;
            } else {
                (
                    PerpBalancer.ReserveAmounts memory srOut,
                    PerpBalancer.ReserveAmounts memory jrOut,
                    PerpController.FeePerc memory srFee,
                    PerpController.FeePerc memory jrFee
                ) = abi.decode(
                    result,
                    (
                        PerpBalancer.ReserveAmounts,
                        PerpBalancer.ReserveAmounts,
                        PerpController.FeePerc,
                        PerpController.FeePerc
                    )
                );
                srOut;
                jrOut;
                sideFee = srSide ? srFee.totalFeePerc : jrFee.totalFeePerc;
            }
        } else if (result.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
        }
        assertTrue(vm.revertToState(snapshot));
    }

    function _advanceIssueAndBalancedMint(LocalSystem memory s, uint256 price, uint256 underlyingAmount)
        private
        returns (BondIssuer.BondInfo memory info)
    {
        info = _advanceIssue(s, price);
        _balancedMintLatest(s, info, underlyingAmount);
    }

    function _advanceIssue(LocalSystem memory s, uint256 price) private returns (BondIssuer.BondInfo memory info) {
        uint256 activeBefore = s.issuer.activeBondIDs().length;
        vm.warp(block.timestamp + 604_800);
        s.oracle.setPrice(price);
        s.controller.upkeep();
        assertEq(s.issuer.activeBondIDs().length, activeBefore + 1);
        info = s.issuer.latestBondInfo();
    }

    function _balancedMintLatest(LocalSystem memory s, BondIssuer.BondInfo memory info, uint256 underlyingAmount)
        private
    {
        s.underlying.mint(RECEIVER, underlyingAmount);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(s.manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(info.bondID, underlyingAmount);
        IERC20(srInput.token).approve(address(s.controller), type(uint256).max);
        IERC20(jrInput.token).approve(address(s.controller), type(uint256).max);
        s.controller
            .mint2(
                PerpController.TokenAmount(srInput.token, srInput.amount),
                PerpController.TokenAmount(jrInput.token, jrInput.amount),
                0,
                0
            );
        vm.stopPrank();
    }

    function _assertBalancedMintDisabledAtSnapshot(
        LocalSystem memory s,
        BondIssuer.BondInfo memory info,
        uint256 underlyingAmount
    ) private {
        uint256 snapshot = vm.snapshotState();
        s.underlying.mint(RECEIVER, underlyingAmount);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(s.manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(info.bondID, underlyingAmount);
        IERC20(srInput.token).approve(address(s.controller), type(uint256).max);
        IERC20(jrInput.token).approve(address(s.controller), type(uint256).max);
        (bool success, bytes memory result) = address(s.controller)
            .call(
                abi.encodeCall(
                    PerpController.mint2,
                    (
                        PerpController.TokenAmount(srInput.token, srInput.amount),
                        PerpController.TokenAmount(jrInput.token, jrInput.amount),
                        0,
                        0
                    )
                )
            );
        vm.stopPrank();
        assertFalse(success);
        assertEq(_selector(result), PerpController.OpDisabled.selector);
        assertTrue(vm.revertToState(snapshot));
    }

    function _jrOnlyUnderlyingMint(LocalSystem memory s, uint256 amount) private {
        s.underlying.mint(RECEIVER, amount);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(s.controller), type(uint256).max);
        (, uint256 jrOut,, PerpController.FeePerc memory jrFee) = s.controller.flashMint2(0, amount, 0, 0);
        vm.stopPrank();
        assertGt(jrOut, 0);
        assertLt(jrFee.totalFeePerc, 1e18);
    }

    function _srOnlyBasketRedeem(LocalSystem memory s, uint256 amount) private {
        vm.startPrank(RECEIVER);
        s.perpSr.approve(address(s.controller), type(uint256).max);
        (,, PerpController.FeePerc memory srFee,) = s.controller.redeem2(amount, 0, 0);
        vm.stopPrank();
        assertLt(srFee.totalFeePerc, 1e18);
    }

    function _assertUnderlyingAccounted(LocalSystem memory s) private view {
        uint256 accounted = s.underlying.balanceOf(address(s.manager)) + s.underlying.balanceOf(address(s.perpSr))
            + s.underlying.balanceOf(address(s.perpJr)) + s.underlying.balanceOf(address(s.controller))
            + s.underlying.balanceOf(address(s.seeder)) + s.underlying.balanceOf(address(this))
            + s.underlying.balanceOf(RECEIVER);
        assertEq(accounted, s.underlying.totalSupply());
    }

    function _selector(bytes memory result) private pure returns (bytes4 selector) {
        if (result.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(result, 0x20))
        }
    }

    function _deployPausedSystem(uint256 seedUnderlying) private returns (LocalSystem memory s) {
        s.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        s.oracle = new MockPriceOracle(INITIAL_PRICE);

        Tranche trancheImplementation = new Tranche();
        BondsManager managerImplementation = new BondsManager();
        s.manager = BondsManager(
            address(
                new TransparentUpgradeableProxy(
                    address(managerImplementation),
                    address(this),
                    abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
                )
            )
        );
        s.manager.addAsset(address(s.underlying));
        s.manager.updateOracle(address(s.underlying), address(s.oracle));

        BondIssuer issuerImplementation = new BondIssuer();
        s.issuer = BondIssuer(
            address(
                new TransparentUpgradeableProxy(
                    address(issuerImplementation),
                    address(this),
                    abi.encodeCall(BondIssuer.init, (address(s.manager), address(s.underlying)))
                )
            )
        );
        s.manager.addIssuer(address(s.issuer));

        s.perpSr = new PerpToken(
            "Clean-room cbBTC Senior",
            "cr-cbBTC-SR",
            address(s.underlying),
            address(s.manager),
            address(0),
            false,
            address(this)
        );
        s.perpJr = new PerpToken(
            "Clean-room cbBTC Junior",
            "cr-cbBTC-JR",
            address(s.underlying),
            address(s.manager),
            address(0),
            true,
            address(this)
        );

        PerpController controllerImplementation = new PerpController();
        s.controller = PerpController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImplementation),
                    address(this),
                    abi.encodeCall(PerpController.init, (address(s.underlying), address(s.perpSr), address(s.perpJr)))
                )
            )
        );
        s.perpSr.updateController(address(s.controller));
        s.perpJr.updateController(address(s.controller));
        assertTrue(s.controller.userOpsPaused());

        FeePolicy feeImplementation = new FeePolicy();
        s.feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        s.balancer = new PerpBalancer();
        s.controller.updateFeePolicy(address(s.feePolicy));
        s.controller.updatePerpBalancer(address(s.balancer));
        s.controller.updateIssuer(address(s.issuer));
        s.controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory info) = s.issuer.issue();
        assertTrue(issued);
        s.bondID = info.bondID;
        s.srTranche = info.srTranche;
        s.jrTranche = info.jrTranche;

        s.underlying.mint(address(this), seedUnderlying);
        s.underlying.approve(address(s.manager), seedUnderlying);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(s.bondID, seedUnderlying);
        s.srAmount = srInput.amount;
        s.jrAmount = jrInput.amount;

        s.seeder = new GenesisSeeder(address(this));
        s.maxJrUnderlyingTopUp = MAX_JR_IDLE_TOP_UP;
        s.underlying.mint(address(s.seeder), s.maxJrUnderlyingTopUp);
        IERC20(s.srTranche).safeTransfer(address(s.seeder), s.srAmount);
        IERC20(s.jrTranche).safeTransfer(address(s.seeder), s.jrAmount);
        s.controller.updateKeeper(address(s.seeder));
    }
}
