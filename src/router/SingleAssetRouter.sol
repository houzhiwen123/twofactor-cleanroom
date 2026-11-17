// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDexStrategy} from "../interfaces/IDexStrategy.sol";
import {IPerpToken} from "../interfaces/IPerpToken.sol";
import {ISingleAssetRouter} from "../interfaces/ISingleAssetRouter.sol";
import {PerpBalancer} from "../policy/PerpBalancer.sol";

interface ISingleAssetUsdVault is IERC20 {
    function usd() external view returns (address);
    function underlying() external view returns (address);
    function perpSr() external view returns (address);
    function perpController() external view returns (address);
    function usdUnitAmt() external view returns (uint256);
    function underlyingUnitAmt() external view returns (uint256);
    function usdBalance() external view returns (uint256);
    function perpSrBalance() external view returns (uint256);
    function deposit(uint256 usdMax, uint256 perpSrMax) external returns (uint256 notesMinted);
    function redeem(uint256 notesAmt) external returns (uint256 usdAmtOut, uint256 perpSrAmtOut);
    function upkeep() external;
}

interface ISingleAssetController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    function flashMint2(
        uint256 underlyingAmtIntoPerpSr,
        uint256 underlyingAmtIntoPerpJr,
        uint256 minPerpSrAmtOut,
        uint256 minPerpJrAmtOut
    )
        external
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);

    function flashRedeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minUnderlyingAmtOut)
        external
        returns (uint256 underlyingAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
}

/// @notice Stateless single-asset entry point for the USD/Perp-SR Vault.
/// @dev The two selectors, rounding order and optional health/upkeep flags follow target fork evidence.
contract SingleAssetRouter is ISingleAssetRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidReserveState();

    uint256 private constant WAD = 1e18;
    bytes4 private constant UNHEALTHY_SELECTOR = 0xc9f488c6;

    function depositUsd(
        address vault,
        address strategy,
        uint256 usdMax,
        uint256 minNotes,
        uint256 maxIters,
        bool healthCheck
    ) external nonReentrant returns (uint256 notesOut) {
        _checkHealth(strategy, healthCheck);
        if (usdMax == 0) return 0;

        ISingleAssetUsdVault vault_ = ISingleAssetUsdVault(vault);
        IERC20 usdToken = IERC20(vault_.usd());
        IERC20 underlyingToken = IERC20(vault_.underlying());
        IERC20 perpToken = IERC20(vault_.perpSr());

        usdToken.safeTransferFrom(msg.sender, address(this), usdMax);
        _approveIfNeeded(usdToken, strategy, usdMax);

        for (uint256 i;; ++i) {
            notesOut += _depositPass(vault_, IDexStrategy(strategy), usdToken, underlyingToken, perpToken);
            if (i == maxIters) break;
        }

        if (notesOut < minNotes) revert SlippageTooHigh();
        IERC20(vault).safeTransfer(msg.sender, notesOut);
        _refund(usdToken, underlyingToken, perpToken, msg.sender);
    }

    function redeemUsd(
        address vault,
        address strategy,
        uint256 notesIn,
        uint256 minUsdOut,
        bool runUpkeep,
        bool healthCheck
    ) external nonReentrant returns (uint256 usdOut) {
        _checkHealth(strategy, healthCheck);
        ISingleAssetUsdVault vault_ = ISingleAssetUsdVault(vault);
        if (runUpkeep) vault_.upkeep();

        IERC20 usdToken = IERC20(vault_.usd());
        IERC20 underlyingToken = IERC20(vault_.underlying());
        IERC20 perpToken = IERC20(vault_.perpSr());
        address controller = vault_.perpController();

        IERC20(vault).safeTransferFrom(msg.sender, address(this), notesIn);
        (uint256 directUsd, uint256 perpOut) = vault_.redeem(notesIn);

        uint256 underlyingOut;
        if (perpOut != 0) {
            _approveIfNeeded(perpToken, controller, perpOut);
            (underlyingOut,,) = ISingleAssetController(controller).flashRedeem2(perpOut, 0, 0);
        }

        uint256 swappedUsd;
        if (underlyingOut != 0) {
            _approveIfNeeded(underlyingToken, strategy, underlyingOut);
            swappedUsd = IDexStrategy(strategy).trade(address(underlyingToken), address(usdToken), underlyingOut);
        }

        usdOut = directUsd + swappedUsd;
        if (usdOut < minUsdOut) revert SlippageTooHigh();
        if (usdOut != 0) usdToken.safeTransfer(msg.sender, usdOut);
        _refund(usdToken, underlyingToken, perpToken, msg.sender);
    }

    function _depositPass(
        ISingleAssetUsdVault vault,
        IDexStrategy strategy,
        IERC20 usdToken,
        IERC20 underlyingToken,
        IERC20 perpToken
    ) private returns (uint256 notesOut) {
        uint256 usdAvailable = usdToken.balanceOf(address(this));
        if (usdAvailable == 0) return 0;

        uint256 vaultUsd = vault.usdBalance();
        uint256 vaultPerp = vault.perpSrBalance();
        uint256 perpSupply = IPerpToken(address(perpToken)).totalSupply();
        PerpBalancer.ReserveData memory reserve = IPerpToken(address(perpToken)).reserveData();
        uint256 reserveValue = reserve.underlyingBal;
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            reserveValue += reserve.trancheData[i].value;
        }
        if (perpSupply == 0 || reserveValue == 0) revert InvalidReserveState();

        uint256 vaultPerpUnderlying = Math.mulDiv(vaultPerp, reserveValue, perpSupply);
        uint256 referencePrice = strategy.referencePrice(address(underlyingToken), address(usdToken));
        uint256 vaultPerpUsd = Math.mulDiv(vaultPerpUnderlying, referencePrice, WAD);
        vaultPerpUsd = Math.mulDiv(vaultPerpUsd, vault.usdUnitAmt(), vault.underlyingUnitAmt());
        uint256 totalVaultUsd = vaultUsd + vaultPerpUsd;
        if (totalVaultUsd == 0) revert InvalidReserveState();

        uint256 usdForVault = Math.mulDiv(usdAvailable, vaultUsd, totalVaultUsd, Math.Rounding.Ceil);
        uint256 usdToSell = usdAvailable - usdForVault;
        uint256 underlyingBought = strategy.trade(address(usdToken), address(underlyingToken), usdToSell);

        address controller = vault.perpController();
        _approveIfNeeded(underlyingToken, controller, underlyingBought);
        (uint256 perpMinted,,,) = ISingleAssetController(controller).flashMint2(underlyingBought, 0, 0, 0);

        _approveIfNeeded(usdToken, address(vault), usdForVault);
        _approveIfNeeded(perpToken, address(vault), perpMinted);
        notesOut = vault.deposit(usdForVault, perpMinted);
    }

    function _checkHealth(address strategy, bool healthCheck) private view {
        if (healthCheck && !IDexStrategy(strategy).isHealthy()) _revertSelector(UNHEALTHY_SELECTOR);
    }

    function _approveIfNeeded(IERC20 token, address spender, uint256 amount) private {
        if (amount != 0 && token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    function _refund(IERC20 usdToken, IERC20 underlyingToken, IERC20 perpToken, address recipient) private {
        uint256 amount = usdToken.balanceOf(address(this));
        if (amount != 0) usdToken.safeTransfer(recipient, amount);
        amount = underlyingToken.balanceOf(address(this));
        if (amount != 0) underlyingToken.safeTransfer(recipient, amount);
        amount = perpToken.balanceOf(address(this));
        if (amount != 0) perpToken.safeTransfer(recipient, amount);
    }

    function _revertSelector(bytes4 selector) private pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 4)
        }
    }
}
