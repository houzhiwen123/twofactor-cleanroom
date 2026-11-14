// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IDexStrategy} from "../interfaces/IDexStrategy.sol";

interface IUniswapV3PoolStrategy {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/// @notice Stateless two-token Uniswap V3 strategy used by Vaults and the SingleAssetRouter.
/// @dev The current-tick quote path is exact for the target-confirmed vectors. Execution itself delegates to the pool.
contract UniswapV3DexStrategy is IDexStrategy {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();
    error UnsupportedPair();
    error UnauthorizedCall();
    error UnexpectedAmount();

    uint256 private constant WAD = 1e18;
    uint256 private constant Q96 = 1 << 96;
    uint256 private constant FEE_DENOMINATOR = 1_000_000;
    uint160 private constant MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
    uint160 private constant MAX_SQRT_RATIO_MINUS_ONE =
        1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    address public immutable usd;
    address public immutable underlying;
    uint256 public immutable usdUnit;
    uint256 public immutable underlyingUnit;
    address public immutable pool;
    uint24 public immutable poolFee;
    uint128 public immutable minLiquidity;
    bool public immutable underlyingIsToken0;

    constructor(address usd_, address underlying_, address pool_, uint128 minLiquidity_) {
        if (usd_ == address(0) || underlying_ == address(0) || pool_ == address(0)) revert InvalidParamDefn();
        IUniswapV3PoolStrategy poolContract = IUniswapV3PoolStrategy(pool_);
        address token0 = poolContract.token0();
        address token1 = poolContract.token1();
        if (!((token0 == usd_ && token1 == underlying_) || (token0 == underlying_ && token1 == usd_))) {
            revert InvalidParamDefn();
        }

        usd = usd_;
        underlying = underlying_;
        pool = pool_;
        poolFee = poolContract.fee();
        minLiquidity = minLiquidity_;
        underlyingIsToken0 = token0 == underlying_;
        usdUnit = 10 ** IERC20Metadata(usd_).decimals();
        underlyingUnit = 10 ** IERC20Metadata(underlying_).decimals();
    }

    function isHealthy() external view returns (bool) {
        (,,,,,, bool unlocked) = IUniswapV3PoolStrategy(pool).slot0();
        return unlocked && IUniswapV3PoolStrategy(pool).liquidity() >= minLiquidity;
    }

    function referencePrice(address sellToken, address buyToken) external view returns (uint256) {
        (bool zeroForOne, uint256 sellUnit, uint256 buyUnit) = _pair(sellToken, buyToken);
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolStrategy(pool).slot0();

        uint256 rawPriceWad;
        if (zeroForOne) {
            uint256 sqrtWad = Math.mulDiv(uint256(sqrtPriceX96), WAD, Q96);
            rawPriceWad = Math.mulDiv(sqrtWad, uint256(sqrtPriceX96), Q96);
        } else {
            uint256 inverseSqrtWad = Math.mulDiv(Q96, WAD, uint256(sqrtPriceX96));
            rawPriceWad = Math.mulDiv(inverseSqrtWad, Q96, uint256(sqrtPriceX96));
        }
        return Math.mulDiv(rawPriceWad, sellUnit, buyUnit);
    }

    function quote(address sellToken, address buyToken, uint256 sellAmt) public view returns (uint256 buyAmt) {
        (bool zeroForOne,,) = _pair(sellToken, buyToken);
        if (sellAmt == 0) return 0;
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3PoolStrategy(pool).slot0();
        uint128 liquidity = IUniswapV3PoolStrategy(pool).liquidity();
        if (liquidity == 0) return 0;

        uint256 amountLessFee = Math.mulDiv(sellAmt, FEE_DENOMINATOR - poolFee, FEE_DENOMINATOR);
        if (zeroForOne) {
            uint256 numerator1 = uint256(liquidity) << 96;
            uint256 denominator = numerator1 + amountLessFee * uint256(sqrtPriceX96);
            uint256 nextSqrt = Math.mulDiv(numerator1, uint256(sqrtPriceX96), denominator, Math.Rounding.Ceil);
            buyAmt = Math.mulDiv(uint256(liquidity), uint256(sqrtPriceX96) - nextSqrt, Q96);
        } else {
            uint256 nextSqrt = uint256(sqrtPriceX96) + Math.mulDiv(amountLessFee, Q96, liquidity);
            uint256 numerator1 = uint256(liquidity) << 96;
            buyAmt = Math.mulDiv(numerator1, nextSqrt - uint256(sqrtPriceX96), nextSqrt) / uint256(sqrtPriceX96);
        }
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt)
    {
        buyAmt = quote(sellToken, buyToken, maxSellAmt);
        if (buyAmt < minBuyAmt) return (0, 0);
        return (maxSellAmt, buyAmt);
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        (bool zeroForOne,,) = _pair(sellToken, buyToken);
        if (sellAmt > uint256(type(int256).max)) revert UnexpectedAmount();

        IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmt);
        (int256 amount0, int256 amount1) = IUniswapV3PoolStrategy(pool)
            .swap(
                msg.sender,
                zeroForOne,
                int256(sellAmt),
                zeroForOne ? MIN_SQRT_RATIO_PLUS_ONE : MAX_SQRT_RATIO_MINUS_ONE,
                bytes("")
            );
        int256 bought = zeroForOne ? -amount1 : -amount0;
        if (bought < 0) revert UnexpectedAmount();
        buyAmt = uint256(bought);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != pool) revert UnauthorizedCall();
        if (amount0Delta > 0) {
            IERC20(IUniswapV3PoolStrategy(pool).token0()).safeTransfer(pool, uint256(amount0Delta));
        } else if (amount1Delta > 0) {
            IERC20(IUniswapV3PoolStrategy(pool).token1()).safeTransfer(pool, uint256(amount1Delta));
        } else {
            revert UnexpectedAmount();
        }
    }

    function _pair(address sellToken, address buyToken)
        private
        view
        returns (bool zeroForOne, uint256 sellUnit, uint256 buyUnit)
    {
        if (sellToken == usd && buyToken == underlying) {
            return (!underlyingIsToken0, usdUnit, underlyingUnit);
        }
        if (sellToken == underlying && buyToken == usd) {
            return (underlyingIsToken0, underlyingUnit, usdUnit);
        }
        revert UnsupportedPair();
    }
}
