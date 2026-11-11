// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IRound9Controller {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function owner() external view returns (address);
    function keeper() external view returns (address);
    function issuer() external view returns (address);
    function balancer() external view returns (address);
    function underlying() external view returns (address);
    function underlyingOracle() external view returns (address);
    function minCleanupVal() external view returns (uint256);
    function minMaturitySec() external view returns (uint32);
    function reservedPerpJrLiquidity() external view returns (uint256);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function latestBondInfo() external view returns (BondInfo memory);
    function upkeep() external;
    function rollover() external;
    function flashMint2(
        uint256 underlyingAmtIntoPerpSr,
        uint256 underlyingAmtIntoPerpJr,
        uint256 minPerpSrAmtOut,
        uint256 minPerpJrAmtOut
    ) external returns (uint256 perpSrAmtOut, uint256 perpJrAmtOut);
    function updateRebalanceWindow(uint32 freqSec, uint32 windowOffsetSec, uint32 windowLengthSec) external;
}

interface IRound9Oracle {
    function FEED() external view returns (address);
    function SEQUENCER_FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function cachePrice() external;
}

interface IRound9PriceFeed {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IRound9ERC20 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

contract Round9FreshFeedStub {
    address private constant PRICE_FEED = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (address(this) == PRICE_FEED) {
            return (36893488147419122458, 7482940645796, block.timestamp, block.timestamp, 36893488147419122458);
        }
        return (18446744073709551636, 0, block.timestamp - 3601, block.timestamp, 18446744073709551636);
    }
}

contract Round9TraceProbeTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant OWNER = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant USER = address(0xBEEF);
    uint256 private constant ISSUE_AND_ROLLOVER_TS = 1_794_510_001;
    uint256 private constant REBALANCE_OPEN_TS = 1_794_160_801;
    uint256 private constant NOTHING_DUE_TS = 1_794_160_799;

    IRound9Controller private controller;
    IRound9Oracle private oracle;
    address private priceFeed;
    address private sequencerFeed;
    uint80 private priceRoundId;
    int256 private priceAnswer;
    uint80 private priceAnsweredInRound;
    uint80 private sequencerRoundId;
    uint80 private sequencerAnsweredInRound;
    uint32 private sequencerGracePeriod;

    function setUp() public {
        controller = IRound9Controller(CONTROLLER);
        oracle = IRound9Oracle(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        sequencerGracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IRound9PriceFeed(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,, , sequencerAnsweredInRound) =
                IRound9PriceFeed(sequencerFeed).latestRoundData();
        }
        assertEq(controller.owner(), OWNER);
    }

    function testT1PublicRolloverAfterIssueUpkeep() public {
        _warpAndRefresh(ISSUE_AND_ROLLOVER_TS);
        _logContext("T1_before_upkeep");
        vm.prank(controller.keeper());
        controller.upkeep();
        _logContext("T1_before_rollover");
        vm.prank(controller.keeper());
        controller.rollover();
        _logContext("T1_after_rollover");
    }

    function testT2aUpkeepIssueDueWithRolloverNeeded() public {
        _warpAndRefresh(ISSUE_AND_ROLLOVER_TS);
        _logContext("T2a_before_upkeep");
        vm.prank(controller.keeper());
        controller.upkeep();
        _logContext("T2a_after_upkeep");
    }

    function testT2bUpkeepWithRebalanceWindowOpen() public {
        _logContext("T2b_initial");
        vm.prank(OWNER);
        controller.updateRebalanceWindow(1, 0, 1);
        _warpAndRefresh(REBALANCE_OPEN_TS);
        _logContext("T2b_before_upkeep");
        _assertNoOpUpkeep();
        _logContext("T2b_after_upkeep");
    }

    function testT2cUpkeepNothingDue() public {
        _warpAndRefresh(NOTHING_DUE_TS);
        _logContext("T2c_before_upkeep");
        _assertNoOpUpkeep();
        _logContext("T2c_after_upkeep");
    }

    function testT3SeniorFlashMintWithIdleAboveCleanupThreshold() public {
        _warpAndRefresh(ISSUE_AND_ROLLOVER_TS);
        uint256 minCleanup = controller.minCleanupVal();
        deal(CBBTC, PERP_SR, minCleanup + 1);
        deal(CBBTC, USER, 2_000_000);
        vm.prank(USER);
        IRound9ERC20(CBBTC).approve(CONTROLLER, type(uint256).max);
        _logContext("T3_before_flashMint2");
        console2.log("T3_srIdleAboveMinCleanup", IRound9ERC20(CBBTC).balanceOf(PERP_SR), minCleanup);
        vm.prank(USER);
        controller.flashMint2(2_000_000, 0, 0, 0);
        _logContext("T3_after_flashMint2");
    }

    function _warpAndRefresh(uint256 timestamp) private {
        vm.warp(timestamp);
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IRound9PriceFeed.latestRoundData.selector),
            abi.encode(priceRoundId, priceAnswer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > sequencerGracePeriod ? timestamp - sequencerGracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IRound9PriceFeed.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        oracle.cachePrice();
    }

    function _assertNoOpUpkeep() private {
        vm.prank(controller.keeper());
        (bool success, bytes memory revertData) =
            address(controller).call(abi.encodeWithSelector(IRound9Controller.upkeep.selector));
        assertFalse(success);
        assertEq(bytes4(revertData), bytes4(keccak256("NoOp()")));
    }

    function _logContext(string memory label) private view {
        IRound9Controller.BondInfo memory latest = controller.latestBondInfo();
        console2.log(
            string.concat(
                "ROUND9:{\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(block.timestamp),
                ",\"minCleanupVal\":",
                vm.toString(controller.minCleanupVal()),
                ",\"minMaturitySec\":",
                vm.toString(uint256(controller.minMaturitySec())),
                ",\"reservedPerpJrLiquidity\":",
                vm.toString(controller.reservedPerpJrLiquidity()),
                ",\"lastRebalanceTimestampSec\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                ",\"latestBond\":\"",
                vm.toString(latest.bondID),
                "\"}"
            )
        );
    }
}
