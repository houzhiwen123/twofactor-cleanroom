// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";

library R14Types {
    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct PerpSrRolloverState {
        uint256 staleUnderlyingBal;
        uint256 totalStaleVal;
        ReserveTrancheData[] staleSrTrs;
        ReserveTrancheData[] freshSrTrs;
    }

    struct BondDepositParams {
        bytes32 bondID;
        uint256 underlyingAmt;
    }

    struct RolloverExecution {
        ReserveAmounts stale;
        BondDepositParams[] freshBondDepositAmts;
        TokenAmount[] freshSrTrAmts;
        uint256 underlyingValRolled;
    }
}

interface IR14Balancer {
    function computeBackupRolloverPolicy(R14Types.PerpSrRolloverState memory state, uint256 free)
        external
        pure
        returns (R14Types.RolloverExecution memory);
}

contract Round14BackupExecutionProbe is Test {
    address private constant TARGET_BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testRound14BackupExecutionVectors() public view {
        _observe(0);
        _observe(500);
        _observe(1_199);
        _observe(1_200);
        _observe(2_000);
    }

    function _observe(uint256 free) private view {
        (bool success, bytes memory returnData) =
            TARGET_BALANCER.staticcall(abi.encodeCall(IR14Balancer.computeBackupRolloverPolicy, (_state(), free)));
        if (!success) {
            bytes4 selector;
            if (returnData.length >= 4) {
                assembly {
                    selector := mload(add(returnData, 0x20))
                }
            }
            console2.log(
                string.concat(
                    "OBS:R14_BACKUP_REVERT {\"free\":",
                    vm.toString(free),
                    ",\"selector\":\"",
                    vm.toString(bytes32(selector)),
                    "\"}"
                )
            );
            return;
        }
        R14Types.RolloverExecution memory plan = abi.decode(returnData, (R14Types.RolloverExecution));

        console2.log(
            string.concat(
                "OBS:R14_BACKUP_EXEC {\"free\":",
                vm.toString(free),
                ",\"staleUnderlying\":",
                vm.toString(plan.stale.underlyingAmt),
                ",\"staleRows\":",
                vm.toString(plan.stale.trancheAmts.length),
                ",\"depositRows\":",
                vm.toString(plan.freshBondDepositAmts.length),
                ",\"freshRows\":",
                vm.toString(plan.freshSrTrAmts.length),
                ",\"rolled\":",
                vm.toString(plan.underlyingValRolled),
                "}"
            )
        );
        for (uint256 i; i < plan.stale.trancheAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R14_BACKUP_STALE {\"free\":",
                    vm.toString(free),
                    ",\"index\":",
                    vm.toString(i),
                    ",\"token\":\"",
                    vm.toString(plan.stale.trancheAmts[i].token),
                    "\",\"amount\":",
                    vm.toString(plan.stale.trancheAmts[i].amount),
                    "}"
                )
            );
        }
        for (uint256 i; i < plan.freshBondDepositAmts.length; ++i) {
            console2.log(
                string.concat(
                    "OBS:R14_BACKUP_DEPOSIT {\"free\":",
                    vm.toString(free),
                    ",\"bond\":\"",
                    vm.toString(plan.freshBondDepositAmts[i].bondID),
                    "\",\"amount\":",
                    vm.toString(plan.freshBondDepositAmts[i].underlyingAmt),
                    ",\"srAmount\":",
                    vm.toString(plan.freshSrTrAmts[i].amount),
                    "}"
                )
            );
        }
    }

    function _state() private pure returns (R14Types.PerpSrRolloverState memory state) {
        state.staleUnderlyingBal = 100;
        state.totalStaleVal = 600;
        state.staleSrTrs = new R14Types.ReserveTrancheData[](2);
        state.staleSrTrs[0] = _row(bytes32(uint256(11)), address(0x111), 100, 1_000, 200, 500_000_000_000_000_000);
        state.staleSrTrs[1] = _row(bytes32(uint256(12)), address(0x112), 200, 600, 300, 500_000_000_000_000_000);
        state.freshSrTrs = new R14Types.ReserveTrancheData[](2);
        state.freshSrTrs[0] = _row(bytes32(uint256(21)), address(0x121), 1_000, 1, 0, 400_000_000_000_000_000);
        state.freshSrTrs[1] = _row(bytes32(uint256(22)), address(0x122), 2_000, 1, 0, 500_000_000_000_000_000);
    }

    function _row(bytes32 bondID, address token, uint64 maturity, uint256 balance, uint256 value, uint64 valueRatio)
        private
        pure
        returns (R14Types.ReserveTrancheData memory row)
    {
        row.data.trancheSupply = balance;
        row.data.trancheClaim = value;
        row.data.totalClaim = value;
        row.data.underlyingOpenPrice = 2e18;
        row.data.secondsToMaturity = maturity;
        row.data.trancheRatio = 500_000_000_000_000_000;
        row.data.valueRatio = valueRatio;
        row.data.bondID = bondID;
        row.data.isSenior = true;
        row.data.tranche = token;
        row.balance = balance;
        row.value = value;
    }
}
