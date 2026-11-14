// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {CachedOracle} from "../src/oracle/CachedOracle.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract Phase3RevertingOracle {
    error OracleCallFailure();

    function getValidPrice() external pure returns (uint256) {
        revert OracleCallFailure();
    }

    function cachePrice() external pure returns (uint256) {
        revert OracleCallFailure();
    }

    function resetCache() external pure {
        revert OracleCallFailure();
    }
}

contract UnderlyingPerpVaultRealIntegrationTest is Test {
    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    uint256 private constant VAULT_SEED = 1_000_000;
    uint256 private constant SR_REDEEM_LIQUIDITY_TOP_UP = 10 * VAULT_SEED;
    address private constant RECEIVER = address(0xBEEF);

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
    }

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function testRealComponentsSeniorMintRebalanceConservesAssetsAndAccountsFees() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        _configureCorrectiveTarget(vault, s.controller);

        (uint256 planned, bool isMinting) = vault.computeRebalanceAmount();
        assertTrue(isMinting);
        assertEq(planned, VAULT_SEED, "vault underlying must bind the mint capacity");

        (PerpController.SystemState memory beforeState,,) = s.controller.systemReserveState();
        uint256 trackedUnderlyingBefore = _trackedUnderlying(s, vault);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();
        uint256 vaultUnderlyingBefore = s.underlying.balanceOf(address(vault));
        uint256 vaultPerpBefore = s.perpSr.balanceOf(address(vault));
        uint256 controllerPerpBefore = s.perpSr.balanceOf(address(s.controller));
        uint256 supplyBefore = s.perpSr.totalSupply();

        vm.prank(address(0xCAFE));
        vault.rebalance();

        (PerpController.SystemState memory afterState,,) = s.controller.systemReserveState();
        uint256 supplyDelta = s.perpSr.totalSupply() - supplyBefore;
        uint256 vaultPerpDelta = s.perpSr.balanceOf(address(vault)) - vaultPerpBefore;
        uint256 controllerPerpDelta = s.perpSr.balanceOf(address(s.controller)) - controllerPerpBefore;

        assertEq(vaultUnderlyingBefore - s.underlying.balanceOf(address(vault)), planned);
        assertEq(afterState.perpSr.reserveValue - beforeState.perpSr.reserveValue, planned);
        assertGt(supplyDelta, 0);
        assertEq(vaultPerpDelta + controllerPerpDelta, supplyDelta, "all minted shares must be accounted");
        assertEq(_trackedUnderlying(s, vault), trackedUnderlyingBefore);
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore);
        assertGt(vault.lastRebalanceTimestampSec(), 0);
    }

    function testRealComponentsJuniorRedeemRebalanceConservesGrossAndBurnsExactShares() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, false);

        uint256 donatedPerp = s.perpJr.balanceOf(RECEIVER) / 20;
        vm.prank(RECEIVER);
        s.perpJr.transfer(address(vault), donatedPerp);
        _configureCorrectiveTarget(vault, s.controller);

        (uint256 planned, bool isMinting) = vault.computeRebalanceAmount();
        assertFalse(isMinting);
        assertGt(planned, 0);

        (PerpController.SystemState memory beforeState,,) = s.controller.systemReserveState();
        uint256 perpIn = Math.mulDiv(planned, beforeState.perpJr.totalSupply, beforeState.perpJr.reserveValue);
        uint256 grossUnderlying = Math.mulDiv(perpIn, beforeState.perpJr.reserveValue, beforeState.perpJr.totalSupply);
        uint256 trackedUnderlyingBefore = _trackedUnderlying(s, vault);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();
        uint256 vaultUnderlyingBefore = s.underlying.balanceOf(address(vault));
        uint256 controllerUnderlyingBefore = s.underlying.balanceOf(address(s.controller));
        uint256 vaultPerpBefore = s.perpJr.balanceOf(address(vault));
        uint256 supplyBefore = s.perpJr.totalSupply();

        vault.rebalance();

        (PerpController.SystemState memory afterState,,) = s.controller.systemReserveState();
        uint256 vaultUnderlyingDelta = s.underlying.balanceOf(address(vault)) - vaultUnderlyingBefore;
        uint256 controllerUnderlyingDelta = s.underlying.balanceOf(address(s.controller)) - controllerUnderlyingBefore;

        assertEq(vaultPerpBefore - s.perpJr.balanceOf(address(vault)), perpIn);
        assertEq(supplyBefore - s.perpJr.totalSupply(), perpIn);
        assertEq(beforeState.perpJr.reserveValue - afterState.perpJr.reserveValue, grossUnderlying);
        assertEq(
            vaultUnderlyingDelta + controllerUnderlyingDelta, grossUnderlying, "net output plus fee must equal gross"
        );
        assertEq(_trackedUnderlying(s, vault), trackedUnderlyingBefore);
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore);
    }

    function testRealControllerFailureRollsBackVaultAndSystemState() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        _configureCorrectiveTarget(vault, s.controller);
        (uint256 planned,) = vault.computeRebalanceAmount();
        assertGt(planned, 0);

        s.controller.pauseUserOps(true);
        bytes32 beforeFingerprint = _fingerprint(s, vault);

        vm.expectRevert(PerpController.UserOpsPaused.selector);
        vault.rebalance();

        assertEq(_fingerprint(s, vault), beforeFingerprint);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
    }

    function testRealControllerOracleFailuresLeaveVaultAndSystemAtomic() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        MockChainlinkFeed feed = _installCachedOracle(s);
        _configureCorrectiveTarget(vault, s.controller);
        (uint256 planned,) = vault.computeRebalanceAmount();
        assertGt(planned, 0);
        bytes32 beforeFingerprint = _failureFingerprint(s, vault);

        feed.setRoundData(2, 8_000_000_000_000, block.timestamp, block.timestamp - 3601, 2);
        vm.expectRevert(CachedOracle.InvalidPrice.selector);
        vault.rebalance();
        assertEq(_failureFingerprint(s, vault), beforeFingerprint, "stale oracle changed state");

        feed.setRoundData(3, 0, block.timestamp, block.timestamp, 3);
        vm.expectRevert(CachedOracle.ZeroPrice.selector);
        vault.rebalance();
        assertEq(_failureFingerprint(s, vault), beforeFingerprint, "zero oracle changed state");

        feed.setRoundData(4, -1, block.timestamp, block.timestamp, 4);
        vm.expectRevert(CachedOracle.InvalidPrice.selector);
        vault.rebalance();
        assertEq(_failureFingerprint(s, vault), beforeFingerprint, "negative oracle changed state");

        Phase3RevertingOracle revertingOracle = new Phase3RevertingOracle();
        s.manager.updateOracle(address(s.underlying), address(revertingOracle));
        s.controller.setUnderlyingOracle();
        beforeFingerprint = _failureFingerprint(s, vault);
        vm.expectRevert(Phase3RevertingOracle.OracleCallFailure.selector);
        vault.rebalance();
        assertEq(_failureFingerprint(s, vault), beforeFingerprint, "reverting oracle changed state");
    }

    function testBothVaultsCompletePriceRebalancePauseAndFullUserExitLifecycle() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault seniorVault = _deployVault(s, true);
        UnderlyingPerpVault juniorVault = _deployVault(s, false);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();

        s.underlying.mint(RECEIVER, 2 * VAULT_SEED);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(seniorVault), VAULT_SEED);
        s.underlying.approve(address(juniorVault), VAULT_SEED);
        uint256 seniorUserNotes = seniorVault.deposit(VAULT_SEED, 0);
        uint256 juniorUserNotes = juniorVault.deposit(VAULT_SEED, 0);
        vm.stopPrank();
        assertGt(seniorUserNotes, 0);
        assertGt(juniorUserNotes, 0);

        s.oracle.setPrice(INITIAL_PRICE * 11 / 10);
        _configureDirection(seniorVault, s.controller, true);
        _configureDirection(juniorVault, s.controller, true);
        seniorVault.rebalance();
        juniorVault.rebalance();
        assertGt(s.perpSr.balanceOf(address(seniorVault)), 0);
        assertGt(s.perpJr.balanceOf(address(juniorVault)), 0);

        vm.warp(block.timestamp + 86_400);
        s.oracle.setPrice(INITIAL_PRICE * 9 / 10);
        // Local lifecycle fixture: flash redemption needs idle underlying on the paying Perp side.
        s.underlying.mint(address(s.perpSr), SR_REDEEM_LIQUIDITY_TOP_UP);
        uint256 seniorPerpBefore = s.perpSr.balanceOf(address(seniorVault));
        uint256 juniorPerpBefore = s.perpJr.balanceOf(address(juniorVault));
        _configureDirection(seniorVault, s.controller, false);
        seniorVault.rebalance();
        _configureDirection(juniorVault, s.controller, false);
        juniorVault.rebalance();
        assertLt(s.perpSr.balanceOf(address(seniorVault)), seniorPerpBefore);
        assertLt(s.perpJr.balanceOf(address(juniorVault)), juniorPerpBefore);

        seniorVault.pause();
        juniorVault.pause();
        vm.prank(RECEIVER);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        seniorVault.redeem(1);
        vm.prank(RECEIVER);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        juniorVault.redeem(1);
        seniorVault.unpause();
        juniorVault.unpause();

        vm.startPrank(RECEIVER);
        seniorVault.redeem(seniorUserNotes / 10);
        juniorVault.redeem(juniorUserNotes / 10);
        seniorVault.redeem(seniorVault.balanceOf(RECEIVER));
        juniorVault.redeem(juniorVault.balanceOf(RECEIVER));
        vm.stopPrank();

        seniorVault.redeem(seniorVault.balanceOf(address(this)));
        juniorVault.redeem(juniorVault.balanceOf(address(this)));

        assertEq(seniorVault.balanceOf(RECEIVER), 0);
        assertEq(juniorVault.balanceOf(RECEIVER), 0);
        assertEq(seniorVault.balanceOf(address(this)), 0);
        assertEq(juniorVault.balanceOf(address(this)), 0);
        assertEq(seniorVault.totalSupply(), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.totalSupply(), juniorVault.MINIMUM_LIQUIDITY());
        assertEq(seniorVault.balanceOf(address(seniorVault)), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.balanceOf(address(juniorVault)), juniorVault.MINIMUM_LIQUIDITY());
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore + 2 * VAULT_SEED + SR_REDEEM_LIQUIDITY_TOP_UP);
        assertEq(_trackedUnderlying(s, seniorVault, juniorVault), s.underlying.totalSupply());
    }

    function testPhase4BBothVaultsDepositRebalanceRolloverRedeemLifecycle() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault seniorVault = _deployVault(s, true);
        UnderlyingPerpVault juniorVault = _deployVault(s, false);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();

        s.underlying.mint(RECEIVER, 2 * VAULT_SEED);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(seniorVault), VAULT_SEED);
        s.underlying.approve(address(juniorVault), VAULT_SEED);
        uint256 seniorUserNotes = seniorVault.deposit(VAULT_SEED, 0);
        uint256 juniorUserNotes = juniorVault.deposit(VAULT_SEED, 0);
        vm.stopPrank();

        _configureDirection(seniorVault, s.controller, true);
        _configureDirection(juniorVault, s.controller, true);
        seniorVault.rebalance();
        juniorVault.rebalance();

        uint256 seniorVaultPerpBefore = s.perpSr.balanceOf(address(seniorVault));
        uint256 juniorVaultPerpBefore = s.perpJr.balanceOf(address(juniorVault));
        uint256 seniorNotesBefore = seniorVault.totalSupply();
        uint256 juniorNotesBefore = juniorVault.totalSupply();
        assertGt(seniorVaultPerpBefore, 0);
        assertGt(juniorVaultPerpBefore, 0);

        _advanceIssueAndBalancedMint(s, 82_000e18, 10_000_000);
        _advanceIssueAndBalancedMint(s, 79_000e18, 10_000_000);
        _advanceIssueAndBalancedMint(s, 84_000e18, 10_000_000);

        uint256 staleSrBefore = IERC20(s.srTranche).balanceOf(address(s.perpSr));
        uint256 staleJrBefore = IERC20(s.jrTranche).balanceOf(address(s.perpJr));
        uint256 seniorTvlBefore = seniorVault.getTVL();
        uint256 juniorTvlBefore = juniorVault.getTVL();
        assertGt(staleSrBefore, 0);
        assertGt(staleJrBefore, 0);

        s.controller.rollover();

        assertEq(IERC20(s.srTranche).balanceOf(address(s.perpSr)), 0);
        assertEq(IERC20(s.jrTranche).balanceOf(address(s.perpJr)), 0);
        assertEq(seniorVault.totalSupply(), seniorNotesBefore);
        assertEq(juniorVault.totalSupply(), juniorNotesBefore);
        assertEq(s.perpSr.balanceOf(address(seniorVault)), seniorVaultPerpBefore);
        assertEq(s.perpJr.balanceOf(address(juniorVault)), juniorVaultPerpBefore);
        assertEq(seniorVault.balanceOf(RECEIVER), seniorUserNotes);
        assertEq(juniorVault.balanceOf(RECEIVER), juniorUserNotes);
        uint256 seniorTvlAfterRollover = seniorVault.getTVL();
        uint256 juniorTvlAfterRollover = juniorVault.getTVL();
        assertEq(seniorTvlAfterRollover, seniorTvlBefore);
        assertEq(juniorTvlAfterRollover, juniorTvlBefore);
        assertEq(_trackedUnderlying(s, seniorVault, juniorVault), s.underlying.totalSupply());

        vm.startPrank(RECEIVER);
        seniorVault.redeem(seniorVault.balanceOf(RECEIVER));
        juniorVault.redeem(juniorVault.balanceOf(RECEIVER));
        vm.stopPrank();
        seniorVault.redeem(seniorVault.balanceOf(address(this)));
        juniorVault.redeem(juniorVault.balanceOf(address(this)));

        assertEq(seniorVault.totalSupply(), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.totalSupply(), juniorVault.MINIMUM_LIQUIDITY());
        assertEq(seniorVault.balanceOf(address(seniorVault)), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.balanceOf(address(juniorVault)), juniorVault.MINIMUM_LIQUIDITY());
        assertLe(seniorVault.getTVL(), 1);
        assertLe(juniorVault.getTVL(), 1);
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore + 32 * VAULT_SEED);
        assertEq(_trackedUnderlying(s, seniorVault, juniorVault), s.underlying.totalSupply());

        emit log_named_uint("phase4b.staleSrBefore", staleSrBefore);
        emit log_named_uint("phase4b.staleJrBefore", staleJrBefore);
        emit log_named_uint("phase4b.seniorTvlBefore", seniorTvlBefore);
        emit log_named_uint("phase4b.seniorTvlAfterRollover", seniorTvlAfterRollover);
        emit log_named_uint("phase4b.juniorTvlBefore", juniorTvlBefore);
        emit log_named_uint("phase4b.juniorTvlAfterRollover", juniorTvlAfterRollover);
        emit log_named_uint("phase4b.seniorTvlAfterFullExit", seniorVault.getTVL());
        emit log_named_uint("phase4b.juniorTvlAfterFullExit", juniorVault.getTVL());
    }

    function _deployLiveSystem() private returns (LocalSystem memory s) {
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

        s.underlying.mint(address(this), INITIAL_UNDERLYING);
        s.underlying.approve(address(s.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(s.bondID, INITIAL_UNDERLYING);
        s.srAmount = srInput.amount;
        s.jrAmount = jrInput.amount;

        s.seeder = new GenesisSeeder(address(this));
        s.underlying.mint(address(s.seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(s.srTranche).transfer(address(s.seeder), s.srAmount);
        IERC20(s.jrTranche).transfer(address(s.seeder), s.jrAmount);
        s.controller.updateKeeper(address(s.seeder));
        s.seeder.bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, MAX_JR_IDLE_TOP_UP, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
    }

    function _deployVault(LocalSystem memory s, bool senior) private returns (UnderlyingPerpVault vault) {
        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            senior ? "Real SR Vault" : "Real JR Vault",
                            senior ? "rvSR" : "rvJR",
                            address(s.underlying),
                            address(s.controller),
                            senior,
                            senior
                        )
                    )
                )
            )
        );
        s.underlying.mint(address(this), VAULT_SEED);
        s.underlying.approve(address(vault), VAULT_SEED);
        vault.initDeposit(VAULT_SEED);
        vault.updateMinRebalanceAmt(1);
        vault.updateMaxFlashFeePerc(uint64(1e18));
    }

    function _advanceIssueAndBalancedMint(LocalSystem memory s, uint256 price, uint256 underlyingAmount)
        private
        returns (BondIssuer.BondInfo memory info)
    {
        uint256 activeBefore = s.issuer.activeBondIDs().length;
        vm.warp(block.timestamp + 604_800);
        s.oracle.setPrice(price);
        s.controller.upkeep();
        assertEq(s.issuer.activeBondIDs().length, activeBefore + 1);
        info = s.issuer.latestBondInfo();

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

    function _configureCorrectiveTarget(UnderlyingPerpVault vault, PerpController controller) private {
        (uint256 subDr,) = controller.systemDeviations();
        uint96 target = uint96(subDr / 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
    }

    function _configureDirection(UnderlyingPerpVault vault, PerpController controller, bool minting) private {
        (uint256 subDr,) = controller.systemDeviations();
        bool targetBelow = vault.isPerpSrVault() ? minting : !minting;
        uint96 target = targetBelow ? uint96(subDr / 2) : uint96(subDr * 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (uint256 amount, bool observedMinting) = vault.computeRebalanceAmount();
        assertEq(observedMinting, minting, "direction setup failed");
        assertGt(amount, 0, "direction has no capacity");
    }

    function _installCachedOracle(LocalSystem memory s) private returns (MockChainlinkFeed feed) {
        feed = new MockChainlinkFeed(8);
        feed.setRoundData(1, 8_000_000_000_000, block.timestamp, block.timestamp, 1);
        CachedOracle oracle = new CachedOracle(address(feed), 3600, address(0), 0);
        s.manager.updateOracle(address(s.underlying), address(oracle));
        s.controller.setUnderlyingOracle();
    }

    function _trackedUnderlying(LocalSystem memory s, UnderlyingPerpVault vault) private view returns (uint256) {
        return s.underlying.balanceOf(address(s.manager)) + s.underlying.balanceOf(address(s.perpSr))
            + s.underlying.balanceOf(address(s.perpJr)) + s.underlying.balanceOf(address(s.controller))
            + s.underlying.balanceOf(address(s.seeder)) + s.underlying.balanceOf(address(this))
            + s.underlying.balanceOf(RECEIVER) + s.underlying.balanceOf(address(vault));
    }

    function _trackedUnderlying(LocalSystem memory s, UnderlyingPerpVault seniorVault, UnderlyingPerpVault juniorVault)
        private
        view
        returns (uint256)
    {
        return s.underlying.balanceOf(address(s.manager)) + s.underlying.balanceOf(address(s.perpSr))
            + s.underlying.balanceOf(address(s.perpJr)) + s.underlying.balanceOf(address(s.controller))
            + s.underlying.balanceOf(address(s.seeder)) + s.underlying.balanceOf(address(this))
            + s.underlying.balanceOf(RECEIVER) + s.underlying.balanceOf(address(seniorVault))
            + s.underlying.balanceOf(address(juniorVault));
    }

    function _fingerprint(LocalSystem memory s, UnderlyingPerpVault vault) private view returns (bytes32) {
        (PerpController.SystemState memory state,,) = s.controller.systemReserveState();
        return keccak256(
            abi.encode(
                state,
                s.underlying.balanceOf(address(vault)),
                s.perpSr.balanceOf(address(vault)),
                s.perpSr.totalSupply(),
                s.underlying.balanceOf(address(s.controller)),
                s.perpSr.balanceOf(address(s.controller)),
                vault.lastRebalanceTimestampSec()
            )
        );
    }

    function _failureFingerprint(LocalSystem memory s, UnderlyingPerpVault vault) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                s.underlying.balanceOf(address(vault)),
                s.perpSr.balanceOf(address(vault)),
                s.perpJr.balanceOf(address(vault)),
                vault.totalSupply(),
                vault.lastRebalanceTimestampSec(),
                s.underlying.balanceOf(address(s.controller)),
                s.perpSr.balanceOf(address(s.controller)),
                s.perpJr.balanceOf(address(s.controller)),
                s.perpSr.totalSupply(),
                s.perpJr.totalSupply()
            )
        );
    }
}
