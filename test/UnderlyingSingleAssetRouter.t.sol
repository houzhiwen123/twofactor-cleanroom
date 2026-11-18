// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IUnderlyingSingleAssetRouter} from "../src/interfaces/IUnderlyingSingleAssetRouter.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {UnderlyingSingleAssetRouter} from "../src/router/UnderlyingSingleAssetRouter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockUnderlyingRouterController {
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

    MockERC20 public immutable underlying;
    MockERC20 public immutable perpSr;
    MockERC20 public immutable perpJr;
    uint256 public lastSrMint;
    uint256 public lastJrMint;
    uint256 public lastSrRedeem;
    uint256 public lastJrRedeem;

    constructor(MockERC20 underlying_, MockERC20 perpSr_, MockERC20 perpJr_) {
        underlying = underlying_;
        perpSr = perpSr_;
        perpJr = perpJr_;
    }

    function systemReserveState() external view returns (SystemState memory state) {
        uint256 srSupply = perpSr.totalSupply();
        uint256 jrSupply = perpJr.totalSupply();
        state.perpSr = PerpState(srSupply, srSupply, 1e18);
        state.perpJr = PerpState(jrSupply, jrSupply, 1e18);
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        lastSrMint = srUnderlying;
        lastJrMint = jrUnderlying;
        uint256 total = srUnderlying + jrUnderlying;
        if (total != 0) underlying.transferFrom(msg.sender, address(this), total);
        if (srUnderlying != 0) {
            perpSr.mint(msg.sender, srUnderlying);
            srOut = srUnderlying;
        }
        if (jrUnderlying != 0) {
            perpJr.mint(msg.sender, jrUnderlying);
            jrOut = jrUnderlying;
        }
    }

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee)
    {
        lastSrRedeem = srIn;
        lastJrRedeem = jrIn;
        if (srIn != 0) perpSr.transferFrom(msg.sender, address(this), srIn);
        if (jrIn != 0) perpJr.transferFrom(msg.sender, address(this), jrIn);
        underlyingOut = srIn + jrIn;
        if (underlyingOut != 0) underlying.transfer(msg.sender, underlyingOut);
    }
}

contract UnderlyingSingleAssetRouterTest is Test {
    address private constant USER = address(0xA11CE);
    uint256 private constant VAULT_UNDERLYING = 2_896_806;
    uint256 private constant VAULT_PERP = 143_503_001;
    uint256 private constant USER_INPUT = 100_000;

    MockERC20 private underlying;
    MockERC20 private perpSr;
    MockERC20 private perpJr;
    MockUnderlyingRouterController private controller;
    UnderlyingSingleAssetRouter private router;

    function setUp() public {
        underlying = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        perpSr = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        perpJr = new MockERC20("cbBTC Junior", "cbBTC-JR", 8);
        controller = new MockUnderlyingRouterController(underlying, perpSr, perpJr);
        router = new UnderlyingSingleAssetRouter();
    }

    function testJuniorTargetSplitRoundsUpAndRefundsOneUnit() public {
        UnderlyingPerpVault vault = _seedVault(false);
        _fundAndApprove(vault);

        uint256 notesBefore = vault.balanceOf(USER);
        vm.prank(USER);
        uint256 notesOut = router.depositUnderlying(address(vault), USER_INPUT, 0, 0);

        uint256 directMax = Math.mulDiv(USER_INPUT, VAULT_UNDERLYING, VAULT_UNDERLYING + VAULT_PERP, Math.Rounding.Ceil);
        assertEq(directMax, 1_979);
        assertEq(controller.lastSrMint(), 0);
        assertEq(controller.lastJrMint(), 98_021);
        assertEq(vault.underlyingBalance(), VAULT_UNDERLYING + 1_978);
        assertEq(vault.perpBalance(), VAULT_PERP + 98_021);
        assertEq(vault.balanceOf(USER) - notesBefore, notesOut);
        assertEq(underlying.balanceOf(USER), 1);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(perpJr.balanceOf(address(router)), 0);
    }

    function testPreexistingDustIsNotPaidToNextUnderlyingCaller() public {
        UnderlyingPerpVault vault = _seedVault(false);
        _fundAndApprove(vault);
        underlying.mint(address(router), 7);
        perpJr.mint(address(router), 3);

        vm.prank(USER);
        router.depositUnderlying(address(vault), USER_INPUT, 0, 0);

        assertEq(underlying.balanceOf(USER), 1);
        assertEq(underlying.balanceOf(address(router)), 7);
        assertEq(perpJr.balanceOf(address(router)), 3);
    }

    function testJuniorRedeemMatchesBasketPlusFlashAndMinOutIsAtomic() public {
        UnderlyingPerpVault vault = _seedVault(false);
        _fundAndApprove(vault);
        vm.prank(USER);
        uint256 notes = router.depositUnderlying(address(vault), USER_INPUT, 0, 0);
        vm.prank(USER);
        vault.approve(address(router), type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        uint256 underlyingBefore = underlying.balanceOf(USER);
        vm.prank(USER);
        uint256 out = router.redeemUnderlying(address(vault), notes, 0);
        assertEq(underlying.balanceOf(USER) - underlyingBefore, out);
        assertEq(controller.lastSrRedeem(), 0);
        assertGt(controller.lastJrRedeem(), 0);
        assertEq(underlying.balanceOf(address(router)), 0);
        assertEq(perpJr.balanceOf(address(router)), 0);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(USER);
        assertEq(router.redeemUnderlying(address(vault), notes, out), out);

        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprint(vault);
        vm.prank(USER);
        vm.expectRevert(IUnderlyingSingleAssetRouter.SlippageTooHigh.selector);
        router.redeemUnderlying(address(vault), notes, out + 1);
        assertEq(_fingerprint(vault), beforeFingerprint);
    }

    function testSeniorTargetConfirmedPathSelectsOnlySeniorControllerLegs() public {
        UnderlyingPerpVault vault = _seedVault(true);
        _fundAndApprove(vault);

        vm.prank(USER);
        uint256 notes = router.depositUnderlying(address(vault), USER_INPUT, 0, 1);
        assertGt(notes, 0);
        assertEq(controller.lastSrMint(), 98_021);
        assertEq(controller.lastJrMint(), 0);

        vm.prank(USER);
        vault.approve(address(router), notes);
        vm.prank(USER);
        assertGt(router.redeemUnderlying(address(vault), notes, 0), 0);
        assertGt(controller.lastSrRedeem(), 0);
        assertEq(controller.lastJrRedeem(), 0);
    }

    function testDepositMinOutPlusOneRollsBackEveryAsset() public {
        UnderlyingPerpVault vault = _seedVault(false);
        _fundAndApprove(vault);
        uint256 snapshot = vm.snapshotState();

        vm.prank(USER);
        uint256 exact = router.depositUnderlying(address(vault), USER_INPUT, 0, 0);
        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprint(vault);

        vm.prank(USER);
        vm.expectRevert(IUnderlyingSingleAssetRouter.SlippageTooHigh.selector);
        router.depositUnderlying(address(vault), USER_INPUT, exact + 1, 0);
        assertEq(_fingerprint(vault), beforeFingerprint);
    }

    function _seedVault(bool senior) private returns (UnderlyingPerpVault vault) {
        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        bytes memory initData = abi.encodeCall(
            UnderlyingPerpVault.init,
            (
                senior ? "cbBTC Senior Keeper" : "cbBTC Junior Keeper",
                senior ? "cbBTC-Sr-Keeper" : "cbBTC-Jr-Keeper",
                address(underlying),
                address(controller),
                senior,
                senior
            )
        );
        vault = UnderlyingPerpVault(address(new ERC1967Proxy(address(implementation), initData)));

        underlying.mint(address(this), VAULT_UNDERLYING);
        underlying.approve(address(vault), VAULT_UNDERLYING);
        vault.initDeposit(VAULT_UNDERLYING);
        (senior ? perpSr : perpJr).mint(address(vault), VAULT_PERP);
    }

    function _fundAndApprove(UnderlyingPerpVault vault) private {
        underlying.mint(USER, USER_INPUT);
        vm.prank(USER);
        underlying.approve(address(router), type(uint256).max);
        assertEq(vault.isPerpSrVault(), address(vault.perp()) == address(perpSr));
    }

    function _fingerprint(UnderlyingPerpVault vault) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                underlying.balanceOf(USER),
                perpSr.balanceOf(USER),
                perpJr.balanceOf(USER),
                vault.balanceOf(USER),
                vault.totalSupply(),
                vault.underlyingBalance(),
                vault.perpBalance(),
                underlying.balanceOf(address(router)),
                IERC20(vault.perp()).balanceOf(address(router)),
                controller.lastSrMint(),
                controller.lastJrMint(),
                controller.lastSrRedeem(),
                controller.lastJrRedeem()
            )
        );
    }
}
