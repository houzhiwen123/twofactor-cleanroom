// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library SettlementReference {
    uint256 internal constant WAD = 1e18;

    function settle(uint64 ratio, uint256 balance, uint256 openPrice, uint256 closePrice)
        internal
        pure
        returns (uint256 senior, uint256 junior)
    {
        uint256 base = (balance * ratio + WAD - 1) / WAD;
        uint256 raw = (base * openPrice + closePrice - 1) / closePrice;
        senior = raw < balance ? raw : balance;
        junior = balance - senior;
    }
}
