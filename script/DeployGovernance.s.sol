// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolTimelock} from "../src/governance/ProtocolTimelock.sol";

/// @notice Deploys the governance delay without reading or embedding any signing key.
/// @dev The caller supplies the broadcaster through Forge. Required env: GOVERNANCE_SAFE. Optional: TIMELOCK_DELAY_SEC.
contract DeployGovernance is Script {
    function run() external returns (ProtocolTimelock timelock) {
        address governanceSafe = vm.envAddress("GOVERNANCE_SAFE");
        uint256 delay = vm.envOr("TIMELOCK_DELAY_SEC", uint256(2 days));

        vm.startBroadcast();
        timelock = new ProtocolTimelock(delay, governanceSafe);
        vm.stopBroadcast();

        console2.log("ProtocolTimelock", address(timelock));
        console2.log("Governance Safe", governanceSafe);
        console2.log("Minimum delay seconds", delay);
    }
}
