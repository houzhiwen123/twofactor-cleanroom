// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockChainlinkFeed} from "./MockChainlinkFeed.sol";

contract MockSequencerFeed is MockChainlinkFeed {
    constructor() MockChainlinkFeed(0) {}
}
