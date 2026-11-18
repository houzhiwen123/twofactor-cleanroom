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

/// @notice Local-only acceptance test spanning the deployable core and all three Vault products.
contract FullProtocolThreeVaultLifecycleTest is Test {
    struct UserPositions {
        uint256 usdNotes;
        uint256 srNotes;
        uint256 jrNotes;
    }

    address private constant USER = address(0xBEEF);
    address private constant RECEIVER = address(0xCAFE);
    address private constant LOCAL_ADMIN = address(0xA11CE);
    address private constant LOCKED_LIQUIDITY = 0x000000000000000000000000000000000000dEaD;

    function testAllThreeVaultsCompleteDeploymentFundingRolloverAndExit() public {
        DeployGenesisLocal deploymentScript = new DeployGenesisLocal();
        (DeployGenesisLocal.CoreDeployment memory core, DeployGenesisLocal.PeripheryDeployment memory periphery) =
            deploymentScript.run();

        _assertWiring(core, periphery);
        UserPositions memory positions = _openPositions(core, periphery);
        _assertAllTrackedSupplies(deploymentScript, core, periphery);
        _runFundingAndRollover(core);
        _assertAllTrackedSupplies(deploymentScript, core, periphery);
        _closePositions(core, periphery, positions);
        _assertAllTrackedSupplies(deploymentScript, core, periphery);
    }

    function _openPositions(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private returns (UserPositions memory positions) {
        _rebalanceUnderlyingVault(core, periphery.srVault, true);
        _rebalanceUnderlyingVault(core, periphery.jrVault, false);

        core.underlying.mint(USER, 75_000);
        vm.startPrank(USER);
        core.underlying.approve(address(periphery.underlyingRouter), type(uint256).max);
        positions.srNotes = periphery.underlyingRouter.depositUnderlying(address(periphery.srVault), 75_000, 1, 2);
        vm.stopPrank();
        assertGt(positions.srNotes, 0, "SR notes");

        (positions.usdNotes, positions.jrNotes) = _pairDeposit(core, periphery);
        assertGt(core.perpSr.balanceOf(address(periphery.srVault)), 0, "SR Vault Perp inventory");
        assertGt(core.perpJr.balanceOf(address(periphery.jrVault)), 0, "JR Vault Perp inventory");

        _rebalanceUsdVault(periphery);
        assertGt(core.perpSr.balanceOf(address(periphery.usdVault)), 0, "USD Vault Perp inventory");
    }

    function _runFundingAndRollover(DeployGenesisLocal.CoreDeployment memory core) private {
        _runFunding(core);
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
    }

    function _runFunding(DeployGenesisLocal.CoreDeployment memory core) private {
        (PerpController.SystemState memory beforeFunding,,) = core.controller.systemReserveState();
        uint256 totalBefore = beforeFunding.perpSr.reserveValue + beforeFunding.perpJr.reserveValue;
        core.controller.rebalance();
        (PerpController.SystemState memory afterFunding,,) = core.controller.systemReserveState();
        uint256 totalAfter = afterFunding.perpSr.reserveValue + afterFunding.perpJr.reserveValue;
        assertApproxEqAbs(totalBefore, totalAfter, 2, "funding preserves aggregate reserve value");
        assertGt(core.controller.lastRebalanceTimestampSec(), 0, "funding timestamp recorded");
    }

    function _closePositions(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery,
        UserPositions memory positions
    ) private {
        vm.startPrank(USER);
        periphery.usdVault.approve(address(periphery.pairRouter), positions.usdNotes);
        periphery.jrVault.approve(address(periphery.pairRouter), positions.jrNotes);
        periphery.srVault.approve(address(periphery.underlyingRouter), positions.srNotes);
        vm.stopPrank();

        bytes32 beforeFailure = _srExitFingerprint(core, periphery);
        vm.prank(USER);
        vm.expectRevert(bytes4(keccak256("SlippageTooHigh()")));
        periphery.underlyingRouter.redeemUnderlying(address(periphery.srVault), positions.srNotes, type(uint256).max);
        assertEq(_srExitFingerprint(core, periphery), beforeFailure, "failed SR exit must be atomic");

        uint256 usdBefore = periphery.usd.balanceOf(USER);
        uint256 underlyingBefore = core.underlying.balanceOf(USER);
        vm.startPrank(USER);
        (uint256 usdOut, uint256 pairUnderlyingOut) = _pairRedeem(periphery, positions.usdNotes, positions.jrNotes);
        uint256 srUnderlyingOut =
            periphery.underlyingRouter.redeemUnderlying(address(periphery.srVault), positions.srNotes, 1);
        vm.stopPrank();

        assertEq(periphery.usd.balanceOf(USER) - usdBefore, usdOut, "USD settlement");
        assertEq(
            core.underlying.balanceOf(USER) - underlyingBefore,
            pairUnderlyingOut + srUnderlyingOut,
            "combined underlying settlement"
        );
        assertGt(usdOut, 0, "USD output");
        assertGt(pairUnderlyingOut, 0, "pair underlying output");
        assertGt(srUnderlyingOut, 0, "SR underlying output");
        assertEq(periphery.usdVault.balanceOf(USER), 0, "USD notes burned");
        assertEq(periphery.srVault.balanceOf(USER), 0, "SR notes burned");
        assertEq(periphery.jrVault.balanceOf(USER), 0, "JR notes burned");
        _assertRoutersDustFree(core, periphery);
    }

    function _rebalanceUnderlyingVault(
        DeployGenesisLocal.CoreDeployment memory core,
        IUnderlyingPerpVault vault,
        bool senior
    ) private {
        (uint256 subDr,) = core.controller.systemDeviations();
        uint96 target = senior ? uint96(subDr / 2) : uint96(subDr * 2);
        vm.prank(LOCAL_ADMIN);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (uint256 amount, bool minting) = vault.computeRebalanceAmount();
        assertTrue(minting, senior ? "SR mint direction" : "JR mint direction");
        assertGt(amount, 0, senior ? "SR rebalance amount" : "JR rebalance amount");
        vault.rebalance();
    }

    function _rebalanceUsdVault(DeployGenesisLocal.PeripheryDeployment memory periphery) private {
        (uint256 capacity,, bool minting,,) = periphery.usdVault.rebalanceCapacity();
        assertTrue(minting, "USD Vault mint direction");
        assertGt(capacity, 0, "USD Vault rebalance capacity");
        (,,, uint256 openedAt) = periphery.usdVault.sessionCapacity();
        uint256 executableAt = openedAt + periphery.usdVault.activeRebalanceDelaySec();
        if (block.timestamp < executableAt) vm.warp(executableAt);
        periphery.usdVault.rebalance();
        (bool active, bool direction,,) = periphery.usdVault.sessionCapacity();
        assertTrue(active, "USD Vault session active");
        assertTrue(direction, "USD Vault session direction");
    }

    function _pairDeposit(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private returns (uint256 usdNotes, uint256 jrNotes) {
        uint256 underlyingToTrade = 1_000_000;
        uint256 juniorUnderlying = 2_000_000;
        uint256 totalUnderlying = underlyingToTrade + juniorUnderlying;
        core.underlying.mint(USER, totalUnderlying);
        vm.startPrank(USER);
        core.underlying.approve(address(periphery.pairRouter), type(uint256).max);
        (usdNotes, jrNotes,,,,) = periphery.pairRouter
            .deposit(
                IPairRouter.DepositParams({
                    usdVault: address(periphery.usdVault),
                    underlyingVault: address(periphery.jrVault),
                    strategy: address(periphery.dexStrategy),
                    recipient: USER,
                    underlyingIn: totalUnderlying,
                    minUsdFromTrade: 0,
                    underlyingToTrade: underlyingToTrade,
                    srUnderlyingIn: 0,
                    jrUnderlyingIn: juniorUnderlying,
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
    }

    function _pairRedeem(DeployGenesisLocal.PeripheryDeployment memory periphery, uint256 usdNotes, uint256 jrNotes)
        private
        returns (uint256 usdOut, uint256 underlyingOut)
    {
        return periphery.pairRouter
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

    function _assertWiring(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        assertEq(core.controller.balancer(), address(core.planGuard), "guarded planner");
        assertEq(core.planGuard.planner(), address(core.balancer), "canonical planner");
        assertEq(periphery.srVault.perp(), address(core.perpSr), "SR Vault Perp");
        assertEq(periphery.jrVault.perp(), address(core.perpJr), "JR Vault Perp");
        assertEq(periphery.usdVault.perpSr(), address(core.perpSr), "USD Vault Perp");
        assertTrue(periphery.usdVault.isSwapper(address(periphery.inventory)), "Inventory authorization");
        assertTrue(periphery.dexStrategy.isHealthy(), "DEX health");
    }

    function _srExitFingerprint(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                core.underlying.balanceOf(USER),
                core.underlying.balanceOf(address(periphery.srVault)),
                core.underlying.balanceOf(address(periphery.underlyingRouter)),
                core.perpSr.balanceOf(address(periphery.srVault)),
                core.perpSr.balanceOf(address(periphery.underlyingRouter)),
                periphery.srVault.balanceOf(USER),
                periphery.srVault.balanceOf(address(periphery.underlyingRouter)),
                periphery.srVault.totalSupply(),
                core.perpSr.totalSupply(),
                core.controller.collectedFeeBal(address(core.underlying)),
                core.controller.collectedFeeBal(address(core.perpSr)),
                core.perpSr.reserves()
            )
        );
    }

    function _assertRoutersDustFree(
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        assertEq(core.underlying.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(periphery.usd.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.perpSr.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.perpJr.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.underlying.balanceOf(address(periphery.underlyingRouter)), 0);
        assertEq(core.perpSr.balanceOf(address(periphery.underlyingRouter)), 0);
        assertEq(core.perpJr.balanceOf(address(periphery.underlyingRouter)), 0);
        assertEq(periphery.usdVault.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(periphery.srVault.balanceOf(address(periphery.underlyingRouter)), 0);
        assertEq(periphery.jrVault.balanceOf(address(periphery.pairRouter)), 0);
    }

    function _assertAllTrackedSupplies(
        DeployGenesisLocal deploymentScript,
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) private view {
        _assertTrackedSupply(core.underlying, deploymentScript, core, periphery, "underlying conservation");
        _assertTrackedSupply(periphery.usd, deploymentScript, core, periphery, "USD conservation");
        _assertTrackedSupply(core.perpSr, deploymentScript, core, periphery, "Perp SR conservation");
        _assertTrackedSupply(core.perpJr, deploymentScript, core, periphery, "Perp JR conservation");
        _assertTrackedSupply(periphery.usdVault, deploymentScript, core, periphery, "USD notes conservation");
        _assertTrackedSupply(periphery.srVault, deploymentScript, core, periphery, "SR notes conservation");
        _assertTrackedSupply(periphery.jrVault, deploymentScript, core, periphery, "JR notes conservation");
    }

    function _assertTrackedSupply(
        IERC20 token,
        DeployGenesisLocal deploymentScript,
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery,
        string memory reason
    ) private view {
        uint256 accounted = token.balanceOf(address(this)) + token.balanceOf(address(deploymentScript));
        accounted += token.balanceOf(LOCAL_ADMIN) + token.balanceOf(USER) + token.balanceOf(RECEIVER);
        accounted += token.balanceOf(LOCKED_LIQUIDITY) + token.balanceOf(address(core.manager));
        accounted += token.balanceOf(address(core.issuer)) + token.balanceOf(address(core.perpSr));
        accounted += token.balanceOf(address(core.perpJr)) + token.balanceOf(address(core.controller));
        accounted += token.balanceOf(address(core.seeder)) + token.balanceOf(address(periphery.pool));
        accounted += token.balanceOf(address(periphery.dexStrategy)) + token.balanceOf(address(periphery.inventory));
        accounted += token.balanceOf(address(periphery.usdVault)) + token.balanceOf(address(periphery.srVault));
        accounted += token.balanceOf(address(periphery.jrVault)) + token.balanceOf(address(periphery.usdRouter));
        accounted += token.balanceOf(address(periphery.underlyingRouter))
        + token.balanceOf(address(periphery.pairRouter));
        assertEq(accounted, token.totalSupply(), reason);
    }
}
