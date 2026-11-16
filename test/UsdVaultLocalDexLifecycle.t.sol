// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UniswapV3DexStrategy} from "../src/strategy/UniswapV3DexStrategy.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUniswapV3Pool} from "./mocks/MockUniswapV3Pool.sol";
import {MockUsdInventory} from "./mocks/MockUsdInventory.sol";

contract LocalLifecyclePerp is ERC20 {
    constructor() ERC20("Local Perp SR", "lPSR") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != from) _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}

contract LocalLifecycleController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    address public immutable underlyingOracle;
    MockERC20 public immutable underlying;
    LocalLifecyclePerp public immutable perpSr;
    uint256 public targetSystemRatio = 2_847_475_019_000_000_000;
    uint256 public jrSupply = 1_000_000_000;
    uint256 public jrReserveValue = 1_000_000_000;
    uint256 public subDR = 1_050_000_000_000_000_000;
    uint256 public vmDR = 1e18;

    constructor(address oracle_, MockERC20 underlying_, LocalLifecyclePerp perpSr_) {
        underlyingOracle = oracle_;
        underlying = underlying_;
        perpSr = perpSr_;
    }

    function setSystemDeviations(uint256 subDR_, uint256 vmDR_) external {
        subDR = subDR_;
        vmDR = vmDR_;
    }

    function setJrState(uint256 supply, uint256 reserveValue) external {
        jrSupply = supply;
        jrReserveValue = reserveValue;
    }

    function systemReserveState() external view returns (SystemState memory state) {
        state.perpSr =
            PerpState({totalSupply: perpSr.totalSupply(), reserveValue: underlying.balanceOf(address(this)), vm: 1e18});
        state.perpJr = PerpState({totalSupply: jrSupply, reserveValue: jrReserveValue, vm: 1e18});
    }

    function systemDeviations() external view returns (uint256, uint256) {
        return (subDR, vmDR);
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        require(jrUnderlying == 0, "jr input");
        underlying.transferFrom(msg.sender, address(this), srUnderlying);
        perpSr.mint(msg.sender, srUnderlying);
        return (srUnderlying, 0, srFee, jrFee);
    }

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        require(jrIn == 0, "jr input");
        perpSr.burnFrom(msg.sender, srIn);
        underlying.transfer(msg.sender, srIn);
        return (srIn, srFee, jrFee);
    }
}

contract UsdVaultLocalDexLifecycleTest is Test {
    address private constant USER = address(0xBEEF);
    address private constant OTHER_PERP_HOLDER = address(0xCAFE);
    uint256 private constant GENESIS_USD = 10_001;
    uint256 private constant USER_DEPOSIT_USD = 1_000_000e6;
    uint256 private constant INVENTORY_WORKING_USD = 500_000e6;
    uint256 private constant MINT_USD_SPEND = 100_000e6;

    struct Env {
        MockERC20 usd;
        MockERC20 underlying;
        LocalLifecyclePerp perp;
        MockPriceOracle underlyingOracle;
        MockPriceOracle usdOracle;
        LocalLifecycleController controller;
        MockUniswapV3Pool pool;
        UniswapV3DexStrategy strategy;
        MockUsdInventory inventory;
        UsdVault vault;
        uint256 userNotes;
    }

    function testGenesisInventoryDexControllerAndUserExitLifecycle() external {
        Env memory env = _deployActivatedEnvironment();
        uint256 usdSupplyBefore = env.usd.totalSupply();
        uint256 underlyingSupplyBefore = env.underlying.totalSupply();
        uint256 initialPerpSupply = env.perp.totalSupply();
        uint160 initialSqrtPrice = env.pool.sqrtPriceX96();

        uint256 expectedUnderlying = env.strategy.quote(address(env.usd), address(env.underlying), MINT_USD_SPEND);
        uint256 inventoryUsdBefore = env.usd.balanceOf(address(env.inventory));
        (uint256 underlyingBought, uint256 mintSurplus) = env.inventory.executeMint(MINT_USD_SPEND, MINT_USD_SPEND);

        assertEq(underlyingBought, expectedUnderlying, "mint DEX output");
        assertEq(mintSurplus, 0, "exact local settlement should have no artificial surplus");
        assertEq(env.usd.balanceOf(address(env.inventory)), inventoryUsdBefore, "inventory USD restored");
        assertEq(env.underlying.balanceOf(address(env.inventory)), 0, "inventory underlying cleared");
        assertEq(env.perp.balanceOf(address(env.vault)), underlyingBought, "Vault received minted Perp");
        assertLt(env.pool.sqrtPriceX96(), initialSqrtPrice, "USD-to-underlying updates pool price");

        (bool mintSession, bool mintDirection, uint256 mintBudget,) = env.vault.sessionCapacity();
        assertTrue(mintSession, "mint session committed");
        assertTrue(mintDirection, "mint direction committed");
        assertGt(mintBudget, 0, "mint budget remains bounded");

        env.controller.setSystemDeviations(1e18, 1e18);
        env.controller.setJrState(1_000_000_000, 100_000_000);
        vm.warp(block.timestamp + env.vault.rebalanceFreqSec());

        (uint256 underlyingOut,, bool minting,,) = env.vault.rebalanceCapacity();
        assertFalse(minting, "second window must redeem Perp");
        assertEq(underlyingOut, underlyingBought, "full local round trip capacity");
        uint256 provisionalUsdIn = env.strategy.quote(address(env.underlying), address(env.usd), underlyingOut);

        (uint256 usdBought, uint256 redeemSurplus) = env.inventory.executeRedeem(provisionalUsdIn, underlyingOut);
        assertEq(usdBought, provisionalUsdIn, "redeem DEX output");
        assertEq(redeemSurplus, 0, "exact local settlement should have no artificial surplus");
        assertEq(env.usd.balanceOf(address(env.inventory)), inventoryUsdBefore, "inventory capital restored");
        assertEq(env.underlying.balanceOf(address(env.inventory)), 0, "inventory has no residue");
        assertEq(env.perp.balanceOf(address(env.vault)), 0, "Vault Perp round trip closed");
        assertEq(env.perp.totalSupply(), initialPerpSupply, "Perp supply round trip closed");

        (bool redeemSession, bool redeemDirection,,) = env.vault.sessionCapacity();
        assertTrue(redeemSession, "redeem session committed");
        assertFalse(redeemDirection, "redeem direction committed");

        uint256 userUsdBefore = env.usd.balanceOf(USER);
        vm.prank(USER);
        (uint256 usdOut, uint256 perpOut) = env.vault.redeem(env.userNotes);
        assertEq(env.vault.balanceOf(USER), 0, "user notes burned");
        assertEq(env.vault.balanceOf(address(env.vault)), env.vault.MINIMUM_LIQUIDITY(), "locked notes remain");
        assertEq(env.usd.balanceOf(USER) - userUsdBefore, usdOut, "user receives quoted USD");
        assertEq(perpOut, 0, "round-trip exit has no Perp residue");
        assertEq(env.usd.totalSupply(), usdSupplyBefore, "USD supply conserved");
        assertEq(env.underlying.totalSupply(), underlyingSupplyBefore, "underlying supply conserved");
    }

    function testExecutablePoolTradeMatchesStrategyQuoteAndCallbackAccounting() external {
        Env memory env = _deployActivatedEnvironment();
        uint256 sellAmt = 10_000e6;
        uint256 expectedBuy = env.strategy.quote(address(env.usd), address(env.underlying), sellAmt);
        uint256 poolUsdBefore = env.usd.balanceOf(address(env.pool));
        uint256 poolUnderlyingBefore = env.underlying.balanceOf(address(env.pool));

        env.usd.mint(address(this), sellAmt);
        env.usd.approve(address(env.strategy), sellAmt);
        uint256 actualBuy = env.strategy.trade(address(env.usd), address(env.underlying), sellAmt);

        assertEq(actualBuy, expectedBuy, "execution must equal pre-trade quote");
        assertEq(env.usd.balanceOf(address(env.pool)), poolUsdBefore + sellAmt, "callback pays exact input");
        assertEq(
            env.underlying.balanceOf(address(env.pool)), poolUnderlyingBefore - actualBuy, "pool pays exact output"
        );
        assertEq(env.underlying.balanceOf(address(this)), actualBuy, "recipient receives output");
    }

    function testPartialPoolFillRefundsUnusedInputAndPreservesPreexistingDust() external {
        Env memory env = _deployActivatedEnvironment();
        uint256 sellAmt = 10_000e6;
        uint256 spentAmt = sellAmt / 2;
        uint256 strategyDust = 777;
        (uint256 expectedBuy,) = env.pool.previewSwap(true, spentAmt);

        env.pool.setMaxInputPerSwap(spentAmt);
        env.usd.mint(address(env.strategy), strategyDust);
        env.usd.mint(address(this), sellAmt);
        env.usd.approve(address(env.strategy), sellAmt);

        uint256 callerUsdBefore = env.usd.balanceOf(address(this));
        uint256 poolUsdBefore = env.usd.balanceOf(address(env.pool));
        uint256 actualBuy = env.strategy.trade(address(env.usd), address(env.underlying), sellAmt);

        assertEq(actualBuy, expectedBuy, "partial execution output");
        assertEq(callerUsdBefore - env.usd.balanceOf(address(this)), spentAmt, "unused input refunded");
        assertEq(env.usd.balanceOf(address(env.pool)) - poolUsdBefore, spentAmt, "pool receives actual input only");
        assertEq(env.usd.balanceOf(address(env.strategy)), strategyDust, "preexisting strategy dust preserved");
        assertEq(env.underlying.balanceOf(address(this)), actualBuy, "caller receives partial output");
    }

    function testOracleAnchoredFloorRejectsAdverseSpotAndPreservesVaultState() external {
        Env memory env = _deployActivatedEnvironment();
        address marketMaker = address(0xA77AC);
        uint256 marketUnderlying = 20e8;
        uint256 vaultUnderlying = 1e8;
        uint256 oraclePrice = env.underlyingOracle.getValidPrice();

        env.inventory.executeMint(MINT_USD_SPEND, MINT_USD_SPEND);
        env.controller.setSystemDeviations(1e18, 1e18);
        env.controller.setJrState(1_000_000_000, 100_000_000);
        vm.warp(block.timestamp + env.vault.rebalanceFreqSec());
        env.underlying.mint(address(env.vault), vaultUnderlying);
        env.underlying.mint(marketMaker, marketUnderlying);

        vm.startPrank(marketMaker);
        env.underlying.approve(address(env.strategy), marketUnderlying);
        env.strategy.trade(address(env.underlying), address(env.usd), marketUnderlying);
        vm.stopPrank();

        uint256 adverseSpotPrice = env.strategy.referencePrice(address(env.underlying), address(env.usd));
        assertGe(adverseSpotPrice, oraclePrice * 95 / 100, "spot remains inside configured health band");
        assertLt(adverseSpotPrice, oraclePrice * 9_985 / 10_000, "spot is below oracle-anchored settlement floor");
        bytes32 beforeFingerprint = _fingerprint(env);

        vm.expectRevert(UsdVault.NoOp.selector);
        env.vault.upkeep();

        assertEq(_fingerprint(env), beforeFingerprint, "rejected upkeep must leave all tracked state unchanged");
        assertEq(env.underlying.balanceOf(address(env.vault)), vaultUnderlying, "Vault inventory remains protected");
    }

    function testRepeatedUpkeepCannotResellAfterOracleFloorStopsExecution() external {
        Env memory env = _deployActivatedEnvironment();
        uint256 vaultUnderlying = 1e8;

        env.inventory.executeMint(MINT_USD_SPEND, MINT_USD_SPEND);
        env.controller.setSystemDeviations(1e18, 1e18);
        env.controller.setJrState(1_000_000_000, 100_000_000);
        vm.warp(block.timestamp + env.vault.rebalanceFreqSec());
        env.underlying.mint(address(env.vault), vaultUnderlying);

        env.vault.upkeep();
        uint256 remaining = env.underlying.balanceOf(address(env.vault));
        assertLt(remaining, vaultUnderlying, "first upkeep executes a bounded settlement");
        bytes32 beforeSecondCall = _fingerprint(env);

        vm.expectRevert(UsdVault.NoOp.selector);
        env.vault.upkeep();

        assertEq(_fingerprint(env), beforeSecondCall, "repeated no-op upkeep leaves state unchanged");
    }

    function testDexFailureAfterVaultRedeemRollsBackEntireSettlement() external {
        Env memory env = _deployActivatedEnvironment();
        uint256 expectedUnderlying = env.strategy.quote(address(env.usd), address(env.underlying), MINT_USD_SPEND);
        env.inventory.executeMint(MINT_USD_SPEND, MINT_USD_SPEND);
        assertEq(env.perp.balanceOf(address(env.vault)), expectedUnderlying);

        env.controller.setSystemDeviations(1e18, 1e18);
        env.controller.setJrState(1_000_000_000, 100_000_000);
        vm.warp(block.timestamp + env.vault.rebalanceFreqSec());
        (uint256 underlyingOut,,,,) = env.vault.rebalanceCapacity();
        uint256 usdIn = env.strategy.quote(address(env.underlying), address(env.usd), underlyingOut);
        bytes32 beforeFingerprint = _fingerprint(env);

        env.pool.setExecutionEnabled(false);
        vm.expectRevert(MockUniswapV3Pool.ExecutionDisabled.selector);
        env.inventory.executeRedeem(usdIn, underlyingOut);

        assertEq(_fingerprint(env), beforeFingerprint, "Vault, Controller, pool and session must roll back");
    }

    function _deployActivatedEnvironment() private returns (Env memory env) {
        vm.warp(1_800_000_000);
        env.usd = new MockERC20("USD Coin", "USDC", 6);
        env.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        env.perp = new LocalLifecyclePerp();
        env.pool = new MockUniswapV3Pool(address(env.usd), address(env.underlying));
        env.strategy = new UniswapV3DexStrategy(address(env.usd), address(env.underlying), address(env.pool), 1);
        env.underlyingOracle =
            new MockPriceOracle(env.strategy.referencePrice(address(env.underlying), address(env.usd)));
        env.usdOracle = new MockPriceOracle(1e18);
        env.controller = new LocalLifecycleController(address(env.underlyingOracle), env.underlying, env.perp);
        env.inventory = new MockUsdInventory(address(env.usd), address(env.underlying), address(env.strategy));

        UsdVault implementation = new UsdVault();
        bytes memory initData = abi.encodeCall(
            UsdVault.initExecution,
            (
                "Local USD Senior Vault",
                "lUSD-SR",
                address(env.usd),
                address(env.perp),
                address(env.underlying),
                address(env.controller),
                address(env.strategy),
                address(env.usdOracle),
                address(env.inventory)
            )
        );
        env.vault = UsdVault(address(new ERC1967Proxy(address(implementation), initData)));
        env.inventory.configureVault(address(env.vault));

        env.usd.mint(address(env.pool), 20_000_000e6);
        env.underlying.mint(address(env.pool), 100e8);
        env.pool.setExecutionEnabled(true);

        env.underlying.mint(address(env.controller), 1e8);
        env.perp.mint(OTHER_PERP_HOLDER, 1e8);
        env.usd.mint(address(env.inventory), INVENTORY_WORKING_USD);

        env.usd.mint(address(this), GENESIS_USD);
        env.usd.approve(address(env.vault), GENESIS_USD);
        assertEq(env.vault.initDeposit(GENESIS_USD), GENESIS_USD * 1e12, "Genesis notes");

        env.usd.mint(USER, USER_DEPOSIT_USD);
        vm.startPrank(USER);
        env.usd.approve(address(env.vault), USER_DEPOSIT_USD);
        env.userNotes = env.vault.deposit(USER_DEPOSIT_USD, 0);
        vm.stopPrank();
        assertGt(env.userNotes, 0, "user deposit notes");
    }

    function _fingerprint(Env memory env) private view returns (bytes32) {
        (bool active, bool direction, uint256 budget, uint256 openedAt) = env.vault.sessionCapacity();
        return keccak256(
            abi.encode(
                env.usd.balanceOf(address(env.vault)),
                env.underlying.balanceOf(address(env.vault)),
                env.perp.balanceOf(address(env.vault)),
                env.usd.balanceOf(address(env.inventory)),
                env.underlying.balanceOf(address(env.inventory)),
                env.usd.balanceOf(address(env.pool)),
                env.underlying.balanceOf(address(env.pool)),
                env.underlying.balanceOf(address(env.controller)),
                env.perp.totalSupply(),
                env.pool.sqrtPriceX96(),
                active,
                direction,
                budget,
                openedAt
            )
        );
    }
}
