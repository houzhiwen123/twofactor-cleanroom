// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

interface ITargetUsdVaultPhase2 {
    function deposit(uint256 usdMax, uint256 perpSrMax) external returns (uint256 notesMinted);
}

contract UsdVaultPhase2TargetProbe is Test {
    address private constant VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PROBE_CALLER = address(0xBEEF);
    bytes32 private constant SINGLE_ASSET_TX =
        0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254;
    bytes32 private constant PAIR_ROUTER_TX =
        0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7;
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(uint256,uint256,uint256)");

    function testRealSingleAssetDepositOrder() public {
        _assertReplayOrder(SINGLE_ASSET_TX, 37_273, 10_800_619_432, 108_320_498_554_343_292_777);
    }

    function testRealPairRouterDepositOrder() public {
        _assertReplayOrder(PAIR_ROUTER_TX, 3_672, 1_064_222_447, 10_672_407_599_351_449_815);
    }

    function testZeroInputTargetBehaviorProbe() public {
        vm.createSelectFork(_rpcUrl(), 53_526_143);
        vm.recordLogs();
        vm.prank(PROBE_CALLER);
        uint256 notesMinted = ITargetUsdVaultPhase2(VAULT).deposit(0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(notesMinted, 0);
        assertEq(logs.length, 0);
    }

    function _assertReplayOrder(bytes32 txHash, uint256 usdIn, uint256 perpIn, uint256 notesMinted) private {
        vm.createSelectFork(_rpcUrl(), txHash);
        vm.recordLogs();
        vm.transact(txHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 depositIndex = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VAULT && logs[i].topics[0] == DEPOSIT_TOPIC) {
                depositIndex = i;
                break;
            }
        }
        assertNotEq(depositIndex, type(uint256).max);
        assertGe(depositIndex, 3);
        _assertTransfer(logs[depositIndex - 3], USDC, usdIn);
        _assertTransfer(logs[depositIndex - 2], PERP_SR, perpIn);
        _assertTransfer(logs[depositIndex - 1], VAULT, notesMinted);
        assertEq(logs[depositIndex].topics.length, 1);
        (uint256 eventUsd, uint256 eventPerp, uint256 eventNotes) =
            abi.decode(logs[depositIndex].data, (uint256, uint256, uint256));
        assertEq(eventUsd, usdIn);
        assertEq(eventPerp, perpIn);
        assertEq(eventNotes, notesMinted);
    }

    function _assertTransfer(Vm.Log memory log, address emitter, uint256 amount) private pure {
        assertEq(log.emitter, emitter);
        assertEq(log.topics[0], TRANSFER_TOPIC);
        assertEq(abi.decode(log.data, (uint256)), amount);
    }

    function _rpcUrl() private view returns (string memory) {
        return vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
    }
}
