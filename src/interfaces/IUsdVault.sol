// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Evidence-backed exit surface for the clean-room USD Senior Vault.
/// @dev Mint, session, capacity and rebalance behavior are intentionally absent
///      until target observations establish those semantics.
interface IUsdVault is IERC20 {
    event Redeem(uint256 notesAmt, uint256 usdAmtOut, uint256 perpSrAmtOut);

    function computeRedemptionAmts(uint256 notesAmt) external view returns (uint256 usdAmtOut, uint256 perpSrAmtOut);

    function redeem(uint256 notesAmt) external returns (uint256 usdAmtOut, uint256 perpSrAmtOut);

    function usdBalance() external view returns (uint256);

    function perpSrBalance() external view returns (uint256);
}
