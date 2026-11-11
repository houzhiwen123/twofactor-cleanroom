// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PerpBalancer} from "./PerpBalancer.sol";

/// @notice Stateless arithmetic used by PerpController. This contract never holds assets or
/// protocol state and is deployed as an immutable dependency of each Controller implementation.
contract PerpMath {
    uint256 private constant WAD = 1e18;

    error ValueCapExceeded();
    error ZeroSupply();

    function proRataMintShares(
        uint256 srInput,
        uint256 jrInput,
        uint256 srSupply,
        uint256 jrSupply,
        uint256 srReserveValue,
        uint256 jrReserveValue
    ) external pure returns (uint256 srShares, uint256 jrShares) {
        if (srInput != 0) {
            if (srSupply == 0 || srReserveValue == 0) revert ZeroSupply();
            srShares = Math.mulDiv(srInput, srSupply, srReserveValue);
        }
        if (jrInput != 0) {
            if (jrSupply == 0 || jrReserveValue == 0) revert ZeroSupply();
            jrShares = Math.mulDiv(jrInput, jrSupply, jrReserveValue);
        }
    }

    function trancheMintShares(
        uint256 srInput,
        uint256 jrInput,
        uint256 srValue,
        uint256 jrValue,
        uint256 srSupply,
        uint256 jrSupply,
        uint256 srReserveValue,
        uint256 jrReserveValue
    ) external pure returns (uint256 srShares, uint256 jrShares, bool genesis) {
        genesis = srSupply == 0 || jrSupply == 0;
        if (genesis) {
            if (
                srSupply != 0 || jrSupply != 0 || srReserveValue != 0 || jrReserveValue != 0 || srInput == 0
                    || jrInput == 0
            ) revert ZeroSupply();
            return (srInput, jrInput, true);
        }
        if ((srInput != 0 && srReserveValue == 0) || (jrInput != 0 && jrReserveValue == 0)) {
            revert ZeroSupply();
        }
        if (srInput != 0) srShares = Math.mulDiv(srValue, srSupply, srReserveValue);
        if (jrInput != 0) jrShares = Math.mulDiv(jrValue, jrSupply, jrReserveValue);
    }

    function reserveState(PerpBalancer.ReserveData calldata rd)
        external
        pure
        returns (uint256 reserveValue, uint256 vm)
    {
        reserveValue = rd.underlyingBal;
        uint256 vmValue = rd.underlyingBal * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData calldata item = rd.trancheData[i];
            reserveValue += item.value;
            vmValue += item.value * item.data.volatilityMultiplier;
        }
        vm = reserveValue == 0 ? 0 : vmValue / reserveValue;
    }

    function stateAfterDeposit(
        uint256 preTotalSupply,
        uint256 preReserveValue,
        PerpBalancer.ReserveData calldata rd,
        uint256 value,
        uint256 depositVm,
        uint256 shares
    ) external pure returns (uint256 totalSupply, uint256 reserveValue, uint256 vm) {
        totalSupply = preTotalSupply + shares;
        reserveValue = preReserveValue + value;
        if (reserveValue == 0) return (totalSupply, 0, 0);

        uint256 vmValue = rd.underlyingBal * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            vmValue += rd.trancheData[i].value * rd.trancheData[i].data.volatilityMultiplier;
        }
        vmValue += value * depositVm;
        vm = vmValue / reserveValue;
    }

    function stateAfterWithdrawal(
        uint256 preTotalSupply,
        uint256 preReserveValue,
        uint256 preVm,
        PerpBalancer.ReserveData calldata rd,
        uint256 shares,
        uint256 valueOut,
        bool proportionalBasket
    ) external pure returns (uint256 totalSupply, uint256 reserveValue, uint256 vm) {
        totalSupply = preTotalSupply - shares;
        reserveValue = preReserveValue - valueOut;
        if (proportionalBasket) return (totalSupply, reserveValue, preVm);
        if (reserveValue == 0) return (totalSupply, 0, 0);

        uint256 underlyingAfter = rd.underlyingBal > valueOut ? rd.underlyingBal - valueOut : 0;
        uint256 vmValue = underlyingAfter * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            vmValue += rd.trancheData[i].value * rd.trancheData[i].data.volatilityMultiplier;
        }
        vm = vmValue / reserveValue;
    }

    function redeemBasket(PerpBalancer.ReserveData calldata rd, uint256 netShares, uint256 supply)
        external
        pure
        returns (PerpBalancer.ReserveAmounts memory amounts)
    {
        amounts.trancheAmts = new PerpBalancer.TokenAmount[](rd.trancheData.length);
        if (netShares == 0) {
            for (uint256 i; i < rd.trancheData.length; ++i) {
                amounts.trancheAmts[i].token = rd.trancheData[i].data.tranche;
            }
            return amounts;
        }
        if (supply == 0) revert ZeroSupply();
        amounts.underlyingAmt = Math.mulDiv(rd.underlyingBal, netShares, supply);
        for (uint256 i; i < rd.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData calldata tranche = rd.trancheData[i];
            amounts.trancheAmts[i] =
                PerpBalancer.TokenAmount(tranche.data.tranche, Math.mulDiv(tranche.balance, netShares, supply));
        }
    }

    function basketValue(PerpBalancer.ReserveData calldata rd, PerpBalancer.ReserveAmounts calldata amounts)
        external
        pure
        returns (uint256 value)
    {
        value = amounts.underlyingAmt;
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            if (amounts.trancheAmts[i].amount == 0) continue;
            for (uint256 j; j < rd.trancheData.length; ++j) {
                if (amounts.trancheAmts[i].token == rd.trancheData[j].data.tranche) {
                    if (rd.trancheData[j].data.trancheSupply == 0) revert ZeroSupply();
                    value += Math.mulDiv(
                        amounts.trancheAmts[i].amount,
                        rd.trancheData[j].data.trancheClaim,
                        rd.trancheData[j].data.trancheSupply
                    );
                    break;
                }
            }
        }
    }

    function checkValueCap(
        uint256 preSr,
        uint256 preJr,
        uint256 postSr,
        uint256 postJr,
        uint256 valueCap,
        uint256 srInput,
        uint256 jrInput,
        uint256 targetSystemRatio
    ) external pure {
        if (preSr + preJr <= valueCap && postSr + postJr <= valueCap) return;
        if (srInput != 0 && jrInput != 0) revert ValueCapExceeded();
        uint256 preSub = _subDr(preSr, preJr, targetSystemRatio);
        uint256 postSub = _subDr(postSr, postJr, targetSystemRatio);
        if (preSub > WAD) {
            if (srInput == 0 || postSub > preSub || postSub < WAD) revert ValueCapExceeded();
        } else if (preSub < WAD) {
            if (jrInput == 0 || postSub < preSub || postSub > WAD) revert ValueCapExceeded();
        } else {
            revert ValueCapExceeded();
        }
    }

    function _subDr(uint256 srValue, uint256 jrValue, uint256 targetSystemRatio) private pure returns (uint256) {
        if (srValue == 0) return type(uint120).max;
        if (jrValue == 0) return 0;
        return Math.mulDiv(jrValue, 1e36, srValue * targetSystemRatio);
    }
}
