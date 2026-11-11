// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
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

    function _bootstrap(LocalSystem memory s, address receiver) private returns (uint256, uint256) {
        return s.seeder
            .bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, s.maxJrUnderlyingTopUp, receiver);
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
