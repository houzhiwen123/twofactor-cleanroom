// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDexStrategy} from "../src/interfaces/IDexStrategy.sol";
import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {PairRouter} from "../src/router/PairRouter.sol";
import {SingleAssetRouter} from "../src/router/SingleAssetRouter.sol";
import {UnderlyingSingleAssetRouter} from "../src/router/UnderlyingSingleAssetRouter.sol";
import {DeployGenesisLocal} from "../script/DeployGenesisLocal.s.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ReentrantPairStrategy is IDexStrategy {
    PairRouter private immutable _router;
    address private immutable _usdVault;
    address private immutable _underlyingVault;

    constructor(PairRouter router_, address usdVault_, address underlyingVault_) {
        _router = router_;
        _usdVault = usdVault_;
        _underlyingVault = underlyingVault_;
    }

    function usd() external pure returns (address) {
        return address(0);
    }

    function underlying() external pure returns (address) {
        return address(0);
    }

    function usdUnit() external pure returns (uint256) {
        return 1e6;
    }

    function underlyingUnit() external pure returns (uint256) {
        return 1e8;
    }

    function pool() external pure returns (address) {
        return address(0);
    }

    function poolFee() external pure returns (uint24) {
        return 0;
    }

    function minLiquidity() external pure returns (uint128) {
        return 0;
    }

    function underlyingIsToken0() external pure returns (bool) {
        return false;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function referencePrice(address, address) external pure returns (uint256) {
        return 1e18;
    }

    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function maxFillable(address, address, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function trade(address, address, uint256) external returns (uint256) {
        _router.redeem(
            IPairRouter.RedeemParams({
                usdVault: _usdVault,
                underlyingVault: _underlyingVault,
                strategy: address(this),
                usdNotes: 0,
                underlyingNotes: 0,
                maxUsdRetained: type(uint256).max,
                underlyingToTrade: 0,
                runUpkeep: false,
                minUsdOut: 0,
                minUnderlyingOut: 0,
                minSubDr: 0,
                maxSubDr: type(uint256).max,
                minVmDr: 0,
                maxVmDr: type(uint256).max,
                healthCheck: false
            })
        );
        return 0;
    }
}

contract ReentrantSingleAssetStrategy is IDexStrategy {
    SingleAssetRouter private immutable _router;
    address private immutable _vault;

    constructor(SingleAssetRouter router_, address vault_) {
        _router = router_;
        _vault = vault_;
    }

    function usd() external pure returns (address) {
        return address(0);
    }

    function underlying() external pure returns (address) {
        return address(0);
    }

    function usdUnit() external pure returns (uint256) {
        return 1e6;
    }

    function underlyingUnit() external pure returns (uint256) {
        return 1e8;
    }

    function pool() external pure returns (address) {
        return address(0);
    }

    function poolFee() external pure returns (uint24) {
        return 0;
    }

    function minLiquidity() external pure returns (uint128) {
        return 0;
    }

    function underlyingIsToken0() external pure returns (bool) {
        return false;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function referencePrice(address, address) external pure returns (uint256) {
        return 1e18;
    }

    function quote(address, address, uint256) external pure returns (uint256) {
        return 0;
    }

    function maxFillable(address, address, uint256, uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function trade(address, address, uint256) external returns (uint256) {
        _router.redeemUsd(_vault, address(this), 0, 0, false, false);
        return 0;
    }
}

contract ReentrantUnderlyingController {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function systemReserveState() external pure returns (SystemState memory state) {
        state.perpSr = PerpState({totalSupply: 1, reserveValue: 1, vm: 1e18});
        state.perpJr = PerpState({totalSupply: 1, reserveValue: 1, vm: 1e18});
    }
}

contract ReentrantUnderlyingVault {
    MockERC20 private immutable _underlying;
    MockERC20 private immutable _perp;
    ReentrantUnderlyingController private immutable _controller;
    UnderlyingSingleAssetRouter private immutable _router;

    constructor(
        MockERC20 underlying_,
        MockERC20 perp_,
        ReentrantUnderlyingController controller_,
        UnderlyingSingleAssetRouter router_
    ) {
        _underlying = underlying_;
        _perp = perp_;
        _controller = controller_;
        _router = router_;
    }

    function underlying() external view returns (address) {
        return address(_underlying);
    }

    function perp() external view returns (address) {
        return address(_perp);
    }

    function underlyingBalance() external pure returns (uint256) {
        return 1;
    }

    function perpBalance() external pure returns (uint256) {
        return 0;
    }

    function perpController() external view returns (address) {
        return address(_controller);
    }

    function isPerpSrVault() external pure returns (bool) {
        return true;
    }

    function deposit(uint256, uint256) external returns (uint256) {
        _router.redeemUnderlying(address(this), 0, 0);
        return 0;
    }

    function redeem(uint256) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

contract RouterReentrancyHardeningTest is Test {
    address private constant USER = address(0xBEEF);

    DeployGenesisLocal private deploymentScript;
    DeployGenesisLocal.CoreDeployment private core;
    DeployGenesisLocal.PeripheryDeployment private periphery;

    function setUp() public {
        deploymentScript = new DeployGenesisLocal();
        (core, periphery) = deploymentScript.run();
    }

    function testPairRouterRejectsStrategyCrossEntryAndRollsBackUserInput() public {
        ReentrantPairStrategy strategy =
            new ReentrantPairStrategy(periphery.pairRouter, address(periphery.usdVault), address(periphery.jrVault));
        uint256 amount = 100_000;
        core.underlying.mint(USER, amount);
        vm.prank(USER);
        core.underlying.approve(address(periphery.pairRouter), amount);

        vm.prank(USER);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        periphery.pairRouter
            .deposit(
                IPairRouter.DepositParams({
                    usdVault: address(periphery.usdVault),
                    underlyingVault: address(periphery.jrVault),
                    strategy: address(strategy),
                    recipient: USER,
                    underlyingIn: amount,
                    minUsdFromTrade: 0,
                    underlyingToTrade: amount,
                    srUnderlyingIn: 0,
                    jrUnderlyingIn: 0,
                    minUsdNotes: 0,
                    minUnderlyingNotes: 0,
                    minSubDr: 0,
                    maxSubDr: type(uint256).max,
                    minVmDr: 0,
                    maxVmDr: type(uint256).max,
                    healthCheck: false
                })
            );

        assertEq(core.underlying.balanceOf(USER), amount);
        assertEq(core.underlying.balanceOf(address(periphery.pairRouter)), 0);
        assertEq(core.underlying.balanceOf(address(strategy)), 0);
    }

    function testSingleAssetRouterRejectsStrategyCrossEntryAndRollsBackUserInput() public {
        ReentrantSingleAssetStrategy strategy =
            new ReentrantSingleAssetStrategy(periphery.usdRouter, address(periphery.usdVault));
        // The fresh USD Vault contains only USD, so the hardened Router correctly skips a
        // zero-valued DEX leg. Seed a real Perp reserve to exercise a nonzero strategy call.
        address localAdmin = deploymentScript.LOCAL_ADMIN();
        uint256 perpSeed = core.perpSr.balanceOf(localAdmin) / 100;
        assertGt(perpSeed, 0);
        vm.prank(localAdmin);
        core.perpSr.transfer(address(periphery.usdVault), perpSeed);
        uint256 amount = 100e6;
        periphery.usd.mint(USER, amount);
        vm.prank(USER);
        periphery.usd.approve(address(periphery.usdRouter), amount);

        vm.prank(USER);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        periphery.usdRouter.depositUsd(address(periphery.usdVault), address(strategy), amount, 0, 0, false);

        assertEq(periphery.usd.balanceOf(USER), amount);
        assertEq(periphery.usd.balanceOf(address(periphery.usdRouter)), 0);
        assertEq(periphery.usd.balanceOf(address(strategy)), 0);
    }

    function testUnderlyingRouterRejectsVaultCrossEntryAndRollsBackUserInput() public {
        MockERC20 underlying = new MockERC20("Underlying", "UND", 8);
        MockERC20 perp = new MockERC20("Perp", "PERP", 8);
        UnderlyingSingleAssetRouter router = new UnderlyingSingleAssetRouter();
        ReentrantUnderlyingController controller = new ReentrantUnderlyingController();
        ReentrantUnderlyingVault vault = new ReentrantUnderlyingVault(underlying, perp, controller, router);
        uint256 amount = 100_000;
        underlying.mint(USER, amount);
        vm.prank(USER);
        underlying.approve(address(router), amount);

        vm.prank(USER);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.depositUnderlying(address(vault), amount, 0, 0);

        assertEq(underlying.balanceOf(USER), amount);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(underlying.balanceOf(address(vault)), 0);
    }
}
