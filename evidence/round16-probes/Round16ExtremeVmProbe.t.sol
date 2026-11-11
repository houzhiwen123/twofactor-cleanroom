// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IRound16VmController {
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

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function underlyingOracle() external view returns (address);
    function systemReserveState() external view returns (SystemState memory, ReserveData memory, ReserveData memory);
}

interface IRound16VmOracle {
    function FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function SEQUENCER_FEED() external view returns (address);
    function cachePrice() external;
}

interface IRound16VmFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract Round16ExtremeVmProbe is Test {
    uint256 private constant FORK_BLOCK = 54_990_962;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant USER = address(0xBEEF);

    IRound16VmController private controller;
    IRound16VmOracle private oracle;
    address private priceFeed;
    address private sequencerFeed;
    uint32 private gracePeriod;
    uint80 private priceRoundId;
    int256 private priceAnswer;
    uint80 private priceAnsweredInRound;
    uint80 private sequencerRoundId;
    uint80 private sequencerAnsweredInRound;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        controller = IRound16VmController(CONTROLLER);
        oracle = IRound16VmOracle(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        gracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IRound16VmFeed(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IRound16VmFeed(sequencerFeed).latestRoundData();
        }
        assertEq(block.chainid, 8453);
        assertGt(priceAnswer, 0);
    }

    function testVmAtOneFeedUnit() public {
        _observe("one_feed_unit", 1);
    }

    function testVmAtOnePercentSpot() public {
        _observe("one_percent_spot", priceAnswer / 100);
    }

    function testVmAtTenTimesSpot() public {
        _observe("ten_times_spot", priceAnswer * 10);
    }

    function testVmAtHundredTimesSpot() public {
        _observe("hundred_times_spot", priceAnswer * 100);
    }

    function _observe(string memory label, int256 answer) private {
        _setAndCachePrice(answer);
        (
            IRound16VmController.SystemState memory state,
            IRound16VmController.ReserveData memory sr,
            IRound16VmController.ReserveData memory jr
        ) = controller.systemReserveState();

        console2.log("OBS:R16_VM label", label);
        console2.log("OBS:R16_VM answer", uint256(answer));
        console2.log("OBS:R16_VM srReserveValue", state.perpSr.reserveValue);
        console2.log("OBS:R16_VM srVm", state.perpSr.vm);
        console2.log("OBS:R16_VM jrReserveValue", state.perpJr.reserveValue);
        console2.log("OBS:R16_VM jrVm", state.perpJr.vm);
        _logRows("sr", sr.trancheData);
        _logRows("jr", jr.trancheData);
    }

    function _logRows(string memory side, IRound16VmController.ReserveTrancheData[] memory rows) private view {
        for (uint256 i; i < rows.length; ++i) {
            console2.log("OBS:R16_VM rowSide", side);
            console2.log("OBS:R16_VM rowIndex", i);
            console2.log("OBS:R16_VM tranche", rows[i].data.tranche);
            console2.log("OBS:R16_VM claim", rows[i].data.trancheClaim);
            console2.log("OBS:R16_VM totalClaim", rows[i].data.totalClaim);
            console2.log("OBS:R16_VM trancheVm", rows[i].data.volatilityMultiplier);
            console2.log("OBS:R16_VM valueRatio", uint256(rows[i].data.valueRatio));
            console2.log("OBS:R16_VM reserveValue", rows[i].value);
        }
    }

    function _setAndCachePrice(int256 answer) private {
        uint256 timestamp = block.timestamp;
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IRound16VmFeed.latestRoundData.selector),
            abi.encode(priceRoundId, answer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > gracePeriod ? timestamp - gracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IRound16VmFeed.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(USER);
        oracle.cachePrice();
    }
}
