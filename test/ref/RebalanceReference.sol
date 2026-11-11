// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library RebalanceReference {
    uint256 internal constant WAD = 1e18;

    function quote(
        uint256 srTVL,
        uint256 jrTVL,
        uint256 targetRatio,
        uint64 srLag,
        uint256 srLower,
        uint256 srUpper,
        uint64 jrLag,
        uint256 jrLower,
        uint256 jrUpper
    ) internal pure returns (uint256 value, bool srPayer) {
        uint256 targetSr = (srTVL + jrTVL) * WAD / (targetRatio + WAD);
        uint256 imbalance = srTVL > targetSr ? srTVL - targetSr : targetSr - srTVL;
        if (imbalance == 0) return (0, false);
        srPayer = srTVL > targetSr;
        uint256 payer = srPayer ? srTVL : jrTVL;
        uint256 lag = srPayer ? srLag : jrLag;
        uint256 lower = payer * (srPayer ? srLower : jrLower) / WAD;
        uint256 upper = payer * (srPayer ? srUpper : jrUpper) / WAD;
        uint256 linear = imbalance / lag;
        if (linear < lower) linear = lower;
        if (linear > upper) linear = upper;
        value = linear < imbalance ? linear : imbalance;
    }
}
