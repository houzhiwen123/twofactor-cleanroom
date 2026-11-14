// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IUnderlyingSingleAssetRouter {
    error SlippageTooHigh();

    function depositUnderlying(address vault, uint256 underlyingAmtIn, uint256 minNotesOut, uint256 maxIters)
        external
        returns (uint256 notesMinted);

    function redeemUnderlying(address vault, uint256 notesAmtIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingAmtOut);
}
