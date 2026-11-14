// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IDexStrategy {
    function usd() external view returns (address);
    function underlying() external view returns (address);
    function usdUnit() external view returns (uint256);
    function underlyingUnit() external view returns (uint256);
    function pool() external view returns (address);
    function poolFee() external view returns (uint24);
    function minLiquidity() external view returns (uint128);
    function underlyingIsToken0() external view returns (bool);
    function isHealthy() external view returns (bool);
    function referencePrice(address sellToken, address buyToken) external view returns (uint256);
    function quote(address sellToken, address buyToken, uint256 sellAmt) external view returns (uint256 buyAmt);
    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);
    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt);
}
