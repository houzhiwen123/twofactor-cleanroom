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

    /// @dev Preserve the protocol floor for both single and batch self-calls to updateDelay().
    function _execute(address target, uint256 value, bytes calldata data) internal override {
        if (target == address(this) && data.length >= 4 && bytes4(data[:4]) == this.updateDelay.selector) {
            uint256 newDelay = abi.decode(data[4:], (uint256));
            if (newDelay < MIN_DELAY) revert InvalidGovernanceConfig();
        }
        super._execute(target, value, data);
    }

    function _singleton(address account) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = account;
    }
}
