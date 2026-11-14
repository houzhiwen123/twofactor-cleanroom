// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface ITargetUnderlyingPerpVaultPhase4A {
    function MINIMUM_LIQUIDITY() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function keeper() external view returns (address);
    function owner() external view returns (address);
    function paused() external view returns (bool);
    function underlyingUnitAmt() external view returns (uint96);
    function isPerpSrVault() external view returns (bool);
    function mintsAboveTarget() external view returns (bool);
    function underlyingBalance() external view returns (uint256);
    function perpBalance() external view returns (uint256);
    function getTVL() external view returns (uint256);
    function targetDR() external view returns (uint96);
    function eqDRRange() external view returns (uint96 lower, uint96 upper);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceOffsetSec() external view returns (uint32);
    function minRebalanceVal() external view returns (uint128);
    function maxFlashFeePerc() external view returns (uint64);
    function computeRebalanceAmount() external view returns (uint256 underlyingAmt, bool isMintingPerp);
}

interface ITargetVaultControllerPhase4A {
    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
}

interface IERC20Phase4A {
    function decimals() external view returns (uint8);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IOwnablePhase4A {
    function owner() external view returns (address);
}

/// @dev Public Base data and local fork replay only. No signing or broadcasting is used.
contract UnderlyingPerpVaultPhase4AConfigProbeTest is Test {
    uint256 internal constant FIXED_BLOCK = 53_526_143;

    address internal constant JUNIOR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address internal constant SENIOR_VAULT = 0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB;
    address internal constant IMPLEMENTATION = 0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea;
    address internal constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address internal constant UNDERLYING = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address internal constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address internal constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address internal constant DEPLOYER = 0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b;
    address internal constant CURRENT_OWNER_KEEPER = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address internal constant JUNIOR_PROXY_ADMIN = 0xe49e746CCcd4c897Ca3aD985747B30Dd0a88d18d;
    address internal constant SENIOR_PROXY_ADMIN = 0x558818c8F369e6804041A8BdCa5AFcaFA9Acb06d;

    bytes32 internal constant JUNIOR_DEPLOY_TX = 0x72eb95ae4ffeab83d7e736a0018c60a584ddd23f4280f8b6a91f18290b2506c3;
    bytes32 internal constant SENIOR_DEPLOY_TX = 0xb1e500ac0e936bd907e09f515813156394d2b26dcc25f0a5a1824956ec40b5ce;
    uint256 internal constant JUNIOR_DEPLOY_BLOCK = 51_749_808;
    uint256 internal constant SENIOR_DEPLOY_BLOCK = 51_749_809;

    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_CODEHASH =
        0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645;
    bytes32 internal constant JUNIOR_PROXY_CODEHASH =
        0x0a16141b955fdc3548daeab3d02a4f007fcd407b6f88758a94caae8e8f4a4ab7;
    bytes32 internal constant SENIOR_PROXY_CODEHASH =
        0x2aed056fa5d6761cedf311376549767d063f32970ddc944418f0f16c965b65c3;
    bytes32 internal constant PROXY_ADMIN_CODEHASH = 0x097b23f80b082223dac6782c1aac884dc42d49a1b459e83df1efe5c1d794e0ce;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FIXED_BLOCK);
    }

    function testJuniorDeploymentBoundaryAndInitializerResult() public {
        _assertDeploymentBoundaryAndInitializerResult(
            JUNIOR_DEPLOY_TX,
            JUNIOR_DEPLOY_BLOCK,
            JUNIOR_VAULT,
            JUNIOR_PROXY_ADMIN,
            JUNIOR_PROXY_CODEHASH,
            "cbBTC Junior Keeper",
            "cbBTC-Jr-Keeper",
            PERP_JR,
            false,
            false
        );
    }

    function testSeniorDeploymentBoundaryAndInitializerResult() public {
        _assertDeploymentBoundaryAndInitializerResult(
            SENIOR_DEPLOY_TX,
            SENIOR_DEPLOY_BLOCK,
            SENIOR_VAULT,
            SENIOR_PROXY_ADMIN,
            SENIOR_PROXY_CODEHASH,
            "cbBTC Senior Keeper",
            "cbBTC-Sr-Keeper",
            PERP_SR,
            true,
            true
        );
    }

    function testVersionLockedProxyAndDependencyTopology() public view {
        _assertProxyTopology(JUNIOR_VAULT, JUNIOR_PROXY_ADMIN, JUNIOR_PROXY_CODEHASH, CURRENT_OWNER_KEEPER);
        _assertProxyTopology(SENIOR_VAULT, SENIOR_PROXY_ADMIN, SENIOR_PROXY_CODEHASH, CURRENT_OWNER_KEEPER);

        ITargetVaultControllerPhase4A controller = ITargetVaultControllerPhase4A(CONTROLLER);
        assertEq(controller.perpJr(), PERP_JR);
        assertEq(controller.perpSr(), PERP_SR);
        assertEq(IERC20Phase4A(UNDERLYING).decimals(), 8);
        assertEq(IERC20Phase4A(PERP_JR).decimals(), 8);
        assertEq(IERC20Phase4A(PERP_SR).decimals(), 8);
    }

    function testVersionLockedJuniorRuntimeConfiguration() public view {
        ITargetUnderlyingPerpVaultPhase4A vault = ITargetUnderlyingPerpVaultPhase4A(JUNIOR_VAULT);
        _assertSharedRuntimeConfiguration(
            vault,
            "cbBTC Junior Keeper",
            "cbBTC-Jr-Keeper",
            PERP_JR,
            115792089237316195423570985008687907853269984665640564039457584007913118077089
        );
        assertFalse(vault.isPerpSrVault());
        assertFalse(vault.mintsAboveTarget());
        assertEq(vault.targetDR(), 1_053_564_994_000_000_000);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        assertEq(lower, 1_053_564_994_000_000_000);
        assertEq(upper, 1_230_000_000_000_000_000);
        assertEq(vault.lastRebalanceTimestampSec(), 1_793_318_400);
        assertEq(vault.rebalanceFreqSec(), 28_800);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.minRebalanceVal(), 100_000);
        assertEq(vault.maxFlashFeePerc(), 5_000_000_000_000_000);
        assertEq(vault.totalSupply(), 3_813_064_395_481_201_456);
        assertEq(vault.underlyingBalance(), 0);
        assertEq(vault.perpBalance(), 32_102_063_162_351);
        assertEq(vault.getTVL(), 375_476_086);
        (uint256 amount, bool minting) = vault.computeRebalanceAmount();
        assertEq(amount, 0);
        assertTrue(minting);
    }

    function testVersionLockedSeniorRuntimeConfiguration() public view {
        ITargetUnderlyingPerpVaultPhase4A vault = ITargetUnderlyingPerpVaultPhase4A(SENIOR_VAULT);
        _assertSharedRuntimeConfiguration(
            vault,
            "cbBTC Senior Keeper",
            "cbBTC-Sr-Keeper",
            PERP_SR,
            115792089237316195423570985008687907853269984665640564039457584007913113892084
        );
        assertTrue(vault.isPerpSrVault());
        assertTrue(vault.mintsAboveTarget());
        assertEq(vault.targetDR(), 1_053_564_994_000_000_000);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        assertEq(lower, 1_043_029_344_100_000_000);
        assertEq(upper, 1_064_100_643_900_000_000);
        assertEq(vault.lastRebalanceTimestampSec(), 1_793_785_200);
        assertEq(vault.rebalanceFreqSec(), 28_800);
        assertEq(vault.rebalanceOffsetSec(), 6_000);
        assertEq(vault.minRebalanceVal(), 100_000);
        assertEq(vault.maxFlashFeePerc(), 5_000_000_000_000_000);
        assertEq(vault.totalSupply(), 121_588_631_786_949_865);
        assertEq(vault.underlyingBalance(), 10_259_975);
        assertEq(vault.perpBalance(), 170_465_061_177);
        assertEq(vault.getTVL(), 12_403_293);
        (uint256 amount, bool minting) = vault.computeRebalanceAmount();
        assertEq(amount, 0);
        assertFalse(minting);
    }

    function _assertDeploymentBoundaryAndInitializerResult(
        bytes32 transactionHash,
        uint256 deploymentBlock,
        address vaultAddress,
        address proxyAdmin,
        bytes32 proxyCodehash,
        string memory expectedName,
        string memory expectedSymbol,
        address expectedPerp,
        bool expectedSenior,
        bool expectedMintsAbove
    ) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), deploymentBlock - 1);
        assertEq(vaultAddress.code.length, 0);

        vm.createSelectFork(vm.envString("BASE_RPC_URL"), deploymentBlock);
        emit log_named_bytes32("deployment.transaction", transactionHash);

        assertEq(vaultAddress.code.length, 830);
        _assertProxyTopology(vaultAddress, proxyAdmin, proxyCodehash, DEPLOYER);
        ITargetUnderlyingPerpVaultPhase4A vault = ITargetUnderlyingPerpVaultPhase4A(vaultAddress);
        _assertSharedDeploymentConfiguration(vault, expectedName, expectedSymbol, expectedPerp);
        assertEq(vault.isPerpSrVault(), expectedSenior);
        assertEq(vault.mintsAboveTarget(), expectedMintsAbove);
    }

    function _assertProxyTopology(address vault, address proxyAdmin, bytes32 proxyCodehash, address adminOwner)
        private
        view
    {
        assertEq(vault.codehash, proxyCodehash);
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH);
        assertEq(_slotAddress(vault, IMPLEMENTATION_SLOT), IMPLEMENTATION);
        assertEq(_slotAddress(vault, ADMIN_SLOT), proxyAdmin);
        assertEq(proxyAdmin.codehash, PROXY_ADMIN_CODEHASH);
        assertEq(IOwnablePhase4A(proxyAdmin).owner(), adminOwner);
    }

    function _assertSharedDeploymentConfiguration(
        ITargetUnderlyingPerpVaultPhase4A vault,
        string memory expectedName,
        string memory expectedSymbol,
        address expectedPerp
    ) private view {
        assertEq(vault.name(), expectedName);
        assertEq(vault.symbol(), expectedSymbol);
        assertEq(vault.decimals(), 18);
        assertEq(vault.underlying(), UNDERLYING);
        assertEq(vault.perp(), expectedPerp);
        assertEq(vault.perpController(), CONTROLLER);
        assertEq(vault.owner(), DEPLOYER);
        assertEq(vault.keeper(), DEPLOYER);
        assertFalse(vault.paused());
        assertEq(vault.underlyingUnitAmt(), 1e8);
        assertEq(vault.MINIMUM_LIQUIDITY(), 1e10);
        assertEq(vault.targetDR(), 1e18);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        assertEq(lower, 1e18);
        assertEq(upper, 1e18);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
        assertEq(vault.rebalanceFreqSec(), 86_400);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.minRebalanceVal(), 0);
        assertEq(vault.maxFlashFeePerc(), 1e16);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.underlyingBalance(), 0);
        assertEq(vault.perpBalance(), 0);
        assertEq(vault.getTVL(), 0);
        assertEq(IERC20Phase4A(UNDERLYING).allowance(address(vault), CONTROLLER), type(uint256).max);
        assertEq(IERC20Phase4A(expectedPerp).allowance(address(vault), CONTROLLER), type(uint256).max);
    }

    function _assertSharedRuntimeConfiguration(
        ITargetUnderlyingPerpVaultPhase4A vault,
        string memory expectedName,
        string memory expectedSymbol,
        address expectedPerp,
        uint256 expectedUnderlyingAllowance
    ) private view {
        assertEq(vault.name(), expectedName);
        assertEq(vault.symbol(), expectedSymbol);
        assertEq(vault.decimals(), 18);
        assertEq(vault.underlying(), UNDERLYING);
        assertEq(vault.perp(), expectedPerp);
        assertEq(vault.perpController(), CONTROLLER);
        assertEq(vault.owner(), CURRENT_OWNER_KEEPER);
        assertEq(vault.keeper(), CURRENT_OWNER_KEEPER);
        assertFalse(vault.paused());
        assertEq(vault.underlyingUnitAmt(), 1e8);
        assertEq(vault.MINIMUM_LIQUIDITY(), 1e10);
        assertEq(IERC20Phase4A(UNDERLYING).allowance(address(vault), CONTROLLER), expectedUnderlyingAllowance);
        assertEq(IERC20Phase4A(expectedPerp).allowance(address(vault), CONTROLLER), type(uint256).max);
    }

    function _slotAddress(address account, bytes32 slot) private view returns (address) {
        return address(uint160(uint256(vm.load(account, slot))));
    }
}
