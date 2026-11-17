// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {DeployGenesisLocal} from "../script/DeployGenesisLocal.s.sol";

contract FullProtocolDeploymentLifecycleTest is Test {
    address private constant USER = address(0xBEEF);
    address private constant RECEIVER = address(0xCAFE);
    address private constant LOCAL_ADMIN = address(0xA11CE);
    address private constant LOCKED_LIQUIDITY = 0x000000000000000000000000000000000000dEaD;

    function testOneCommandDeploymentManifestWiringAndFullLifecycle() public {
        DeployGenesisLocal deploymentScript = new DeployGenesisLocal();
        (DeployGenesisLocal.CoreDeployment memory core, DeployGenesisLocal.PeripheryDeployment memory periphery) =
            deploymentScript.run();

        _assertDeploymentWiring(core, periphery);
        _rebalanceJuniorVault(core, periphery);
        (uint256 usdNotes, uint256 jrNotes) = _pairDeposit(core, periphery);
        _assertAssetAccounting(deploymentScript, core, periphery);

        _advanceIssueAndBalancedMint(core, 82_000e18);
        _advanceIssueAndBalancedMint(core, 79_000e18);
        _advanceIssueAndBalancedMint(core, 84_000e18);
        assertEq(core.issuer.activeBondIDs().length, 4, "four Bond epochs deployed");

        IPerpToken.ReserveTokens memory srBefore = core.perpSr.reserves();
        IPerpToken.ReserveTokens memory jrBefore = core.perpJr.reserves();
        core.controller.rollover();
        IPerpToken.ReserveTokens memory srAfter = core.perpSr.reserves();
        IPerpToken.ReserveTokens memory jrAfter = core.perpJr.reserves();
        assertEq(srBefore.trancheTokens.length, 4, "four SR reserve rows before rollover");
        assertEq(jrBefore.trancheTokens.length, 4, "four JR reserve rows before rollover");
        assertEq(srAfter.trancheTokens.length, 3, "stale SR row removed");
        assertEq(jrAfter.trancheTokens.length, 3, "stale JR row removed");
        _assertAssetAccounting(deploymentScript, core, periphery);

        vm.startPrank(USER);
        periphery.usdVault.approve(address(periphery.pairRouter), usdNotes);
        periphery.jrVault.approve(address(periphery.pairRouter), jrNotes);
        uint256 usdBefore = periphery.usd.balanceOf(USER);
        uint256 underlyingBefore = core.underlying.balanceOf(USER);
        (uint256 usdOut, uint256 underlyingOut) = periphery.pairRouter
            .redeem(
                IPairRouter.RedeemParams({
                    usdVault: address(periphery.usdVault),
                    underlyingVault: address(periphery.jrVault),
                    strategy: address(periphery.dexStrategy),
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
                })
            );
        vm.stopPrank();

        assertEq(periphery.usd.balanceOf(USER) - usdBefore, usdOut, "USD settlement");
        assertEq(core.underlying.balanceOf(USER) - underlyingBefore, underlyingOut, "underlying settlement");
        assertGt(usdOut, 0, "USD output");
        assertGt(underlyingOut, 0, "underlying output");
        assertEq(periphery.usdVault.balanceOf(USER), 0, "USD notes burned");
        assertEq(periphery.jrVault.balanceOf(USER), 0, "JR notes burned");
        _assertRouterDustFree(core, periphery);
        _assertAssetAccounting(deploymentScript, core, periphery);
    }

    function _assertDeploymentWiring(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        address admin = LOCAL_ADMIN;
        assertEq(core.controller.owner(), admin, "Controller owner");
        assertEq(core.controller.keeper(), admin, "Controller keeper");
        assertEq(core.controller.underlying(), address(core.underlying), "Controller underlying");
        assertEq(core.controller.perpSr(), address(core.perpSr), "Controller SR");
        assertEq(core.controller.perpJr(), address(core.perpJr), "Controller JR");
        assertEq(core.controller.feePolicy(), address(core.feePolicy), "Controller fee policy");
        assertEq(core.controller.balancer(), address(core.planGuard), "Controller guarded planner");
        assertEq(core.planGuard.planner(), address(core.balancer), "guard canonical planner");
        assertEq(core.planGuard.bondsManager(), address(core.manager), "guard BondsManager");
        assertEq(core.perpSr.controller(), address(core.controller), "SR controller");
        assertEq(core.perpJr.controller(), address(core.controller), "JR controller");
        assertEq(periphery.srVault.perp(), address(core.perpSr), "SR Vault Perp");
        assertEq(periphery.jrVault.perp(), address(core.perpJr), "JR Vault Perp");
        assertEq(periphery.usdVault.perpController(), address(core.controller), "USD Vault Controller");
        assertEq(periphery.usdVault.dexStrategy(), address(periphery.dexStrategy), "USD Vault Strategy");
        assertEq(periphery.usdVault.usdOracle(), address(periphery.usdOracle), "USD Vault oracle");
        assertTrue(periphery.usdVault.isSwapper(address(periphery.inventory)), "Inventory authorization");
        assertTrue(periphery.dexStrategy.isHealthy(), "DEX health");
        assertTrue(periphery.pool.executionEnabled(), "DEX execution");
    }

    function _pairDeposit(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private returns (uint256 usdNotes, uint256 jrNotes) {
        uint256 tradeUnderlying = 10_000;
        uint256 jrUnderlying = 50_000;
        core.underlying.mint(USER, tradeUnderlying + jrUnderlying);

        vm.startPrank(USER);
        core.underlying.approve(address(periphery.pairRouter), type(uint256).max);
        (usdNotes, jrNotes,,,,) = periphery.pairRouter
            .deposit(
                IPairRouter.DepositParams({
                    usdVault: address(periphery.usdVault),
                    underlyingVault: address(periphery.jrVault),
                    strategy: address(periphery.dexStrategy),
                    recipient: USER,
                    underlyingIn: tradeUnderlying + jrUnderlying,
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
                })
            );
        vm.stopPrank();
        assertGt(usdNotes, 0, "USD notes");
        assertGt(jrNotes, 0, "JR notes");
        _assertRouterDustFree(core, periphery);
    }

    function _rebalanceJuniorVault(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private {
        (uint256 subDr,) = core.controller.systemDeviations();
        uint96 target = uint96(subDr * 2);
        vm.prank(LOCAL_ADMIN);
        periphery.jrVault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (uint256 amount, bool minting) = periphery.jrVault.computeRebalanceAmount();
        assertTrue(minting, "JR Vault mint direction");
        assertGt(amount, 0, "JR Vault rebalance amount");
        periphery.jrVault.rebalance();
        assertGt(core.perpJr.balanceOf(address(periphery.jrVault)), 0, "JR Vault Perp inventory");
    }

    function _advanceIssueAndBalancedMint(DeployGenesisLocal.CoreDeployment memory core, uint256 price) private {
        vm.warp(block.timestamp + 604_800);
        core.underlyingOracle.setPrice(price);
        core.controller.upkeep();
        BondIssuer.BondInfo memory info = core.issuer.latestBondInfo();

        core.underlying.mint(RECEIVER, 10_000_000);
        vm.startPrank(RECEIVER);
        core.underlying.approve(address(core.manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            core.manager.deposit(info.bondID, 10_000_000);
        IERC20(srInput.token).approve(address(core.controller), type(uint256).max);
        IERC20(jrInput.token).approve(address(core.controller), type(uint256).max);
        core.controller
            .mint2(
                PerpController.TokenAmount(srInput.token, srInput.amount),
                PerpController.TokenAmount(jrInput.token, jrInput.amount),
                0,
                0
            );
        vm.stopPrank();
    }

    function _assertRouterDustFree(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        assertEq(core.underlying.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(periphery.usd.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.perpSr.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.perpJr.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(periphery.usdVault.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(periphery.jrVault.balanceOf(address(periphery.pairRouter)), 0);
    }

    function _assertAssetAccounting(
        DeployGenesisLocal deploymentScript,
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        assertEq(
            _trackedToken(core.underlying, deploymentScript, core, periphery),
            core.underlying.totalSupply(),
            "underlying conservation"
        );
        assertEq(
            _trackedToken(periphery.usd, deploymentScript, core, periphery),
            periphery.usd.totalSupply(),
            "USD conservation"
        );
        assertEq(
            _trackedToken(core.perpSr, deploymentScript, core, periphery),
            core.perpSr.totalSupply(),
            "Perp SR conservation"
        );
        assertEq(
            _trackedToken(core.perpJr, deploymentScript, core, periphery),
            core.perpJr.totalSupply(),
            "Perp JR conservation"
        );
        assertEq(
            _trackedToken(periphery.usdVault, deploymentScript, core, periphery),
            periphery.usdVault.totalSupply(),
            "USD notes conservation"
        );
        assertEq(
            _trackedToken(periphery.jrVault, deploymentScript, core, periphery),
            periphery.jrVault.totalSupply(),
            "JR notes conservation"
        );
    }

    function _trackedToken(
        IERC20 token,
        DeployGenesisLocal deploymentScript,
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view returns (uint256 total) {
        total += token.balanceOf(address(this));
        total += token.balanceOf(address(deploymentScript));
        total += token.balanceOf(LOCAL_ADMIN);
        total += token.balanceOf(USER);
        total += token.balanceOf(RECEIVER);
        total += token.balanceOf(LOCKED_LIQUIDITY);
        total += token.balanceOf(address(core.manager));
        total += token.balanceOf(address(core.issuer));
        total += token.balanceOf(address(core.perpSr));
        total += token.balanceOf(address(core.perpJr));
        total += token.balanceOf(address(core.controller));
        total += token.balanceOf(address(core.seeder));
        total += token.balanceOf(address(periphery.pool));
        total += token.balanceOf(address(periphery.dexStrategy));
        total += token.balanceOf(address(periphery.inventory));
        total += token.balanceOf(address(periphery.usdVault));
        total += token.balanceOf(address(periphery.srVault));
        total += token.balanceOf(address(periphery.jrVault));
        total += token.balanceOf(address(periphery.usdRouter));
        total += token.balanceOf(address(periphery.underlyingRouter));
        total += token.balanceOf(address(periphery.pairRouter));
    }
}
