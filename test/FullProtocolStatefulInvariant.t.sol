// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {PairRouter} from "../src/router/PairRouter.sol";
import {UnderlyingSingleAssetRouter} from "../src/router/UnderlyingSingleAssetRouter.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {DeployGenesisLocal} from "../script/DeployGenesisLocal.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";

contract FullProtocolStatefulHandler is Test {
    address private constant LOCAL_ADMIN = address(0xA11CE);

    address public immutable deploymentScript;
    MockERC20 public immutable underlying;
    MockERC20 public immutable usd;
    MockPriceOracle public immutable underlyingOracle;
    BondsManager public immutable manager;
    BondIssuer public immutable issuer;
    PerpToken public immutable perpSr;
    PerpToken public immutable perpJr;
    PerpController public immutable controller;
    UnderlyingPerpVault public immutable jrVault;
    UnderlyingPerpVault public immutable srVault;
    UsdVault public immutable usdVault;
    PairRouter public immutable pairRouter;
    UnderlyingSingleAssetRouter public immutable underlyingRouter;
    MockUniswapV3Pool public immutable pool;
    address public immutable usdRouter;
    address public immutable dexStrategy;
    address public immutable inventory;

    address[3] public actors = [address(0xB0B), address(0xCA11), address(0xBEEF)];
    bool public atomicityBroken;
    uint256 public successfulCalls;
    uint256 public revertedCalls;

    constructor(
        address deploymentScript_,
        DeployGenesisLocal.CoreDeployment memory core,
        DeployGenesisLocal.PeripheryDeployment memory periphery
    ) {
        deploymentScript = deploymentScript_;
        underlying = core.underlying;
        usd = periphery.usd;
        underlyingOracle = core.underlyingOracle;
        manager = core.manager;
        issuer = core.issuer;
        perpSr = core.perpSr;
        perpJr = core.perpJr;
        controller = core.controller;
        jrVault = periphery.jrVault;
        srVault = periphery.srVault;
        usdVault = periphery.usdVault;
        pairRouter = periphery.pairRouter;
        underlyingRouter = periphery.underlyingRouter;
        pool = periphery.pool;
        usdRouter = address(periphery.usdRouter);
        dexStrategy = address(periphery.dexStrategy);
        inventory = address(periphery.inventory);
    }

    function pairDeposit(uint8 actorSeed, uint96 rawTrade, uint96 rawSr, uint96 rawJr) external {
        address actor = _actor(actorSeed);
        uint256 tradeUnderlying = bound(uint256(rawTrade), 1, 50_000);
        uint256 srUnderlying = bound(uint256(rawSr), 1, 250_000);
        uint256 jrUnderlying = bound(uint256(rawJr), 1, 500_000);
        uint256 underlyingIn = tradeUnderlying + srUnderlying + jrUnderlying;

        underlying.mint(actor, underlyingIn);
        vm.startPrank(actor);
        underlying.approve(address(pairRouter), type(uint256).max);
        try pairRouter.deposit(
            IPairRouter.DepositParams({
                usdVault: address(usdVault),
                underlyingVault: address(jrVault),
                strategy: dexStrategy,
                recipient: actor,
                underlyingIn: underlyingIn,
                minUsdFromTrade: 0,
                underlyingToTrade: tradeUnderlying,
                srUnderlyingIn: srUnderlying,
                jrUnderlyingIn: jrUnderlying,
                minUsdNotes: 0,
                minUnderlyingNotes: 0,
                minSubDr: 0,
                maxSubDr: type(uint256).max,
                minVmDr: 0,
                maxVmDr: type(uint256).max,
                healthCheck: false
            })
        ) returns (
            uint256, uint256, uint256, uint256, uint256, uint256
        ) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function pairRedeem(uint8 actorSeed, uint96 rawUsdNotes, uint96 rawJrNotes, bool tradeUsd, bool runUpkeep)
        external
    {
        address actor = _actor(actorSeed);
        uint256 usdBalance = usdVault.balanceOf(actor);
        uint256 jrBalance = jrVault.balanceOf(actor);
        if (usdBalance == 0 && jrBalance == 0) return;
        uint256 usdNotes = usdBalance == 0 ? 0 : bound(uint256(rawUsdNotes), 1, usdBalance);
        uint256 jrNotes = jrBalance == 0 ? 0 : bound(uint256(rawJrNotes), 1, jrBalance);

        vm.startPrank(actor);
        usdVault.approve(address(pairRouter), type(uint256).max);
        jrVault.approve(address(pairRouter), type(uint256).max);
        try pairRouter.redeem(
            IPairRouter.RedeemParams({
                usdVault: address(usdVault),
                underlyingVault: address(jrVault),
                strategy: dexStrategy,
                usdNotes: usdNotes,
                underlyingNotes: jrNotes,
                maxUsdRetained: tradeUsd ? 0 : type(uint256).max,
                underlyingToTrade: 0,
                runUpkeep: runUpkeep,
                minUsdOut: 0,
                minUnderlyingOut: 0,
                minSubDr: 0,
                maxSubDr: type(uint256).max,
                minVmDr: 0,
                maxVmDr: type(uint256).max,
                healthCheck: false
            })
        ) returns (
            uint256, uint256
        ) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function underlyingDeposit(uint8 actorSeed, bool senior, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? srVault : jrVault;
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000);
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(underlyingRouter), type(uint256).max);
        try underlyingRouter.depositUnderlying(address(vault), amount, 0, 2) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function underlyingRedeem(uint8 actorSeed, bool senior, uint96 rawNotes) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? srVault : jrVault;
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 notes = bound(uint256(rawNotes), 1, balance);
        vm.startPrank(actor);
        vault.approve(address(underlyingRouter), type(uint256).max);
        try underlyingRouter.redeemUnderlying(address(vault), notes, 0) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function directUsdDeposit(uint8 actorSeed, uint96 rawUsd, uint96 rawPerp) external {
        address actor = _actor(actorSeed);
        uint256 usdAmount = bound(uint256(rawUsd), 1, 1_000_000e6);
        uint256 perpBalance = perpSr.balanceOf(actor);
        uint256 perpAmount = perpBalance == 0 ? 0 : bound(uint256(rawPerp), 1, perpBalance);
        usd.mint(actor, usdAmount);
        vm.startPrank(actor);
        usd.approve(address(usdVault), type(uint256).max);
        perpSr.approve(address(usdVault), type(uint256).max);
        try usdVault.deposit(usdAmount, perpAmount) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function directUsdRedeem(uint8 actorSeed, uint96 rawNotes) external {
        address actor = _actor(actorSeed);
        uint256 balance = usdVault.balanceOf(actor);
        if (balance == 0) return;
        uint256 notes = bound(uint256(rawNotes), 1, balance);
        vm.prank(actor);
        try usdVault.redeem(notes) returns (uint256, uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
    }

    function configureDex(bool enabled, bool unlocked, bool noFill, uint96 rawMaxInput) external {
        pool.setExecutionEnabled(enabled);
        pool.setUnlocked(unlocked);
        pool.setMaxInputPerSwap(noFill ? 0 : bound(uint256(rawMaxInput), 1, 1_000_000e6));
        successfulCalls += 1;
    }

    function advanceTime(uint32 rawSeconds) external {
        vm.warp(block.timestamp + bound(uint256(rawSeconds), 1, 604_800));
        successfulCalls += 1;
    }

    function changePrice(uint96 rawPrice) external {
        underlyingOracle.setPrice(bound(uint256(rawPrice), 8_000e18, 800_000e18));
        successfulCalls += 1;
    }

    function advanceEpoch(uint96 rawPrice) external {
        vm.warp(block.timestamp + 604_800);
        underlyingOracle.setPrice(bound(uint256(rawPrice), 8_000e18, 800_000e18));
        _recordCall(address(controller), abi.encodeCall(PerpController.upkeep, ()));
    }

    function bondMint(uint8 actorSeed, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 100_000, 2_000_000);
        BondIssuer.BondInfo memory info = issuer.latestBondInfo();
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            manager.deposit(info.bondID, amount);
        IERC20(srInput.token).approve(address(controller), type(uint256).max);
        IERC20(jrInput.token).approve(address(controller), type(uint256).max);
        _recordCall(
            address(controller),
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
    }

    function rollover() external {
        _recordCall(address(controller), abi.encodeCall(PerpController.rollover, ()));
    }

    function underlyingRebalance(bool senior, bool minting) external {
        UnderlyingPerpVault vault = senior ? srVault : jrVault;
        (uint256 subDr,) = controller.systemDeviations();
        bool targetBelow = senior ? minting : !minting;
        uint96 target = targetBelow ? uint96(subDr / 2) : uint96(subDr * 2);
        vm.prank(LOCAL_ADMIN);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        _recordCall(address(vault), abi.encodeCall(UnderlyingPerpVault.rebalance, ()));
    }

    function usdRebalance() external {
        _recordCall(address(usdVault), abi.encodeCall(UsdVault.rebalance, ()));
    }

    function usdUpkeep() external {
        _recordCall(address(usdVault), abi.encodeCall(UsdVault.upkeep, ()));
    }

    function donate(uint8 actorSeed, bool usdAsset, uint8 destinationSeed, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        MockERC20 token = usdAsset ? usd : underlying;
        uint256 amount = bound(uint256(rawAmount), 1, usdAsset ? 100_000e6 : 1_000_000);
        token.mint(actor, amount);
        address destination;
        uint256 choice = uint256(destinationSeed) % 5;
        if (choice == 0) destination = address(usdVault);
        else if (choice == 1) destination = address(jrVault);
        else if (choice == 2) destination = address(srVault);
        else if (choice == 3) destination = address(pool);
        else destination = usdAsset ? inventory : address(perpJr);
        vm.prank(actor);
        assertTrue(token.transfer(destination, amount));
        successfulCalls += 1;
    }

    function failedPairDeposit(uint8 actorSeed, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 3, 1_000_000);
        uint256 tradeUnderlying = amount / 3;
        uint256 srUnderlying = amount / 3;
        uint256 jrUnderlying = amount - tradeUnderlying - srUnderlying;
        underlying.mint(actor, amount);
        vm.prank(actor);
        underlying.approve(address(pairRouter), type(uint256).max);
        bytes32 beforeState = _failureFingerprint(actor);
        vm.prank(actor);
        (bool ok,) = address(pairRouter)
            .call(
                abi.encodeCall(
                    PairRouter.deposit,
                    (IPairRouter.DepositParams({
                            usdVault: address(usdVault),
                            underlyingVault: address(jrVault),
                            strategy: dexStrategy,
                            recipient: actor,
                            underlyingIn: amount,
                            minUsdFromTrade: 0,
                            underlyingToTrade: tradeUnderlying,
                            srUnderlyingIn: srUnderlying,
                            jrUnderlyingIn: jrUnderlying,
                            minUsdNotes: type(uint256).max,
                            minUnderlyingNotes: type(uint256).max,
                            minSubDr: 0,
                            maxSubDr: type(uint256).max,
                            minVmDr: 0,
                            maxVmDr: type(uint256).max,
                            healthCheck: false
                        }))
                )
            );
        if (ok || _failureFingerprint(actor) != beforeState) atomicityBroken = true;
    }

    function failedPairRedeem(uint8 actorSeed, uint96 rawUsdNotes, uint96 rawJrNotes) external {
        address actor = _actor(actorSeed);
        uint256 usdBalance = usdVault.balanceOf(actor);
        uint256 jrBalance = jrVault.balanceOf(actor);
        if (usdBalance == 0 && jrBalance == 0) return;
        uint256 usdNotes = usdBalance == 0 ? 0 : bound(uint256(rawUsdNotes), 1, usdBalance);
        uint256 jrNotes = jrBalance == 0 ? 0 : bound(uint256(rawJrNotes), 1, jrBalance);
        vm.startPrank(actor);
        usdVault.approve(address(pairRouter), type(uint256).max);
        jrVault.approve(address(pairRouter), type(uint256).max);
        vm.stopPrank();
        bytes32 beforeState = _failureFingerprint(actor);
        vm.prank(actor);
        (bool ok,) = address(pairRouter)
            .call(
                abi.encodeCall(
                    PairRouter.redeem,
                    (IPairRouter.RedeemParams({
                            usdVault: address(usdVault),
                            underlyingVault: address(jrVault),
                            strategy: dexStrategy,
                            usdNotes: usdNotes,
                            underlyingNotes: jrNotes,
                            maxUsdRetained: type(uint256).max,
                            underlyingToTrade: 0,
                            runUpkeep: false,
                            minUsdOut: type(uint256).max,
                            minUnderlyingOut: type(uint256).max,
                            minSubDr: 0,
                            maxSubDr: type(uint256).max,
                            minVmDr: 0,
                            maxVmDr: type(uint256).max,
                            healthCheck: false
                        }))
                )
            );
        if (ok || _failureFingerprint(actor) != beforeState) atomicityBroken = true;
    }

    function _failureFingerprint(address actor) private view returns (bytes32) {
        bytes32 balances = keccak256(
            abi.encode(
                underlying.totalSupply(),
                usd.totalSupply(),
                perpSr.totalSupply(),
                perpJr.totalSupply(),
                usdVault.totalSupply(),
                jrVault.totalSupply(),
                srVault.totalSupply(),
                underlying.balanceOf(actor),
                usd.balanceOf(actor),
                perpSr.balanceOf(actor),
                perpJr.balanceOf(actor),
                usdVault.balanceOf(actor),
                jrVault.balanceOf(actor),
                srVault.balanceOf(actor),
                underlying.balanceOf(address(pairRouter)),
                usd.balanceOf(address(pairRouter)),
                perpSr.balanceOf(address(pairRouter)),
                perpJr.balanceOf(address(pairRouter))
            )
        );
        bytes32 systemState = keccak256(
            abi.encode(
                underlying.balanceOf(address(usdVault)),
                usd.balanceOf(address(usdVault)),
                perpSr.balanceOf(address(usdVault)),
                underlying.balanceOf(address(jrVault)),
                perpJr.balanceOf(address(jrVault)),
                underlying.balanceOf(address(srVault)),
                perpSr.balanceOf(address(srVault)),
                underlying.balanceOf(address(pool)),
                usd.balanceOf(address(pool)),
                pool.sqrtPriceX96(),
                controller.collectedFeeBal(address(underlying)),
                controller.collectedFeeBal(address(perpSr)),
                controller.collectedFeeBal(address(perpJr)),
                controller.protocolFeeBals(address(underlying)),
                perpSr.reserves(),
                perpJr.reserves(),
                usdVault.sessionBudgetUsdVal(),
                usdVault.sessionOpenedAtSec(),
                usdVault.sessionIsMintingPerp()
            )
        );
        return keccak256(abi.encode(balances, systemState));
    }

    function _recordCall(address target, bytes memory data) private {
        (bool ok,) = target.call(data);
        if (ok) successfulCalls += 1;
        else revertedCalls += 1;
    }

    function _actor(uint8 seed) private view returns (address) {
        return actors[uint256(seed) % actors.length];
    }
}

contract FullProtocolStatefulInvariantTest is StdInvariant, Test {
    address private constant LOCAL_ADMIN = address(0xA11CE);
    address private constant LOCKED_LIQUIDITY = 0x000000000000000000000000000000000000dEaD;

    DeployGenesisLocal internal deploymentScript;
    DeployGenesisLocal.CoreDeployment internal core;
    DeployGenesisLocal.PeripheryDeployment internal periphery;
    FullProtocolStatefulHandler internal handler;

    function setUp() public {
        deploymentScript = new DeployGenesisLocal();
        (core, periphery) = deploymentScript.run();

        (uint256 subDr,) = core.controller.systemDeviations();
        uint96 target = uint96(subDr * 2);
        vm.prank(LOCAL_ADMIN);
        periphery.jrVault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        periphery.jrVault.rebalance();

        handler = new FullProtocolStatefulHandler(address(deploymentScript), core, periphery);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = handler.pairDeposit.selector;
        selectors[1] = handler.pairRedeem.selector;
        selectors[2] = handler.underlyingDeposit.selector;
        selectors[3] = handler.underlyingRedeem.selector;
        selectors[4] = handler.directUsdDeposit.selector;
        selectors[5] = handler.directUsdRedeem.selector;
        selectors[6] = handler.configureDex.selector;
        selectors[7] = handler.advanceTime.selector;
        selectors[8] = handler.changePrice.selector;
        selectors[9] = handler.advanceEpoch.selector;
        selectors[10] = handler.bondMint.selector;
        selectors[11] = handler.rollover.selector;
        selectors[12] = handler.underlyingRebalance.selector;
        selectors[13] = handler.usdRebalance.selector;
        selectors[14] = handler.usdUpkeep.selector;
        selectors[15] = handler.donate.selector;
        selectors[16] = handler.failedPairDeposit.selector;
        selectors[17] = handler.failedPairRedeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_AllFixedSupplyAssetsAreAccounted() public view {
        _assertSupply(core.underlying);
        _assertSupply(periphery.usd);
        _assertSupply(core.perpSr);
        _assertSupply(core.perpJr);
        _assertSupply(periphery.usdVault);
        _assertSupply(periphery.jrVault);
        _assertSupply(periphery.srVault);
    }

    function invariant_LockedVaultLiquidityCannotBeRedeemed() public view {
        assertEq(periphery.usdVault.balanceOf(address(periphery.usdVault)), periphery.usdVault.MINIMUM_LIQUIDITY());
        assertEq(periphery.jrVault.balanceOf(address(periphery.jrVault)), periphery.jrVault.MINIMUM_LIQUIDITY());
        assertEq(periphery.srVault.balanceOf(address(periphery.srVault)), periphery.srVault.MINIMUM_LIQUIDITY());
        assertGe(periphery.usdVault.totalSupply(), periphery.usdVault.MINIMUM_LIQUIDITY());
        assertGe(periphery.jrVault.totalSupply(), periphery.jrVault.MINIMUM_LIQUIDITY());
        assertGe(periphery.srVault.totalSupply(), periphery.srVault.MINIMUM_LIQUIDITY());
    }

    function invariant_RoutersNeverRetainUserAssets() public view {
        address[3] memory routers =
            [address(periphery.pairRouter), address(periphery.underlyingRouter), address(periphery.usdRouter)];
        for (uint256 i; i < routers.length; ++i) {
            assertEq(core.underlying.balanceOf(routers[i]), 0);
            assertEq(periphery.usd.balanceOf(routers[i]), 0);
            assertEq(core.perpSr.balanceOf(routers[i]), 0);
            assertEq(core.perpJr.balanceOf(routers[i]), 0);
            assertEq(periphery.usdVault.balanceOf(routers[i]), 0);
            assertEq(periphery.jrVault.balanceOf(routers[i]), 0);
            assertEq(periphery.srVault.balanceOf(routers[i]), 0);
        }
    }

    function invariant_ReserveArraysAreUniqueAndMatchControllerValue() public view {
        (
            PerpController.SystemState memory state,
            PerpBalancer.ReserveData memory sr,
            PerpBalancer.ReserveData memory jr
        ) = core.controller.systemReserveState();
        assertEq(_reserveValueAndValidate(core.perpSr, sr), state.perpSr.reserveValue);
        assertEq(_reserveValueAndValidate(core.perpJr, jr), state.perpJr.reserveValue);
    }

    function invariant_ForcedFailuresAreAtomic() public view {
        assertFalse(handler.atomicityBroken());
    }

    function _assertSupply(IERC20 token) private view {
        assertEq(_trackedToken(token), token.totalSupply());
    }

    function _trackedToken(IERC20 token) private view returns (uint256 total) {
        total += token.balanceOf(address(this));
        total += token.balanceOf(address(deploymentScript));
        total += token.balanceOf(address(handler));
        total += token.balanceOf(LOCAL_ADMIN);
        total += token.balanceOf(LOCKED_LIQUIDITY);
        for (uint256 i; i < 3; ++i) {
            total += token.balanceOf(handler.actors(i));
        }

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
        total += token.balanceOf(address(periphery.jrVault));
        total += token.balanceOf(address(periphery.srVault));
        total += token.balanceOf(address(periphery.usdRouter));
        total += token.balanceOf(address(periphery.underlyingRouter));
        total += token.balanceOf(address(periphery.pairRouter));
    }

    function _reserveValueAndValidate(PerpToken perp, PerpBalancer.ReserveData memory data)
        private
        view
        returns (uint256 value)
    {
        assertEq(data.underlyingBal, core.underlying.balanceOf(address(perp)));
        assertLe(data.trancheData.length, perp.maxTrancheCount());
        value = data.underlyingBal;
        for (uint256 i; i < data.trancheData.length; ++i) {
            assertEq(data.trancheData[i].balance, IERC20(data.trancheData[i].data.tranche).balanceOf(address(perp)));
            value += data.trancheData[i].value;
            for (uint256 j; j < i; ++j) {
                assertTrue(data.trancheData[i].data.tranche != data.trancheData[j].data.tranche);
            }
        }
    }
}
