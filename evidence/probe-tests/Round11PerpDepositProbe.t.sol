// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, console2, Vm} from "forge-std/Test.sol";

struct R11BondDeposit {
    bytes32 bondID;
    uint256 underlyingAmt;
}

struct R11TokenAmount {
    address token;
    uint256 amount;
}

struct R11ReserveTokens {
    uint256 underlyingBal;
    R11TokenAmount[] trancheTokens;
}

interface IR11Controller {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function latestBondInfo() external view returns (BondInfo memory);
}

interface IR11PerpView {
    function reserves() external view returns (R11ReserveTokens memory);
}

interface IR11ERC20 {
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Round11PerpDepositProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant OWNER_SAFE = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant RANDOM_CALLER = address(0xCAFE);
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;

    bytes32 private constant RESERVE_SYNCED = 0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testRound11PermissionAndEmptyArray() public {
        R11BondDeposit[] memory deposits = new R11BondDeposit[](0);
        address[3] memory callers = [CONTROLLER, OWNER_SAFE, RANDOM_CALLER];
        string[3] memory labels = ["controller", "owner", "random"];

        for (uint256 i; i < callers.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            vm.recordLogs();
            vm.prank(callers[i]);
            (bool success, bytes memory returndata) = PERP_JR.call(
                abi.encodeWithSignature("bondDepositsForRollover(address,(bytes32,uint256)[])", BONDS_MANAGER, deposits)
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            console2.log(
                string.concat(
                    "OBS:R11_BOND_DEPOSITS_PERMISSION {\"caller\":\"",
                    labels[i],
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"selector\":\"",
                    vm.toString(_selector(returndata)),
                    "\",\"returnLength\":",
                    vm.toString(returndata.length),
                    ",\"reserveSyncCount\":",
                    vm.toString(_reserveSyncCount(logs)),
                    "}"
                )
            );
            require(vm.revertToState(snapshot), "permission snapshot restore failed");
        }

        uint256 srSnapshot = vm.snapshotState();
        vm.prank(CONTROLLER);
        (bool srSuccess, bytes memory srReturndata) = PERP_SR.call(
            abi.encodeWithSignature("bondDepositsForRollover(address,(bytes32,uint256)[])", BONDS_MANAGER, deposits)
        );
        console2.log(
            string.concat(
                "OBS:R11_BOND_DEPOSITS_SR {\"success\":",
                vm.toString(srSuccess),
                ",\"selector\":\"",
                vm.toString(_selector(srReturndata)),
                "\",\"returnLength\":",
                vm.toString(srReturndata.length),
                "}"
            )
        );
        require(vm.revertToState(srSnapshot), "senior snapshot restore failed");
    }

    function testRound11ZeroAndPositiveDepositEffects() public {
        IR11Controller.BondInfo memory latest = IR11Controller(CONTROLLER).latestBondInfo();
        _probeDeposit(latest, 0, "zero");
        _probeDeposit(latest, 1_000, "positive");
    }

    function testRound11EmptyArrayWithDifferentManager() public {
        R11BondDeposit[] memory deposits = new R11BondDeposit[](0);
        vm.recordLogs();
        vm.prank(CONTROLLER);
        (bool success, bytes memory returndata) = PERP_JR.call(
            abi.encodeWithSignature("bondDepositsForRollover(address,(bytes32,uint256)[])", address(0x1234), deposits)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log("OBS:R11_EMPTY_DIFFERENT_MANAGER success", success);
        console2.logBytes4(_selector(returndata));
        console2.log("returnLength", returndata.length);
        console2.log("reserveSyncCount", _reserveSyncCount(logs));
    }

    function testRound11MultipleDepositsSyncOrder() public {
        IR11Controller.BondInfo memory latest = IR11Controller(CONTROLLER).latestBondInfo();
        R11ReserveTokens memory beforeReserves = IR11PerpView(PERP_JR).reserves();
        deal(CBBTC, PERP_JR, beforeReserves.underlyingBal + 2_000);
        vm.prank(CONTROLLER);
        (bool approvalSuccess,) = PERP_JR.call(abi.encodeWithSignature("primeApproval(address)", BONDS_MANAGER));
        require(approvalSuccess, "approval failed");

        R11BondDeposit[] memory deposits = new R11BondDeposit[](2);
        deposits[0] = R11BondDeposit(latest.bondID, 1_000);
        deposits[1] = R11BondDeposit(latest.bondID, 1_000);
        vm.recordLogs();
        vm.prank(CONTROLLER);
        (bool success, bytes memory returndata) = PERP_JR.call(
            abi.encodeWithSignature("bondDepositsForRollover(address,(bytes32,uint256)[])", BONDS_MANAGER, deposits)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        console2.log("OBS:R11_MULTIPLE_DEPOSITS success", success);
        console2.logBytes4(_selector(returndata));
        console2.log("returnLength", returndata.length);
        console2.log("reserveSyncCount", _reserveSyncCount(logs));
        _logReserveSyncs(logs, "multiple");
    }

    function _probeDeposit(IR11Controller.BondInfo memory latest, uint256 amount, string memory label) private {
        uint256 snapshot = vm.snapshotState();
        R11ReserveTokens memory beforeReserves = IR11PerpView(PERP_JR).reserves();
        deal(CBBTC, PERP_JR, beforeReserves.underlyingBal + amount);

        vm.prank(CONTROLLER);
        (bool approvalSuccess, bytes memory approvalReturndata) =
            PERP_JR.call(abi.encodeWithSignature("primeApproval(address)", BONDS_MANAGER));

        R11BondDeposit[] memory deposits = new R11BondDeposit[](1);
        deposits[0] = R11BondDeposit(latest.bondID, amount);
        vm.recordLogs();
        vm.prank(CONTROLLER);
        (bool success, bytes memory returndata) = PERP_JR.call(
            abi.encodeWithSignature("bondDepositsForRollover(address,(bytes32,uint256)[])", BONDS_MANAGER, deposits)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        R11ReserveTokens memory afterReserves = IR11PerpView(PERP_JR).reserves();
        console2.log("OBS:R11_BOND_DEPOSITS_EFFECT case", label);
        console2.log("amount", amount);
        console2.log("approvalSuccess", approvalSuccess);
        console2.logBytes4(_selector(approvalReturndata));
        console2.log("allowance", IR11ERC20(CBBTC).allowance(PERP_JR, BONDS_MANAGER));
        console2.log("success", success);
        console2.logBytes4(_selector(returndata));
        console2.log("beforeCount", beforeReserves.trancheTokens.length);
        console2.log("afterCount", afterReserves.trancheTokens.length);
        console2.log("reserveSyncCount", _reserveSyncCount(logs));
        console2.log("latestSrRegistered", _contains(afterReserves.trancheTokens, latest.srTranche));
        console2.log("latestJrRegistered", _contains(afterReserves.trancheTokens, latest.jrTranche));
        _logReserveSyncs(logs, label);
        require(vm.revertToState(snapshot), "deposit snapshot restore failed");
    }

    function _logReserveSyncs(Vm.Log[] memory logs, string memory label) private view {
        uint256 index;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != PERP_JR || logs[i].topics.length == 0 || logs[i].topics[0] != RESERVE_SYNCED) {
                continue;
            }
            (address token, uint256 balance) = abi.decode(logs[i].data, (address, uint256));
            console2.log(
                string.concat(
                    "OBS:R11_RESERVE_SYNC {\"case\":\"",
                    label,
                    "\",\"index\":",
                    vm.toString(index),
                    ",\"token\":\"",
                    vm.toString(token),
                    "\",\"balance\":",
                    vm.toString(balance),
                    "}"
                )
            );
            ++index;
        }
    }

    function _reserveSyncCount(Vm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == PERP_JR && logs[i].topics.length != 0 && logs[i].topics[0] == RESERVE_SYNCED) {
                ++count;
            }
        }
    }

    function _contains(R11TokenAmount[] memory rows, address token) private pure returns (bool) {
        for (uint256 i; i < rows.length; ++i) {
            if (rows[i].token == token) return true;
        }
        return false;
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 selector) {
        if (returndata.length >= 4) {
            assembly {
                selector := mload(add(returndata, 32))
            }
        }
    }
}
