// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PairRouter} from "../../src/router/PairRouter.sol";

interface IPairRouterProbeController {
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

contract PairRouterRedeemTargetProbe is Test {
    struct ReplaySnapshot {
        bytes32 resultHash;
        uint256 usdDelta;
        uint256 underlyingDelta;
        uint256 usdNotesBurned;
        uint256 jrNotesBurned;
        uint256 usdNotesSupply;
        uint256 jrNotesSupply;
        uint256 subDR;
        uint256 vmDR;
    }

    bytes32 private constant REDEEM_TX = 0xcb92c779fd030f2524da58822354ddbc755818da877a0774baea1da70eaf6634;

    address private constant ROUTER = 0x97c521D21468022E205d8A57b2fcaeE33d6714d6;
    address private constant USER = 0x5d13C850F3E8eB925B8aB73155b8d8b610e16E5a;
    address private constant USD_VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant JR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant UNDERLYING = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USD = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;

    uint256 private constant EXPECTED_USD_OUT = 14_245_807;
    uint256 private constant EXPECTED_UNDERLYING_OUT = 0;

    function testNaturalBalanceRedeemReplaysExactly() public {
        _selectStrictPrestate();

        (uint256 preSubDR, uint256 preVmDR) = IPairRouterProbeController(CONTROLLER).systemDeviations();
        uint256 userUsdBefore = IERC20(USD).balanceOf(USER);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(_exactCalldata());
        assertTrue(success, "natural target redeem must succeed");

        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        assertEq(usdOut, EXPECTED_USD_OUT, "exact USD return");
        assertEq(underlyingOut, EXPECTED_UNDERLYING_OUT, "exact underlying return");
        assertEq(IERC20(USD).balanceOf(USER) - userUsdBefore, EXPECTED_USD_OUT, "user USD delta");

        assertEq(IERC20(USD_VAULT).balanceOf(ROUTER), 0, "USD notes dust");
        assertEq(IERC20(JR_VAULT).balanceOf(ROUTER), 0, "JR notes dust");
        assertEq(IERC20(UNDERLYING).balanceOf(ROUTER), 0, "underlying dust");
        assertEq(IERC20(USD).balanceOf(ROUTER), 0, "USD dust");
        assertEq(IERC20(PERP_SR).balanceOf(ROUTER), 0, "SR dust");
        assertEq(IERC20(PERP_JR).balanceOf(ROUTER), 0, "JR dust");

        (uint256 postSubDR, uint256 postVmDR) = IPairRouterProbeController(CONTROLLER).systemDeviations();
        emit log_named_bytes32("router codehash", ROUTER.codehash);
        emit log_named_uint("pre subDR", preSubDR);
        emit log_named_uint("pre vmDR", preVmDR);
        emit log_named_uint("post subDR", postSubDR);
        emit log_named_uint("post vmDR", postVmDR);
    }

    function testCleanRoomRouterMatchesNaturalTargetReplayExactly() public {
        _selectStrictPrestate();
        ReplaySnapshot memory target = _runReplay(ROUTER, false);

        _selectStrictPrestate();
        PairRouter localRouter = new PairRouter();
        ReplaySnapshot memory local = _runReplay(address(localRouter), true);

        assertEq(local.resultHash, target.resultHash, "return data");
        assertEq(local.usdDelta, target.usdDelta, "user USD delta");
        assertEq(local.underlyingDelta, target.underlyingDelta, "user underlying delta");
        assertEq(local.usdNotesBurned, target.usdNotesBurned, "USD notes burn");
        assertEq(local.jrNotesBurned, target.jrNotesBurned, "JR notes burn");
        assertEq(local.usdNotesSupply, target.usdNotesSupply, "USD notes supply");
        assertEq(local.jrNotesSupply, target.jrNotesSupply, "JR notes supply");
        assertEq(local.subDR, target.subDR, "post subDR");
        assertEq(local.vmDR, target.vmDR, "post vmDR");
        _assertNoRouterDust(address(localRouter));
    }

    function testProbeOperationalArgumentBoundaries() public {
        _probeMutation(5, 0, "arg5 zero");
        _probeMutation(5, 1, "arg5 one");
        _probeMutation(5, 246_764_097, "arg5 SR amount minus one");
        _probeMutation(5, 246_764_098, "arg5 SR amount");
        _probeMutation(5, 246_764_099, "arg5 SR amount plus one");
        _probeMutation(6, 19_770, "arg6 expected minus one");
        _probeMutation(6, 19_771, "arg6 expected");
        _probeMutation(6, 19_772, "arg6 expected plus one");
        _probeMutation(7, 1, "arg7 one");
        _probeMutation(7, 2, "arg7 two");
        _probeMutation(7, 1_459_344_074, "arg7 JR amount minus one");
        _probeMutation(7, 1_459_344_075, "arg7 JR amount");
        _probeMutation(7, type(uint256).max, "arg7 max");
        _probeMutation(8, EXPECTED_USD_OUT - 1, "arg8 actual minus one");
        _probeMutation(8, EXPECTED_USD_OUT, "arg8 actual");
        _probeMutation(8, EXPECTED_USD_OUT + 1, "arg8 actual plus one");
        _probeMutation(9, 1, "arg9 one");
    }

    function testProbePostDeviationBoundaries() public {
        uint256 postSubDR = 1_049_008_142_808_840_695;
        uint256 postVmDR = 1_001_085_976_679_671_604;

        _probeMutation(10, postSubDR, "min subDR exact");
        _probeMutation(10, postSubDR + 1, "min subDR plus one");
        _probeMutation(11, postSubDR, "max subDR exact");
        _probeMutation(11, postSubDR - 1, "max subDR minus one");
        _probeMutation(12, postVmDR, "min vmDR exact");
        _probeMutation(12, postVmDR + 1, "min vmDR plus one");
        _probeMutation(13, postVmDR, "max vmDR exact");
        _probeMutation(13, postVmDR - 1, "max vmDR minus one");
    }

    function testArg7OneRevertsNoOp() public {
        _selectStrictPrestate();
        bytes memory data = _exactCalldata();
        _setArg(data, 7, 1);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(data);
        assertFalse(success);
        assertEq(_selector(result), bytes4(keccak256("NoOp()")));
    }

    function testProbeArg5AgainstOneUnitUnderlyingRefund() public {
        _probeDoubleMutation(5, 0, 6, 19_770, "arg5 zero with one underlying refund");
        _probeDoubleMutation(5, 1, 6, 19_770, "arg5 one with one underlying refund");
    }

    function testProbeArg5OnNaturalOneSidedRedeems() public {
        _probeOneSided(true, 0, "USD-only arg5 zero");
        _probeOneSided(true, 1, "USD-only arg5 one");
        _probeOneSided(true, type(uint256).max, "USD-only arg5 max");
        _probeOneSided(false, 0, "JR-only arg5 zero");
        _probeOneSided(false, 1, "JR-only arg5 one");
        _probeOneSided(false, type(uint256).max, "JR-only arg5 max");
    }

    function testProbeBidirectionalTradeOrdering() public {
        _selectStrictPrestate();
        bytes memory data = _exactCalldata();
        _setArg(data, 5, 0);
        _setArg(data, 8, 0);
        _setArg(data, 9, 0);
        _setArg(data, 10, 0);
        _setArg(data, 11, type(uint256).max);
        _setArg(data, 12, 0);
        _setArg(data, 13, type(uint256).max);
        _setArg(data, 14, 0);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(data);
        assertTrue(success);
        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        emit log_named_uint("bidirectional USD out", usdOut);
        emit log_named_uint("bidirectional underlying out", underlyingOut);
    }

    function _probeMutation(uint256 index, uint256 value, string memory label) private {
        _selectStrictPrestate();
        bytes memory data = _exactCalldata();
        _setArg(data, index, value);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(data);
        emit log_named_string("case", label);
        emit log_named_uint("arg index", index);
        emit log_named_uint("arg value", value);
        emit log_named_uint("success", success ? 1 : 0);
        if (success) {
            (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
            emit log_named_uint("USD out", usdOut);
            emit log_named_uint("underlying out", underlyingOut);
        } else {
            emit log_named_bytes32("error selector", bytes32(_selector(result)));
        }
    }

    function _probeDoubleMutation(
        uint256 firstIndex,
        uint256 firstValue,
        uint256 secondIndex,
        uint256 secondValue,
        string memory label
    ) private {
        _selectStrictPrestate();
        bytes memory data = _exactCalldata();
        _setArg(data, firstIndex, firstValue);
        _setArg(data, secondIndex, secondValue);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(data);
        emit log_named_string("case", label);
        emit log_named_uint("success", success ? 1 : 0);
        if (success) {
            (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
            emit log_named_uint("USD out", usdOut);
            emit log_named_uint("underlying out", underlyingOut);
        } else {
            emit log_named_bytes32("error selector", bytes32(_selector(result)));
        }
    }

    function _probeOneSided(bool usdOnly, uint256 arg5, string memory label) private {
        _selectStrictPrestate();
        bytes memory data = _exactCalldata();
        if (usdOnly) _setArg(data, 4, 0);
        else _setArg(data, 3, 0);
        _setArg(data, 5, arg5);
        _setArg(data, 6, 0);
        _setArg(data, 8, 0);
        _setArg(data, 9, 0);
        _setArg(data, 10, 0);
        _setArg(data, 11, type(uint256).max);
        _setArg(data, 12, 0);
        _setArg(data, 13, type(uint256).max);
        _setArg(data, 14, 0);

        vm.prank(USER);
        (bool success, bytes memory result) = ROUTER.call(data);
        emit log_named_string("case", label);
        emit log_named_uint("success", success ? 1 : 0);
        if (success) {
            (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
            emit log_named_uint("USD out", usdOut);
            emit log_named_uint("underlying out", underlyingOut);
        } else {
            emit log_named_bytes32("error selector", bytes32(_selector(result)));
        }
    }

    function _selectStrictPrestate() private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), REDEEM_TX);
        assertEq(block.chainid, 8453, "Base chain ID");
        assertEq(block.number, 57_015_384, "strict transaction prestate block");
    }

    function _setArg(bytes memory data, uint256 index, uint256 value) private pure {
        assembly ("memory-safe") {
            mstore(add(add(data, 36), mul(index, 32)), value)
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 32))
        }
    }

    function _runReplay(address router, bool approveRouter) private returns (ReplaySnapshot memory replay) {
        if (approveRouter) {
            vm.startPrank(USER);
            IERC20(USD_VAULT).approve(router, type(uint256).max);
            IERC20(JR_VAULT).approve(router, type(uint256).max);
            vm.stopPrank();
        }

        uint256 usdBefore = IERC20(USD).balanceOf(USER);
        uint256 underlyingBefore = IERC20(UNDERLYING).balanceOf(USER);
        uint256 usdNotesBefore = IERC20(USD_VAULT).balanceOf(USER);
        uint256 jrNotesBefore = IERC20(JR_VAULT).balanceOf(USER);
        vm.prank(USER);
        (bool success, bytes memory result) = router.call(_exactCalldata());
        assertTrue(success, approveRouter ? "clean-room replay" : "target replay");

        replay.resultHash = keccak256(result);
        replay.usdDelta = IERC20(USD).balanceOf(USER) - usdBefore;
        replay.underlyingDelta = IERC20(UNDERLYING).balanceOf(USER) - underlyingBefore;
        replay.usdNotesBurned = usdNotesBefore - IERC20(USD_VAULT).balanceOf(USER);
        replay.jrNotesBurned = jrNotesBefore - IERC20(JR_VAULT).balanceOf(USER);
        replay.usdNotesSupply = IERC20(USD_VAULT).totalSupply();
        replay.jrNotesSupply = IERC20(JR_VAULT).totalSupply();
        (replay.subDR, replay.vmDR) = IPairRouterProbeController(CONTROLLER).systemDeviations();
    }

    function _assertNoRouterDust(address router) private view {
        assertEq(IERC20(USD_VAULT).balanceOf(router), 0, "USD notes dust");
        assertEq(IERC20(JR_VAULT).balanceOf(router), 0, "JR notes dust");
        assertEq(IERC20(UNDERLYING).balanceOf(router), 0, "underlying dust");
        assertEq(IERC20(USD).balanceOf(router), 0, "USD dust");
        assertEq(IERC20(PERP_SR).balanceOf(router), 0, "SR dust");
        assertEq(IERC20(PERP_JR).balanceOf(router), 0, "JR dust");
    }

    function _exactCalldata() private pure returns (bytes memory) {
        return hex"b2a72016" hex"000000000000000000000000e356d1ed9ad82ccc79e70f50abce08057e8d75f3"
            hex"000000000000000000000000ebee489b84c1b3408838a87a691a4370aed139db"
            hex"000000000000000000000000e0fc0566adcd6b83149874619a1fafdf3345144f"
            hex"0000000000000000000000000000000000000000000000002b3c80042e8ca5da"
            hex"00000000000000000000000000000000000000000000000000009da6df8dffcc"
            hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            hex"0000000000000000000000000000000000000000000000000000000000004d3b"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000d82023"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000e7c3102e20526cb"
            hex"0000000000000000000000000000000000000000000000000ea175af4b34cd22"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            hex"0000000000000000000000000000000000000000000000000000000000000001";
    }
}
