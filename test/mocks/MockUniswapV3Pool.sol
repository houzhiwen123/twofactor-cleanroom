// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Local-only Uniswap V3 surface used by the secret-free deployment simulation.
/// @dev It exposes a healthy target-like price/liquidity snapshot, but intentionally disables
///      execution. Production pool selection and live settlement remain deployment decisions.
contract MockUniswapV3Pool {
    error ExecutionDisabled();

    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 500;
    uint160 public sqrtPriceX96 = 2_800_063_142_574_549_000_000_000_000;
    uint128 public liquidity = 2_782_022_353_822;
    bool public unlocked = true;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, -66_858, 0, 0, 0, 0, unlocked);
    }

    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) {
        revert ExecutionDisabled();
    }
}
