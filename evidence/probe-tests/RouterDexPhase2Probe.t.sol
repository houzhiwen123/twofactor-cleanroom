// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UniswapV3DexStrategy} from "../../src/strategy/UniswapV3DexStrategy.sol";

interface ITargetDexStrategyPhase2 {
    function quote(address sellToken, address buyToken, uint256 sellAmt) external view returns (uint256);
    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);
}

interface IUniswapV3PoolPhase2 {
    function liquidity() external view returns (uint128);
    function tickSpacing() external view returns (int24);
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
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}

contract RouterDexPhase2Probe is Test {
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    bytes32 private constant EXIT_TX = 0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab;
    bytes32 private constant STRATEGY_CODEHASH = 0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302;

    ITargetDexStrategyPhase2 private target;
    UniswapV3DexStrategy private local;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), EXIT_TX);
        assertEq(block.chainid, 8453);
        assertEq(block.number, 53_243_583);
        assertEq(DEX_STRATEGY.codehash, STRATEGY_CODEHASH);
        target = ITargetDexStrategyPhase2(DEX_STRATEGY);
        local = new UniswapV3DexStrategy(USDC, CBBTC, POOL, 200_000_000_000);
    }

    function testTargetQuoteMatchesCurrentLiquidityAcrossInitializedTicks() public view {
        _logPoolState();

        uint256[10] memory usdAmounts = [
            uint256(1_000_000),
            10_000_000,
            100_000_000,
            1_000_000_000,
            10_000_000_000,
            100_000_000_000,
            1_000_000_000_000,
            10_000_000_000_000,
            100_000_000_000_000,
            1_000_000_000_000_000
        ];
        for (uint256 i; i < usdAmounts.length; ++i) {
            _logQuote("USDC_CBBTC", USDC, CBBTC, usdAmounts[i]);
        }

        uint256[10] memory btcAmounts = [
            uint256(1_000),
            10_000,
            100_000,
            1_000_000,
            10_000_000,
            100_000_000,
            1_000_000_000,
            10_000_000_000,
            100_000_000_000,
            1_000_000_000_000
        ];
        for (uint256 i; i < btcAmounts.length; ++i) {
            _logQuote("CBBTC_USDC", CBBTC, USDC, btcAmounts[i]);
        }
    }

    function testTargetMaxFillableFullPartialZeroBoundaryMatrix() public view {
        _logMaxFillableMatrix(USDC, CBBTC, 1_000_000);
        _logMaxFillableMatrix(USDC, CBBTC, 3_390_111_185);
        _logMaxFillableMatrix(USDC, CBBTC, 100_000_000_000);
        _logMaxFillableMatrix(CBBTC, USDC, 4_723);
        _logMaxFillableMatrix(CBBTC, USDC, 960_289);
        _logMaxFillableMatrix(CBBTC, USDC, 100_000_000);
    }

    function testTargetMaxFillableMatchesTenRoundScaledMinimumModel() public view {
        uint256[6] memory usdMax =
            [uint256(1_000_000), 3_390_111_185, 10_000_000_000, 100_000_000_000, 1_000_000_000_000, 10_000_000_000_000];
        for (uint256 i; i < usdMax.length; ++i) {
            _assertMaxModel(USDC, CBBTC, usdMax[i]);
        }

        uint256[6] memory btcMax = [uint256(4_723), 960_289, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000];
        for (uint256 i; i < btcMax.length; ++i) {
            _assertMaxModel(CBBTC, USDC, btcMax[i]);
        }
    }

    function testTargetMaxFillableZeroInputMatrix() public view {
        (bool zeroZeroOk, bytes memory zeroZeroResult) =
            address(target).staticcall(abi.encodeCall(ITargetDexStrategyPhase2.maxFillable, (USDC, CBBTC, 0, 0)));
        assertTrue(zeroZeroOk);
        (uint256 zeroZeroSell, uint256 zeroZeroBuy) = abi.decode(zeroZeroResult, (uint256, uint256));
        assertEq(zeroZeroSell, 0);
        assertEq(zeroZeroBuy, 0);

        (bool zeroOneOk, bytes memory zeroOneResult) =
            address(target).staticcall(abi.encodeCall(ITargetDexStrategyPhase2.maxFillable, (USDC, CBBTC, 0, 1)));
        assertTrue(zeroOneOk);
        (uint256 zeroOneSell, uint256 zeroOneBuy) = abi.decode(zeroOneResult, (uint256, uint256));
        assertEq(zeroOneSell, 0);
        assertEq(zeroOneBuy, 0);

        (uint256 localZeroZeroSell, uint256 localZeroZeroBuy) = local.maxFillable(USDC, CBBTC, 0, 0);
        assertEq(localZeroZeroSell, zeroZeroSell);
        assertEq(localZeroZeroBuy, zeroZeroBuy);
        (uint256 localZeroOneSell, uint256 localZeroOneBuy) = local.maxFillable(USDC, CBBTC, 0, 1);
        assertEq(localZeroOneSell, zeroOneSell);
        assertEq(localZeroOneBuy, zeroOneBuy);
    }

    function _logPoolState() private view {
        IUniswapV3PoolPhase2 pool = IUniswapV3PoolPhase2(POOL);
        (uint160 sqrtPriceX96, int24 tick,,,,,) = pool.slot0();
        console2.log("POOL sqrtPriceX96", uint256(sqrtPriceX96));
        console2.log("POOL tick", int256(tick));
        console2.log("POOL tickSpacing", int256(pool.tickSpacing()));
        console2.log("POOL liquidity", uint256(pool.liquidity()));

        int24 spacing = pool.tickSpacing();
        int24 compressed = tick / spacing;
        if (tick < 0 && tick % spacing != 0) --compressed;
        bool downFound;
        bool upFound;
        for (uint24 distance; distance <= 512 && (!downFound || !upFound); ++distance) {
            if (!downFound) {
                int24 downTick = (compressed - int24(distance)) * spacing;
                (,,,,,,, bool initialized) = pool.ticks(downTick);
                if (initialized) {
                    console2.log("POOL nearest initialized down tick", int256(downTick));
                    downFound = true;
                }
            }
            if (!upFound) {
                int24 upTick = (compressed + int24(distance) + 1) * spacing;
                (,,,,,,, bool initialized) = pool.ticks(upTick);
                if (initialized) {
                    console2.log("POOL nearest initialized up tick", int256(upTick));
                    upFound = true;
                }
            }
        }
    }

    function _logQuote(string memory direction, address sellToken, address buyToken, uint256 amount) private view {
        (bool targetOk, uint256 targetOut, bytes4 targetError) = _quote(address(target), sellToken, buyToken, amount);
        (bool localOk, uint256 localOut, bytes4 localError) = _quote(address(local), sellToken, buyToken, amount);
        console2.log("QUOTE direction", direction);
        console2.log("QUOTE amount", amount);
        console2.log("QUOTE target ok", targetOk);
        console2.log("QUOTE target out", targetOut);
        console2.log("QUOTE target error", uint256(uint32(targetError)));
        console2.log("QUOTE local ok", localOk);
        console2.log("QUOTE local out", localOut);
        console2.log("QUOTE local error", uint256(uint32(localError)));
        assertEq(localOk, targetOk, "local/target quote status");
        assertEq(localOut, targetOut, "local/target quote output");
        assertEq(localError, targetError, "local/target quote selector");
    }

    function _logMaxFillableMatrix(address sellToken, address buyToken, uint256 maxSell) private view {
        uint256 quoted = target.quote(sellToken, buyToken, maxSell);
        uint256[5] memory minimums = [uint256(0), quoted == 0 ? 0 : quoted - 1, quoted, quoted + 1, quoted * 2];
        for (uint256 i; i < minimums.length; ++i) {
            (bool ok, bytes memory result) = address(target)
                .staticcall(
                    abi.encodeCall(ITargetDexStrategyPhase2.maxFillable, (sellToken, buyToken, maxSell, minimums[i]))
                );
            console2.log("MAX sell token", sellToken);
            console2.log("MAX buy token", buyToken);
            console2.log("MAX maxSell", maxSell);
            console2.log("MAX quoted", quoted);
            console2.log("MAX minimum", minimums[i]);
            console2.log("MAX ok", ok);
            if (ok) {
                (uint256 sellOut, uint256 buyOut) = abi.decode(result, (uint256, uint256));
                console2.log("MAX sellOut", sellOut);
                console2.log("MAX buyOut", buyOut);
            } else {
                console2.log("MAX error", uint256(uint32(_selector(result))));
            }
        }
    }

    function _assertMaxModel(address sellToken, address buyToken, uint256 maxSell) private view {
        uint256 fullQuote = target.quote(sellToken, buyToken, maxSell);
        uint256[5] memory minima =
            [uint256(0), fullQuote, fullQuote + 1, fullQuote + Math.max(uint256(1), fullQuote / 1000), fullQuote * 2];
        for (uint256 i; i < minima.length; ++i) {
            (uint256 expectedSell, uint256 expectedBuy) = _modelMaxFillable(sellToken, buyToken, maxSell, minima[i]);
            (uint256 actualSell, uint256 actualBuy) = target.maxFillable(sellToken, buyToken, maxSell, minima[i]);
            assertEq(actualSell, expectedSell, "target sell differs from ten-round model");
            assertEq(actualBuy, expectedBuy, "target buy differs from ten-round model");

            (uint256 localSell, uint256 localBuy) = local.maxFillable(sellToken, buyToken, maxSell, minima[i]);
            assertEq(localSell, actualSell, "local/target max-fill sell");
            assertEq(localBuy, actualBuy, "local/target max-fill buy");
        }
    }

    function _modelMaxFillable(address sellToken, address buyToken, uint256 maxSell, uint256 minBuy)
        private
        view
        returns (uint256 sellOut, uint256 buyOut)
    {
        buyOut = target.quote(sellToken, buyToken, maxSell);
        if (buyOut >= minBuy) return (maxSell, buyOut);

        uint256 low;
        uint256 high = maxSell;
        for (uint256 i; i < 10; ++i) {
            uint256 candidate = (low + high) / 2;
            uint256 candidateBuy = target.quote(sellToken, buyToken, candidate);
            uint256 scaledMinimum = Math.mulDiv(minBuy, candidate, maxSell, Math.Rounding.Ceil);
            if (candidateBuy >= scaledMinimum) {
                low = candidate;
            } else {
                high = candidate;
            }
        }
        sellOut = low;
        buyOut = target.quote(sellToken, buyToken, sellOut);
    }

    function _quote(address strategy, address sellToken, address buyToken, uint256 amount)
        private
        view
        returns (bool ok, uint256 output, bytes4 errorSelector)
    {
        bytes memory result;
        (ok, result) =
            strategy.staticcall(abi.encodeCall(ITargetDexStrategyPhase2.quote, (sellToken, buyToken, amount)));
        if (ok && result.length >= 32) output = abi.decode(result, (uint256));
        if (!ok) errorSelector = _selector(result);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
        }
    }
}
