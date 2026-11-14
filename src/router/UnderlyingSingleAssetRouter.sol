// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IUnderlyingPerpVault} from "../interfaces/IUnderlyingPerpVault.sol";
import {IUnderlyingSingleAssetRouter} from "../interfaces/IUnderlyingSingleAssetRouter.sol";

interface IUnderlyingSingleAssetController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function systemReserveState() external view returns (SystemState memory state);

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee);

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee);
}

/// @notice Converts a single underlying asset into or out of an UnderlyingPerpVault basket.
/// @dev Junior behavior is target-confirmed. Reusing the same side-selecting state machine for a
///      Senior UnderlyingPerpVault is an explicit clean-room product extension.
contract UnderlyingSingleAssetRouter is IUnderlyingSingleAssetRouter {
    using SafeERC20 for IERC20;

    function depositUnderlying(address vault, uint256 underlyingAmtIn, uint256 minNotesOut, uint256 maxIters)
        external
        returns (uint256 notesMinted)
    {
        IUnderlyingPerpVault vault_ = IUnderlyingPerpVault(vault);
        IERC20 underlyingToken = IERC20(vault_.underlying());
        IERC20 perpToken = IERC20(vault_.perp());

        if (underlyingAmtIn != 0) {
            underlyingToken.safeTransferFrom(msg.sender, address(this), underlyingAmtIn);
        }

        for (uint256 i;; ++i) {
            uint256 notesThisPass = _depositPass(vault_, underlyingToken, perpToken);
            notesMinted += notesThisPass;
            if (notesThisPass == 0 || i == maxIters) break;
        }

        if (notesMinted < minNotesOut) revert SlippageTooHigh();
        if (notesMinted != 0) IERC20(vault).safeTransfer(msg.sender, notesMinted);
        _refund(underlyingToken, perpToken, msg.sender);
    }

    function redeemUnderlying(address vault, uint256 notesAmtIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingAmtOut)
    {
        IUnderlyingPerpVault vault_ = IUnderlyingPerpVault(vault);
        IERC20 underlyingToken = IERC20(vault_.underlying());
        IERC20 perpToken = IERC20(vault_.perp());
        address controller = vault_.perpController();

        if (notesAmtIn != 0) IERC20(vault).safeTransferFrom(msg.sender, address(this), notesAmtIn);
        (uint256 directUnderlying, uint256 perpOut) = vault_.redeem(notesAmtIn);

        uint256 flashUnderlying;
        if (perpOut != 0) {
            _approveIfNeeded(perpToken, controller, perpOut);
            if (vault_.isPerpSrVault()) {
                (flashUnderlying,,) = IUnderlyingSingleAssetController(controller).flashRedeem2(perpOut, 0, 0);
            } else {
                (flashUnderlying,,) = IUnderlyingSingleAssetController(controller).flashRedeem2(0, perpOut, 0);
            }
        }

        underlyingAmtOut = directUnderlying + flashUnderlying;
        if (underlyingAmtOut < minUnderlyingOut) revert SlippageTooHigh();
        if (underlyingAmtOut != 0) underlyingToken.safeTransfer(msg.sender, underlyingAmtOut);
        _refund(underlyingToken, perpToken, msg.sender);
    }

    function _depositPass(IUnderlyingPerpVault vault, IERC20 underlyingToken, IERC20 perpToken)
        private
        returns (uint256 notesMinted)
    {
        uint256 underlyingAvailable = underlyingToken.balanceOf(address(this));
        if (underlyingAvailable == 0) return 0;

        uint256 vaultUnderlying = vault.underlyingBalance();
        uint256 vaultPerp = vault.perpBalance();
        address controller = vault.perpController();
        IUnderlyingSingleAssetController.SystemState memory state =
            IUnderlyingSingleAssetController(controller).systemReserveState();
        IUnderlyingSingleAssetController.PerpState memory selected = vault.isPerpSrVault() ? state.perpSr : state.perpJr;

        uint256 vaultPerpValue;
        if (vaultPerp != 0) {
            if (selected.totalSupply == 0) return 0;
            vaultPerpValue = Math.mulDiv(vaultPerp, selected.reserveValue, selected.totalSupply);
        }
        uint256 vaultValue = vaultUnderlying + vaultPerpValue;
        if (vaultValue == 0) return 0;

        uint256 directUnderlying = Math.mulDiv(underlyingAvailable, vaultUnderlying, vaultValue, Math.Rounding.Ceil);
        uint256 flashUnderlying = underlyingAvailable - directUnderlying;
        uint256 perpMinted;
        if (flashUnderlying != 0) {
            _approveIfNeeded(underlyingToken, controller, flashUnderlying);
            if (vault.isPerpSrVault()) {
                (perpMinted,,,) = IUnderlyingSingleAssetController(controller).flashMint2(flashUnderlying, 0, 0, 0);
            } else {
                (, perpMinted,,) = IUnderlyingSingleAssetController(controller).flashMint2(0, flashUnderlying, 0, 0);
            }
        }

        _approveIfNeeded(underlyingToken, address(vault), directUnderlying);
        _approveIfNeeded(perpToken, address(vault), perpMinted);
        notesMinted = vault.deposit(directUnderlying, perpMinted);
    }

    function _approveIfNeeded(IERC20 token, address spender, uint256 amount) private {
        if (amount != 0 && token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    function _refund(IERC20 underlyingToken, IERC20 perpToken, address recipient) private {
        uint256 amount = underlyingToken.balanceOf(address(this));
        if (amount != 0) underlyingToken.safeTransfer(recipient, amount);
        amount = perpToken.balanceOf(address(this));
        if (amount != 0) perpToken.safeTransfer(recipient, amount);
    }
}
