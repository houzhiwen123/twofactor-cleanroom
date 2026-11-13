// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";

interface ITargetUnderlyingPerpVault {
    function MINIMUM_LIQUIDITY() external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function isPerpSrVault() external view returns (bool);
    function mintsAboveTarget() external view returns (bool);
    function underlyingBalance() external view returns (uint256);
    function perpBalance() external view returns (uint256);
    function getTVL() external view returns (uint256);
    function targetDR() external view returns (uint96);
    function eqDRRange() external view returns (uint96 lower, uint96 upper);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function paused() external view returns (bool);
    function computeMintAmt(uint256 underlyingMax, uint256 perpMax)
        external
        view
        returns (uint256 notesMinted, uint256 underlyingAmtIn, uint256 perpAmtIn);
    function computeRedemptionAmts(uint256 notesAmt)
        external
        view
        returns (uint256 underlyingAmtOut, uint256 perpAmtOut);
    function initDeposit(uint256 underlyingAmt) external returns (uint256 notesMinted);
    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted);
    function redeem(uint256 notesAmt) external returns (uint256 underlyingAmtOut, uint256 perpAmtOut);
    function updateKeeper(address keeper_) external;
    function pause() external;
    function unpause() external;
}

/// @notice TARGET-CONFIRMED read-only probes against the version-locked Base snapshot.
/// @dev No target storage mutation, private keys, signing or broadcasting is used.
contract UnderlyingPerpVaultPhase1ProbeTest is Test {
    uint256 internal constant FORK_BLOCK = 53_526_143;
    address internal constant JUNIOR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address internal constant SENIOR_VAULT = 0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB;
    address internal constant INITIALIZER = 0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b;
    address internal constant IMPLEMENTATION = 0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea;
    bytes32 internal constant IMPLEMENTATION_CODEHASH =
        0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint256 internal constant SENIOR_PRE_INIT_BLOCK = 51_749_944;
    uint256 internal constant SENIOR_PRE_DEPOSIT_BLOCK = 51_777_489;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
    }

    function testReadVersionLockedTopologyAndState() public {
        ITargetUnderlyingPerpVault jr = ITargetUnderlyingPerpVault(JUNIOR_VAULT);
        ITargetUnderlyingPerpVault sr = ITargetUnderlyingPerpVault(SENIOR_VAULT);
        _logState("JR", jr);
        _logState("SR", sr);

        assertEq(jr.name(), "cbBTC Junior Keeper");
        assertEq(jr.symbol(), "cbBTC-Jr-Keeper");
        assertEq(jr.totalSupply(), 3_813_064_395_481_201_456);
        assertEq(jr.underlyingBalance(), 0);
        assertEq(jr.perpBalance(), 32_102_063_162_351);
        assertEq(jr.getTVL(), 375_476_086);
        assertFalse(jr.isPerpSrVault());
        assertFalse(jr.mintsAboveTarget());

        assertEq(sr.name(), "cbBTC Senior Keeper");
        assertEq(sr.symbol(), "cbBTC-Sr-Keeper");
        assertEq(sr.totalSupply(), 121_588_631_786_949_865);
        assertEq(sr.underlyingBalance(), 10_259_975);
        assertEq(sr.perpBalance(), 170_465_061_177);
        assertEq(sr.getTVL(), 12_403_293);
        assertTrue(sr.isPerpSrVault());
        assertTrue(sr.mintsAboveTarget());
        assertEq(jr.MINIMUM_LIQUIDITY(), 1e10);
        assertEq(sr.MINIMUM_LIQUIDITY(), 1e10);

        assertEq(address(uint160(uint256(vm.load(JUNIOR_VAULT, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(address(uint160(uint256(vm.load(SENIOR_VAULT, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH);
    }

    function testReadMintAndRedeemMatrix() public {
        uint256[6] memory underlyingInputs = [uint256(0), 1, 100_000, 1_000_000, 1e8, type(uint64).max];
        uint256[6] memory perpInputs = [uint256(0), 1, 10_000_000_000, 1_000_000_000_000, 1e14, type(uint64).max];
        uint256[5] memory noteInputs = [uint256(0), 1, 1e10, 1e15, 1e18];

        _logMatrix("JR", ITargetUnderlyingPerpVault(JUNIOR_VAULT), underlyingInputs, perpInputs, noteInputs);
        _logMatrix("SR", ITargetUnderlyingPerpVault(SENIOR_VAULT), underlyingInputs, perpInputs, noteInputs);

        (uint256 jrNotes, uint256 jrUnderlying, uint256 jrPerp) =
            ITargetUnderlyingPerpVault(JUNIOR_VAULT).computeMintAmt(100_000, 10_000_000_000);
        assertEq(jrNotes, 1_187_794_185_126_745);
        assertEq(jrUnderlying, 0);
        assertEq(jrPerp, 10_000_000_000);

        (uint256 srNotes, uint256 srUnderlying, uint256 srPerp) =
            ITargetUnderlyingPerpVault(SENIOR_VAULT).computeMintAmt(100_000, 10_000_000_000);
        assertEq(srNotes, 1_185_077_271_503_584);
        assertEq(srUnderlying, 100_000);
        assertEq(srPerp, 1_661_456_886);

        (uint256 jrUnderlyingOut, uint256 jrPerpOut) =
            ITargetUnderlyingPerpVault(JUNIOR_VAULT).computeRedemptionAmts(1e15);
        assertEq(jrUnderlyingOut, 0);
        assertEq(jrPerpOut, 8_418_966_960);
        (uint256 srUnderlyingOut, uint256 srPerpOut) =
            ITargetUnderlyingPerpVault(SENIOR_VAULT).computeRedemptionAmts(1e15);
        assertEq(srUnderlyingOut, 84_382);
        assertEq(srPerpOut, 1_401_981_901);

        _assertMintQuote(
            ITargetUnderlyingPerpVault(SENIOR_VAULT),
            10_259_975,
            170_465_061_176,
            121_588_619_936_177_149,
            10_259_974,
            170_465_061_176
        );
        _assertMintQuote(
            ITargetUnderlyingPerpVault(SENIOR_VAULT),
            10_259_975,
            170_465_061_177,
            121_588_631_786_949_865,
            10_259_975,
            170_465_061_177
        );
        _assertMintQuote(
            ITargetUnderlyingPerpVault(SENIOR_VAULT),
            10_259_975,
            170_465_061_178,
            121_588_631_786_949_865,
            10_259_975,
            170_465_061_177
        );
    }

    function testSyntheticForkReadInitDepositDustBoundaries() public {
        uint256[3] memory amounts = [uint256(0), 1, 2];
        for (uint256 i; i < amounts.length; ++i) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_PRE_INIT_BLOCK);
            ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(SENIOR_VAULT);

            vm.recordLogs();
            vm.prank(INITIALIZER);
            uint256 returnedNotes = vault.initDeposit(amounts[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            emit log_named_uint("init.amount", amounts[i]);
            emit log_named_uint("init.returnedNotes", returnedNotes);
            emit log_named_uint("init.supply", vault.totalSupply());
            emit log_named_uint("init.vaultNotes", vault.balanceOf(SENIOR_VAULT));
            emit log_named_uint("init.userNotes", vault.balanceOf(INITIALIZER));
            emit log_named_uint("init.underlyingBalance", vault.underlyingBalance());
            emit log_named_uint("init.logs", logs.length);

            (bool success, bytes memory data) =
                SENIOR_VAULT.call(abi.encodeCall(ITargetUnderlyingPerpVault.deposit, (0, 0)));
            emit log_named_uint("postInit.depositZeroSuccess", success ? 1 : 0);
            emit log_named_bytes("postInit.depositZeroResult", data);

            if (i < 2) {
                assertEq(returnedNotes, 0);
                assertEq(vault.totalSupply(), 0);
                assertEq(vault.underlyingBalance(), 0);
                assertEq(logs.length, 0);
                assertFalse(success);
                assertEq(data, abi.encodeWithSelector(bytes4(0x9a09fd87)));
            } else {
                assertEq(returnedNotes, 2e10);
                assertEq(vault.totalSupply(), 2e10);
                assertEq(vault.balanceOf(SENIOR_VAULT), 1e10);
                assertEq(vault.balanceOf(INITIALIZER), 1e10);
                assertEq(vault.underlyingBalance(), 2);
                assertEq(logs.length, 5);
                assertTrue(success);
                assertEq(abi.decode(data, (uint256)), 0);
            }
        }
    }

    function testSyntheticForkReadDepositDustBoundaries() public {
        uint256[3] memory underlyingInputs = [uint256(0), 1, 1];
        uint256[3] memory perpInputs = [uint256(1), 0, 1];
        for (uint256 i; i < underlyingInputs.length; ++i) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_PRE_DEPOSIT_BLOCK);
            ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(SENIOR_VAULT);
            address perpToken = vault.perp();
            uint256 userPerpBefore = IERC20Probe(perpToken).balanceOf(INITIALIZER);
            uint256 vaultPerpBefore = vault.perpBalance();

            vm.recordLogs();
            vm.prank(INITIALIZER);
            uint256 returnedNotes = vault.deposit(underlyingInputs[i], perpInputs[i]);
            Vm.Log[] memory logs = vm.getRecordedLogs();

            emit log_named_uint("dust.vector", i);
            emit log_named_uint("dust.returnedNotes", returnedNotes);
            emit log_named_uint("dust.userPerpDelta", userPerpBefore - IERC20Probe(perpToken).balanceOf(INITIALIZER));
            emit log_named_uint("dust.vaultPerpDelta", vault.perpBalance() - vaultPerpBefore);
            emit log_named_uint("dust.logs", logs.length);
            assertEq(returnedNotes, 0);
            assertEq(userPerpBefore - IERC20Probe(perpToken).balanceOf(INITIALIZER), 0);
            assertEq(vault.perpBalance() - vaultPerpBefore, 0);
            assertEq(logs.length, 0);
        }
    }

    function testReadZeroRedeemHasNoEvents() public {
        ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(SENIOR_VAULT);
        vm.recordLogs();
        vm.prank(INITIALIZER);
        (uint256 underlyingOut, uint256 perpOut) = vault.redeem(0);
        assertEq(underlyingOut, 0);
        assertEq(perpOut, 0);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testHistoricalGoldenQuotesAndVersionSlots() public {
        _assertHistoricalMint(SENIOR_VAULT, 51_749_945, 1e15, 100_000, 0, 100_000, 0, 1e15, 100_000, 0);
        _assertHistoricalMint(
            JUNIOR_VAULT,
            51_777_455,
            10_010_350_000_000_000,
            0,
            84_239_786_870,
            0,
            1_636_069_530_773,
            194_416_786_128_004_843,
            0,
            1_636_069_530_773
        );
        _assertHistoricalMint(
            SENIOR_VAULT,
            51_777_489,
            1_379_300_000_000_000,
            27_196,
            9_257_448_029,
            1_590_000,
            540_252_299_306,
            80_494_093_785_850_860,
            1_587_122,
            540_252_299_306
        );
        _assertHistoricalRedeem(
            JUNIOR_VAULT,
            51_777_349,
            51_572_640_000_000_000,
            4_412_145,
            62_639_427_178,
            41_562_290_000_000_000,
            3_555_739,
            50_480_992_204
        );
        _assertHistoricalRedeem(
            SENIOR_VAULT,
            51_777_358,
            51_000_000_000_000_000,
            5_043_416,
            4_785_545_326,
            49_620_700_000_000_000,
            4_907_016,
            4_656_119_783
        );
    }

    function testSyntheticForkAdminRoleMatrix() public {
        ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(SENIOR_VAULT);
        address owner = vault.owner();
        address newKeeper = address(0xCA11);
        address random = address(0xBEEF);

        emit log_named_address("admin.owner", owner);
        emit log_named_address("admin.initialKeeper", vault.keeper());

        _assertAdminCall(
            "updateKeeper.random",
            random,
            abi.encodeCall(vault.updateKeeper, (newKeeper)),
            false,
            abi.encodeWithSelector(bytes4(0x118cdaa7), random)
        );
        _assertAdminCall(
            "updateKeeper.zero.owner", owner, abi.encodeCall(vault.updateKeeper, (address(0))), true, bytes("")
        );
        assertEq(vault.keeper(), address(0));

        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        vault = ITargetUnderlyingPerpVault(SENIOR_VAULT);
        vm.prank(owner);
        vault.updateKeeper(newKeeper);
        emit log_named_address("admin.updatedKeeper", vault.keeper());

        uint256 roleSnapshot = vm.snapshotState();
        _assertAdminCall(
            "pause.owner", owner, abi.encodeCall(vault.pause, ()), false, abi.encodeWithSelector(bytes4(0x7bf6a16f))
        );
        vm.revertToState(roleSnapshot);
        _assertAdminCall("pause.keeper", newKeeper, abi.encodeCall(vault.pause, ()), true, bytes(""));
        vm.revertToState(roleSnapshot);
        _assertAdminCall(
            "pause.random", random, abi.encodeCall(vault.pause, ()), false, abi.encodeWithSelector(bytes4(0x7bf6a16f))
        );
        vm.revertToState(roleSnapshot);

        vm.prank(newKeeper);
        vault.pause();
        uint256 pausedSnapshot = vm.snapshotState();
        _assertAdminCall(
            "unpause.owner", owner, abi.encodeCall(vault.unpause, ()), false, abi.encodeWithSelector(bytes4(0x7bf6a16f))
        );
        vm.revertToState(pausedSnapshot);
        _assertAdminCall("unpause.keeper", newKeeper, abi.encodeCall(vault.unpause, ()), true, bytes(""));
        vm.revertToState(pausedSnapshot);
        _assertAdminCall(
            "unpause.random",
            random,
            abi.encodeCall(vault.unpause, ()),
            false,
            abi.encodeWithSelector(bytes4(0x7bf6a16f))
        );
    }

    function _assertAdminCall(
        string memory label,
        address caller,
        bytes memory payload,
        bool expectedSuccess,
        bytes memory expectedData
    ) private {
        vm.prank(caller);
        (bool success, bytes memory data) = SENIOR_VAULT.call(payload);
        emit log_string(label);
        emit log_named_uint("admin.success", success ? 1 : 0);
        emit log_named_bytes("admin.result", data);
        emit log_named_address("admin.keeper", ITargetUnderlyingPerpVault(SENIOR_VAULT).keeper());
        emit log_named_uint("admin.paused", ITargetUnderlyingPerpVault(SENIOR_VAULT).paused() ? 1 : 0);
        assertEq(success, expectedSuccess);
        assertEq(data, expectedData);
    }

    function _logState(string memory side, ITargetUnderlyingPerpVault vault) private {
        emit log_string(side);
        emit log_named_string("name", vault.name());
        emit log_named_string("symbol", vault.symbol());
        emit log_named_uint("decimals", vault.decimals());
        emit log_named_address("underlying", vault.underlying());
        emit log_named_address("perp", vault.perp());
        emit log_named_address("controller", vault.perpController());
        emit log_named_uint("senior", vault.isPerpSrVault() ? 1 : 0);
        emit log_named_uint("mintsAboveTarget", vault.mintsAboveTarget() ? 1 : 0);
        emit log_named_uint("minimumLiquidity", vault.MINIMUM_LIQUIDITY());
        emit log_named_uint("supply", vault.totalSupply());
        emit log_named_uint("underlyingBalance", vault.underlyingBalance());
        emit log_named_uint("perpBalance", vault.perpBalance());
        emit log_named_uint("tvl", vault.getTVL());
        emit log_named_uint("targetDR", vault.targetDR());
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        emit log_named_uint("eqDRLower", lower);
        emit log_named_uint("eqDRUpper", upper);
    }

    function _logMatrix(
        string memory side,
        ITargetUnderlyingPerpVault vault,
        uint256[6] memory underlyingInputs,
        uint256[6] memory perpInputs,
        uint256[5] memory noteInputs
    ) private {
        emit log_string(side);
        for (uint256 i; i < underlyingInputs.length; ++i) {
            (uint256 notes, uint256 underlyingIn, uint256 perpIn) =
                vault.computeMintAmt(underlyingInputs[i], perpInputs[i]);
            emit log_named_uint("mint.vector", i);
            emit log_named_uint("mint.notes", notes);
            emit log_named_uint("mint.underlying", underlyingIn);
            emit log_named_uint("mint.perp", perpIn);
        }
        for (uint256 i; i < noteInputs.length; ++i) {
            (uint256 underlyingOut, uint256 perpOut) = vault.computeRedemptionAmts(noteInputs[i]);
            emit log_named_uint("redeem.vector", i);
            emit log_named_uint("redeem.underlying", underlyingOut);
            emit log_named_uint("redeem.perp", perpOut);
        }
    }

    function _assertHistoricalMint(
        address vaultAddress,
        uint256 blockNumber,
        uint256 supply,
        uint256 underlyingBal,
        uint256 perpBal,
        uint256 underlyingMax,
        uint256 perpMax,
        uint256 expectedNotes,
        uint256 expectedUnderlying,
        uint256 expectedPerp
    ) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), blockNumber);
        ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(vaultAddress);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.underlyingBalance(), underlyingBal);
        assertEq(vault.perpBalance(), perpBal);
        (uint256 notes, uint256 underlyingIn, uint256 perpIn) = vault.computeMintAmt(underlyingMax, perpMax);
        assertEq(notes, expectedNotes);
        assertEq(underlyingIn, expectedUnderlying);
        assertEq(perpIn, expectedPerp);
        assertEq(address(uint160(uint256(vm.load(vaultAddress, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH);
    }

    function _assertMintQuote(
        ITargetUnderlyingPerpVault vault,
        uint256 underlyingMax,
        uint256 perpMax,
        uint256 expectedNotes,
        uint256 expectedUnderlying,
        uint256 expectedPerp
    ) private view {
        (uint256 notes, uint256 underlyingIn, uint256 perpIn) = vault.computeMintAmt(underlyingMax, perpMax);
        assertEq(notes, expectedNotes);
        assertEq(underlyingIn, expectedUnderlying);
        assertEq(perpIn, expectedPerp);
    }

    function _assertHistoricalRedeem(
        address vaultAddress,
        uint256 blockNumber,
        uint256 supply,
        uint256 underlyingBal,
        uint256 perpBal,
        uint256 notes,
        uint256 expectedUnderlying,
        uint256 expectedPerp
    ) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), blockNumber);
        ITargetUnderlyingPerpVault vault = ITargetUnderlyingPerpVault(vaultAddress);
        assertEq(vault.totalSupply(), supply);
        assertEq(vault.underlyingBalance(), underlyingBal);
        assertEq(vault.perpBalance(), perpBal);
        (uint256 underlyingOut, uint256 perpOut) = vault.computeRedemptionAmts(notes);
        assertEq(underlyingOut, expectedUnderlying);
        assertEq(perpOut, expectedPerp);
        assertEq(address(uint160(uint256(vm.load(vaultAddress, IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH);
    }
}

interface IERC20Probe {
    function balanceOf(address account) external view returns (uint256);
}
