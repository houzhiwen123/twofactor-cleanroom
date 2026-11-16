// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IDexStrategy} from "../src/interfaces/IDexStrategy.sol";
import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {PairRouter} from "../src/router/PairRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PairControllerMock {
    MockERC20 public immutable underlying;
    MockERC20 public immutable sr;
    MockERC20 public immutable jr;
    uint256 public subDR = 1_040_088_606_506_973_317;
    uint256 public vmDR = 1_002_894_667_332_216_205;

    constructor(MockERC20 underlying_, MockERC20 sr_, MockERC20 jr_) {
        underlying = underlying_;
        sr = sr_;
        jr = jr_;
    }

    function setDeviations(uint256 subDr, uint256 vmDr) external {
        subDR = subDr;
        vmDR = vmDr;
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (
            uint256 srOut,
            uint256 jrOut,
            IPairControllerTest.FeePerc memory srFee,
            IPairControllerTest.FeePerc memory jrFee
        )
    {
        uint256 total = srUnderlying + jrUnderlying;
        srFee = IPairControllerTest.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = IPairControllerTest.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        if (total != 0) underlying.transferFrom(msg.sender, address(this), total);
        if (srUnderlying != 0) {
            sr.mint(msg.sender, srUnderlying);
            srOut = srUnderlying;
        }
        if (jrUnderlying != 0) {
            jr.mint(msg.sender, jrUnderlying);
            jrOut = jrUnderlying;
        }
    }

    function systemDeviations() external view returns (uint256, uint256) {
        return (subDR, vmDR);
    }
}

interface IPairControllerTest {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }
}

contract PairUsdVaultMock is ERC20 {
    MockERC20 public immutable usdToken;
    MockERC20 public immutable underlyingToken;
    MockERC20 public immutable srToken;
    address public immutable controller;
    uint256 public immutable retainedUsd;

    constructor(MockERC20 usd_, MockERC20 underlying_, MockERC20 sr_, address controller_, uint256 retainedUsd_)
        ERC20("Pair USD Notes", "pUSD")
    {
        usdToken = usd_;
        underlyingToken = underlying_;
        srToken = sr_;
        controller = controller_;
        retainedUsd = retainedUsd_;
    }

    function usd() external view returns (address) {
        return address(usdToken);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function perpSr() external view returns (address) {
        return address(srToken);
    }

    function perpController() external view returns (address) {
        return controller;
    }

    function deposit(uint256 usdMax, uint256 srMax) external returns (uint256 notesMinted) {
        uint256 usdIn = usdMax > retainedUsd ? usdMax - retainedUsd : 0;
        if (usdIn != 0) usdToken.transferFrom(msg.sender, address(this), usdIn);
        if (srMax != 0) srToken.transferFrom(msg.sender, address(this), srMax);
        notesMinted = usdIn + srMax;
        _mint(msg.sender, notesMinted);
    }
}

contract PairUnderlyingVaultMock is ERC20 {
    MockERC20 public immutable underlyingToken;
    MockERC20 public immutable jrToken;
    address public immutable controller;

    constructor(MockERC20 underlying_, MockERC20 jr_, address controller_) ERC20("Pair JR Notes", "pJR") {
        underlyingToken = underlying_;
        jrToken = jr_;
        controller = controller_;
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function perp() external view returns (address) {
        return address(jrToken);
    }

    function perpController() external view returns (address) {
        return controller;
    }

    function deposit(uint256 underlyingMax, uint256 jrMax) external returns (uint256 notesMinted) {
        if (underlyingMax != 0) underlyingToken.transferFrom(msg.sender, address(this), underlyingMax);
        if (jrMax != 0) jrToken.transferFrom(msg.sender, address(this), jrMax);
        notesMinted = underlyingMax + jrMax;
        _mint(msg.sender, notesMinted);
    }
}

contract PairStrategyMock is IDexStrategy {
    MockERC20 public immutable usdToken;
    MockERC20 public immutable underlyingToken;
    bool public healthy = true;
    uint256 public usdPerUnderlying = 1_000;

    constructor(MockERC20 usd_, MockERC20 underlying_) {
        usdToken = usd_;
        underlyingToken = underlying_;
    }

    function setHealthy(bool value) external {
        healthy = value;
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
        return address(0);
    }

    function poolFee() external pure returns (uint24) {
        return 500;
    }

    function minLiquidity() external pure returns (uint128) {
        return 0;
    }

    function underlyingIsToken0() external pure returns (bool) {
        return false;
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function referencePrice(address, address) external pure returns (uint256) {
        return 1e18;
    }

    function quote(address, address, uint256 sellAmt) external view returns (uint256) {
        return sellAmt * usdPerUnderlying;
    }

    function maxFillable(address, address, uint256 maxSellAmt, uint256) external view returns (uint256, uint256) {
        return (maxSellAmt, maxSellAmt * usdPerUnderlying);
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
        buyAmt = sellAmt * usdPerUnderlying;
        MockERC20(buyToken).mint(msg.sender, buyAmt);
    }
}

contract PairRouterTest is Test {
    MockERC20 private underlying;
    MockERC20 private usd;
    MockERC20 private sr;
    MockERC20 private jr;
    PairControllerMock private controller;
    PairUsdVaultMock private usdVault;
    PairUnderlyingVaultMock private jrVault;
    PairStrategyMock private strategy;
    PairRouter private router;

    address private constant USER = address(0xBEEF);
    bytes4 private constant TARGET_SELECTOR = 0x0176cb45;
    bytes4 private constant UNHEALTHY_SELECTOR = 0xc9f488c6;

    function setUp() public {
        underlying = new MockERC20("cbBTC", "cbBTC", 8);
        usd = new MockERC20("USD", "USD", 6);
        sr = new MockERC20("SR", "SR", 8);
        jr = new MockERC20("JR", "JR", 8);
        controller = new PairControllerMock(underlying, sr, jr);
        usdVault = new PairUsdVaultMock(usd, underlying, sr, address(controller), 388);
        jrVault = new PairUnderlyingVaultMock(underlying, jr, address(controller));
        strategy = new PairStrategyMock(usd, underlying);
        router = new PairRouter();
        underlying.mint(USER, 60_000);
        usd.mint(address(strategy), 1_000_000_000);
        vm.prank(USER);
        underlying.approve(address(router), type(uint256).max);
    }

    function testHistoricalSelectorDepositReturnsSixValuesAndNoRouterDust() public {
        IPairRouter.DepositParams memory params = _params();
        vm.prank(USER);
        (bool ok, bytes memory result) = address(router).call(abi.encodePacked(TARGET_SELECTOR, abi.encode(params)));
        assertTrue(ok);
        assertEq(result.length, 6 * 32);
        (
            uint256 usdNotes,
            uint256 jrNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        ) = abi.decode(result, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertGt(usdNotes, 0);
        assertGt(jrNotes, 0);
        assertEq(underlyingRefund, 1);
        assertEq(usdRefund, 388);
        assertEq(srRefund, 0);
        assertEq(jrRefund, 0);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(usd.balanceOf(address(router)), 0);
        assertEq(sr.balanceOf(address(router)), 0);
        assertEq(jr.balanceOf(address(router)), 0);
    }

    function testInclusiveOutputAndDeviationBounds() public {
        IPairRouter.DepositParams memory params = _params();
        params.minUsdFromTrade = 6_000;
        params.minSubDr = 1_040_088_606_506_973_317;
        params.maxSubDr = params.minSubDr;
        params.minVmDr = 1_002_894_667_332_216_205;
        params.maxVmDr = params.minVmDr;
        vm.prank(USER);
        (uint256 usdNotes, uint256 jrNotes,,,,) = router.deposit(params);
        assertGt(usdNotes, 0);
        assertGt(jrNotes, 0);
    }

    function testMinOutputPlusOneRollsBackAllAssets() public {
        IPairRouter.DepositParams memory params = _params();
        params.minUsdFromTrade = 6_001;
        uint256 beforeUnderlying = underlying.balanceOf(USER);
        uint256 beforeUsdNotes = usdVault.balanceOf(USER);
        uint256 beforeJrNotes = jrVault.balanceOf(USER);
        vm.prank(USER);
        vm.expectRevert(IPairRouter.SlippageTooHigh.selector);
        router.deposit(params);
        assertEq(underlying.balanceOf(USER), beforeUnderlying);
        assertEq(usdVault.balanceOf(USER), beforeUsdNotes);
        assertEq(jrVault.balanceOf(USER), beforeJrNotes);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(usd.balanceOf(address(router)), 0);
    }

    function testHealthCheckFalseBypassesUnhealthyStrategy() public {
        strategy.setHealthy(false);
        IPairRouter.DepositParams memory params = _params();
        params.healthCheck = false;
        vm.prank(USER);
        (uint256 usdNotes, uint256 jrNotes,,,,) = router.deposit(params);
        assertGt(usdNotes, 0);
        assertGt(jrNotes, 0);
    }

    function testHealthCheckTrueUsesTargetSelector() public {
        strategy.setHealthy(false);
        vm.prank(USER);
        vm.expectRevert(UNHEALTHY_SELECTOR);
        router.deposit(_params());
    }

    function testInvalidAllocationRollsBack() public {
        IPairRouter.DepositParams memory params = _params();
        params.underlyingToTrade = params.underlyingIn;
        vm.prank(USER);
        vm.expectRevert(IPairRouter.InvalidInput.selector);
        router.deposit(params);
        assertEq(underlying.balanceOf(USER), 60_000);
    }

    function _params() private view returns (IPairRouter.DepositParams memory params) {
        params = IPairRouter.DepositParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(strategy),
            recipient: address(0),
            underlyingIn: 60_000,
            minUsdFromTrade: 0,
            underlyingToTrade: 6,
            srUnderlyingIn: 13_194,
            jrUnderlyingIn: 46_799,
            minUsdNotes: 0,
            minUnderlyingNotes: 0,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: true
        });
    }
}
