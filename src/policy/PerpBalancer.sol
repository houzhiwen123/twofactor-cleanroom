// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";

contract PerpBalancer {
    error InsufficientRebalance();
    error InvalidInitialization();
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

    function computeSystemRebalancePlan(ReserveData memory reserves, uint256 rebalVal)
        external
        pure
        returns (ReserveAmounts memory plan)
    {
        if (rebalVal == 0) return plan;
        uint256 available = reserves.underlyingBal;
        uint256 count = reserves.trancheData.length;
        for (uint256 i; i < count; ++i) available += reserves.trancheData[i].value;
        if (available < rebalVal) revert InsufficientRebalance();

        plan.underlyingAmt = reserves.underlyingBal < rebalVal ? reserves.underlyingBal : rebalVal;
        uint256 remaining = rebalVal - plan.underlyingAmt;
        uint256[] memory order = new uint256[](count);
        for (uint256 i; i < count; ++i) order[i] = i;
        for (uint256 i = 1; i < count; ++i) {
            uint256 key = order[i];
            uint256 j = i;
            while (j != 0 && reserves.trancheData[order[j - 1]].data.secondsToMaturity
                > reserves.trancheData[key].data.secondsToMaturity)
            {
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
        for (uint256 i; i < used; ++i) trimmed[i] = amounts[i];
        plan.trancheAmts = trimmed;
    }
}
