// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ISingleAssetRouter {
    error SlippageTooHigh();

    function depositUsd(
        address vault,
        address strategy,
        uint256 usdMax,
        uint256 minNotes,
        uint256 maxIters,
        bool healthCheck
    ) external returns (uint256 notesOut);

    function redeemUsd(
        address vault,
        address strategy,
        uint256 notesIn,
        uint256 minUsdOut,
        bool runUpkeep,
        bool healthCheck
    ) external returns (uint256 usdOut);
}
