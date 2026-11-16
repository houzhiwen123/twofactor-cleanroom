// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {RolloverPlanGuard} from "../src/policy/RolloverPlanGuard.sol";
import {SingleAssetRouter} from "../src/router/SingleAssetRouter.sol";
import {UnderlyingSingleAssetRouter} from "../src/router/UnderlyingSingleAssetRouter.sol";
import {UniswapV3DexStrategy} from "../src/strategy/UniswapV3DexStrategy.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";
import {MockUniswapV3Pool} from "../test/mocks/MockUniswapV3Pool.sol";
import {MockUsdInventory} from "../test/mocks/MockUsdInventory.sol";

/// @notice Secret-free local simulation of a complete clean-room Genesis deployment.
/// @dev Defaults to simulation. Broadcasting is permitted only to an ephemeral local Anvil with an unlocked,
///      auto-impersonated LOCAL_ADMIN; this script never reads private signing material.
contract DeployGenesisLocal is Script {
    using SafeERC20 for IERC20;

    struct CoreDeployment {
        MockERC20 underlying;
        MockPriceOracle underlyingOracle;
        BondsManager manager;
        BondIssuer issuer;
        PerpToken perpSr;
        PerpToken perpJr;
        PerpController controller;
        FeePolicy feePolicy;
        PerpBalancer balancer;
        RolloverPlanGuard planGuard;
        GenesisSeeder seeder;
        address firstBondSr;
        address firstBondJr;
    }

    struct PeripheryDeployment {
        MockERC20 usd;
        MockPriceOracle usdOracle;
        MockUniswapV3Pool pool;
        UniswapV3DexStrategy dexStrategy;
        MockUsdInventory inventory;
        UnderlyingPerpVault jrVault;
        UnderlyingPerpVault srVault;
        UsdVault usdVault;
        SingleAssetRouter usdRouter;
        UnderlyingSingleAssetRouter underlyingRouter;
    }

    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    uint256 private constant UNDERLYING_VAULT_SEED = 1_000_000;
    uint256 private constant USD_VAULT_SEED = 10_001;
    uint256 private constant LOCAL_POOL_USD_LIQUIDITY = 20_000_000e6;
    uint256 private constant LOCAL_POOL_UNDERLYING_LIQUIDITY = 100e8;
    uint256 private constant LOCAL_INVENTORY_WORKING_USD = 500_000e6;
    uint96 private constant TARGET_DR = 1_053_564_994_000_000_000;
    uint96 private constant JR_EQ_DR_LOWER = TARGET_DR;
    uint96 private constant JR_EQ_DR_UPPER = 1_230_000_000_000_000_000;
    uint96 private constant SR_EQ_DR_LOWER = 1_043_029_344_100_000_000;
    uint96 private constant SR_EQ_DR_UPPER = 1_064_100_643_900_000_000;
    uint32 private constant REBALANCE_FREQ_SEC = 28_800;
    uint32 private constant SR_REBALANCE_OFFSET_SEC = 6_000;
    uint128 private constant MIN_REBALANCE_VAL = 100_000;
    uint64 private constant MAX_FLASH_FEE_PERC = 5_000_000_000_000_000;
    address private constant LOCAL_ADMIN = address(0xA11CE);

    function run() external {
        vm.warp(1_800_000_000);
        vm.startBroadcast(LOCAL_ADMIN);

        CoreDeployment memory core = _deployCore();
        PeripheryDeployment memory periphery = _deployPeriphery(core);

        vm.stopBroadcast();

        _logDeployment(core, periphery);
    }

    function _deployCore() private returns (CoreDeployment memory d) {
        d.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        d.underlyingOracle = new MockPriceOracle(INITIAL_PRICE);
        Tranche trancheImplementation = new Tranche();

        BondsManager managerImplementation = new BondsManager();
        d.manager = BondsManager(
            address(
                new TransparentUpgradeableProxy(
                    address(managerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
                )
            )
        );
        d.manager.addAsset(address(d.underlying));
        d.manager.updateOracle(address(d.underlying), address(d.underlyingOracle));

        BondIssuer issuerImplementation = new BondIssuer();
        d.issuer = BondIssuer(
            address(
                new TransparentUpgradeableProxy(
                    address(issuerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(BondIssuer.init, (address(d.manager), address(d.underlying)))
                )
            )
        );
        d.manager.addIssuer(address(d.issuer));

        d.perpSr = new PerpToken(
            "Clean-room cbBTC Senior",
            "cr-cbBTC-SR",
            address(d.underlying),
            address(d.manager),
            address(0),
            false,
            LOCAL_ADMIN
        );
        d.perpJr = new PerpToken(
            "Clean-room cbBTC Junior",
            "cr-cbBTC-JR",
            address(d.underlying),
            address(d.manager),
            address(0),
            true,
            LOCAL_ADMIN
        );

        PerpController controllerImplementation = new PerpController();
        d.controller = PerpController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(PerpController.init, (address(d.underlying), address(d.perpSr), address(d.perpJr)))
                )
            )
        );
        d.perpSr.updateController(address(d.controller));
        d.perpJr.updateController(address(d.controller));

        FeePolicy feeImplementation = new FeePolicy();
        d.feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), LOCAL_ADMIN, abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        d.balancer = new PerpBalancer();
        d.planGuard = new RolloverPlanGuard(address(d.balancer), address(d.manager));
        d.controller.updateFeePolicy(address(d.feePolicy));
        d.controller.updatePerpBalancer(address(d.planGuard));
        d.controller.updateIssuer(address(d.issuer));
        d.controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory firstBond) = d.issuer.issue();
        require(issued, "first bond not issued");
        d.firstBondSr = firstBond.srTranche;
        d.firstBondJr = firstBond.jrTranche;

        d.underlying.mint(LOCAL_ADMIN, INITIAL_UNDERLYING);
        d.underlying.approve(address(d.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            d.manager.deposit(firstBond.bondID, INITIAL_UNDERLYING);

        d.seeder = new GenesisSeeder(LOCAL_ADMIN);
        d.underlying.mint(address(d.seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(srInput.token).safeTransfer(address(d.seeder), srInput.amount);
        IERC20(jrInput.token).safeTransfer(address(d.seeder), jrInput.amount);
        d.controller.updateKeeper(address(d.seeder));
        d.seeder
            .bootstrap(
                d.controller,
                srInput.token,
                srInput.amount,
                jrInput.token,
                jrInput.amount,
                MAX_JR_IDLE_TOP_UP,
                LOCAL_ADMIN
            );
        d.controller.updateKeeper(LOCAL_ADMIN);
        d.controller.pauseUserOps(false);
    }

    function _deployPeriphery(CoreDeployment memory core) private returns (PeripheryDeployment memory d) {
        d.usd = new MockERC20("USD Coin", "USDC", 6);
        d.usdOracle = new MockPriceOracle(1e18);
        d.pool = new MockUniswapV3Pool(address(d.usd), address(core.underlying));
        d.dexStrategy = new UniswapV3DexStrategy(address(d.usd), address(core.underlying), address(d.pool), 1);
        d.inventory = new MockUsdInventory(address(d.usd), address(core.underlying), address(d.dexStrategy));

        UnderlyingPerpVault vaultImplementation = new UnderlyingPerpVault();
        d.jrVault = _deployUnderlyingVault(vaultImplementation, core, false);
        d.srVault = _deployUnderlyingVault(vaultImplementation, core, true);

        UsdVault usdVaultImplementation = new UsdVault();
        d.usdVault = UsdVault(
            address(
                new TransparentUpgradeableProxy(
                    address(usdVaultImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(
                        UsdVault.initExecution,
                        (
                            "Clean-room USD Senior Vault",
                            "cr-USD-SR",
                            address(d.usd),
                            address(core.perpSr),
                            address(core.underlying),
                            address(core.controller),
                            address(d.dexStrategy),
                            address(d.usdOracle),
                            address(d.inventory)
                        )
                    )
                )
            )
        );
        d.inventory.configureVault(address(d.usdVault));

        d.usdRouter = new SingleAssetRouter();
        d.underlyingRouter = new UnderlyingSingleAssetRouter();

        d.usd.mint(LOCAL_ADMIN, USD_VAULT_SEED);
        d.usd.approve(address(d.usdVault), USD_VAULT_SEED);
        require(d.usdVault.initDeposit(USD_VAULT_SEED) == USD_VAULT_SEED * 1e12, "USD Vault seed failed");

        d.usd.mint(address(d.pool), LOCAL_POOL_USD_LIQUIDITY);
        core.underlying.mint(address(d.pool), LOCAL_POOL_UNDERLYING_LIQUIDITY);
        d.usd.mint(address(d.inventory), LOCAL_INVENTORY_WORKING_USD);
        d.pool.setExecutionEnabled(true);

        require(d.jrVault.perp() == address(core.perpJr), "JR Vault Perp mismatch");
        require(d.srVault.perp() == address(core.perpSr), "SR Vault Perp mismatch");
        require(d.jrVault.keeper() == LOCAL_ADMIN && d.srVault.keeper() == LOCAL_ADMIN, "keeper mismatch");
        require(d.usdVault.dexStrategy() == address(d.dexStrategy), "DEX mismatch");
        require(d.usdVault.usdOracle() == address(d.usdOracle), "USD oracle mismatch");
        require(d.usdVault.isSwapper(address(d.inventory)), "inventory role mismatch");
        require(d.dexStrategy.isHealthy(), "local DEX unhealthy");
        require(d.pool.executionEnabled(), "local DEX execution disabled");
        require(d.usdVault.balanceOf(address(d.usdVault)) == d.usdVault.MINIMUM_LIQUIDITY(), "USD lock mismatch");
    }

    function _deployUnderlyingVault(UnderlyingPerpVault implementation, CoreDeployment memory core, bool senior)
        private
        returns (UnderlyingPerpVault vault)
    {
        vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            senior ? "cbBTC Senior Keeper" : "cbBTC Junior Keeper",
                            senior ? "cbBTC-Sr-Keeper" : "cbBTC-Jr-Keeper",
                            address(core.underlying),
                            address(core.controller),
                            senior,
                            senior
                        )
                    )
                )
            )
        );

        IUnderlyingPerpVault.DRRange memory range = IUnderlyingPerpVault.DRRange({
            lower: senior ? SR_EQ_DR_LOWER : JR_EQ_DR_LOWER, upper: senior ? SR_EQ_DR_UPPER : JR_EQ_DR_UPPER
        });
        vault.updateTargetDR(TARGET_DR, range);
        vault.updateRebalanceTimingParams(REBALANCE_FREQ_SEC, senior ? SR_REBALANCE_OFFSET_SEC : 0);
        vault.updateMinRebalanceAmt(MIN_REBALANCE_VAL);
        vault.updateMaxFlashFeePerc(MAX_FLASH_FEE_PERC);

        core.underlying.mint(LOCAL_ADMIN, UNDERLYING_VAULT_SEED);
        core.underlying.approve(address(vault), UNDERLYING_VAULT_SEED);
        uint256 notesMinted = vault.initDeposit(UNDERLYING_VAULT_SEED);
        require(notesMinted != 0, "Vault seed failed");
    }

    function _logDeployment(CoreDeployment memory core, PeripheryDeployment memory periphery) private view {
        (uint256 genesisSubDr, uint256 genesisVmDr) = core.controller.systemDeviations();

        console2.log("underlying", address(core.underlying));
        console2.log("usd", address(periphery.usd));
        console2.log("manager", address(core.manager));
        console2.log("issuer", address(core.issuer));
        console2.log("controller", address(core.controller));
        console2.log("canonicalBalancer", address(core.balancer));
        console2.log("rolloverPlanGuard", address(core.planGuard));
        console2.log("perpSr", address(core.perpSr));
        console2.log("perpJr", address(core.perpJr));
        console2.log("firstBondSr", core.firstBondSr);
        console2.log("firstBondJr", core.firstBondJr);
        console2.log("jrVault", address(periphery.jrVault));
        console2.log("srVault", address(periphery.srVault));
        console2.log("usdVault", address(periphery.usdVault));
        console2.log("usdRouter", address(periphery.usdRouter));
        console2.log("underlyingRouter", address(periphery.underlyingRouter));
        console2.log("dexStrategy", address(periphery.dexStrategy));
        console2.log("inventory", address(periphery.inventory));
        console2.log("localDexExecutionEnabled", periphery.pool.executionEnabled());
        console2.log("usdVaultActivationPending", false);
        console2.log("lockedSharesPerSide", core.seeder.MIN_LOCKED_SHARES());
        console2.log("genesisSubDR", genesisSubDr);
        console2.log("genesisVmDR", genesisVmDr);
        console2.log("userOpsPaused", core.controller.userOpsPaused());
    }
}
