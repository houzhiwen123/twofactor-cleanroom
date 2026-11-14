// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDexStrategy} from "../src/interfaces/IDexStrategy.sol";
import {ISingleAssetRouter} from "../src/interfaces/ISingleAssetRouter.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {SingleAssetRouter} from "../src/router/SingleAssetRouter.sol";
import {UniswapV3DexStrategy} from "../src/strategy/UniswapV3DexStrategy.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockRouterPerp is ERC20 {
    uint256 public reserveValue;

    constructor() ERC20("Mock Perp", "mPERP") {}

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function setReserveValue(uint256 value) external {
        reserveValue = value;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function reserveData() external view returns (PerpBalancer.ReserveData memory data) {
        data.underlyingBal = reserveValue;
        data.trancheData = new PerpBalancer.ReserveTrancheData[](0);
    }
}

contract MockRouterController {
    error UnexpectedAmount();

    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    MockERC20 public immutable underlying;
    MockRouterPerp public immutable perp;

    constructor(MockERC20 underlying_, MockRouterPerp perp_) {
        underlying = underlying_;
        perp = perp_;
    }

    function flashMint2(uint256 srUnderlying, uint256, uint256, uint256)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        if (srUnderlying == 0) revert UnexpectedAmount();
        underlying.transferFrom(msg.sender, address(this), srUnderlying);
        perp.mint(msg.sender, srUnderlying);
        return (srUnderlying, 0, srFee, jrFee);
    }

    function flashRedeem2(uint256 srIn, uint256, uint256)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        if (srIn == 0) revert UnexpectedAmount();
        perp.transferFrom(msg.sender, address(this), srIn);
        underlying.mint(msg.sender, srIn);
        return (srIn, srFee, jrFee);
    }
}

contract MockRouterVault is ERC20 {
    MockERC20 public immutable usdToken;
    MockERC20 public immutable underlyingToken;
    MockRouterPerp public immutable perpToken;
    address public immutable controller;
    bool public upkeepReverts;

    constructor(MockERC20 usd_, MockERC20 underlying_, MockRouterPerp perp_, address controller_)
        ERC20("Mock USD Vault", "mNOTES")
    {
        usdToken = usd_;
        underlyingToken = underlying_;
        perpToken = perp_;
        controller = controller_;
    }

    function usd() external view returns (address) {
        return address(usdToken);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function perpSr() external view returns (address) {
        return address(perpToken);
    }

    function perpController() external view returns (address) {
        return controller;
    }

    function usdUnitAmt() external pure returns (uint256) {
        return 1e6;
    }

    function underlyingUnitAmt() external pure returns (uint256) {
        return 1e8;
    }

    function usdBalance() external view returns (uint256) {
        return usdToken.balanceOf(address(this));
    }

    function perpSrBalance() external view returns (uint256) {
        return perpToken.balanceOf(address(this));
    }

    function deposit(uint256 usdMax, uint256 perpMax) external returns (uint256 notesMinted) {
        uint256 usdIn = usdMax == 0 ? 0 : usdMax - 1;
        if (usdIn != 0) usdToken.transferFrom(msg.sender, address(this), usdIn);
        if (perpMax != 0) perpToken.transferFrom(msg.sender, address(this), perpMax);
        notesMinted = usdIn * 1e12 + perpMax * 1e10;
        _mint(msg.sender, notesMinted);
    }

    function redeem(uint256 notesIn) external returns (uint256 usdOut, uint256 perpOut) {
        uint256 supply = totalSupply();
        usdOut = Math.mulDiv(usdToken.balanceOf(address(this)), notesIn, supply);
        perpOut = Math.mulDiv(perpToken.balanceOf(address(this)), notesIn, supply);
        _burn(msg.sender, notesIn);
        if (usdOut != 0) usdToken.transfer(msg.sender, usdOut);
        if (perpOut != 0) perpToken.transfer(msg.sender, perpOut);
    }

    function setUpkeepReverts(bool value) external {
        upkeepReverts = value;
    }

    function upkeep() external view {
        if (upkeepReverts) revert("NO_OP");
    }
}

contract MockRouterStrategy is IDexStrategy {
    MockERC20 public immutable usdToken;
    MockERC20 public immutable underlyingToken;
    bool public healthy = true;
    uint256 public price = 80_000e18;

    constructor(MockERC20 usd_, MockERC20 underlying_) {
        usdToken = usd_;
        underlyingToken = underlying_;
    }

    function usd() external view returns (address) {
        return address(usdToken);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function usdUnit() external pure returns (uint256) {
        return 1e6;
    }

    function underlyingUnit() external pure returns (uint256) {
        return 1e8;
    }

    function pool() external pure returns (address) {
        return address(1);
    }

    function poolFee() external pure returns (uint24) {
        return 500;
    }

    function minLiquidity() external pure returns (uint128) {
        return 1;
    }

    function underlyingIsToken0() external pure returns (bool) {
        return false;
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function setHealthy(bool value) external {
        healthy = value;
    }

    function referencePrice(address sellToken, address buyToken) external view returns (uint256) {
        if (sellToken == address(underlyingToken) && buyToken == address(usdToken)) return price;
        if (sellToken == address(usdToken) && buyToken == address(underlyingToken)) return 1e36 / price;
        revert("PAIR");
    }

    function quote(address sellToken, address buyToken, uint256 sellAmt) public view returns (uint256) {
        if (sellToken == address(usdToken) && buyToken == address(underlyingToken)) {
            return Math.mulDiv(sellAmt, 1e20, price);
        }
        if (sellToken == address(underlyingToken) && buyToken == address(usdToken)) {
            return Math.mulDiv(sellAmt, price, 1e20);
        }
        revert("PAIR");
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt)
    {
        buyAmt = quote(sellToken, buyToken, maxSellAmt);
        return buyAmt < minBuyAmt ? (uint256(0), uint256(0)) : (maxSellAmt, buyAmt);
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
        buyAmt = quote(sellToken, buyToken, sellAmt);
        MockERC20(buyToken).mint(msg.sender, buyAmt);
    }
}

contract MockStrategyPool {
    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 500;
    uint160 public sqrtPriceX96 = 2_800_063_142_574_549_000_000_000_000;
    uint128 public liquidity = 2_782_022_353_822;
    bool public unlocked = true;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setLiquidity(uint128 value) external {
        liquidity = value;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, -66_858, 0, 0, 0, 0, unlocked);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert("NOT_USED");
    }
}

contract SingleAssetRouterTest is Test {
    address private constant USER = address(0xBEEF);

    MockERC20 private usd;
    MockERC20 private underlying;
    MockRouterPerp private perp;
    MockRouterController private controller;
    MockRouterVault private vault;
    MockRouterStrategy private strategy;
    SingleAssetRouter private router;

    function setUp() public {
        usd = new MockERC20("USD", "USD", 6);
        underlying = new MockERC20("BTC", "BTC", 8);
        perp = new MockRouterPerp();
        controller = new MockRouterController(underlying, perp);
        vault = new MockRouterVault(usd, underlying, perp, address(controller));
        strategy = new MockRouterStrategy(usd, underlying);
        router = new SingleAssetRouter();

        perp.setReserveValue(1e8);
        perp.mint(address(vault), 1e8);
        usd.mint(address(vault), 1e6);
        usd.mint(USER, 100e6);
        vm.startPrank(USER);
        usd.approve(address(router), type(uint256).max);
        vault.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function testDepositMinNotesBoundaryAndExtraIterationFailureAreAtomic() public {
        uint256 snapshot = vm.snapshotState();
        vm.prank(USER);
        uint256 notes = router.depositUsd(address(vault), address(strategy), 100e6, 0, 0, true);
        assertGt(notes, 0);
        assertEq(usd.balanceOf(address(router)), 0);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(perp.balanceOf(address(router)), 0);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(USER);
        vm.expectRevert(ISingleAssetRouter.SlippageTooHigh.selector);
        router.depositUsd(address(vault), address(strategy), 100e6, notes + 1, 0, true);
        assertEq(usd.balanceOf(USER), 100e6);

        vm.prank(USER);
        vm.expectRevert(MockRouterController.UnexpectedAmount.selector);
        router.depositUsd(address(vault), address(strategy), 100e6, 0, 1, true);
        assertEq(usd.balanceOf(USER), 100e6);
    }

    function testHealthFlagAndRedeemUpkeepFailure() public {
        strategy.setHealthy(false);
        vm.prank(USER);
        vm.expectRevert(bytes4(0xc9f488c6));
        router.depositUsd(address(vault), address(strategy), 0, 0, 0, true);

        vm.prank(USER);
        assertEq(router.depositUsd(address(vault), address(strategy), 0, 0, 0, false), 0);

        strategy.setHealthy(true);
        vm.prank(USER);
        uint256 notes = router.depositUsd(address(vault), address(strategy), 100e6, 0, 0, true);
        vault.setUpkeepReverts(true);
        vm.prank(USER);
        vm.expectRevert(bytes("NO_OP"));
        router.redeemUsd(address(vault), address(strategy), notes, 0, true, true);
        assertEq(vault.balanceOf(USER), notes);
    }

    function testRedeemReturnsSingleAssetAndMinOutFailureRollsBack() public {
        vm.prank(USER);
        uint256 notes = router.depositUsd(address(vault), address(strategy), 100e6, 0, 0, true);
        uint256 snapshot = vm.snapshotState();

        uint256 before = usd.balanceOf(USER);
        vm.prank(USER);
        uint256 out = router.redeemUsd(address(vault), address(strategy), notes, 0, false, true);
        assertEq(usd.balanceOf(USER) - before, out);
        assertEq(usd.balanceOf(address(router)), 0);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(perp.balanceOf(address(router)), 0);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(USER);
        vm.expectRevert(ISingleAssetRouter.SlippageTooHigh.selector);
        router.redeemUsd(address(vault), address(strategy), notes, out + 1, false, true);
        assertEq(vault.balanceOf(USER), notes);
    }
}

contract UniswapV3DexStrategyTest is Test {
    function testTargetGoldenReferencePricesQuotesHealthAndCallbackAuth() public {
        MockERC20 usd = new MockERC20("USD", "USD", 6);
        MockERC20 underlying = new MockERC20("BTC", "BTC", 8);
        MockStrategyPool pool = new MockStrategyPool(address(usd), address(underlying));
        UniswapV3DexStrategy strategy =
            new UniswapV3DexStrategy(address(usd), address(underlying), address(pool), 200_000_000_000);

        assertTrue(strategy.isHealthy());
        assertEq(strategy.referencePrice(address(underlying), address(usd)), 80_061_462_195_552_451_024_100);
        assertEq(strategy.referencePrice(address(usd), address(underlying)), 12_490_403_904_408);
        assertEq(strategy.quote(address(underlying), address(usd), 4_723), 3_778_900);
        assertEq(strategy.quote(address(usd), address(underlying), 1_000_000), 1_248);

        (uint256 sellAmt, uint256 buyAmt) = strategy.maxFillable(address(underlying), address(usd), 4_723, 3_778_900);
        assertEq(sellAmt, 4_723);
        assertEq(buyAmt, 3_778_900);
        (sellAmt, buyAmt) = strategy.maxFillable(address(underlying), address(usd), 4_723, 3_778_901);
        assertEq(sellAmt, 0);
        assertEq(buyAmt, 0);

        pool.setLiquidity(199_999_999_999);
        assertFalse(strategy.isHealthy());
        vm.expectRevert(UniswapV3DexStrategy.UnauthorizedCall.selector);
        strategy.uniswapV3SwapCallback(1, 0, bytes(""));
    }
}
