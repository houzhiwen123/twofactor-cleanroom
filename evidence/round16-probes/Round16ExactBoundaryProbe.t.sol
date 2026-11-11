// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IRound16Controller {
    function keeper() external view returns (address);
    function owner() external view returns (address);
    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
    function targetSystemRatio() external view returns (uint256);
    function updateValueCap(uint256 valueCap) external;
    function updateMinCleanupVal(uint256 minCleanupVal) external;
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function flashMint2(uint256 srIn, uint256 jrIn, uint256 minSrOut, uint256 minJrOut) external;
}

interface IRound16Perp {
    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveData {
        uint256 underlyingBal;
        TokenAmount[] trancheTokens;
    }

    function reserves() external view returns (ReserveData memory);
}

interface IRound16ERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
}

contract Round16ExactBoundaryProbe is Test {
    uint256 private constant FORK_BLOCK = 54_990_962;
    uint256 private constant WAD = 1e18;
    uint256 private constant EXACT_SR_POST = 1e9;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USER = address(0xBEEF);

    IRound16Controller private controller;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        controller = IRound16Controller(CONTROLLER);
        assertEq(block.chainid, 8453);
    }

    function testExactPostSubDrOneIsAllowed() public {
        address sr = controller.perpSr();
        address jr = controller.perpJr();
        _clearTranches(sr);
        _clearTranches(jr);

        uint256 ratio = controller.targetSystemRatio();
        assertEq(ratio % 1e9, 0);
        deal(CBBTC, sr, EXACT_SR_POST - 1);
        deal(CBBTC, jr, ratio / 1e9);

        vm.prank(controller.owner());
        controller.updateMinCleanupVal(type(uint256).max);
        vm.prank(controller.keeper());
        controller.updateValueCap(1);

        (uint256 preSubDR,) = controller.systemDeviations();
        deal(CBBTC, USER, 1);
        vm.prank(USER);
        IRound16ERC20(CBBTC).approve(CONTROLLER, 1);
        vm.prank(USER);
        (bool success, bytes memory ret) = CONTROLLER.call(
            abi.encodeWithSelector(
                IRound16Controller.flashMint2.selector, uint256(1), uint256(0), uint256(0), uint256(0)
            )
        );
        (uint256 postSubDR,) = controller.systemDeviations();

        console2.log("OBS:R16_EXACT_VALUE_CAP ratio", ratio);
        console2.log("OBS:R16_EXACT_VALUE_CAP preSubDR", preSubDR);
        console2.log("OBS:R16_EXACT_VALUE_CAP success", success);
        console2.log("OBS:R16_EXACT_VALUE_CAP selector", vm.toString(_selector(ret)));
        console2.log("OBS:R16_EXACT_VALUE_CAP postSubDR", postSubDR);

        assertGt(preSubDR, WAD);
        assertTrue(success);
        assertEq(postSubDR, WAD);
    }

    function testExactPostSubDrOneFromBelowIsAllowed() public {
        address sr = controller.perpSr();
        address jr = controller.perpJr();
        _clearTranches(sr);
        _clearTranches(jr);

        uint256 ratio = controller.targetSystemRatio();
        assertEq(ratio % 1e9, 0);
        uint256 exactJrPost = ratio / 1e9;
        deal(CBBTC, sr, EXACT_SR_POST);
        deal(CBBTC, jr, exactJrPost - 1);

        vm.prank(controller.keeper());
        controller.updateValueCap(1);

        (uint256 preSubDR,) = controller.systemDeviations();
        deal(CBBTC, USER, 1);
        vm.prank(USER);
        IRound16ERC20(CBBTC).approve(CONTROLLER, 1);
        vm.prank(USER);
        (bool success, bytes memory ret) = CONTROLLER.call(
            abi.encodeWithSelector(
                IRound16Controller.flashMint2.selector, uint256(0), uint256(1), uint256(0), uint256(0)
            )
        );
        (uint256 postSubDR,) = controller.systemDeviations();

        console2.log("OBS:R16_EXACT_VALUE_CAP_JR ratio", ratio);
        console2.log("OBS:R16_EXACT_VALUE_CAP_JR preSubDR", preSubDR);
        console2.log("OBS:R16_EXACT_VALUE_CAP_JR success", success);
        console2.log("OBS:R16_EXACT_VALUE_CAP_JR selector", vm.toString(_selector(ret)));
        console2.log("OBS:R16_EXACT_VALUE_CAP_JR postSubDR", postSubDR);

        assertLt(preSubDR, WAD);
        assertTrue(success);
        assertEq(postSubDR, WAD);
    }

    function _clearTranches(address perp) private {
        IRound16Perp.ReserveData memory reserve = IRound16Perp(perp).reserves();
        for (uint256 i; i < reserve.trancheTokens.length; ++i) {
            deal(reserve.trancheTokens[i].token, perp, 0);
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }
    }
}
