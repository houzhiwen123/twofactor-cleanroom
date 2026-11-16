// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {PairRouter} from "../src/router/PairRouter.sol";
import {UniswapV3DexStrategy} from "../src/strategy/UniswapV3DexStrategy.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

contract PairRouterRealIntegrationTest is Test {
    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    uint256 private constant JR_VAULT_SEED = 1_000_000;
    uint256 private constant USD_VAULT_SEED = 100_000e6;
    address private constant RECEIVER = address(0xCAFE);
    address private constant USER = address(0xBEEF);

    struct LocalSystem {
        MockERC20 underlying;
        MockERC20 usd;
        MockPriceOracle oracle;
        BondsManager manager;
        BondIssuer issuer;
        PerpToken perpSr;
        PerpToken perpJr;
        PerpController controller;
        GenesisSeeder seeder;
        MockUniswapV3Pool pool;
        UniswapV3DexStrategy strategy;
        UsdVault usdVault;
        UnderlyingPerpVault jrVault;
        PairRouter router;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function testRealCoreVaultDexPairDepositAndRedeemLifecycle() public {
        LocalSystem memory s = _deploySystem();
        _deployPeriphery(s);
        _convertJrVaultToPerpOnly(s);

        uint256 tradeUnderlying = 10_000;
        uint256 jrUnderlying = 50_000;
        uint256 totalUnderlying = tradeUnderlying + jrUnderlying;
        s.underlying.mint(USER, totalUnderlying);
        vm.startPrank(USER);
        s.underlying.approve(address(s.router), type(uint256).max);

        IPairRouter.DepositParams memory depositParams = IPairRouter.DepositParams({
            usdVault: address(s.usdVault),
            underlyingVault: address(s.jrVault),
            strategy: address(s.strategy),
            recipient: USER,
            underlyingIn: totalUnderlying,
            minUsdFromTrade: 0,
            underlyingToTrade: tradeUnderlying,
            srUnderlyingIn: 0,
            jrUnderlyingIn: jrUnderlying,
            minUsdNotes: 1,
            minUnderlyingNotes: 1,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: false
        });
        (uint256 usdNotes, uint256 jrNotes,,,,) = s.router.deposit(depositParams);
        emit log_named_uint("pair USD notes", usdNotes);
        emit log_named_uint("pair JR notes", jrNotes);
        assertGt(usdNotes, 0, "USD notes");
        assertGt(jrNotes, 0, "JR notes");
        assertEq(s.usdVault.balanceOf(USER), usdNotes, "USD notes delivered");
        assertEq(s.jrVault.balanceOf(USER), jrNotes, "JR notes delivered");

        s.usdVault.approve(address(s.router), usdNotes);
        s.jrVault.approve(address(s.router), jrNotes);
        uint256 userUsdBefore = s.usd.balanceOf(USER);
        uint256 userUnderlyingBefore = s.underlying.balanceOf(USER);
        IPairRouter.RedeemParams memory redeemParams = IPairRouter.RedeemParams({
            usdVault: address(s.usdVault),
            underlyingVault: address(s.jrVault),
            strategy: address(s.strategy),
            usdNotes: usdNotes,
            underlyingNotes: jrNotes,
            maxUsdRetained: type(uint256).max,
            underlyingToTrade: 0,
            runUpkeep: false,
            minUsdOut: 1,
            minUnderlyingOut: 1,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: false
        });
        (uint256 usdOut, uint256 underlyingOut) = s.router.redeem(redeemParams);
        vm.stopPrank();

        emit log_named_uint("pair USD output", usdOut);
        emit log_named_uint("pair underlying output", underlyingOut);

        assertEq(s.usd.balanceOf(USER) - userUsdBefore, usdOut, "USD settlement");
        assertEq(s.underlying.balanceOf(USER) - userUnderlyingBefore, underlyingOut, "underlying settlement");
        assertGt(usdOut, 0, "USD output");
        assertGt(underlyingOut, 0, "underlying output");
        assertEq(s.usdVault.balanceOf(USER), 0, "USD user notes burned");
        assertEq(s.jrVault.balanceOf(USER), 0, "JR user notes burned");
        _assertRouterDustFree(s);
    }

    function _deploySystem() private returns (LocalSystem memory s) {
        s.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        s.usd = new MockERC20("USD Coin", "USDC", 6);
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
        s.underlying.mint(address(this), INITIAL_UNDERLYING);
        s.underlying.approve(address(s.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(info.bondID, INITIAL_UNDERLYING);

        s.seeder = new GenesisSeeder(address(this));
        s.underlying.mint(address(s.seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(srInput.token).transfer(address(s.seeder), srInput.amount);
        IERC20(jrInput.token).transfer(address(s.seeder), jrInput.amount);
        s.controller.updateKeeper(address(s.seeder));
        s.seeder
            .bootstrap(
                s.controller, srInput.token, srInput.amount, jrInput.token, jrInput.amount, MAX_JR_IDLE_TOP_UP, RECEIVER
            );
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
    }

    function _deployPeriphery(LocalSystem memory s) private {
        s.pool = new MockUniswapV3Pool(address(s.usd), address(s.underlying));
        s.strategy = new UniswapV3DexStrategy(address(s.usd), address(s.underlying), address(s.pool), 1);
        s.usd.mint(address(s.pool), 20_000_000e6);
        s.underlying.mint(address(s.pool), 100e8);
        s.pool.setExecutionEnabled(true);

        UsdVault usdImplementation = new UsdVault();
        s.usdVault = UsdVault(
            address(
                new ERC1967Proxy(
                    address(usdImplementation),
                    abi.encodeCall(
                        UsdVault.init,
                        (
                            "Integrated USD Vault",
                            "iUSD",
                            address(s.usd),
                            address(s.perpSr),
                            address(s.underlying),
                            address(s.controller)
                        )
                    )
                )
            )
        );
        s.usd.mint(address(this), USD_VAULT_SEED);
        s.usd.approve(address(s.usdVault), USD_VAULT_SEED);
        assertGt(s.usdVault.initDeposit(USD_VAULT_SEED), 0);

        UnderlyingPerpVault jrImplementation = new UnderlyingPerpVault();
        s.jrVault = UnderlyingPerpVault(
            address(
                new ERC1967Proxy(
                    address(jrImplementation),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        ("Integrated JR Vault", "iJR", address(s.underlying), address(s.controller), false, false)
                    )
                )
            )
        );
        s.underlying.mint(address(this), JR_VAULT_SEED);
        s.underlying.approve(address(s.jrVault), JR_VAULT_SEED);
        assertGt(s.jrVault.initDeposit(JR_VAULT_SEED), 0);
        s.jrVault.updateMinRebalanceAmt(1);
        s.jrVault.updateMaxFlashFeePerc(uint64(1e18));
        s.router = new PairRouter();
    }

    function _convertJrVaultToPerpOnly(LocalSystem memory s) private {
        (uint256 subDr,) = s.controller.systemDeviations();
        uint96 target = uint96(subDr * 2);
        s.jrVault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (uint256 amount, bool minting) = s.jrVault.computeRebalanceAmount();
        assertTrue(minting, "JR vault mint direction");
        assertEq(amount, JR_VAULT_SEED, "all JR idle converted");
        s.jrVault.rebalance();
        assertEq(s.underlying.balanceOf(address(s.jrVault)), 0, "JR vault is perp-only");
        assertGt(s.perpJr.balanceOf(address(s.jrVault)), 0, "JR vault has perp");
    }

    function _assertRouterDustFree(LocalSystem memory s) private view {
        assertEq(s.underlying.balanceOf(address(s.router)), 0);
        assertEq(s.usd.balanceOf(address(s.router)), 0);
        assertEq(s.perpSr.balanceOf(address(s.router)), 0);
        assertEq(s.perpJr.balanceOf(address(s.router)), 0);
        assertEq(s.usdVault.balanceOf(address(s.router)), 0);
        assertEq(s.jrVault.balanceOf(address(s.router)), 0);
    }
}
