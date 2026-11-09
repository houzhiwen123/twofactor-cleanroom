// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IChainlinkFeed} from "../interfaces/IChainlinkFeed.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract CachedOracle {
    error InvalidPrice();
    error ZeroPrice();
    error SequencerDown();

    bytes32 private constant PRICE_SLOT = keccak256("twofactor.cached-oracle.price");
    bytes32 private constant SET_SLOT = keccak256("twofactor.cached-oracle.set");

    address public immutable FEED;
    uint32 public immutable STALE_AFTER;
    address public immutable SEQUENCER_FEED;
    uint32 public immutable GRACE_PERIOD;
    uint8 public immutable DECIMALS;

    constructor(address feed, uint32 staleAfter, address sequencerFeed, uint32 gracePeriod) {
        FEED = feed;
        STALE_AFTER = staleAfter;
        SEQUENCER_FEED = sequencerFeed;
        GRACE_PERIOD = gracePeriod;
        DECIMALS = IChainlinkFeed(feed).decimals();
    }

    function getValidPrice() public view returns (uint256 price) {
        bytes32 priceSlot = PRICE_SLOT;
        bytes32 setSlot = SET_SLOT;
        uint256 cached;
        uint256 isSet;
        assembly {
            cached := tload(priceSlot)
            isSet := tload(setSlot)
        }
        if (isSet != 0) return cached;

        if (SEQUENCER_FEED != address(0)) {
            (, int256 status, uint256 startedAt,,) = IChainlinkFeed(SEQUENCER_FEED).latestRoundData();
            if (status != 0 || startedAt > block.timestamp || block.timestamp - startedAt < GRACE_PERIOD) {
                revert SequencerDown();
            }
        }

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            IChainlinkFeed(FEED).latestRoundData();
        if (answer == 0) revert ZeroPrice();
        if (answer < 0 || updatedAt == 0 || answeredInRound < roundId) revert InvalidPrice();
        if (block.timestamp < updatedAt || block.timestamp - updatedAt > STALE_AFTER) revert InvalidPrice();

        uint256 unsignedAnswer = SafeCast.toUint256(answer);
        if (DECIMALS < 18) return unsignedAnswer * 10 ** (18 - DECIMALS);
        if (DECIMALS > 18) return unsignedAnswer / 10 ** (DECIMALS - 18);
        return unsignedAnswer;
    }

    function cachePrice() external {
        uint256 price = getValidPrice();
        bytes32 priceSlot = PRICE_SLOT;
        bytes32 setSlot = SET_SLOT;
        assembly {
            tstore(priceSlot, price)
            tstore(setSlot, 1)
        }
    }

    function resetCache() external {
        bytes32 priceSlot = PRICE_SLOT;
        bytes32 setSlot = SET_SLOT;
        assembly {
            tstore(priceSlot, 0)
            tstore(setSlot, 0)
        }
    }
}
