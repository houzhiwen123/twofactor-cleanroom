// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {UniswapV3DexStrategy} from "../src/strategy/UniswapV3DexStrategy.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {
    MockUnderlyingPerpVaultRebalanceController,
    MockUnderlyingPerpVaultRebalanceToken
} from "./mocks/MockUnderlyingPerpVaultRebalanceController.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract OperationalDeploymentTest is Test {
    address private constant RANDOM_CALLER = address(0xBEEF);
    address private constant NEW_KEEPER = address(0xCA11);
    bytes4 private constant INVALID_INITIALIZATION = bytes4(keccak256("InvalidInitialization()"));
    bytes4 private constant OWNABLE_UNAUTHORIZED_ACCOUNT = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    function testUnderlyingVaultDeploymentConfigAndKeeperBoundary() external {
        MockERC20 underlying = new MockERC20("Underlying", "UND", 8);
        MockUnderlyingPerpVaultRebalanceToken perpSr = new MockUnderlyingPerpVaultRebalanceToken("Perp SR", "PSR", 8);
        MockUnderlyingPerpVaultRebalanceToken perpJr = new MockUnderlyingPerpVaultRebalanceToken("Perp JR", "PJR", 8);
        MockUnderlyingPerpVaultRebalanceController controller =
            new MockUnderlyingPerpVaultRebalanceController(address(underlying), address(perpSr), address(perpJr));

        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        UnderlyingPerpVault vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            "cbBTC Junior Keeper",
                            "cbBTC-Jr-Keeper",
                            address(underlying),
                            address(controller),
                            false,
                            false
                        )
                    )
                )
            )
        );

        IUnderlyingPerpVault.DRRange memory range =
            IUnderlyingPerpVault.DRRange({lower: 1_053_564_994_000_000_000, upper: 1_230_000_000_000_000_000});
        vault.updateTargetDR(1_053_564_994_000_000_000, range);
        vault.updateRebalanceTimingParams(28_800, 0);
        vault.updateMinRebalanceAmt(100_000);
        vault.updateMaxFlashFeePerc(5_000_000_000_000_000);

        assertEq(vault.owner(), address(this));
        assertEq(vault.keeper(), address(this));
        assertEq(vault.perp(), address(perpJr));
        assertEq(vault.targetDR(), 1_053_564_994_000_000_000);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        assertEq(lower, range.lower);
        assertEq(upper, range.upper);
        assertEq(vault.rebalanceFreqSec(), 28_800);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.minRebalanceVal(), 100_000);
        assertEq(vault.maxFlashFeePerc(), 5_000_000_000_000_000);

        vm.prank(RANDOM_CALLER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT, RANDOM_CALLER));
        vault.updateKeeper(NEW_KEEPER);

        vault.updateKeeper(NEW_KEEPER);
        vm.expectRevert(UnderlyingPerpVault.UnauthorizedCall.selector);
        vault.pause();

        vm.prank(NEW_KEEPER);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(NEW_KEEPER);
        vault.unpause();
        assertFalse(vault.paused());

        vm.prank(RANDOM_CALLER);
        vm.expectRevert(UnderlyingPerpVault.NoOp.selector);
        vault.rebalance();

        vm.expectRevert(INVALID_INITIALIZATION);
        vault.init("again", "again", address(underlying), address(controller), false, false);
    }

    function testUsdVaultDependenciesReplayAndPermissionlessMaintenanceBoundary() external {
        MockERC20 usd = new MockERC20("USD Coin", "USDC", 6);
        MockERC20 underlying = new MockERC20("Underlying", "UND", 8);
        MockERC20 perpSr = new MockERC20("Perp SR", "PSR", 8);
        MockPriceOracle underlyingOracle = new MockPriceOracle(80_000e18);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        MockUsdVaultController controller = new MockUsdVaultController(address(underlyingOracle));
        controller.setSystemDeviations(1e18, 1e18);

        MockUniswapV3Pool pool = new MockUniswapV3Pool(address(usd), address(underlying));
        UniswapV3DexStrategy dex = new UniswapV3DexStrategy(address(usd), address(underlying), address(pool), 1);

        UsdVault implementation = new UsdVault();
        UsdVault vault =
            UsdVault(address(new TransparentUpgradeableProxy(address(implementation), address(this), bytes(""))));

        vm.expectRevert(UsdVault.InvalidParamDefn.selector);
        vault.initExecution(
            "USD Senior Vault",
            "USD-SR",
            address(usd),
            address(perpSr),
            address(underlying),
            address(controller),
            address(0),
            address(usdOracle),
            NEW_KEEPER
        );

        vault.initExecution(
            "USD Senior Vault",
            "USD-SR",
            address(usd),
            address(perpSr),
            address(underlying),
            address(controller),
            address(dex),
            address(usdOracle),
            NEW_KEEPER
        );

        assertEq(vault.usd(), address(usd));
        assertEq(vault.perpSr(), address(perpSr));
        assertEq(vault.underlying(), address(underlying));
        assertEq(vault.perpController(), address(controller));
        assertEq(vault.dexStrategy(), address(dex));
        assertEq(vault.usdOracle(), address(usdOracle));
        assertTrue(vault.isSwapper(NEW_KEEPER));
        assertTrue(dex.isHealthy());
        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        assertEq(vault.initDeposit(10_000), 0, "target threshold must remain a no-op");
        assertEq(vault.initDeposit(10_001), 10_001e12, "USD Vault Genesis mismatch");
        assertEq(vault.balanceOf(address(vault)), vault.MINIMUM_LIQUIDITY());

        vm.expectRevert(UsdVault.VaultInitialized.selector);
        vault.initDeposit(10_001);

        vm.expectRevert(INVALID_INITIALIZATION);
        vault.initExecution(
            "again",
            "again",
            address(usd),
            address(perpSr),
            address(underlying),
            address(controller),
            address(dex),
            address(usdOracle),
            NEW_KEEPER
        );

        vm.prank(RANDOM_CALLER);
        vm.expectRevert(UsdVault.UnauthorizedCall.selector);
        vault.swap(address(usd), address(underlying), 1, 1);

        vm.prank(RANDOM_CALLER);
        vm.expectRevert(UsdVault.NoOp.selector);
        vault.rebalance();

        vm.prank(RANDOM_CALLER);
        vm.expectRevert(UsdVault.NoOp.selector);
        vault.upkeep();
    }
}
