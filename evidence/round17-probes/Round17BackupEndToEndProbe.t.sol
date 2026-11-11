// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

library R17Types {
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

    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct BondDepositParams {
        bytes32 bondID;
        uint256 underlyingAmt;
    }

    struct RolloverExecution {
        ReserveAmounts stale;
        BondDepositParams[] freshBondDepositAmts;
        TokenAmount[] freshSrTrAmts;
        uint256 underlyingValRolled;
    }
}

interface IR17Controller {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
    function balancer() external view returns (address);
    function underlyingOracle() external view returns (address);
    function minMaturitySec() external view returns (uint32);
    function reservedPerpJrLiquidity() external view returns (uint256);
    function availPerpJrLiquidity() external view returns (uint256);
    function latestBondInfo() external view returns (R17Types.BondInfo memory);
    function systemReserveState()
        external
        view
        returns (R17Types.SystemState memory, R17Types.ReserveData memory, R17Types.ReserveData memory);
    function updateLiquidityThresholds(uint256 absolute, uint64 percentage) external;
    function upkeep() external;
    function rollover() external;
}

interface IR17Balancer {
    function computePerpSrRolloverPlan(
        R17Types.ReserveData memory sr,
        R17Types.ReserveData memory jr,
        address bondsManager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external pure returns (R17Types.RolloverExecution memory);
}

interface IR17Oracle {
    function FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function SEQUENCER_FEED() external view returns (address);
    function resetCache() external;
    function cachePrice() external;
}

interface IR17Feed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface IR17ERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract Round17BackupEndToEndProbe is Test {
    uint256 private constant FORK_BLOCK = 54_990_962;
    uint256 private constant ISSUE_DUE_TS = 1_794_510_001;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;

    IR17Controller private controller;
    IR17Oracle private oracle;
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
        controller = IR17Controller(CONTROLLER);
        oracle = IR17Oracle(controller.underlyingOracle());
        priceFeed = oracle.FEED();
        sequencerFeed = oracle.SEQUENCER_FEED();
        gracePeriod = oracle.GRACE_PERIOD();
        (priceRoundId, priceAnswer,,, priceAnsweredInRound) = IR17Feed(priceFeed).latestRoundData();
        if (sequencerFeed != address(0)) {
            (sequencerRoundId,,,, sequencerAnsweredInRound) = IR17Feed(sequencerFeed).latestRoundData();
        }
        assertEq(block.chainid, 8453);
    }

    function testNonHalfBackupPlanExecutesThroughController() public {
        _refreshOracle(ISSUE_DUE_TS, priceAnswer);
        vm.prank(controller.keeper());
        controller.upkeep();

        _refreshOracle(block.timestamp, priceAnswer * 130 / 100);
        _setJrFree(2_500_000);
        uint256 freeBefore = controller.availPerpJrLiquidity();
        (, R17Types.ReserveData memory sr, R17Types.ReserveData memory jr) = controller.systemReserveState();
        R17Types.BondInfo memory latest = controller.latestBondInfo();
        R17Types.RolloverExecution memory plan = IR17Balancer(controller.balancer())
            .computePerpSrRolloverPlan(
                sr, jr, latest.manager, controller.minMaturitySec(), controller.reservedPerpJrLiquidity()
            );
        require(plan.freshBondDepositAmts.length == 1, "expected backup single-bond plan");
        require(plan.freshSrTrAmts.length == 1, "expected one fresh SR output");

        address selectedSr = plan.freshSrTrAmts[0].token;
        (uint256 valueRatio, address selectedJr) = _freshPair(sr, selectedSr);
        uint256 srBefore = IR17ERC20(selectedSr).balanceOf(controller.perpSr());
        uint256 jrBefore = IR17ERC20(selectedJr).balanceOf(controller.perpJr());
        vm.prank(controller.keeper());
        (bool success, bytes memory ret) = CONTROLLER.call(abi.encodeWithSelector(IR17Controller.rollover.selector));
        uint256 srAfter = IR17ERC20(selectedSr).balanceOf(controller.perpSr());
        uint256 jrAfter = IR17ERC20(selectedJr).balanceOf(controller.perpJr());

        console2.log("OBS:R17_BACKUP_E2E selectedBond", vm.toString(plan.freshBondDepositAmts[0].bondID));
        console2.log("OBS:R17_BACKUP_E2E selectedSr", selectedSr);
        console2.log("OBS:R17_BACKUP_E2E selectedJr", selectedJr);
        console2.log("OBS:R17_BACKUP_E2E valueRatio", valueRatio);
        console2.log("OBS:R17_BACKUP_E2E deposit", plan.freshBondDepositAmts[0].underlyingAmt);
        console2.log("OBS:R17_BACKUP_E2E rolledValue", plan.underlyingValRolled);
        console2.log("OBS:R17_BACKUP_E2E freeBefore", freeBefore);
        console2.log("OBS:R17_BACKUP_E2E success", success);
        console2.log("OBS:R17_BACKUP_E2E selector", vm.toString(_selector(ret)));
        console2.log("OBS:R17_BACKUP_E2E srBeforeAfter", srBefore, srAfter);
        console2.log("OBS:R17_BACKUP_E2E jrBeforeAfter", jrBefore, jrAfter);

        assertTrue(success);
        assertTrue(valueRatio != 500_000_000_000_000_000);
        assertGt(plan.freshBondDepositAmts[0].underlyingAmt, 0);
        assertGt(srAfter, srBefore);
        assertGt(jrAfter, jrBefore);
    }

    function _setJrFree(uint256 desiredFree) private {
        (,, R17Types.ReserveData memory jr) = controller.systemReserveState();
        uint256 reserved = jr.underlyingBal > desiredFree ? jr.underlyingBal - desiredFree : 0;
        vm.prank(controller.owner());
        controller.updateLiquidityThresholds(reserved, 0);
    }

    function _freshPair(R17Types.ReserveData memory sr, address selectedSr)
        private
        pure
        returns (uint256 valueRatio, address selectedJr)
    {
        for (uint256 i; i < sr.trancheData.length; ++i) {
            if (sr.trancheData[i].data.tranche == selectedSr) {
                return (sr.trancheData[i].data.valueRatio, sr.trancheData[i].data.counterpart);
            }
        }
        revert("selected fresh tranche missing");
    }

    function _refreshOracle(uint256 timestamp, int256 answer) private {
        vm.warp(timestamp);
        vm.mockCall(
            priceFeed,
            abi.encodeWithSelector(IR17Feed.latestRoundData.selector),
            abi.encode(priceRoundId, answer, timestamp, timestamp, priceAnsweredInRound)
        );
        if (sequencerFeed != address(0)) {
            uint256 startedAt = timestamp > gracePeriod ? timestamp - gracePeriod - 1 : 0;
            vm.mockCall(
                sequencerFeed,
                abi.encodeWithSelector(IR17Feed.latestRoundData.selector),
                abi.encode(sequencerRoundId, int256(0), startedAt, timestamp, sequencerAnsweredInRound)
            );
        }
        vm.prank(CONTROLLER);
        oracle.resetCache();
        oracle.cachePrice();
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 32))
            }
        }
    }
}
