// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";

contract PerpBalancer {
    error InsufficientRebalance();
    error InvalidInitialization();
    error InvalidRolloverData();
    error LengthMismatch();
    error NotInitializing();

    event Initialized(uint64 version);

    struct ReserveTrancheData {
        IBondsManager.TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
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

    function computeSystemRebalancePlan(ReserveData memory reserves, uint256 rebalVal)
        external
        pure
        returns (ReserveAmounts memory plan)
    {
        if (rebalVal == 0) return plan;
        uint256 available = reserves.underlyingBal;
        uint256 count = reserves.trancheData.length;
        for (uint256 i; i < count; ++i) {
            available += reserves.trancheData[i].value;
        }
        if (available < rebalVal) revert InsufficientRebalance();

        plan.underlyingAmt = reserves.underlyingBal < rebalVal ? reserves.underlyingBal : rebalVal;
        uint256 remaining = rebalVal - plan.underlyingAmt;
        uint256[] memory order = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            order[i] = i;
        }
        for (uint256 i = 1; i < count; ++i) {
            uint256 key = order[i];
            uint256 j = i;
            while (
                j != 0
                    && reserves.trancheData[order[j - 1]].data.secondsToMaturity
                        > reserves.trancheData[key].data.secondsToMaturity
            ) {
                order[j] = order[j - 1];
                unchecked {
                    --j;
                }
            }
            order[j] = key;
        }

        TokenAmount[] memory amounts = new TokenAmount[](count);
        uint256 used;
        for (uint256 i; i < count && remaining != 0; ++i) {
            ReserveTrancheData memory tranche = reserves.trancheData[order[i]];
            if (tranche.value == 0) continue;
            uint256 amount;
            if (tranche.value <= remaining) {
                amount = tranche.balance;
                remaining -= tranche.value;
            } else {
                amount = Math.mulDiv(tranche.balance, remaining, tranche.value);
                remaining = 0;
            }
            if (amount != 0) {
                amounts[used++] = TokenAmount(tranche.data.tranche, amount);
            }
        }
        TokenAmount[] memory trimmed = new TokenAmount[](used);
        for (uint256 i; i < used; ++i) {
            trimmed[i] = amounts[i];
        }
        plan.trancheAmts = trimmed;
    }

    /// @dev Evidence-backed standard and backup rollover planner.
    function computePerpSrRolloverPlan(
        ReserveData memory perpSrReserveData,
        ReserveData memory perpJrReserveData,
        address bondsManager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external pure returns (RolloverExecution memory execution) {
        PerpSrRolloverState memory state = computePerpSrRolloverState(perpSrReserveData, minMaturitySec, bondsManager);
        if (state.totalStaleVal == 0 || state.freshSrTrs.length == 0) return execution;

        (uint256 free, uint256 unlocked, uint256[] memory unpaired) =
            computePerpJrLiquidity(perpJrReserveData, state, reservedPerpJrLiquidity);
        (uint256 required, RolloverExecution memory standard) = computeRolloverPolicy(state, unpaired, free + unlocked);
        return required <= free + unlocked ? standard : computeBackupRolloverPolicy(state, free);
    }

    function computePerpSrRolloverState(ReserveData memory reserves, uint32 minMaturitySec, address bondsManager)
        public
        pure
        returns (PerpSrRolloverState memory state)
    {
        state.staleUnderlyingBal = reserves.underlyingBal;
        state.totalStaleVal = reserves.underlyingBal;

        uint256 staleCount;
        uint256 freshCount;
        for (uint256 i; i < reserves.trancheData.length; ++i) {
            ReserveTrancheData memory item = reserves.trancheData[i];
            if (item.data.manager != bondsManager || !item.data.isSenior) continue;
            if (item.data.secondsToMaturity <= minMaturitySec) ++staleCount;
            else ++freshCount;
        }

        state.staleSrTrs = new ReserveTrancheData[](staleCount);
        state.freshSrTrs = new ReserveTrancheData[](freshCount);
        uint256 staleIndex;
        uint256 freshIndex;
        for (uint256 i; i < reserves.trancheData.length; ++i) {
            ReserveTrancheData memory item = reserves.trancheData[i];
            if (item.data.manager != bondsManager || !item.data.isSenior) continue;
            if (item.data.secondsToMaturity <= minMaturitySec) {
                state.staleSrTrs[staleIndex++] = item;
                state.totalStaleVal += item.value;
            } else {
                state.freshSrTrs[freshIndex++] = item;
            }
        }
        _sortByMaturity(state.staleSrTrs);
        _sortByMaturity(state.freshSrTrs);
    }

    function computePerpJrLiquidity(
        ReserveData memory perpJrReserves,
        PerpSrRolloverState memory rolloverState,
        uint256 reservedPerpJrLiquidity
    ) public pure returns (uint256 freePerpJrLiquidity, uint256 unlockedPerpJrLiquidity, uint256[] memory unpaired) {
        freePerpJrLiquidity = perpJrReserves.underlyingBal > reservedPerpJrLiquidity
            ? perpJrReserves.underlyingBal - reservedPerpJrLiquidity
            : 0;
        unlockedPerpJrLiquidity = rolloverState.staleUnderlyingBal;
        unpaired = new uint256[](rolloverState.staleSrTrs.length);

        for (uint256 i; i < rolloverState.staleSrTrs.length; ++i) {
            ReserveTrancheData memory sr = rolloverState.staleSrTrs[i];
            unpaired[i] = sr.balance;
            for (uint256 j; j < perpJrReserves.trancheData.length; ++j) {
                ReserveTrancheData memory jr = perpJrReserves.trancheData[j];
                if (jr.data.bondID != sr.data.bondID || jr.data.isSenior) continue;
                if (jr.data.trancheSupply == 0 || sr.data.trancheSupply == 0) break;

                unlockedPerpJrLiquidity += Math.mulDiv(jr.balance, jr.data.totalClaim, jr.data.trancheSupply);
                uint256 pairedSr = Math.mulDiv(jr.balance, sr.data.trancheSupply, jr.data.trancheSupply);
                unpaired[i] = sr.balance > pairedSr ? sr.balance - pairedSr : 0;
                break;
            }
        }
    }

    function computeRolloverPolicy(
        PerpSrRolloverState memory rolloverState,
        uint256[] memory unpairedStaleSrTrAmts,
        uint256
    ) public pure returns (uint256 underlyingAmtToDeploy, RolloverExecution memory execution) {
        if (unpairedStaleSrTrAmts.length != rolloverState.staleSrTrs.length) revert LengthMismatch();
        uint256 freshCount = rolloverState.freshSrTrs.length;
        if (rolloverState.totalStaleVal == 0 || freshCount == 0) return (0, execution);

        execution.stale.underlyingAmt = rolloverState.staleUnderlyingBal;
        execution.stale.trancheAmts = new TokenAmount[](rolloverState.staleSrTrs.length);
        for (uint256 i; i < rolloverState.staleSrTrs.length; ++i) {
            ReserveTrancheData memory stale = rolloverState.staleSrTrs[i];
            uint256 excluded = unpairedStaleSrTrAmts[i] < stale.balance ? unpairedStaleSrTrAmts[i] : stale.balance;
            execution.stale.trancheAmts[i] = TokenAmount(stale.data.tranche, stale.balance - excluded);
        }

        execution.freshBondDepositAmts = new BondDepositParams[](freshCount);
        execution.freshSrTrAmts = new TokenAmount[](freshCount);
        uint256 valueSum = rolloverState.totalStaleVal;
        uint256 maxNonLatest;
        for (uint256 i; i < freshCount; ++i) {
            valueSum += rolloverState.freshSrTrs[i].value;
            if (i + 1 < freshCount && rolloverState.freshSrTrs[i].value > maxNonLatest) {
                maxNonLatest = rolloverState.freshSrTrs[i].value;
            }
        }
        uint256 averageTarget = Math.ceilDiv(valueSum, freshCount);
        uint256 target = averageTarget > maxNonLatest ? averageTarget : maxNonLatest;

        uint256 remaining = rolloverState.totalStaleVal;
        for (uint256 i; i < freshCount; ++i) {
            ReserveTrancheData memory fresh = rolloverState.freshSrTrs[i];
            uint256 topUp;
            if (i + 1 == freshCount) {
                topUp = remaining;
            } else if (target > fresh.value) {
                uint256 gap = target - fresh.value;
                topUp = gap < remaining ? gap : remaining;
            }
            remaining -= topUp;

            uint256 depositAmt;
            if (topUp != 0) {
                if (fresh.data.valueRatio == 0) revert InvalidRolloverData();
                depositAmt = Math.mulDiv(topUp, 1e18, fresh.data.valueRatio, Math.Rounding.Ceil);
            }
            underlyingAmtToDeploy += depositAmt;
            execution.freshBondDepositAmts[i] = BondDepositParams(fresh.data.bondID, depositAmt);

            uint256 totalTranche = Math.mulDiv(depositAmt, fresh.data.underlyingOpenPrice, 1e18);
            uint256 seniorAmount = Math.mulDiv(totalTranche, fresh.data.trancheRatio, 1e18);
            execution.freshSrTrAmts[i] = TokenAmount(fresh.data.tranche, seniorAmount);
        }
        execution.underlyingValRolled = rolloverState.totalStaleVal;
    }

    function computeBackupRolloverPolicy(PerpSrRolloverState memory state, uint256 underlyingAvailable)
        public
        pure
        returns (RolloverExecution memory execution)
    {
        uint256 freshCount = state.freshSrTrs.length;
        if (freshCount == 0) return execution;

        uint256 selected;
        uint256 bestScore = type(uint256).max;
        for (uint256 i; i < freshCount; ++i) {
            uint256 ratio = state.freshSrTrs[i].data.valueRatio;
            if (ratio == 0) revert InvalidRolloverData();
            uint256 multiplier = Math.mulDiv(1e18, 1e18, ratio);
            uint256 score = multiplier >= 2e18 ? multiplier - 2e18 : 2e18 - multiplier;
            if (score < bestScore) {
                bestScore = score;
                selected = i;
            }
        }

        ReserveTrancheData memory fresh = state.freshSrTrs[selected];
        uint256 maxDeposit = Math.mulDiv(state.totalStaleVal, 1e18, fresh.data.valueRatio);
        uint256 deposit = underlyingAvailable < maxDeposit ? underlyingAvailable : maxDeposit;
        uint256 rolled = Math.mulDiv(deposit, fresh.data.valueRatio, 1e18);

        execution.stale.underlyingAmt = state.staleUnderlyingBal < rolled ? state.staleUnderlyingBal : rolled;
        uint256 remaining = rolled - execution.stale.underlyingAmt;
        TokenAmount[] memory staleAmounts = new TokenAmount[](state.staleSrTrs.length);
        uint256 used;
        for (uint256 i; i < state.staleSrTrs.length && remaining != 0; ++i) {
            ReserveTrancheData memory stale = state.staleSrTrs[i];
            if (stale.value == 0) continue;
            uint256 amount;
            if (stale.value <= remaining) {
                amount = stale.balance;
                remaining -= stale.value;
            } else {
                amount = Math.mulDiv(stale.balance, remaining, stale.value);
                remaining = 0;
            }
            if (amount != 0) staleAmounts[used++] = TokenAmount(stale.data.tranche, amount);
        }
        execution.stale.trancheAmts = new TokenAmount[](used);
        for (uint256 i; i < used; ++i) {
            execution.stale.trancheAmts[i] = staleAmounts[i];
        }

        execution.freshBondDepositAmts = new BondDepositParams[](1);
        execution.freshBondDepositAmts[0] = BondDepositParams(fresh.data.bondID, deposit);
        execution.freshSrTrAmts = new TokenAmount[](1);
        uint256 totalTranche = Math.mulDiv(deposit, fresh.data.underlyingOpenPrice, 1e18);
        uint256 seniorAmount = Math.mulDiv(totalTranche, fresh.data.trancheRatio, 1e18);
        execution.freshSrTrAmts[0] = TokenAmount(fresh.data.tranche, seniorAmount);
        execution.underlyingValRolled = rolled;
    }

    function _sortByMaturity(ReserveTrancheData[] memory rows) private pure {
        for (uint256 i = 1; i < rows.length; ++i) {
            ReserveTrancheData memory key = rows[i];
            uint256 j = i;
            while (j != 0 && rows[j - 1].data.secondsToMaturity > key.data.secondsToMaturity) {
                rows[j] = rows[j - 1];
                unchecked {
                    --j;
                }
            }
            rows[j] = key;
        }
    }
}
