// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal two-vault entry point supported by the fixed historical PairRouter evidence.
/// @dev The deployed target selector is retained by PairRouter's compatibility fallback. This
///      interface names the same static argument layout for clean-room callers and tests.
interface IPairRouter {
    struct DepositParams {
        address usdVault;
        address underlyingVault;
        address strategy;
        address recipient;
        uint256 underlyingIn;
        uint256 minUsdFromTrade;
        uint256 underlyingToTrade;
        uint256 srUnderlyingIn;
        uint256 jrUnderlyingIn;
        uint256 minUsdNotes;
        uint256 minUnderlyingNotes;
        uint256 minSubDr;
        uint256 maxSubDr;
        uint256 minVmDr;
        uint256 maxVmDr;
        bool healthCheck;
    }

    struct RedeemParams {
        address usdVault;
        address underlyingVault;
        address strategy;
        uint256 usdNotes;
        uint256 underlyingNotes;
        uint256 maxUsdRetained;
        uint256 underlyingToTrade;
        bool runUpkeep;
        uint256 minUsdOut;
        uint256 minUnderlyingOut;
        uint256 minSubDr;
        uint256 maxSubDr;
        uint256 minVmDr;
        uint256 maxVmDr;
        bool healthCheck;
    }

    error InvalidInput();
    error InvalidParamDefn();
    error InvalidSelector();
    error PostStateOutOfBounds();
    error SlippageTooHigh();

    function deposit(DepositParams calldata params)
        external
        returns (
            uint256 usdNotes,
            uint256 underlyingNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        );

    function redeem(RedeemParams calldata params) external returns (uint256 usdOut, uint256 underlyingOut);
}
