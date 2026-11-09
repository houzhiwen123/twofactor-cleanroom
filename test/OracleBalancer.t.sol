// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CachedOracle} from "../src/oracle/CachedOracle.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockSequencerFeed} from "./mocks/MockSequencerFeed.sol";

contract OracleCacheHarness {
    function cacheUpdateAndRead(
        CachedOracle oracle,
        MockChainlinkFeed feed,
        uint80 roundId,
        int256 answer,
        uint256 timestamp
    ) external returns (uint256) {
        oracle.cachePrice();
        feed.setRoundData(roundId, answer, timestamp, timestamp, roundId);
        return oracle.getValidPrice();
    }
}

contract OracleBalancerTest is Test {
    uint256 private constant WAD = 1e18;

    function testOracleScalesAndCachesWithinTransaction() public {
        vm.warp(1_800_000_000);
        MockChainlinkFeed feed = new MockChainlinkFeed(8);
        feed.setRoundData(2, 8_114_533_207_136, block.timestamp, block.timestamp, 2);
        CachedOracle oracle = new CachedOracle(address(feed), 3600, address(0), 3600);
        assertEq(oracle.getValidPrice(), 81_145_332_071_360_000_000_000);

        OracleCacheHarness harness = new OracleCacheHarness();
        assertEq(
            harness.cacheUpdateAndRead(oracle, feed, 3, 1, block.timestamp), 81_145_332_071_360_000_000_000
        );
        oracle.resetCache();
        assertEq(oracle.getValidPrice(), 10_000_000_000);
    }

    function testOracleValidityBoundaries() public {
        vm.warp(1_800_000_000);
        MockChainlinkFeed feed = new MockChainlinkFeed(8);
        MockSequencerFeed sequencer = new MockSequencerFeed();
        feed.setRoundData(2, 100, block.timestamp, block.timestamp - 3600, 2);
        sequencer.setRoundData(1, 0, block.timestamp - 3600, block.timestamp, 1);
        CachedOracle oracle = new CachedOracle(address(feed), 3600, address(sequencer), 3600);
        assertEq(oracle.getValidPrice(), 1e12);

        feed.setRoundData(3, 100, block.timestamp, block.timestamp - 3601, 3);
        vm.expectRevert(CachedOracle.InvalidPrice.selector);
        oracle.getValidPrice();

        feed.setRoundData(4, 0, block.timestamp, block.timestamp, 4);
        vm.expectRevert(CachedOracle.ZeroPrice.selector);
        oracle.getValidPrice();

        feed.setRoundData(5, 100, block.timestamp, block.timestamp, 5);
        sequencer.setRoundData(2, 0, block.timestamp - 3599, block.timestamp, 2);
        vm.expectRevert(CachedOracle.SequencerDown.selector);
        oracle.getValidPrice();
    }

    function testBalancerConsumesUnderlyingThenNearestMaturity() public {
        PerpBalancer balancer = new PerpBalancer();
        PerpBalancer.ReserveTrancheData[] memory tranches = new PerpBalancer.ReserveTrancheData[](2);
        tranches[0] = _tranche(address(0xA11CE), 1000, 1000, 500);
        tranches[1] = _tranche(address(0xB0B), 100, 600, 300);
        PerpBalancer.ReserveData memory reserves =
            PerpBalancer.ReserveData({underlyingBal: 100, trancheData: tranches});
        PerpBalancer.ReserveAmounts memory plan = balancer.computeSystemRebalancePlan(reserves, 500);
        assertEq(plan.underlyingAmt, 100);
        assertEq(plan.trancheAmts.length, 2);
        assertEq(plan.trancheAmts[0].token, address(0xB0B));
        assertEq(plan.trancheAmts[0].amount, 600);
        assertEq(plan.trancheAmts[1].token, address(0xA11CE));
        assertEq(plan.trancheAmts[1].amount, 200);

        PerpBalancer.ReserveAmounts memory empty = balancer.computeSystemRebalancePlan(reserves, 0);
        assertEq(empty.underlyingAmt, 0);
        assertEq(empty.trancheAmts.length, 0);
        vm.expectRevert(PerpBalancer.InsufficientRebalance.selector);
        balancer.computeSystemRebalancePlan(reserves, 901);
    }

    function _tranche(address token, uint64 maturity, uint256 balance, uint256 value)
        private
        pure
        returns (PerpBalancer.ReserveTrancheData memory)
    {
        return PerpBalancer.ReserveTrancheData({
            data: IBondsManager.TrancheData({
                trancheSupply: 0,
                trancheClaim: 0,
                totalClaim: 0,
                volatilityMultiplier: WAD,
                underlyingOpenPrice: 0,
                isMature: false,
                secondsToMaturity: maturity,
                trancheRatio: 0,
                valueRatio: 0,
                bondID: bytes32(0),
                isSenior: true,
                tranche: token,
                counterpart: address(0),
                manager: address(0)
            }),
            balance: balance,
            value: value
        });
    }
}
