// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {
    MockUnderlyingPerpVaultRebalanceController,
    MockUnderlyingPerpVaultRebalanceToken
} from "./mocks/MockUnderlyingPerpVaultRebalanceController.sol";

contract UnderlyingPerpVaultRebalanceTest is Test {
    event Rebalance(uint256 drBefore, uint256 underlyingAmt, bool isMintingPerp);

    uint256 private constant WAD = 1e18;
    uint256 private constant WAD_SQUARED = 1e36;
    uint256 private constant DEFAULT_FREQ = 86_400;
    uint256 private constant DEFAULT_MAX_FEE = 1e16;
    address private constant RANDOM = address(0xBEEF);
    address private constant KEEPER = address(0xCA11);

    MockUnderlyingPerpVaultRebalanceToken private underlying;
    MockUnderlyingPerpVaultRebalanceToken private perpSr;
    MockUnderlyingPerpVaultRebalanceToken private perpJr;
    MockUnderlyingPerpVaultRebalanceController private controller;

    function setUp() public {
        underlying = new MockUnderlyingPerpVaultRebalanceToken("Coinbase Wrapped BTC", "cbBTC", 8);
        perpSr = new MockUnderlyingPerpVaultRebalanceToken("cbBTC Senior", "cbBTC-SR", 8);
        perpJr = new MockUnderlyingPerpVaultRebalanceToken("cbBTC Junior", "cbBTC-JR", 8);
        controller =
            new MockUnderlyingPerpVaultRebalanceController(address(underlying), address(perpSr), address(perpJr));
    }

    function testDefaultPhase2ConfigurationMatchesTarget() public {
        UnderlyingPerpVault vault = _deploy(true);
        (uint96 lower, uint96 upper) = vault.eqDRRange();

        assertEq(vault.targetDR(), WAD);
        assertEq(lower, WAD);
        assertEq(upper, WAD);
        assertEq(vault.rebalanceFreqSec(), DEFAULT_FREQ);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
        assertEq(vault.minRebalanceVal(), 0);
        assertEq(vault.maxFlashFeePerc(), DEFAULT_MAX_FEE);
    }

    function testPhase2SettersAreOwnerOnlyAndValidateExactBoundaries() public {
        UnderlyingPerpVault vault = _deploy(true);
        vault.updateKeeper(KEEPER);

        vault.updateTargetDR(uint96(WAD), IUnderlyingPerpVault.DRRange(uint96(WAD), uint96(WAD)));
        vault.updateRebalanceTimingParams(100, 99);
        vault.updateMinRebalanceAmt(type(uint128).max);
        vault.updateMaxFlashFeePerc(uint64(WAD));

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", KEEPER));
        vault.updateMinRebalanceAmt(1);
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", RANDOM));
        vault.updateMinRebalanceAmt(1);

        vm.expectRevert(UnderlyingPerpVault.InvalidParamDefn.selector);
        vault.updateTargetDR(0, IUnderlyingPerpVault.DRRange(0, 0));
        vm.expectRevert(UnderlyingPerpVault.InvalidRange.selector);
        vault.updateTargetDR(uint96(WAD), IUnderlyingPerpVault.DRRange(uint96(WAD + 1), uint96(WAD + 2)));
        vm.expectRevert(UnderlyingPerpVault.InvalidParamDefn.selector);
        vault.updateRebalanceTimingParams(0, 0);
        vm.expectRevert(UnderlyingPerpVault.InvalidParamDefn.selector);
        vault.updateRebalanceTimingParams(100, 100);
        vm.expectRevert(UnderlyingPerpVault.InvalidPerc.selector);
        vault.updateMaxFlashFeePerc(uint64(WAD + 1));
    }

    function testFourDirectionsUseSingleFullPrecisionMulDiv() public {
        uint256 ratio = 1_234_567_890_123_456_789;
        controller.setTargetSystemRatio(ratio);

        {
            uint256 srValue = 10_000_003;
            uint256 jrValue = 20_000_017;
            UnderlyingPerpVault vault = _deploy(true);
            underlying.mint(address(vault), 50_000_000);
            _setState(100_000_000, srValue, 100_000_000, jrValue);
            controller.setDeviations(WAD + 1, WAD);

            uint256 targetSr = Math.mulDiv(jrValue, WAD_SQUARED, ratio * WAD);
            (uint256 amount, bool isMinting) = vault.computeRebalanceAmount();
            assertTrue(isMinting);
            assertEq(amount, targetSr - srValue);
        }

        {
            uint256 srValue = 20_000_017;
            uint256 jrValue = 20_000_017;
            UnderlyingPerpVault vault = _deploy(true);
            perpSr.mint(address(vault), 100_000_000);
            _setState(100_000_000, srValue, 100_000_000, jrValue);
            controller.setDeviations(WAD - 1, WAD);

            uint256 targetSr = Math.mulDiv(jrValue, WAD_SQUARED, ratio * WAD, Math.Rounding.Ceil);
            (uint256 amount, bool isMinting) = vault.computeRebalanceAmount();
            assertFalse(isMinting);
            assertEq(amount, srValue - targetSr);
        }

        {
            uint256 srValue = 20_000_017;
            uint256 jrValue = 10_000_003;
            UnderlyingPerpVault vault = _deploy(false);
            underlying.mint(address(vault), 50_000_000);
            _setState(100_000_000, srValue, 100_000_000, jrValue);
            controller.setDeviations(WAD - 1, WAD);

            uint256 targetJr = Math.mulDiv(srValue, ratio * WAD, WAD_SQUARED);
            (uint256 amount, bool isMinting) = vault.computeRebalanceAmount();
            assertTrue(isMinting);
            assertEq(amount, targetJr - jrValue);
        }

        {
            uint256 srValue = 20_000_017;
            uint256 jrValue = 30_000_019;
            UnderlyingPerpVault vault = _deploy(false);
            perpJr.mint(address(vault), 100_000_000);
            _setState(100_000_000, srValue, 100_000_000, jrValue);
            controller.setDeviations(WAD + 1, WAD);

            uint256 targetJr = Math.mulDiv(srValue, ratio * WAD, WAD_SQUARED, Math.Rounding.Ceil);
            (uint256 amount, bool isMinting) = vault.computeRebalanceAmount();
            assertFalse(isMinting);
            assertEq(amount, jrValue - targetJr);
        }
    }

    function testMintAndRedeemAmountsAreCappedByVaultAssets() public {
        UnderlyingPerpVault mintVault = _deploy(true);
        underlying.mint(address(mintVault), 123);
        _setState(1_000, 100, 1_000, 1_000);
        controller.setDeviations(WAD + 1, WAD);
        (uint256 mintAmount, bool mintDirection) = mintVault.computeRebalanceAmount();
        assertTrue(mintDirection);
        assertEq(mintAmount, 125);

        UnderlyingPerpVault redeemVault = _deploy(true);
        perpSr.mint(address(redeemVault), 111);
        _setState(1_000, 400, 1_000, 200);
        controller.setDeviations(WAD - 1, WAD);
        (uint256 redeemAmount, bool redeemDirection) = redeemVault.computeRebalanceAmount();
        assertFalse(redeemDirection);
        assertEq(redeemAmount, 44);
    }

    function testEquilibriumRangeEndpointsAreInclusive() public {
        UnderlyingPerpVault vault = _deploy(true);
        vault.updateTargetDR(uint96(WAD), IUnderlyingPerpVault.DRRange({lower: uint96(9e17), upper: uint96(11e17)}));

        _setState(1_000, 100, 1_000, 1_000);
        controller.setDeviations(9e17, WAD);
        (uint256 lowerAmount,) = vault.computeRebalanceAmount();
        assertEq(lowerAmount, 0);

        controller.setDeviations(11e17, WAD);
        (uint256 upperAmount,) = vault.computeRebalanceAmount();
        assertEq(upperAmount, 0);

        controller.setDeviations(11e17 + 1, WAD);
        (uint256 aboveAmount, bool aboveMinting) = vault.computeRebalanceAmount();
        assertTrue(aboveMinting);
        assertGt(aboveAmount, 0);

        _setState(1_000, 1_000, 1_000, 100);
        perpSr.mint(address(vault), 1_000);
        controller.setDeviations(9e17 - 1, WAD);
        (uint256 belowAmount, bool belowMinting) = vault.computeRebalanceAmount();
        assertFalse(belowMinting);
        assertGt(belowAmount, 0);
    }

    function testPermissionlessSeniorMintMapsSelectedControllerInputsAndEmitsGross() public {
        UnderlyingPerpVault vault = _deploy(true);
        underlying.mint(address(vault), 998);
        _setState(1_000, 1_000, 1_000, 2_000);
        controller.setDeviations(WAD + 1, WAD);
        controller.setMintResult(777, 0, _fee(DEFAULT_MAX_FEE), _fee(type(uint256).max));

        uint256 beforeUnderlying = underlying.balanceOf(address(vault));
        vm.warp(DEFAULT_FREQ);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Rebalance(WAD + 1, 1_000, true);
        vm.prank(RANDOM);
        vault.rebalance();

        assertEq(controller.flashMintCalls(), 1);
        assertEq(controller.lastMintCaller(), address(vault));
        assertEq(controller.lastSrUnderlyingIn(), 1_000);
        assertEq(controller.lastJrUnderlyingIn(), 0);
        assertEq(controller.lastMinSrOut(), 0);
        assertEq(controller.lastMinJrOut(), 0);
        assertEq(underlying.balanceOf(address(vault)), beforeUnderlying - 1_000);
        assertEq(perpSr.balanceOf(address(vault)), 777);
        assertEq(vault.lastRebalanceTimestampSec(), DEFAULT_FREQ);
    }

    function testPermissionlessJuniorMintMapsSelectedControllerInputs() public {
        UnderlyingPerpVault vault = _deploy(false);
        underlying.mint(address(vault), 998);
        _setState(1_000, 2_000, 1_000, 1_000);
        controller.setDeviations(WAD - 1, WAD);
        controller.setMintResult(0, 888, _fee(type(uint256).max), _fee(DEFAULT_MAX_FEE));

        vm.warp(DEFAULT_FREQ);
        vm.prank(RANDOM);
        vault.rebalance();

        assertEq(controller.lastSrUnderlyingIn(), 0);
        assertEq(controller.lastJrUnderlyingIn(), 1_000);
        assertEq(perpJr.balanceOf(address(vault)), 888);
    }

    function testSeniorRedeemUsesFloorPerpInputAndEventUsesGrossUnderlying() public {
        UnderlyingPerpVault vault = _deploy(true);
        _setState(10_000, 5_000, 10_000, 2_000);
        controller.setDeviations(WAD - 1, WAD);
        perpSr.mint(address(vault), 10_000);
        controller.setRedeemResult(2_900, _fee(DEFAULT_MAX_FEE), _fee(type(uint256).max));
        underlying.mint(address(controller), 2_900);

        vm.warp(DEFAULT_FREQ);
        vm.expectEmit(false, false, false, true, address(vault));
        emit Rebalance(WAD - 1, 3_000, false);
        vault.rebalance();

        assertEq(controller.flashRedeemCalls(), 1);
        assertEq(controller.lastRedeemCaller(), address(vault));
        assertEq(controller.lastSrPerpIn(), 6_000);
        assertEq(controller.lastJrPerpIn(), 0);
        assertEq(controller.lastMinUnderlyingOut(), 0);
        assertEq(perpSr.balanceOf(address(vault)), 4_000);
        assertEq(underlying.balanceOf(address(vault)), 2 + 2_900);
    }

    function testJuniorRedeemUsesFloorPerpInputAndSelectedFee() public {
        UnderlyingPerpVault vault = _deploy(false);
        _setState(10_000, 2_000, 10_000, 5_000);
        controller.setDeviations(WAD + 1, WAD);
        perpJr.mint(address(vault), 10_000);
        controller.setRedeemResult(2_900, _fee(type(uint256).max), _fee(DEFAULT_MAX_FEE));
        underlying.mint(address(controller), 2_900);

        vm.warp(DEFAULT_FREQ);
        vault.rebalance();

        assertEq(controller.lastSrPerpIn(), 0);
        assertEq(controller.lastJrPerpIn(), 6_000);
        assertEq(perpJr.balanceOf(address(vault)), 4_000);
    }

    function testNoCapacityAndBelowMinimumUseExactReasonAndExactMinimumSucceeds() public {
        UnderlyingPerpVault vault = _deploy(true);
        vm.warp(DEFAULT_FREQ);

        controller.setDeviations(WAD, WAD);
        vm.expectRevert(abi.encodeWithSelector(UnderlyingPerpVault.OpUnavailable.selector, "no capacity"));
        vault.rebalance();

        vault.updateMinRebalanceAmt(100);
        underlying.mint(address(vault), 97);
        _setState(1_000, 1_000, 1_000, 1_100);
        controller.setDeviations(WAD + 1, WAD);
        vm.expectRevert(abi.encodeWithSelector(UnderlyingPerpVault.OpUnavailable.selector, "no capacity"));
        vault.rebalance();

        underlying.mint(address(vault), 1);
        controller.setMintResult(100, 0, _fee(0), _fee(0));
        vault.rebalance();
        assertEq(controller.lastSrUnderlyingIn(), 100);
    }

    function testCooldownUsesBucketTimestampAndExactLastPlusFrequencyBoundary() public {
        UnderlyingPerpVault vault = _deploy(true);
        underlying.mint(address(vault), 10_000);
        _setState(1_000, 1_000, 1_000, 2_000);
        controller.setDeviations(WAD + 1, WAD);
        controller.setMintResult(1_000, 0, _fee(0), _fee(0));

        vm.warp(2 * DEFAULT_FREQ + 123);
        vault.rebalance();
        assertEq(vault.lastRebalanceTimestampSec(), 2 * DEFAULT_FREQ);

        vm.warp(3 * DEFAULT_FREQ - 1);
        vm.expectRevert(UnderlyingPerpVault.LastRebalanceTooRecent.selector);
        vault.rebalance();

        vm.warp(3 * DEFAULT_FREQ);
        vault.rebalance();
        assertEq(vault.lastRebalanceTimestampSec(), 3 * DEFAULT_FREQ);
    }

    function testMintFeeAboveMaximumRevertsAllAssetAndTimestampChanges() public {
        UnderlyingPerpVault vault = _deploy(true);
        underlying.mint(address(vault), 998);
        _setState(1_000, 1_000, 1_000, 2_000);
        controller.setDeviations(WAD + 1, WAD);
        controller.setMintResult(777, 0, _fee(DEFAULT_MAX_FEE + 1), _fee(0));

        uint256 underlyingBefore = underlying.balanceOf(address(vault));
        uint256 perpBefore = perpSr.balanceOf(address(vault));
        vm.warp(DEFAULT_FREQ);
        vm.expectRevert(UnderlyingPerpVault.SlippageTooHigh.selector);
        vault.rebalance();

        assertEq(underlying.balanceOf(address(vault)), underlyingBefore);
        assertEq(perpSr.balanceOf(address(vault)), perpBefore);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
        assertEq(controller.flashMintCalls(), 0);
    }

    function testRedeemFeeAboveMaximumRevertsAllAssetAndTimestampChanges() public {
        UnderlyingPerpVault vault = _deploy(true);
        _setState(10_000, 5_000, 10_000, 2_000);
        controller.setDeviations(WAD - 1, WAD);
        perpSr.mint(address(vault), 10_000);
        controller.setRedeemResult(2_900, _fee(DEFAULT_MAX_FEE + 1), _fee(0));
        underlying.mint(address(controller), 2_900);

        uint256 underlyingBefore = underlying.balanceOf(address(vault));
        uint256 perpBefore = perpSr.balanceOf(address(vault));
        vm.warp(DEFAULT_FREQ);
        vm.expectRevert(UnderlyingPerpVault.SlippageTooHigh.selector);
        vault.rebalance();

        assertEq(underlying.balanceOf(address(vault)), underlyingBefore);
        assertEq(perpSr.balanceOf(address(vault)), perpBefore);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
        assertEq(controller.flashRedeemCalls(), 0);
    }

    function testDownstreamRevertAfterTransferIsAtomic() public {
        UnderlyingPerpVault vault = _deploy(true);
        underlying.mint(address(vault), 998);
        _setState(1_000, 1_000, 1_000, 2_000);
        controller.setDeviations(WAD + 1, WAD);
        controller.setMintResult(777, 0, _fee(0), _fee(0));
        bytes memory failure = abi.encodeWithSignature("MockControllerFailure()");
        controller.setMintRevert(failure, true);

        uint256 underlyingBefore = underlying.balanceOf(address(vault));
        vm.warp(DEFAULT_FREQ);
        vm.expectRevert(failure);
        vault.rebalance();

        assertEq(underlying.balanceOf(address(vault)), underlyingBefore);
        assertEq(perpSr.balanceOf(address(vault)), 0);
        assertEq(controller.flashMintCalls(), 0);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
    }

    function _deploy(bool senior) private returns (UnderlyingPerpVault vault) {
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

        underlying.mint(address(this), 2);
        underlying.approve(address(vault), 2);
        vault.initDeposit(2);
    }

    function _setState(uint256 srSupply, uint256 srValue, uint256 jrSupply, uint256 jrValue) private {
        controller.setSystemState(
            MockUnderlyingPerpVaultRebalanceController.PerpState({
                totalSupply: srSupply, reserveValue: srValue, vm: WAD
            }),
            MockUnderlyingPerpVaultRebalanceController.PerpState({
                    totalSupply: jrSupply, reserveValue: jrValue, vm: WAD
                })
        );
    }

    function _fee(uint256 totalFeePerc)
        private
        pure
        returns (MockUnderlyingPerpVaultRebalanceController.FeePerc memory)
    {
        return MockUnderlyingPerpVaultRebalanceController.FeePerc({totalFeePerc: totalFeePerc, protocolFeePerc: 0});
    }
}
