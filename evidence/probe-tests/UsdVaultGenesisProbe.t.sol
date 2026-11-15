// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

interface ITargetUsdVaultGenesis {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function initDeposit(uint256 usdAmt) external returns (uint256 notesMinted);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

contract GenesisProbeDex {
    address public immutable usd;
    address public immutable underlying;

    constructor(address usd_, address underlying_) {
        usd = usd_;
        underlying = underlying_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }
}

contract UsdVaultGenesisProbe is Test {
    address private constant TARGET_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 private constant FORK_BLOCK = 53_526_143;
    address private constant RANDOM = address(0xBEEF);

    struct FreshVault {
        ITargetUsdVaultGenesis vault;
        MockERC20 usd;
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    }

    function testProbeAmountBoundaryAndLockedNotes() public {
        uint256[8] memory amounts = [uint256(0), 1, 9_999, 10_000, 10_001, 99_999, 100_000, 1_000_000];
        for (uint256 i; i < amounts.length; ++i) {
            FreshVault memory fresh = _freshVault();
            uint256 amount = amounts[i];
            fresh.usd.mint(address(this), amount);
            fresh.usd.approve(address(fresh.vault), amount);

            vm.recordLogs();
            (bool ok, bytes memory result) =
                address(fresh.vault).call(abi.encodeCall(ITargetUsdVaultGenesis.initDeposit, (amount)));
            Vm.Log[] memory logs = vm.getRecordedLogs();

            emit log_named_uint("amount", amount);
            emit log_named_uint("ok", ok ? 1 : 0);
            emit log_named_bytes32("selector", bytes32(_selector(result)));
            emit log_named_uint("return", ok && result.length >= 32 ? abi.decode(result, (uint256)) : 0);
            emit log_named_uint("supply", fresh.vault.totalSupply());
            emit log_named_uint("ownerNotes", fresh.vault.balanceOf(address(this)));
            emit log_named_uint("vaultNotes", fresh.vault.balanceOf(address(fresh.vault)));
            emit log_named_uint("usdMoved", fresh.usd.balanceOf(address(fresh.vault)));
            emit log_named_uint("logCount", logs.length);
        }
    }

    function testProbeAuthorizationReplayDonationAndEventOrder() public {
        FreshVault memory unauthorized = _freshVault();
        unauthorized.usd.mint(RANDOM, 10_001);
        vm.startPrank(RANDOM);
        unauthorized.usd.approve(address(unauthorized.vault), 10_001);
        (bool randomOk, bytes memory randomResult) =
            address(unauthorized.vault).call(abi.encodeCall(ITargetUsdVaultGenesis.initDeposit, (10_001)));
        vm.stopPrank();
        emit log_named_uint("random.ok", randomOk ? 1 : 0);
        emit log_named_bytes32("random.selector", bytes32(_selector(randomResult)));

        FreshVault memory replay = _freshVault();
        replay.usd.mint(address(this), 20_002);
        replay.usd.approve(address(replay.vault), 20_002);
        vm.recordLogs();
        uint256 firstReturn = replay.vault.initDeposit(10_001);
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        bytes32 beforeReplay = _fingerprint(replay);
        (bool replayOk, bytes memory replayResult) =
            address(replay.vault).call(abi.encodeCall(ITargetUsdVaultGenesis.initDeposit, (10_001)));
        emit log_named_uint("first.return", firstReturn);
        emit log_named_uint("first.supply", replay.vault.totalSupply());
        emit log_named_uint("first.ownerNotes", replay.vault.balanceOf(address(this)));
        emit log_named_uint("first.vaultNotes", replay.vault.balanceOf(address(replay.vault)));
        emit log_named_uint("first.logCount", firstLogs.length);
        for (uint256 i; i < firstLogs.length; ++i) {
            emit log_named_uint("first.logIndex", i);
            emit log_named_address("first.emitter", firstLogs[i].emitter);
            emit log_named_bytes32("first.topic0", firstLogs[i].topics.length == 0 ? bytes32(0) : firstLogs[i].topics[0]);
        }
        emit log_named_uint("replay.ok", replayOk ? 1 : 0);
        emit log_named_bytes32("replay.selector", bytes32(_selector(replayResult)));
        assertEq(_fingerprint(replay), beforeReplay, "replay must be atomic");

        FreshVault memory donated = _freshVault();
        donated.usd.mint(address(donated.vault), 1);
        donated.usd.mint(address(this), 10_001);
        donated.usd.approve(address(donated.vault), 10_001);
        (bool donationOk, bytes memory donationResult) =
            address(donated.vault).call(abi.encodeCall(ITargetUsdVaultGenesis.initDeposit, (10_001)));
        emit log_named_uint("donation.ok", donationOk ? 1 : 0);
        emit log_named_bytes32("donation.selector", bytes32(_selector(donationResult)));
        emit log_named_uint("donation.supply", donated.vault.totalSupply());
        emit log_named_uint("donation.usd", donated.usd.balanceOf(address(donated.vault)));
    }

    function _freshVault() private returns (FreshVault memory fresh) {
        fresh.usd = new MockERC20("Genesis USD", "GUSD", 6);
        GenesisProbeDex dex = new GenesisProbeDex(address(fresh.usd), CBBTC);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "USD Genesis Probe",
            "USD-GEN",
            address(fresh.usd),
            CONTROLLER,
            address(dex)
        );
        fresh.vault = ITargetUsdVaultGenesis(address(new ERC1967Proxy(TARGET_IMPLEMENTATION, initData)));
        assertEq(fresh.vault.owner(), address(this));
        assertEq(fresh.vault.keeper(), address(this));
    }

    function _fingerprint(FreshVault memory fresh) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                fresh.vault.totalSupply(),
                fresh.vault.balanceOf(address(this)),
                fresh.vault.balanceOf(address(fresh.vault)),
                fresh.usd.balanceOf(address(this)),
                fresh.usd.balanceOf(address(fresh.vault))
            )
        );
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(reason, 0x20))
        }
    }
}
