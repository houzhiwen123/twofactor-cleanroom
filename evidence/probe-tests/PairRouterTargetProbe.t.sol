// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Read-only target probes. Every test executes on a local fork at the
///         exact pre-state of the historical PairRouter transaction.
contract PairRouterTargetProbe is Test {
    bytes4 private constant DEPOSIT_SELECTOR = 0x0176cb45;

    bytes32 private constant TX_HASH = 0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7;
    address private constant USER = 0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b;
    address private constant ROUTER = 0x97c521D21468022E205d8A57b2fcaeE33d6714d6;
    address private constant USD_VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant JR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address private constant STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;

    uint256 private constant USD_NOTES_OUT = 10_672_407_599_351_449_815;
    uint256 private constant JR_NOTES_OUT = 474_271_839_185_754;
    uint256 private constant POST_SUB_DR = 1_040_088_606_506_973_317;
    uint256 private constant POST_VM_DR = 1_002_894_667_332_216_205;

    struct DepositArgs {
        address usdVault;
        address underlyingVault;
        address strategy;
        address recipient;
        uint256 underlyingIn;
        uint256 minUsdFromTrade;
        uint256 underlyingToTrade;
        uint256 srUnderlyingIn;
        uint256 jrUnderlyingIn;
        uint256 minUsdNotes;
        uint256 minUnderlyingNotes;
        uint256 minSubDr;
        uint256 maxSubDr;
        uint256 minVmDr;
        uint256 maxVmDr;
        bool healthCheck;
    }

    function setUp() public {
        vm.createSelectFork(vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org")), TX_HASH);
    }

    function testHistoricalDepositReturnAndAssetDeltas() public {
        uint256 cbBtcBefore = IERC20(CBBTC).balanceOf(USER);
        uint256 usdcBefore = IERC20(USDC).balanceOf(USER);
        uint256 usdNotesBefore = IERC20(USD_VAULT).balanceOf(USER);
        uint256 jrNotesBefore = IERC20(JR_VAULT).balanceOf(USER);

        (bool ok, bytes memory ret) = _call(_historicalArgs());
        assertTrue(ok);
        assertEq(ret.length, 6 * 32);

        (
            uint256 usdNotes,
            uint256 jrNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        ) = abi.decode(ret, (uint256, uint256, uint256, uint256, uint256, uint256));

        assertEq(usdNotes, USD_NOTES_OUT);
        assertEq(jrNotes, JR_NOTES_OUT);
        assertEq(underlyingRefund, 1);
        assertEq(usdRefund, 388);
        assertEq(srRefund, 0);
        assertEq(jrRefund, 0);

        assertEq(cbBtcBefore - IERC20(CBBTC).balanceOf(USER), 59_999);
        assertEq(IERC20(USDC).balanceOf(USER) - usdcBefore, 388);
        assertEq(IERC20(USD_VAULT).balanceOf(USER) - usdNotesBefore, USD_NOTES_OUT);
        assertEq(IERC20(JR_VAULT).balanceOf(USER) - jrNotesBefore, JR_NOTES_OUT);
        _assertRouterEmpty();
    }

    function testMinUsdTradeOutExactSucceeds() public {
        DepositArgs memory args = _historicalArgs();
        args.minUsdFromTrade = 4_060;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testMinUsdTradeOutPlusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.minUsdFromTrade = 4_061;
        _assertRevertAtomic(args);
    }

    function testMinUsdNotesExactSucceeds() public {
        DepositArgs memory args = _historicalArgs();
        args.minUsdNotes = USD_NOTES_OUT;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testMinUsdNotesPlusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.minUsdNotes = USD_NOTES_OUT + 1;
        _assertRevertAtomic(args);
    }

    function testMinUnderlyingNotesExactSucceeds() public {
        DepositArgs memory args = _historicalArgs();
        args.minUnderlyingNotes = JR_NOTES_OUT;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testMinUnderlyingNotesPlusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.minUnderlyingNotes = JR_NOTES_OUT + 1;
        _assertRevertAtomic(args);
    }

    function testSubDrBoundsAreInclusive() public {
        DepositArgs memory args = _historicalArgs();
        args.minSubDr = POST_SUB_DR;
        args.maxSubDr = POST_SUB_DR;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testSubDrLowerBoundPlusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.minSubDr = POST_SUB_DR + 1;
        _assertRevertAtomic(args);
    }

    function testSubDrUpperBoundMinusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.maxSubDr = POST_SUB_DR - 1;
        _assertRevertAtomic(args);
    }

    function testVmDrBoundsAreInclusive() public {
        DepositArgs memory args = _historicalArgs();
        args.minVmDr = POST_VM_DR;
        args.maxVmDr = POST_VM_DR;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testVmDrLowerBoundPlusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.minVmDr = POST_VM_DR + 1;
        _assertRevertAtomic(args);
    }

    function testVmDrUpperBoundMinusOneRevertsAtomically() public {
        DepositArgs memory args = _historicalArgs();
        args.maxVmDr = POST_VM_DR - 1;
        _assertRevertAtomic(args);
    }

    function testZeroRecipientMeansCaller() public {
        (bool ok,) = _call(_historicalArgs());
        assertTrue(ok);
        assertEq(IERC20(USD_VAULT).balanceOf(ROUTER), 0);
        assertEq(IERC20(JR_VAULT).balanceOf(ROUTER), 0);
    }

    function testExplicitRecipientReceivesNotesAndRefunds() public {
        address recipient = address(0xBEEF);
        DepositArgs memory args = _historicalArgs();
        args.recipient = recipient;

        (bool ok,) = _call(args);
        assertTrue(ok);
        assertEq(IERC20(USD_VAULT).balanceOf(recipient), USD_NOTES_OUT);
        assertEq(IERC20(JR_VAULT).balanceOf(recipient), JR_NOTES_OUT);
        assertEq(IERC20(CBBTC).balanceOf(recipient), 1);
        assertEq(IERC20(USDC).balanceOf(recipient), 388);
    }

    function testHealthCheckFalseSkipsStrategyHealthCall() public {
        vm.mockCallRevert(STRATEGY, abi.encodeWithSignature("isHealthy()"), bytes("forced health failure"));
        DepositArgs memory args = _historicalArgs();
        args.healthCheck = false;
        (bool ok,) = _call(args);
        assertTrue(ok);
    }

    function testHealthCheckTruePropagatesStrategyHealthFailure() public {
        vm.mockCallRevert(STRATEGY, abi.encodeWithSignature("isHealthy()"), bytes("forced health failure"));
        _assertRevertAtomic(_historicalArgs());
    }

    function testPostDeviationsMatchHistoricalBoundsVector() public {
        (bool ok,) = _call(_historicalArgs());
        assertTrue(ok);
        (uint256 subDr, uint256 vmDr) = IControllerView(CONTROLLER).systemDeviations();
        assertEq(subDr, POST_SUB_DR);
        assertEq(vmDr, POST_VM_DR);
    }

    function _historicalArgs() private pure returns (DepositArgs memory args) {
        args = DepositArgs({
            usdVault: USD_VAULT,
            underlyingVault: JR_VAULT,
            strategy: STRATEGY,
            recipient: address(0),
            underlyingIn: 60_000,
            minUsdFromTrade: 0,
            underlyingToTrade: 6,
            srUnderlyingIn: 13_194,
            jrUnderlyingIn: 46_799,
            minUsdNotes: 10_619_045_561_354_692_565,
            minUnderlyingNotes: 471_900_479_989_825,
            minSubDr: 1_034_888_163_474_438_450,
            maxSubDr: 1_045_289_049_539_508_183,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: true
        });
    }

    function _call(DepositArgs memory args) private returns (bool ok, bytes memory ret) {
        bytes memory data = abi.encodePacked(DEPOSIT_SELECTOR, abi.encode(args));
        vm.prank(USER);
        (ok, ret) = ROUTER.call(data);
        if (!ok && ret.length >= 4) emit log_named_bytes32("revert selector", bytes32(_selector(ret)));
    }

    function _assertRevertAtomic(DepositArgs memory args) private {
        uint256[6] memory beforeBalances = _trackedBalances();
        (bool ok, bytes memory ret) = _call(args);
        assertFalse(ok);
        assertGe(ret.length, 4);
        uint256[6] memory afterBalances = _trackedBalances();
        for (uint256 i; i < beforeBalances.length; ++i) {
            assertEq(afterBalances[i], beforeBalances[i]);
        }
    }

    function _trackedBalances() private view returns (uint256[6] memory balances) {
        balances[0] = IERC20(CBBTC).balanceOf(USER);
        balances[1] = IERC20(USDC).balanceOf(USER);
        balances[2] = IERC20(USD_VAULT).balanceOf(USER);
        balances[3] = IERC20(JR_VAULT).balanceOf(USER);
        balances[4] = IERC20(PERP_SR).balanceOf(ROUTER);
        balances[5] = IERC20(PERP_JR).balanceOf(ROUTER);
    }

    function _assertRouterEmpty() private view {
        assertEq(IERC20(CBBTC).balanceOf(ROUTER), 0);
        assertEq(IERC20(USDC).balanceOf(ROUTER), 0);
        assertEq(IERC20(PERP_SR).balanceOf(ROUTER), 0);
        assertEq(IERC20(PERP_JR).balanceOf(ROUTER), 0);
        assertEq(IERC20(USD_VAULT).balanceOf(ROUTER), 0);
        assertEq(IERC20(JR_VAULT).balanceOf(ROUTER), 0);
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        assembly ("memory-safe") {
            selector := mload(add(data, 0x20))
        }
    }
}

interface IControllerView {
    function systemDeviations() external view returns (uint256 subDr, uint256 vmDr);
}
