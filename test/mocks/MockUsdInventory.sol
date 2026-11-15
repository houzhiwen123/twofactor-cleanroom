// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexStrategy} from "../../src/interfaces/IDexStrategy.sol";

interface ILocalUsdInventoryVault {
    function swap(address tokenIn, address tokenOut, uint256 tokenInAmt, uint256 tokenOutAmt) external;
}

/// @notice Local-only atomic inventory/settlement harness for the target-observed USD Vault topology.
/// @dev It never holds protocol authority beyond the Vault's explicit swapper role. Any DEX or Vault
///      failure reverts the whole top-level call, including Controller and session state transitions.
contract MockUsdInventory {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();
    error SettlementLoss();
    error UnauthorizedCall();
    error VaultAlreadyConfigured();

    address public immutable owner;
    IERC20 public immutable usd;
    IERC20 public immutable underlying;
    IDexStrategy public immutable strategy;
    ILocalUsdInventoryVault public vault;

    constructor(address usd_, address underlying_, address strategy_) {
        if (usd_ == address(0) || underlying_ == address(0) || strategy_ == address(0)) {
            revert InvalidParamDefn();
        }
        owner = msg.sender;
        usd = IERC20(usd_);
        underlying = IERC20(underlying_);
        strategy = IDexStrategy(strategy_);
    }

    function configureVault(address vault_) external {
        if (msg.sender != owner) revert UnauthorizedCall();
        if (address(vault) != address(0)) revert VaultAlreadyConfigured();
        if (vault_ == address(0)) revert InvalidParamDefn();
        vault = ILocalUsdInventoryVault(vault_);
    }

    function executeMint(uint256 usdSpend, uint256 provisionalUsdOut)
        external
        returns (uint256 underlyingBought, uint256 surplusReturned)
    {
        if (address(vault) == address(0) || usdSpend == 0) revert InvalidParamDefn();
        uint256 startingUsd = usd.balanceOf(address(this));

        usd.forceApprove(address(strategy), usdSpend);
        underlyingBought = strategy.trade(address(usd), address(underlying), usdSpend);
        underlying.forceApprove(address(vault), underlyingBought);
        vault.swap(address(underlying), address(usd), underlyingBought, provisionalUsdOut);

        uint256 endingUsd = usd.balanceOf(address(this));
        if (endingUsd < startingUsd) revert SettlementLoss();
        surplusReturned = endingUsd - startingUsd;
        if (surplusReturned != 0) usd.safeTransfer(address(vault), surplusReturned);
    }

    function executeRedeem(uint256 provisionalUsdIn, uint256 underlyingOut)
        external
        returns (uint256 usdBought, uint256 surplusReturned)
    {
        if (address(vault) == address(0) || provisionalUsdIn == 0 || underlyingOut == 0) {
            revert InvalidParamDefn();
        }
        uint256 startingUsd = usd.balanceOf(address(this));

        usd.forceApprove(address(vault), provisionalUsdIn);
        vault.swap(address(usd), address(underlying), provisionalUsdIn, underlyingOut);
        underlying.forceApprove(address(strategy), underlyingOut);
        usdBought = strategy.trade(address(underlying), address(usd), underlyingOut);

        uint256 endingUsd = usd.balanceOf(address(this));
        if (endingUsd < startingUsd) revert SettlementLoss();
        surplusReturned = endingUsd - startingUsd;
        if (surplusReturned != 0) usd.safeTransfer(address(vault), surplusReturned);
    }
}
