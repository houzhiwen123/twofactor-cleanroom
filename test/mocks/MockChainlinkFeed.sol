// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";

contract MockChainlinkFeed is IChainlinkFeed {
    uint8 private immutable _decimals;
    uint80 public roundId = 1;
    int256 public answer = 1;
    uint256 public startedAt = 1;
    uint256 public updatedAt = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function setRoundData(uint80 roundId_, int256 answer_, uint256 startedAt_, uint256 updatedAt_, uint80 answeredInRound_)
        external
    {
        roundId = roundId_;
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData()
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
