// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

import {ProtocolTimelock} from "../src/governance/ProtocolTimelock.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {DeployGenesisLocal} from "../script/DeployGenesisLocal.s.sol";

interface IOwnableGovernanceDrill {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IOwnable2StepGovernanceDrill is IOwnableGovernanceDrill {
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

contract GovernanceDeploymentDrillTest is Test {
    address private constant LOCAL_ADMIN = address(0xA11CE);
    address private constant GOVERNANCE_SAFE = address(0x5AFE);
    address private constant EXECUTOR = address(0xE0EC);
    address private constant KEEPER = address(0xB0B);
    uint256 private constant DELAY = 2 days;

    DeployGenesisLocal private deploymentScript;
    DeployGenesisLocal.CoreDeployment private core;
    DeployGenesisLocal.PeripheryDeployment private periphery;
    ProtocolTimelock private timelock;

    function setUp() public {
        deploymentScript = new DeployGenesisLocal();
        (core, periphery) = deploymentScript.run();
        timelock = new ProtocolTimelock(DELAY, GOVERNANCE_SAFE);
        _wireGovernance();
    }

    function testFullStackOwnersProxyAdminsAndKeepersAreSeparated() public view {
        address[] memory governed = _governedContracts();
        for (uint256 i; i < governed.length; ++i) {
            assertEq(IOwnableGovernanceDrill(governed[i]).owner(), address(timelock));
        }

        address[] memory proxies = _proxyContracts();
        for (uint256 i; i < proxies.length; ++i) {
            assertEq(ProxyAdmin(_proxyAdmin(proxies[i])).owner(), address(timelock));
        }

        assertEq(core.controller.keeper(), KEEPER);
        assertEq(periphery.jrVault.keeper(), KEEPER);
        assertEq(periphery.srVault.keeper(), KEEPER);
        assertTrue(periphery.usdVault.isSwapper(address(periphery.inventory)));

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), GOVERNANCE_SAFE));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), GOVERNANCE_SAFE));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), GOVERNANCE_SAFE));
    }

    function testConfigAndProxyUpgradeRequireTheFullDelay() public {
        vm.prank(GOVERNANCE_SAFE);
        vm.expectRevert();
        core.feePolicy.updateAumFeePerc(1, 2);

        bytes memory updateFee = abi.encodeCall(core.feePolicy.updateAumFeePerc, (uint64(1), uint64(2)));
        bytes32 feeSalt = keccak256("governance-drill-update-fee");
        _schedule(address(core.feePolicy), updateFee, feeSalt);
        _expectEarlyExecutionRevert(address(core.feePolicy), updateFee, feeSalt);
        vm.warp(block.timestamp + DELAY);
        _execute(address(core.feePolicy), updateFee, feeSalt);
        assertEq(core.feePolicy.perpSrAUMFeePerc(), 1);
        assertEq(core.feePolicy.perpJrAUMFeePerc(), 2);

        address proxyAdminAddress = _proxyAdmin(address(core.feePolicy));
        FeePolicy replacement = new FeePolicy();
        bytes memory upgrade = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (ITransparentUpgradeableProxy(address(core.feePolicy)), address(replacement), bytes(""))
        );
        bytes32 upgradeSalt = keccak256("governance-drill-upgrade-fee-policy");
        bytes32 implementationBefore = vm.load(address(core.feePolicy), _implementationSlot());
        _schedule(proxyAdminAddress, upgrade, upgradeSalt);
        _expectEarlyExecutionRevert(proxyAdminAddress, upgrade, upgradeSalt);
        assertEq(vm.load(address(core.feePolicy), _implementationSlot()), implementationBefore);
        vm.warp(block.timestamp + DELAY);
        _execute(proxyAdminAddress, upgrade, upgradeSalt);
        assertEq(
            address(uint160(uint256(vm.load(address(core.feePolicy), _implementationSlot())))), address(replacement)
        );
        assertEq(core.feePolicy.owner(), address(timelock));
        assertEq(core.feePolicy.perpSrAUMFeePerc(), 1);
        assertEq(core.feePolicy.perpJrAUMFeePerc(), 2);
    }

    function testTimelockDelayCannotBeReducedBelowProtocolFloor() public {
        bytes memory lowerDelay = abi.encodeCall(timelock.updateDelay, (uint256(0)));
        bytes32 salt = keccak256("governance-drill-lower-delay");
        _schedule(address(timelock), lowerDelay, salt);
        vm.warp(block.timestamp + DELAY);

        vm.prank(EXECUTOR);
        vm.expectRevert(ProtocolTimelock.InvalidGovernanceConfig.selector);
        timelock.execute(address(timelock), 0, lowerDelay, bytes32(0), salt);
        assertEq(timelock.getMinDelay(), DELAY);

        address[] memory targets = new address[](1);
        targets[0] = address(timelock);
        uint256[] memory values = new uint256[](1);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = lowerDelay;
        bytes32 batchSalt = keccak256("governance-drill-lower-delay-batch");
        vm.prank(GOVERNANCE_SAFE);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), batchSalt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        vm.expectRevert(ProtocolTimelock.InvalidGovernanceConfig.selector);
        timelock.executeBatch(targets, values, payloads, bytes32(0), batchSalt);
        assertEq(timelock.getMinDelay(), DELAY);

        uint256 longerDelay = 3 days;
        bytes memory raiseDelay = abi.encodeCall(timelock.updateDelay, (longerDelay));
        bytes32 raiseSalt = keccak256("governance-drill-raise-delay");
        _schedule(address(timelock), raiseDelay, raiseSalt);
        vm.warp(block.timestamp + DELAY);
        _execute(address(timelock), raiseDelay, raiseSalt);
        assertEq(timelock.getMinDelay(), longerDelay);
    }

    function testKeeperIsTheOnlyImmediatePauseAndUnpauseAuthority() public {
        vm.prank(GOVERNANCE_SAFE);
        vm.expectRevert();
        core.controller.pauseUserOps(true);

        vm.prank(GOVERNANCE_SAFE);
        vm.expectRevert();
        periphery.jrVault.pause();

        vm.prank(GOVERNANCE_SAFE);
        vm.expectRevert();
        periphery.srVault.pause();

        vm.prank(KEEPER);
        core.controller.pauseUserOps(true);
        vm.prank(KEEPER);
        periphery.jrVault.pause();
        vm.prank(KEEPER);
        periphery.srVault.pause();
        assertTrue(core.controller.userOpsPaused());
        assertTrue(periphery.jrVault.paused());
        assertTrue(periphery.srVault.paused());

        vm.prank(KEEPER);
        core.controller.pauseUserOps(false);
        vm.prank(KEEPER);
        periphery.jrVault.unpause();
        vm.prank(KEEPER);
        periphery.srVault.unpause();
        assertFalse(core.controller.userOpsPaused());
        assertFalse(periphery.jrVault.paused());
        assertFalse(periphery.srVault.paused());
    }

    function testGovernanceSafeCanCancelButCannotExecuteCancelledOperation() public {
        bytes memory updateFee = abi.encodeCall(core.feePolicy.updateAumFeePerc, (uint64(3), uint64(4)));
        bytes32 salt = keccak256("governance-drill-cancel");
        _schedule(address(core.feePolicy), updateFee, salt);
        bytes32 operation = timelock.hashOperation(address(core.feePolicy), 0, updateFee, bytes32(0), salt);

        vm.prank(GOVERNANCE_SAFE);
        timelock.cancel(operation);
        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.execute(address(core.feePolicy), 0, updateFee, bytes32(0), salt);
        assertEq(core.feePolicy.perpSrAUMFeePerc(), 0);
        assertEq(core.feePolicy.perpJrAUMFeePerc(), 0);
    }

    function _wireGovernance() private {
        vm.startPrank(LOCAL_ADMIN);
        core.controller.updateKeeper(KEEPER);
        periphery.jrVault.updateKeeper(KEEPER);
        periphery.srVault.updateKeeper(KEEPER);

        address[] memory twoStep = _twoStepOwnedContracts();
        for (uint256 i; i < twoStep.length; ++i) {
            IOwnableGovernanceDrill(twoStep[i]).transferOwnership(address(timelock));
            assertEq(IOwnable2StepGovernanceDrill(twoStep[i]).pendingOwner(), address(timelock));
        }

        address[] memory oneStep = _oneStepOwnedContracts();
        for (uint256 i; i < oneStep.length; ++i) {
            IOwnableGovernanceDrill(oneStep[i]).transferOwnership(address(timelock));
        }

        address[] memory proxies = _proxyContracts();
        for (uint256 i; i < proxies.length; ++i) {
            ProxyAdmin(_proxyAdmin(proxies[i])).transferOwnership(address(timelock));
        }
        vm.stopPrank();

        address[] memory targets = twoStep;
        uint256[] memory values = new uint256[](targets.length);
        bytes[] memory payloads = new bytes[](targets.length);
        for (uint256 i; i < targets.length; ++i) {
            payloads[i] = abi.encodeCall(IOwnable2StepGovernanceDrill.acceptOwnership, ());
        }
        bytes32 salt = keccak256("governance-drill-accept-all-ownership");
        vm.prank(GOVERNANCE_SAFE);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), salt, DELAY);
        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.warp(block.timestamp + DELAY);
        vm.prank(EXECUTOR);
        timelock.executeBatch(targets, values, payloads, bytes32(0), salt);
    }

    function _schedule(address target, bytes memory payload, bytes32 salt) private {
        vm.prank(GOVERNANCE_SAFE);
        timelock.schedule(target, 0, payload, bytes32(0), salt, DELAY);
    }

    function _expectEarlyExecutionRevert(address target, bytes memory payload, bytes32 salt) private {
        vm.prank(EXECUTOR);
        vm.expectRevert();
        timelock.execute(target, 0, payload, bytes32(0), salt);
    }

    function _execute(address target, bytes memory payload, bytes32 salt) private {
        vm.prank(EXECUTOR);
        timelock.execute(target, 0, payload, bytes32(0), salt);
    }

    function _governedContracts() private view returns (address[] memory contracts_) {
        address[] memory twoStep = _twoStepOwnedContracts();
        address[] memory oneStep = _oneStepOwnedContracts();
        contracts_ = new address[](twoStep.length + oneStep.length);
        for (uint256 i; i < twoStep.length; ++i) {
            contracts_[i] = twoStep[i];
        }
        for (uint256 i; i < oneStep.length; ++i) {
            contracts_[twoStep.length + i] = oneStep[i];
        }
    }

    function _twoStepOwnedContracts() private view returns (address[] memory contracts_) {
        contracts_ = new address[](6);
        contracts_[0] = address(core.manager);
        contracts_[1] = address(core.issuer);
        contracts_[2] = address(core.controller);
        contracts_[3] = address(core.feePolicy);
        contracts_[4] = address(core.perpSr);
        contracts_[5] = address(core.perpJr);
    }

    function _oneStepOwnedContracts() private view returns (address[] memory contracts_) {
        contracts_ = new address[](3);
        contracts_[0] = address(periphery.jrVault);
        contracts_[1] = address(periphery.srVault);
        contracts_[2] = address(periphery.usdVault);
    }

    function _proxyContracts() private view returns (address[] memory proxies) {
        proxies = new address[](7);
        proxies[0] = address(core.manager);
        proxies[1] = address(core.issuer);
        proxies[2] = address(core.controller);
        proxies[3] = address(core.feePolicy);
        proxies[4] = address(periphery.jrVault);
        proxies[5] = address(periphery.srVault);
        proxies[6] = address(periphery.usdVault);
    }

    function _proxyAdmin(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, _adminSlot()))));
    }

    function _adminSlot() private pure returns (bytes32) {
        return bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    }

    function _implementationSlot() private pure returns (bytes32) {
        return bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    }
}
