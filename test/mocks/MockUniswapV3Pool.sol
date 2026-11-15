// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IMockUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// @notice Local-only Uniswap V3 surface used by the secret-free deployment simulation.
/// @dev It exposes a healthy target-like price/liquidity snapshot. Execution is disabled by
///      default and can be enabled explicitly for local lifecycle tests and secret-free scripts.
contract MockUniswapV3Pool {
    using SafeERC20 for IERC20;

    error ExecutionDisabled();
    error InvalidSwap();
    error InsufficientInput();

    uint256 private constant Q96 = 1 << 96;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;

    address public immutable token0;
    address public immutable token1;
    uint24 public constant fee = 500;
    uint160 public sqrtPriceX96 = 2_800_063_142_574_549_000_000_000_000;
    uint128 public liquidity = 2_782_022_353_822;
    bool public unlocked = true;
    bool public executionEnabled;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, -66_858, 0, 0, 0, 0, unlocked);
    }

    function setExecutionEnabled(bool enabled) external {
        executionEnabled = enabled;
    }

    function setUnlocked(bool unlocked_) external {
        unlocked = unlocked_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function previewSwap(bool zeroForOne, uint256 sellAmt)
        public
        view
        returns (uint256 buyAmt, uint160 nextSqrtPriceX96)
    {
        if (sellAmt == 0 || liquidity == 0) return (0, sqrtPriceX96);
        uint256 amountLessFee = Math.mulDiv(sellAmt, FEE_DENOMINATOR - fee, FEE_DENOMINATOR);
        uint256 currentSqrtPriceX96 = uint256(sqrtPriceX96);
        uint256 nextSqrt;

        if (zeroForOne) {
            uint256 numerator1 = uint256(liquidity) << 96;
            uint256 denominator = numerator1 + amountLessFee * currentSqrtPriceX96;
            nextSqrt = Math.mulDiv(numerator1, currentSqrtPriceX96, denominator, Math.Rounding.Ceil);
            buyAmt = Math.mulDiv(uint256(liquidity), currentSqrtPriceX96 - nextSqrt, Q96);
        } else {
            nextSqrt = currentSqrtPriceX96 + Math.mulDiv(amountLessFee, Q96, liquidity);
            uint256 numerator1 = uint256(liquidity) << 96;
            buyAmt = Math.mulDiv(numerator1, nextSqrt - currentSqrtPriceX96, nextSqrt) / currentSqrtPriceX96;
        }

        if (nextSqrt > type(uint160).max) revert InvalidSwap();
        nextSqrtPriceX96 = uint160(nextSqrt);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (!executionEnabled) revert ExecutionDisabled();
        if (!unlocked || recipient == address(0) || amountSpecified <= 0) revert InvalidSwap();

        uint256 sellAmt = uint256(amountSpecified);
        (uint256 buyAmt, uint160 nextSqrtPriceX96) = previewSwap(zeroForOne, sellAmt);
        if (buyAmt > uint256(type(int256).max)) revert InvalidSwap();

        address sellToken = zeroForOne ? token0 : token1;
        address buyToken = zeroForOne ? token1 : token0;
        amount0 = zeroForOne ? amountSpecified : -int256(buyAmt);
        amount1 = zeroForOne ? -int256(buyAmt) : amountSpecified;

        uint256 sellBalanceBefore = IERC20(sellToken).balanceOf(address(this));
        IERC20(buyToken).safeTransfer(recipient, buyAmt);
        IMockUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (IERC20(sellToken).balanceOf(address(this)) < sellBalanceBefore + sellAmt) {
            revert InsufficientInput();
        }

        sqrtPriceX96 = nextSqrtPriceX96;
    }
}
