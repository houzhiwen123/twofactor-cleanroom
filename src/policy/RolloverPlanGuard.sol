// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PerpBalancer} from "./PerpBalancer.sol";

/// @notice Stateless clean-room safety wrapper for Controller planning calls.
/// @dev This is BNB-DESIGN / CLEANROOM SAFETY, not a claim about target-visible validation.
/// The canonical planner and BondsManager are immutable; governance upgrades by deploying a new
/// guard and explicitly updating the Controller's balancer address.
contract RolloverPlanGuard {
    error InvalidPlanner();
    error InvalidBondsManager();
    error InvalidPlan();

    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_TRANCHES = 50;

    address public immutable planner;
    address public immutable bondsManager;

    constructor(address planner_, address bondsManager_) {
        if (planner_.code.length == 0) revert InvalidPlanner();
        if (bondsManager_.code.length == 0) revert InvalidBondsManager();
        planner = planner_;
        bondsManager = bondsManager_;
    }

    function computeSystemRebalancePlan(PerpBalancer.ReserveData memory reserves, uint256 rebalanceValue)
        external
        view
        returns (PerpBalancer.ReserveAmounts memory plan)
    {
        plan = PerpBalancer(planner).computeSystemRebalancePlan(reserves, rebalanceValue);
        _validateReserveOutflow(reserves, plan);
    }

    function computePerpSrRolloverPlan(
        PerpBalancer.ReserveData memory srReserves,
        PerpBalancer.ReserveData memory jrReserves,
        address manager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external view returns (PerpBalancer.RolloverExecution memory execution) {
        if (manager != bondsManager) revert InvalidBondsManager();
        execution = PerpBalancer(planner)
            .computePerpSrRolloverPlan(srReserves, jrReserves, manager, minMaturitySec, reservedPerpJrLiquidity);
        _validateRollover(srReserves, jrReserves, minMaturitySec, reservedPerpJrLiquidity, execution);
    }

    function _validateRollover(
        PerpBalancer.ReserveData memory srReserves,
        PerpBalancer.ReserveData memory jrReserves,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity,
        PerpBalancer.RolloverExecution memory execution
    ) private view {
        if (
            srReserves.trancheData.length > MAX_TRANCHES || jrReserves.trancheData.length > MAX_TRANCHES
                || execution.stale.trancheAmts.length > MAX_TRANCHES
                || execution.freshBondDepositAmts.length != execution.freshSrTrAmts.length
                || execution.freshSrTrAmts.length > MAX_TRANCHES
        ) revert InvalidPlan();
        if (execution.stale.underlyingAmt > srReserves.underlyingBal) revert InvalidPlan();

        uint256 totalStaleValue = srReserves.underlyingBal;
        for (uint256 i; i < srReserves.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData memory row = srReserves.trancheData[i];
            if (row.data.manager == bondsManager && row.data.isSenior && row.data.secondsToMaturity <= minMaturitySec) {
                totalStaleValue += row.value;
            }
        }
        if (execution.underlyingValRolled > totalStaleValue) revert InvalidPlan();

        for (uint256 i; i < execution.stale.trancheAmts.length; ++i) {
            PerpBalancer.TokenAmount memory item = execution.stale.trancheAmts[i];
            _requireUniqueToken(execution.stale.trancheAmts, i, item.token);
            (bool found, PerpBalancer.ReserveTrancheData memory row) = _findReserve(srReserves, item.token);
            if (
                !found || row.data.manager != bondsManager || !row.data.isSenior
                    || row.data.secondsToMaturity > minMaturitySec || item.amount > row.balance
            ) revert InvalidPlan();
        }

        uint256 depositsTotal;
        for (uint256 i; i < execution.freshBondDepositAmts.length; ++i) {
            PerpBalancer.BondDepositParams memory deposit = execution.freshBondDepositAmts[i];
            PerpBalancer.TokenAmount memory srOut = execution.freshSrTrAmts[i];
            _requireUniqueToken(execution.freshSrTrAmts, i, srOut.token);
            (bool found, PerpBalancer.ReserveTrancheData memory row) = _findReserve(srReserves, srOut.token);
            if (
                !found || row.data.manager != bondsManager || !row.data.isSenior
                    || row.data.secondsToMaturity <= minMaturitySec || row.data.bondID != deposit.bondID
            ) revert InvalidPlan();

            uint256 trancheAmount = Math.mulDiv(deposit.underlyingAmt, row.data.underlyingOpenPrice, WAD);
            uint256 expectedSenior = Math.mulDiv(trancheAmount, row.data.trancheRatio, WAD);
            if (srOut.amount != expectedSenior) revert InvalidPlan();
            depositsTotal += deposit.underlyingAmt;
        }

        (uint256 free, uint256 unlocked) = _jrLiquidity(srReserves, jrReserves, minMaturitySec, reservedPerpJrLiquidity);
        if (depositsTotal > free + unlocked) revert InvalidPlan();
    }

    function _validateReserveOutflow(PerpBalancer.ReserveData memory reserves, PerpBalancer.ReserveAmounts memory plan)
        private
        pure
    {
        if (reserves.trancheData.length > MAX_TRANCHES || plan.trancheAmts.length > MAX_TRANCHES) {
            revert InvalidPlan();
        }
        if (plan.underlyingAmt > reserves.underlyingBal) revert InvalidPlan();
        for (uint256 i; i < plan.trancheAmts.length; ++i) {
            PerpBalancer.TokenAmount memory item = plan.trancheAmts[i];
            _requireUniqueToken(plan.trancheAmts, i, item.token);
            (bool found, PerpBalancer.ReserveTrancheData memory row) = _findReserve(reserves, item.token);
            if (!found || item.amount > row.balance) revert InvalidPlan();
        }
    }

    function _jrLiquidity(
        PerpBalancer.ReserveData memory srReserves,
        PerpBalancer.ReserveData memory jrReserves,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) private view returns (uint256 free, uint256 unlocked) {
        free = jrReserves.underlyingBal > reservedPerpJrLiquidity
            ? jrReserves.underlyingBal - reservedPerpJrLiquidity
            : 0;
        unlocked = srReserves.underlyingBal;

        for (uint256 i; i < srReserves.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData memory sr = srReserves.trancheData[i];
            if (sr.data.manager != bondsManager || !sr.data.isSenior || sr.data.secondsToMaturity > minMaturitySec) {
                continue;
            }
            for (uint256 j; j < jrReserves.trancheData.length; ++j) {
                PerpBalancer.ReserveTrancheData memory jr = jrReserves.trancheData[j];
                if (jr.data.bondID != sr.data.bondID || jr.data.isSenior) continue;
                if (jr.data.trancheSupply != 0) {
                    unlocked += Math.mulDiv(jr.balance, jr.data.totalClaim, jr.data.trancheSupply);
                }
                break;
            }
        }
    }

    function _findReserve(PerpBalancer.ReserveData memory reserves, address token)
        private
        pure
        returns (bool found, PerpBalancer.ReserveTrancheData memory row)
    {
        for (uint256 i; i < reserves.trancheData.length; ++i) {
            if (reserves.trancheData[i].data.tranche == token) return (true, reserves.trancheData[i]);
        }
    }

    function _requireUniqueToken(PerpBalancer.TokenAmount[] memory rows, uint256 index, address token) private pure {
        if (token == address(0)) revert InvalidPlan();
        for (uint256 i; i < index; ++i) {
            if (rows[i].token == token) revert InvalidPlan();
        }
    }
}
