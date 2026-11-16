// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {ProtocolTimelock} from "../src/governance/ProtocolTimelock.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";

contract GovernanceTimelockTest is Test {
    address private constant SAFE = address(0x5AFE);
    address private constant EXECUTOR = address(0xE0EC);
    uint256 private constant DELAY = 2 days;

    ProtocolTimelock private timelock;
    FeePolicy private policy;

    function setUp() public {
        timelock = new ProtocolTimelock(DELAY, SAFE);
        FeePolicy implementation = new FeePolicy();
        policy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
    }

    function testRejectsZeroSafeAndDelayBelowMinimum() public {
        vm.expectRevert(ProtocolTimelock.InvalidGovernanceConfig.selector);
        new ProtocolTimelock(1 days - 1, SAFE);
        vm.expectRevert(ProtocolTimelock.InvalidGovernanceConfig.selector);
        new ProtocolTimelock(1 days, address(0));
    }

    function testOwnershipAcceptanceAndAdminChangeCannotBypassDelay() public {
        policy.transferOwnership(address(timelock));
        bytes memory acceptOwnership = abi.encodeCall(policy.acceptOwnership, ());
        bytes32 acceptSalt = keccak256("accept-policy-ownership");

        vm.prank(SAFE);
        timelock.schedule(address(policy), 0, acceptOwnership, bytes32(0), acceptSalt, DELAY);

        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.execute(address(policy), 0, acceptOwnership, bytes32(0), acceptSalt);

        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        timelock.execute(address(policy), 0, acceptOwnership, bytes32(0), acceptSalt);
        assertEq(policy.owner(), address(timelock));

        bytes memory updateFee = abi.encodeCall(policy.updateAumFeePerc, (uint64(1), uint64(2)));
        bytes32 updateSalt = keccak256("update-aum-fee");
        vm.prank(SAFE);
        timelock.schedule(address(policy), 0, updateFee, bytes32(0), updateSalt, DELAY);

        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.execute(address(policy), 0, updateFee, bytes32(0), updateSalt);

        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        timelock.execute(address(policy), 0, updateFee, bytes32(0), updateSalt);
        assertEq(policy.perpSrAUMFeePerc(), 1);
        assertEq(policy.perpJrAUMFeePerc(), 2);
    }

    function testOnlySafeMayScheduleAndTimelockIsItsOwnAdmin() public {
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        assertTrue(timelock.hasRole(proposerRole, SAFE));
        assertTrue(timelock.hasRole(adminRole, address(timelock)));
        assertFalse(timelock.hasRole(adminRole, SAFE));

        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.schedule(address(policy), 0, "", bytes32(0), bytes32(uint256(1)), DELAY);
    }
}
