// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";

contract RolloverPlannerTest is Test {
    uint256 private constant WAD = 1e18;
    address private constant MANAGER = address(0xB0D5);

    function testRolloverStateUsesInclusiveStaleBoundaryAndSortsFreshRows() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.ReserveTrancheData[] memory rows = new PerpBalancer.ReserveTrancheData[](5);
        rows[0] = _senior(3, address(0xF3), address(0xA3), 1_500_000, 13, 130, WAD / 2, MANAGER);
        rows[1] = _senior(2, address(0x52), address(0xA2), 604_800, 5, 50, WAD / 2, MANAGER);
        rows[2] = _senior(1, address(0x51), address(0xA1), 1, 7, 70, WAD / 2, MANAGER);
        rows[3] = _senior(4, address(0xF4), address(0xA4), 1_000_000, 11, 110, WAD / 2, MANAGER);
        rows[4] = _senior(5, address(0xEE), address(0xEF), 2, 99, 990, WAD / 2, address(0xDEAD));

        PerpBalancer.PerpSrRolloverState memory state = balancer.computePerpSrRolloverState(
            PerpBalancer.ReserveData({underlyingBal: 3, trancheData: rows}), 604_800, MANAGER
        );

        assertEq(state.staleUnderlyingBal, 3);
        assertEq(state.totalStaleVal, 15);
        assertEq(state.staleSrTrs.length, 2);
        assertEq(state.staleSrTrs[0].data.bondID, bytes32(uint256(1)));
        assertEq(state.staleSrTrs[1].data.bondID, bytes32(uint256(2)));
        assertEq(state.freshSrTrs.length, 2);
        assertEq(state.freshSrTrs[0].data.bondID, bytes32(uint256(4)));
        assertEq(state.freshSrTrs[1].data.bondID, bytes32(uint256(3)));
    }

    function testJrLiquidityFloorsUnlockedValueAndUnpairedSeniorAmount() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state;
        state.staleUnderlyingBal = 20;
        state.totalStaleVal = 1_020;
        state.staleSrTrs = new PerpBalancer.ReserveTrancheData[](1);
        state.staleSrTrs[0] = _senior(1, address(0x51), address(0xA1), 10, 1_000, 1_000, WAD / 2, MANAGER);

        PerpBalancer.ReserveTrancheData[] memory jrRows = new PerpBalancer.ReserveTrancheData[](1);
        jrRows[0] = _junior(1, address(0xA1), address(0x51), 10, 401, 800, 600, MANAGER);
        (uint256 free, uint256 unlocked, uint256[] memory unpaired) = balancer.computePerpJrLiquidity(
            PerpBalancer.ReserveData({underlyingBal: 1_000, trancheData: jrRows}), state, 100
        );

        assertEq(free, 900);
        assertEq(unlocked, 320);
        assertEq(unpaired.length, 1);
        assertEq(unpaired[0], 499);
    }

    function testStandardRolloverPolicyMatchesFirstObservedAllocationVector() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state = _firstObservedState();
        uint256[] memory unpaired = new uint256[](1);

        (uint256 required, PerpBalancer.RolloverExecution memory execution) =
            balancer.computeRolloverPolicy(state, unpaired, 0);

        assertEq(required, 83_656_486);
        assertEq(execution.stale.underlyingAmt, 0);
        assertEq(execution.stale.trancheAmts.length, 1);
        assertEq(execution.stale.trancheAmts[0].amount, 3_133_547_705_520);
        assertEq(execution.freshBondDepositAmts.length, 3);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 0);
        assertEq(execution.freshBondDepositAmts[1].underlyingAmt, 6_411_258);
        assertEq(execution.freshBondDepositAmts[2].underlyingAmt, 77_245_228);
        assertEq(execution.freshSrTrAmts[0].amount, 0);
        assertEq(execution.freshSrTrAmts[1].amount, 3_205_629);
        assertEq(execution.freshSrTrAmts[2].amount, 38_622_614);
        assertEq(execution.underlyingValRolled, 41_875_890);
    }

    function testTopLevelPlannerReturnsStandardAndEvidenceBackedBackupBranch() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state = _firstObservedState();
        PerpBalancer.ReserveData memory srReserves =
            PerpBalancer.ReserveData({underlyingBal: 0, trancheData: _join(state.staleSrTrs, state.freshSrTrs)});
        PerpBalancer.ReserveTrancheData[] memory noJrRows = new PerpBalancer.ReserveTrancheData[](0);

        PerpBalancer.RolloverExecution memory execution = balancer.computePerpSrRolloverPlan(
            srReserves,
            PerpBalancer.ReserveData({underlyingBal: 100_000_000, trancheData: noJrRows}),
            MANAGER,
            604_800,
            0
        );
        assertEq(execution.freshBondDepositAmts[1].underlyingAmt, 6_411_258);
        assertEq(execution.freshBondDepositAmts[2].underlyingAmt, 77_245_228);

        execution = balancer.computePerpSrRolloverPlan(
            srReserves, PerpBalancer.ReserveData({underlyingBal: 1_000_000, trancheData: noJrRows}), MANAGER, 604_800, 0
        );
        assertEq(execution.underlyingValRolled, 500_000);
        assertEq(execution.stale.underlyingAmt, 0);
        assertEq(execution.stale.trancheAmts.length, 1);
        assertEq(execution.stale.trancheAmts[0].token, address(0xB051));
        assertEq(execution.stale.trancheAmts[0].amount, 37_414_699_789);
        assertEq(execution.freshBondDepositAmts.length, 1);
        assertEq(execution.freshBondDepositAmts[0].bondID, bytes32(uint256(21)));
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 1_000_000);
        assertEq(execution.freshSrTrAmts[0].token, address(0xC051));
        assertEq(execution.freshSrTrAmts[0].amount, 500_000);
    }

    function testStandardPolicyUsesCeilingAverageTargetAndStoredValueRatio() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state;
        state.totalStaleVal = 341;
        state.staleSrTrs = new PerpBalancer.ReserveTrancheData[](0);
        state.freshSrTrs = new PerpBalancer.ReserveTrancheData[](3);
        state.freshSrTrs[0] = _senior(1, address(0xC1), address(0xD1), 1, 45, 1, WAD / 2, MANAGER);
        state.freshSrTrs[1] = _senior(2, address(0xC2), address(0xD2), 2, 42, 1, WAD / 2, MANAGER);
        state.freshSrTrs[2] = _senior(3, address(0xC3), address(0xD3), 3, 0, 0, WAD / 2, MANAGER);

        uint256[] memory unpaired = new uint256[](0);
        (uint256 required, PerpBalancer.RolloverExecution memory execution) =
            balancer.computeRolloverPolicy(state, unpaired, 0);

        // ceil((341 + 45 + 42) / 3) = 143; top-ups are 98, 101 and 142.
        assertEq(required, 682);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 196);
        assertEq(execution.freshBondDepositAmts[1].underlyingAmt, 202);
        assertEq(execution.freshBondDepositAmts[2].underlyingAmt, 284);

        state.totalStaleVal = 3;
        state.freshSrTrs = new PerpBalancer.ReserveTrancheData[](1);
        state.freshSrTrs[0] = _senior(4, address(0xC4), address(0xD4), 4, 0, 0, 428_571_428_571_428_571, MANAGER);
        (required, execution) = balancer.computeRolloverPolicy(state, unpaired, 0);
        assertEq(required, 8);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 8);
    }

    function testTopLevelStandardBudgetEqualityAndOneUnitShortfall() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state = _firstObservedState();
        PerpBalancer.ReserveData memory srReserves =
            PerpBalancer.ReserveData({underlyingBal: 0, trancheData: _join(state.staleSrTrs, state.freshSrTrs)});
        PerpBalancer.ReserveTrancheData[] memory jrRows = new PerpBalancer.ReserveTrancheData[](1);
        jrRows[0] = _junior(11, address(0xB0A1), address(0xB051), 604_799, 1, 1, 77_232_982, MANAGER);

        PerpBalancer.RolloverExecution memory execution = balancer.computePerpSrRolloverPlan(
            srReserves, PerpBalancer.ReserveData({underlyingBal: 6_423_504, trancheData: jrRows}), MANAGER, 604_800, 0
        );
        assertEq(execution.underlyingValRolled, 41_875_890);
        assertEq(execution.stale.trancheAmts[0].amount, 3_133_547_705_520);

        execution = balancer.computePerpSrRolloverPlan(
            srReserves, PerpBalancer.ReserveData({underlyingBal: 6_423_503, trancheData: jrRows}), MANAGER, 604_800, 0
        );
        assertEq(execution.underlyingValRolled, 3_211_751);
        assertEq(execution.freshBondDepositAmts.length, 1);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 6_423_503);
    }

    function testBackupPolicyMatchesTargetPartialAndFullExecutionVectors() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.PerpSrRolloverState memory state;
        state.staleUnderlyingBal = 100;
        state.totalStaleVal = 600;
        state.staleSrTrs = new PerpBalancer.ReserveTrancheData[](2);
        state.staleSrTrs[0] = _senior(11, address(0x111), address(0), 100, 200, 1_000, WAD / 2, MANAGER);
        state.staleSrTrs[1] = _senior(12, address(0x112), address(0), 200, 300, 600, WAD / 2, MANAGER);
        state.freshSrTrs = new PerpBalancer.ReserveTrancheData[](2);
        state.freshSrTrs[0] = _senior(21, address(0x121), address(0), 1_000, 0, 1, 0.4e18, MANAGER);
        state.freshSrTrs[1] = _senior(22, address(0x122), address(0), 2_000, 0, 1, 0.5e18, MANAGER);
        state.freshSrTrs[0].data.underlyingOpenPrice = 2e18;
        state.freshSrTrs[1].data.underlyingOpenPrice = 2e18;

        PerpBalancer.RolloverExecution memory execution = balancer.computeBackupRolloverPolicy(state, 500);
        assertEq(execution.stale.underlyingAmt, 100);
        assertEq(execution.stale.trancheAmts.length, 1);
        assertEq(execution.stale.trancheAmts[0].token, address(0x111));
        assertEq(execution.stale.trancheAmts[0].amount, 750);
        assertEq(execution.freshBondDepositAmts[0].bondID, bytes32(uint256(22)));
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 500);
        assertEq(execution.freshSrTrAmts[0].amount, 500);
        assertEq(execution.underlyingValRolled, 250);

        execution = balancer.computeBackupRolloverPolicy(state, 1_199);
        assertEq(execution.stale.underlyingAmt, 100);
        assertEq(execution.stale.trancheAmts.length, 2);
        assertEq(execution.stale.trancheAmts[0].amount, 1_000);
        assertEq(execution.stale.trancheAmts[1].amount, 598);
        assertEq(execution.underlyingValRolled, 599);

        execution = balancer.computeBackupRolloverPolicy(state, 2_000);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 1_200);
        assertEq(execution.underlyingValRolled, 600);
        assertEq(execution.stale.trancheAmts[1].amount, 600);
    }

    function testBackupSelectorUsesReciprocalMultiplierScoreAndFirstTie() public {
        PerpBalancer balancer = new PerpBalancer();
        uint256[6] memory lows = [uint256(0.26e18), 0.3e18, 0.35e18, 0.4e18, 0.45e18, 0.49e18];
        uint256[6] memory highs = [uint256(0.5e18), 0.55e18, 0.6e18, 0.7e18, 0.8e18, 0.95e18];

        for (uint256 i; i < lows.length; ++i) {
            for (uint256 j; j < highs.length; ++j) {
                _assertBackupSelection(balancer, lows[i], highs[j], false);
                _assertBackupSelection(balancer, lows[i], highs[j], true);
            }
        }
    }

    function _assertBackupSelection(PerpBalancer balancer, uint256 low, uint256 high, bool reversed) private pure {
        PerpBalancer.PerpSrRolloverState memory state;
        state.staleUnderlyingBal = 1;
        state.totalStaleVal = 1;
        state.staleSrTrs = new PerpBalancer.ReserveTrancheData[](0);
        state.freshSrTrs = new PerpBalancer.ReserveTrancheData[](2);
        state.freshSrTrs[0] = _senior(1, address(0x101), address(0), 1, 0, 1, low, MANAGER);
        state.freshSrTrs[1] = _senior(2, address(0x102), address(0), 2, 0, 1, high, MANAGER);
        if (reversed) (state.freshSrTrs[0], state.freshSrTrs[1]) = (state.freshSrTrs[1], state.freshSrTrs[0]);

        uint256 lowMultiplier = Math.mulDiv(WAD, WAD, low);
        uint256 highMultiplier = Math.mulDiv(WAD, WAD, high);
        uint256 lowScore = lowMultiplier >= 2 * WAD ? lowMultiplier - 2 * WAD : 2 * WAD - lowMultiplier;
        uint256 highScore = highMultiplier >= 2 * WAD ? highMultiplier - 2 * WAD : 2 * WAD - highMultiplier;
        bytes32 expected = lowScore < highScore
            ? bytes32(uint256(1))
            : highScore < lowScore ? bytes32(uint256(2)) : reversed ? bytes32(uint256(2)) : bytes32(uint256(1));
        PerpBalancer.RolloverExecution memory execution = balancer.computeBackupRolloverPolicy(state, 1);
        assertEq(execution.freshBondDepositAmts[0].bondID, expected);
    }

    function _firstObservedState() private pure returns (PerpBalancer.PerpSrRolloverState memory state) {
        state.staleSrTrs = new PerpBalancer.ReserveTrancheData[](1);
        state.staleSrTrs[0] =
            _senior(11, address(0xB051), address(0xB0A1), 604_799, 41_875_890, 3_133_547_705_520, WAD / 2, MANAGER);
        state.totalStaleVal = 41_875_890;
        state.freshSrTrs = new PerpBalancer.ReserveTrancheData[](3);
        state.freshSrTrs[0] = _senior(21, address(0xC051), address(0xC0A1), 1_209_599, 45_338_138, 1, WAD / 2, MANAGER);
        state.freshSrTrs[1] =
            _senior(22, address(0xA051), address(0xA0A1), 1_814_399, 42_084_862, 1, 507_431_799_242_465_803, MANAGER);
        state.freshSrTrs[2] = _senior(23, address(0xD051), address(0xD0A1), 2_419_199, 0, 0, WAD / 2, MANAGER);
    }

    function _join(PerpBalancer.ReserveTrancheData[] memory left, PerpBalancer.ReserveTrancheData[] memory right)
        private
        pure
        returns (PerpBalancer.ReserveTrancheData[] memory rows)
    {
        rows = new PerpBalancer.ReserveTrancheData[](left.length + right.length);
        for (uint256 i; i < left.length; ++i) {
            rows[i] = left[i];
        }
        for (uint256 i; i < right.length; ++i) {
            rows[left.length + i] = right[i];
        }
    }

    function _senior(
        uint256 bond,
        address token,
        address counterpart,
        uint64 maturity,
        uint256 value,
        uint256 balance,
        uint256 valueRatio,
        address manager
    ) private pure returns (PerpBalancer.ReserveTrancheData memory row) {
        row.data = IBondsManager.TrancheData({
            trancheSupply: balance,
            trancheClaim: value,
            totalClaim: value * 2,
            volatilityMultiplier: WAD,
            underlyingOpenPrice: WAD,
            isMature: false,
            secondsToMaturity: maturity,
            trancheRatio: uint64(WAD / 2),
            valueRatio: uint64(valueRatio),
            bondID: bytes32(bond),
            isSenior: true,
            tranche: token,
            counterpart: counterpart,
            manager: manager
        });
        row.balance = balance;
        row.value = value;
    }

    function _junior(
        uint256 bond,
        address token,
        address counterpart,
        uint64 maturity,
        uint256 balance,
        uint256 supply,
        uint256 totalClaim,
        address manager
    ) private pure returns (PerpBalancer.ReserveTrancheData memory row) {
        row.data = IBondsManager.TrancheData({
            trancheSupply: supply,
            trancheClaim: totalClaim,
            totalClaim: totalClaim,
            volatilityMultiplier: WAD,
            underlyingOpenPrice: WAD,
            isMature: false,
            secondsToMaturity: maturity,
            trancheRatio: uint64(WAD / 2),
            valueRatio: uint64(WAD / 2),
            bondID: bytes32(bond),
            isSenior: false,
            tranche: token,
            counterpart: counterpart,
            manager: manager
        });
        row.balance = balance;
        row.value = totalClaim;
    }
}
