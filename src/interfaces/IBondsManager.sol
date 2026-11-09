// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IBondsManager {
    struct BondData {
        address underlying;
        uint64 srTrancheRatio;
        bool isMature;
        uint64 maturityDate;
        address senior;
        address junior;
        uint256 openPrice;
        uint256 underlyingBal;
        uint256 srClaim;
        uint256 jrClaim;
    }

    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    function createBond(address underlying, uint64 srTrancheRatio, uint64 maturityDate)
        external
        returns (bytes32 bondID, BondData memory bondData);

    function tryMature(bytes32 bondID) external returns (bool);

    function isMature(bytes32 bondID) external view returns (bool);

    function trancheData(bytes32 bondID, bool isSenior) external view returns (TrancheData memory);

    function maturityDate(bytes32 bondID) external view returns (uint64);
}
