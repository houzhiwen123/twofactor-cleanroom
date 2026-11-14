// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {IUnderlyingSingleAssetRouter} from "../src/interfaces/IUnderlyingSingleAssetRouter.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {UnderlyingRouterActor} from "./mocks/UnderlyingRouterActor.sol";

contract UnderlyingRouterRealIntegrationTest is Test {
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
        GenesisSeeder seeder;
        address srTranche;
        address jrTranche;
        uint256 srAmount;
        uint256 jrAmount;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function testRouterDepositRebalanceRolloverRedeemBothVaults() public {
        LocalSystem memory s = _deploySystem();
        UnderlyingPerpVault seniorVault = _deployVault(s, true);
        UnderlyingPerpVault juniorVault = _deployVault(s, false);
        UnderlyingRouterActor actor = new UnderlyingRouterActor();

        s.underlying.mint(address(actor), 2 * VAULT_SEED);
        (uint256 seniorNotes, uint256 juniorNotes) =
            actor.depositBoth(address(s.underlying), address(seniorVault), address(juniorVault), VAULT_SEED);
        assertGt(seniorNotes, 0);
        assertGt(juniorNotes, 0);

        _configureDirection(seniorVault, s.controller, true);
        _configureDirection(juniorVault, s.controller, true);
        seniorVault.rebalance();
        juniorVault.rebalance();
        _advanceIssueAndBalancedMint(s, 82_000e18);
        _advanceIssueAndBalancedMint(s, 79_000e18);
        _advanceIssueAndBalancedMint(s, 84_000e18);
        s.controller.rollover();
        s.underlying.mint(address(s.perpSr), SR_REDEEM_LIQUIDITY_TOP_UP);

        uint256 underlyingBefore = s.underlying.balanceOf(address(actor));
        (uint256 seniorOut, uint256 juniorOut) =
            actor.redeemBoth(address(seniorVault), address(juniorVault), seniorNotes, juniorNotes);
        assertEq(s.underlying.balanceOf(address(actor)) - underlyingBefore, seniorOut + juniorOut);
        assertGt(seniorOut, 0);
        assertGt(juniorOut, 0);
        assertEq(seniorVault.balanceOf(address(actor)), 0);
        assertEq(juniorVault.balanceOf(address(actor)), 0);
        _assertRouterDustFree(s, actor);
        assertEq(
            _trackedUnderlying(s, seniorVault, juniorVault) + s.underlying.balanceOf(address(actor)),
            s.underlying.totalSupply()
        );
    }

    function testRouterRealComponentMinOutFailureIsAtomic() public {
        LocalSystem memory s = _deploySystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        UnderlyingRouterActor actor = new UnderlyingRouterActor();
        s.underlying.mint(address(actor), VAULT_SEED);
        uint256 notes = actor.depositOne(address(s.underlying), address(vault), VAULT_SEED);
        _configureDirection(vault, s.controller, true);
        vault.rebalance();
        s.underlying.mint(address(s.perpSr), SR_REDEEM_LIQUIDITY_TOP_UP);
        uint256 snapshot = vm.snapshotState();

        uint256 exactOut = actor.redeemOne(address(vault), notes, 0);
        assertGt(exactOut, 0);
        assertTrue(vm.revertToState(snapshot));

        bytes32 beforeFingerprint = _fingerprint(s, vault, actor);
        vm.expectRevert(IUnderlyingSingleAssetRouter.SlippageTooHigh.selector);
        actor.redeemOne(address(vault), notes, exactOut + 1);
        assertEq(_fingerprint(s, vault, actor), beforeFingerprint);
    }

    function _deploySystem() private returns (LocalSystem memory s) {
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
        FeePolicy feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        s.controller.updateFeePolicy(address(feePolicy));
        s.controller.updatePerpBalancer(address(new PerpBalancer()));
        s.controller.updateIssuer(address(s.issuer));
        s.controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory info) = s.issuer.issue();
        assertTrue(issued);
        s.srTranche = info.srTranche;
        s.jrTranche = info.jrTranche;
        s.underlying.mint(address(this), INITIAL_UNDERLYING);
        s.underlying.approve(address(s.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(info.bondID, INITIAL_UNDERLYING);
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
                            senior ? "Router SR Vault" : "Router JR Vault",
                            senior ? "rrSR" : "rrJR",
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

    function _advanceIssueAndBalancedMint(LocalSystem memory s, uint256 price) private {
        vm.warp(block.timestamp + 604_800);
        s.oracle.setPrice(price);
        s.controller.upkeep();
        BondIssuer.BondInfo memory info = s.issuer.latestBondInfo();
        s.underlying.mint(RECEIVER, 10_000_000);
        vm.startPrank(RECEIVER);
        s.underlying.approve(address(s.manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(info.bondID, 10_000_000);
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

    function _configureDirection(UnderlyingPerpVault vault, PerpController controller, bool minting) private {
        (uint256 subDr,) = controller.systemDeviations();
        bool targetBelow = vault.isPerpSrVault() ? minting : !minting;
        uint96 target = targetBelow ? uint96(subDr / 2) : uint96(subDr * 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (uint256 amount, bool observedMinting) = vault.computeRebalanceAmount();
        assertEq(observedMinting, minting);
        assertGt(amount, 0);
    }

    function _assertRouterDustFree(LocalSystem memory s, UnderlyingRouterActor actor) private view {
        address router = address(actor.router());
        assertEq(s.underlying.balanceOf(router), 0);
        assertEq(s.perpSr.balanceOf(router), 0);
        assertEq(s.perpJr.balanceOf(router), 0);
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

    function _fingerprint(LocalSystem memory s, UnderlyingPerpVault vault, UnderlyingRouterActor actor)
        private
        view
        returns (bytes32)
    {
        address router = address(actor.router());
        return keccak256(
            abi.encode(
                s.underlying.balanceOf(address(vault)),
                s.perpSr.balanceOf(address(vault)),
                s.perpJr.balanceOf(address(vault)),
                vault.totalSupply(),
                vault.lastRebalanceTimestampSec(),
                s.underlying.balanceOf(address(s.controller)),
                s.perpSr.totalSupply(),
                s.perpJr.totalSupply(),
                s.underlying.balanceOf(address(actor)),
                vault.balanceOf(address(actor)),
                s.underlying.balanceOf(router),
                s.perpSr.balanceOf(router),
                s.perpJr.balanceOf(router)
            )
        );
    }
}
