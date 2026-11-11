// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IControllerRound4Window {
    function keeper() external view returns (address);
    function underlyingOracle() external view returns (address);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceWindow(uint256 timestamp) external view returns (uint64, uint64);
    function rebalance() external;
}

interface IOracleRound4Window {
    function FEED() external view returns (address);
    function SEQUENCER_FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function cachePrice() external;
}

interface IFeedRound4Window {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

contract Round4RebalanceWindowTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    uint256 private constant LAST_REBALANCE_SLOT = 9;
    bytes32 private constant LAST_REBALANCE_SELECTOR = bytes4(keccak256("LastRebalanceTooRecent()"));

    function testRound4RebalanceWindowBoundariesAndRepeat() public {
        IControllerRound4Window controller = IControllerRound4Window(CONTROLLER);
        uint256 frequency = controller.rebalanceFreqSec();
        uint256 referenceTimestamp = block.timestamp + 4 * frequency;
        (uint64 start, uint64 end) = controller.rebalanceWindow(referenceTimestamp);
        uint256[5] memory samples =
            [uint256(start) - 1, uint256(start), uint256(end) - 1, uint256(end), uint256(end) + 1];
        string[5] memory labels =
            ["window_start_minus_1", "window_start", "window_end_minus_1", "window_end", "window_end_plus_1"];

        for (uint256 i; i < samples.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _runEdge(controller, labels[i], samples[i], frequency);
            require(vm.revertToState(snapshot), "failed to restore edge snapshot");
        }

        uint256 repeatSnapshot = vm.snapshotState();
        uint256 repeatTimestamp = uint256(start) + 1;
        _setLastRebalance(controller, repeatTimestamp - 2 * frequency);
        vm.warp(repeatTimestamp);
        _refreshOracle(controller);
        _logWindowState(controller, "same_window_first_before", repeatTimestamp);
        vm.prank(controller.keeper());
        (bool firstSuccess, bytes memory firstRet) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerRound4Window.rebalance.selector));
        _logCall("same_window_first", firstSuccess, firstRet, controller.lastRebalanceTimestampSec());
        _logWindowState(controller, "same_window_second_before", repeatTimestamp);
        vm.prank(controller.keeper());
        (bool secondSuccess, bytes memory secondRet) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerRound4Window.rebalance.selector));
        _logCall("same_window_second", secondSuccess, secondRet, controller.lastRebalanceTimestampSec());
        require(!secondSuccess, "second rebalance unexpectedly succeeded");
        require(_selector(secondRet) == LAST_REBALANCE_SELECTOR, "unexpected repeat selector");
        require(vm.revertToState(repeatSnapshot), "failed to restore repeat snapshot");
    }

    function _runEdge(IControllerRound4Window controller, string memory label, uint256 timestamp, uint256 frequency)
        private
    {
        uint256 last = timestamp - 2 * frequency;
        _setLastRebalance(controller, last);
        vm.warp(timestamp);
        _refreshOracle(controller);
        _logWindowState(controller, string.concat(label, "_before"), timestamp);
        vm.prank(controller.keeper());
        (bool success, bytes memory returnData) =
            CONTROLLER.call(abi.encodeWithSelector(IControllerRound4Window.rebalance.selector));
        _logCall(label, success, returnData, controller.lastRebalanceTimestampSec());
        _logWindowState(controller, string.concat(label, "_after"), timestamp);
    }

    function _setLastRebalance(IControllerRound4Window controller, uint256 timestamp) private {
        bytes32 slot = bytes32(LAST_REBALANCE_SLOT);
        uint256 current = uint256(vm.load(CONTROLLER, slot));
        uint256 preserved = current & ((uint256(1) << 96) - 1);
        vm.store(CONTROLLER, slot, bytes32(preserved | (uint256(uint32(timestamp)) << 96)));
        require(controller.lastRebalanceTimestampSec() == uint64(timestamp), "last timestamp slot mismatch");
    }

    function _refreshOracle(IControllerRound4Window controller) private {
        IOracleRound4Window oracle = IOracleRound4Window(controller.underlyingOracle());
        uint256 timestamp = block.timestamp;
        uint80 roundId;
        int256 answer;
        uint80 answeredInRound;
        (roundId, answer,,, answeredInRound) = IFeedRound4Window(oracle.FEED()).latestRoundData();
        vm.mockCall(
            oracle.FEED(),
            abi.encodeWithSelector(IFeedRound4Window.latestRoundData.selector),
            abi.encode(roundId, answer, timestamp, timestamp, answeredInRound)
        );
        address sequencer = oracle.SEQUENCER_FEED();
        if (sequencer != address(0)) {
            (roundId,,,, answeredInRound) = IFeedRound4Window(sequencer).latestRoundData();
            uint256 startedAt = timestamp > oracle.GRACE_PERIOD() ? timestamp - oracle.GRACE_PERIOD() - 1 : 0;
            vm.mockCall(
                sequencer,
                abi.encodeWithSelector(IFeedRound4Window.latestRoundData.selector),
                abi.encode(roundId, int256(0), startedAt, timestamp, answeredInRound)
            );
        }
        oracle.cachePrice();
    }

    function _logWindowState(IControllerRound4Window controller, string memory label, uint256 timestamp) private {
        (uint64 start, uint64 end) = controller.rebalanceWindow(timestamp);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_rebalance_window\",\"label\":\"",
                label,
                "\",\"timestamp\":",
                vm.toString(timestamp),
                ",\"windowStart\":",
                vm.toString(uint256(start)),
                ",\"windowEnd\":",
                vm.toString(uint256(end)),
                ",\"lastRebalanceTimestampSec\":",
                vm.toString(uint256(controller.lastRebalanceTimestampSec())),
                "}"
            )
        );
    }

    function _logCall(string memory label, bool success, bytes memory returnData, uint64 lastAfter) private {
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_rebalance_call\",\"label\":\"",
                label,
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returnData)),
                "\",\"lastAfter\":",
                vm.toString(uint256(lastAfter)),
                "}"
            )
        );
    }

    function _selector(bytes memory returnData) private pure returns (bytes4 selector) {
        if (returnData.length >= 4) {
            assembly {
                selector := mload(add(returnData, 32))
            }
        }
    }
}
