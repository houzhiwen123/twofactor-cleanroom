// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice BNB-DESIGN governance boundary: a multisig proposes, while execution is permissionless after the delay.
/// @dev The timelock itself is the only role administrator; there is no zero-delay external admin escape hatch.
contract ProtocolTimelock is TimelockController {
    uint256 public constant MIN_DELAY = 1 days;

    error InvalidGovernanceConfig();

    constructor(uint256 minDelay, address governanceSafe)
        TimelockController(minDelay, _singleton(governanceSafe), _singleton(address(0)), address(0))
    {
        if (minDelay < MIN_DELAY || governanceSafe == address(0)) revert InvalidGovernanceConfig();
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
