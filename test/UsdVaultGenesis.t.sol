// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract UsdVaultGenesisTest is Test {
    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(uint256,uint256,uint256)");
    bytes4 private constant OWNABLE_UNAUTHORIZED_ACCOUNT = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
    address private constant USER = address(0xBEEF);

    struct Env {
        UsdVault vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockPriceOracle oracle;
        MockUsdVaultController controller;
    }

    function testExactNoOpBoundaryThenTargetFirstDeposit() public {
        Env memory env = _deploy();
        env.usd.mint(address(this), 20_001);
        env.usd.approve(address(env.vault), 20_001);

        vm.recordLogs();
        assertEq(env.vault.initDeposit(10_000), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(env.vault.totalSupply(), 0);
        assertEq(env.vault.usdBalance(), 0);

        uint256 notes = env.vault.initDeposit(10_001);
        assertEq(notes, 10_001e12);
        assertEq(env.vault.totalSupply(), notes);
        assertEq(env.vault.balanceOf(address(env.vault)), 1e16);
        assertEq(env.vault.balanceOf(address(this)), 1e12);
        assertEq(env.vault.usdBalance(), 10_001);
    }

    function testFirstDepositTransferMintAndEventOrderMatchesTarget() public {
        Env memory env = _deploy();
        env.usd.mint(address(this), 10_001);
        env.usd.approve(address(env.vault), 10_001);

        vm.recordLogs();
        assertEq(env.vault.initDeposit(10_001), 10_001e12);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 5);
        assertEq(logs[0].emitter, address(env.usd));
        _assertTransfer(logs[0], address(this), address(env.vault), 10_001);
        assertEq(logs[1].emitter, address(env.vault));
        _assertTransfer(logs[1], address(0), address(env.vault), 1e16);
        assertEq(logs[2].emitter, address(env.vault));
        _assertTransfer(logs[2], address(0), address(this), 1e12);
        assertEq(logs[3].emitter, address(env.vault));
        assertEq(logs[3].topics[0], DEPOSIT_TOPIC);
        (uint256 lockedUsd, uint256 lockedPerp, uint256 lockedNotes) =
            abi.decode(logs[3].data, (uint256, uint256, uint256));
        assertEq(lockedUsd, 0);
        assertEq(lockedPerp, 0);
        assertEq(lockedNotes, 1e16);
        assertEq(logs[4].emitter, address(env.vault));
        assertEq(logs[4].topics[0], DEPOSIT_TOPIC);
        (uint256 userUsd, uint256 userPerp, uint256 userNotes) = abi.decode(logs[4].data, (uint256, uint256, uint256));
        assertEq(userUsd, 10_001);
        assertEq(userPerp, 0);
        assertEq(userNotes, 1e12);
    }

    function testOnlyOwnerMayInitializeAndReplayIsAtomic() public {
        Env memory env = _deploy();
        env.usd.mint(USER, 10_001);
        vm.prank(USER);
        env.usd.approve(address(env.vault), 10_001);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTHORIZED_ACCOUNT, USER));
        env.vault.initDeposit(10_001);

        env.usd.mint(address(this), 20_002);
        env.usd.approve(address(env.vault), 20_002);
        env.vault.initDeposit(10_001);
        bytes32 beforeReplay = _fingerprint(env);
        vm.expectRevert(UsdVault.VaultInitialized.selector);
        env.vault.initDeposit(10_001);
        assertEq(_fingerprint(env), beforeReplay);
    }

    function testPreDepositDonationDoesNotChangeFirstNoteIssuance() public {
        Env memory env = _deploy();
        env.usd.mint(address(env.vault), 1);
        env.usd.mint(address(this), 10_001);
        env.usd.approve(address(env.vault), 10_001);

        assertEq(env.vault.initDeposit(10_001), 10_001e12);
        assertEq(env.vault.totalSupply(), 10_001e12);
        assertEq(env.vault.balanceOf(address(env.vault)), 1e16);
        assertEq(env.vault.balanceOf(address(this)), 1e12);
        assertEq(env.vault.usdBalance(), 10_002);
    }

    function testNormalDepositAndExitWorkAfterGenesis() public {
        Env memory env = _deploy();
        env.usd.mint(address(this), 10_001);
        env.usd.approve(address(env.vault), 10_001);
        env.vault.initDeposit(10_001);

        env.usd.mint(USER, 20_000);
        vm.startPrank(USER);
        env.usd.approve(address(env.vault), 20_000);
        assertEq(env.vault.deposit(20_000, 0), 20_000e12);
        (uint256 usdOut, uint256 perpOut) = env.vault.redeem(20_000e12);
        vm.stopPrank();

        assertEq(usdOut, 20_000);
        assertEq(perpOut, 0);
        assertEq(env.usd.balanceOf(USER), 20_000);
        assertEq(env.vault.totalSupply(), 10_001e12);
        assertEq(env.vault.usdBalance(), 10_001);
    }

    function _deploy() private returns (Env memory env) {
        env.usd = new MockERC20("USD Coin", "USDC", 6);
        env.perp = new MockERC20("Perp SR", "PSR", 8);
        env.underlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        env.oracle = new MockPriceOracle(80_000e18);
        env.controller = new MockUsdVaultController(address(env.oracle));
        env.controller.setPerpSrState(1e8, 1e8, 1e18);
        UsdVault implementation = new UsdVault();
        env.vault = UsdVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UsdVault.initExecution,
                        (
                            "USD Senior Vault",
                            "USD-SR",
                            address(env.usd),
                            address(env.perp),
                            address(env.underlying),
                            address(env.controller),
                            address(0xD3E),
                            address(env.oracle),
                            address(this)
                        )
                    )
                )
            )
        );
    }

    function _assertTransfer(Vm.Log memory entry, address from, address to, uint256 amount) private pure {
        assert(entry.topics.length == 3);
        assert(entry.topics[0] == TRANSFER_TOPIC);
        assert(address(uint160(uint256(entry.topics[1]))) == from);
        assert(address(uint160(uint256(entry.topics[2]))) == to);
        assert(abi.decode(entry.data, (uint256)) == amount);
    }

    function _fingerprint(Env memory env) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                env.vault.totalSupply(),
                env.vault.balanceOf(address(this)),
                env.vault.balanceOf(address(env.vault)),
                env.usd.balanceOf(address(this)),
                env.vault.usdBalance()
            )
        );
    }
}
