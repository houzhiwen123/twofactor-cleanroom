// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IPairRouter} from "../src/interfaces/IPairRouter.sol";
import {PairRouter} from "../src/router/PairRouter.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PairGenesisController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    MockERC20 public immutable underlying;
    MockERC20 public immutable sr;
    MockERC20 public immutable jr;

    constructor(MockERC20 underlying_, MockERC20 sr_, MockERC20 jr_) {
        underlying = underlying_;
        sr = sr_;
        jr = jr_;
    }

    function perpSr() external view returns (address) {
        return address(sr);
    }

    function perpJr() external view returns (address) {
        return address(jr);
    }

    function systemDeviations() external pure returns (uint256 subDR, uint256 vmDR) {
        return (1e18, 1e18);
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        srFee = FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        uint256 total = srUnderlying + jrUnderlying;
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

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        srFee = FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        if (srIn != 0) sr.transferFrom(msg.sender, address(this), srIn);
        if (jrIn != 0) jr.transferFrom(msg.sender, address(this), jrIn);
        underlyingOut = srIn + jrIn;
        if (underlyingOut != 0) underlying.mint(msg.sender, underlyingOut);
    }
}

contract PairRouterGenesisMatrixTest is Test {
    address private constant USER = address(0xBEEF);

    MockERC20 private underlying;
    MockERC20 private usd;
    MockERC20 private sr;
    MockERC20 private jr;
    PairGenesisController private controller;
    UsdVault private usdVault;
    UnderlyingPerpVault private jrVault;
    PairRouter private router;

    function setUp() public {
        underlying = new MockERC20("cbBTC", "cbBTC", 8);
        usd = new MockERC20("USD Coin", "USDC", 6);
        sr = new MockERC20("Perp SR", "pSR", 8);
        jr = new MockERC20("Perp JR", "pJR", 8);
        controller = new PairGenesisController(underlying, sr, jr);

        UsdVault usdImplementation = new UsdVault();
        usdVault = UsdVault(
            address(
                new ERC1967Proxy(
                    address(usdImplementation),
                    abi.encodeCall(
                        UsdVault.init,
                        ("Fresh USD Vault", "fUSD", address(usd), address(sr), address(underlying), address(controller))
                    )
                )
            )
        );

        UnderlyingPerpVault jrImplementation = new UnderlyingPerpVault();
        jrVault = UnderlyingPerpVault(
            address(
                new ERC1967Proxy(
                    address(jrImplementation),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        ("Fresh JR Vault", "fJR", address(underlying), address(controller), false, false)
                    )
                )
            )
        );
        router = new PairRouter();

        underlying.mint(USER, 100);
        vm.prank(USER);
        underlying.approve(address(router), type(uint256).max);
    }

    function testZeroNotesAreNoOpAgainstActualFreshVaults() public {
        vm.prank(USER);
        (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f) = router.deposit(_zeroDeposit());
        assertEq(a | b | c | d | e | f, 0);

        vm.prank(USER);
        (uint256 usdOut, uint256 underlyingOut) = router.redeem(_zeroRedeem());
        assertEq(usdOut | underlyingOut, 0);
        assertEq(usdVault.totalSupply(), 0);
        assertEq(jrVault.totalSupply(), 0);
        assertEq(underlying.balanceOf(USER), 100);
        _assertNoRouterDust();
    }

    function testPositiveSrDepositCannotBootstrapFreshUsdVaultAndIsAtomic() public {
        IPairRouter.DepositParams memory params = _zeroDeposit();
        params.underlyingIn = 1;
        params.srUnderlyingIn = 1;

        vm.prank(USER);
        vm.expectRevert(stdError.divisionError);
        router.deposit(params);

        assertEq(underlying.balanceOf(USER), 100);
        assertEq(underlying.balanceOf(address(controller)), 0);
        assertEq(sr.totalSupply(), 0);
        assertEq(usdVault.totalSupply(), 0);
        _assertNoRouterDust();
    }

    function testPositiveJrDepositCannotBootstrapFreshJrVaultAndIsAtomic() public {
        IPairRouter.DepositParams memory params = _zeroDeposit();
        params.underlyingIn = 1;
        params.jrUnderlyingIn = 1;

        vm.prank(USER);
        vm.expectRevert(UnderlyingPerpVault.VaultNotInitialized.selector);
        router.deposit(params);

        assertEq(underlying.balanceOf(USER), 100);
        assertEq(underlying.balanceOf(address(controller)), 0);
        assertEq(jr.totalSupply(), 0);
        assertEq(jrVault.totalSupply(), 0);
        _assertNoRouterDust();
    }

    function testZeroNotesStillEnforceMinimumOutputsAtomically() public {
        IPairRouter.DepositParams memory depositParams = _zeroDeposit();
        depositParams.minUsdNotes = 1;
        vm.prank(USER);
        vm.expectRevert(IPairRouter.SlippageTooHigh.selector);
        router.deposit(depositParams);

        IPairRouter.RedeemParams memory redeemParams = _zeroRedeem();
        redeemParams.minUnderlyingOut = 1;
        vm.prank(USER);
        vm.expectRevert(IPairRouter.SlippageTooHigh.selector);
        router.redeem(redeemParams);

        assertEq(underlying.balanceOf(USER), 100);
        assertEq(usdVault.totalSupply(), 0);
        assertEq(jrVault.totalSupply(), 0);
        _assertNoRouterDust();
    }

    function _zeroDeposit() private view returns (IPairRouter.DepositParams memory params) {
        params = IPairRouter.DepositParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(0),
            recipient: address(0),
            underlyingIn: 0,
            minUsdFromTrade: 0,
            underlyingToTrade: 0,
            srUnderlyingIn: 0,
            jrUnderlyingIn: 0,
            minUsdNotes: 0,
            minUnderlyingNotes: 0,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: false
        });
    }

    function _zeroRedeem() private view returns (IPairRouter.RedeemParams memory params) {
        params = IPairRouter.RedeemParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(0),
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
        });
    }

    function _assertNoRouterDust() private view {
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(usd.balanceOf(address(router)), 0);
        assertEq(sr.balanceOf(address(router)), 0);
        assertEq(jr.balanceOf(address(router)), 0);
    }
}
