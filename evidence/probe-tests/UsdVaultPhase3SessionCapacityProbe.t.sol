// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

interface IPhase3Token {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ITargetUsdVaultPhase3 {
    struct Range {
        uint96 lower;
        uint96 upper;
    }

    struct ReserveState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        ReserveState perpSr;
        ReserveState perpJr;
    }

    function computeMintAmt(uint256 usdAmtMax, uint256 perpSrAmtMax)
        external
        view
        returns (uint256 notesMinted, uint256 usdAmtIn, uint256 perpSrAmtIn);
    function deposit(uint256 usdAmtMax, uint256 perpSrAmtMax) external returns (uint256 notesMinted);
    function getTVL() external view returns (uint256);
    function maxDeploymentVelocityPerc() external view returns (uint64);
    function minOpUsdVal() external view returns (uint128);
    function perpSr() external view returns (address);
    function rebalanceCapacity()
        external
        view
        returns (
            uint256 maxRebalanceUnderlying,
            uint256 underlyingPrice,
            bool isMintingPerp,
            uint256 currentDR,
            SystemState memory state
        );
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceOffsetSec() external view returns (uint32);
    function sessionBudgetUsdVal() external view returns (uint128);
    function sessionCapacity()
        external
        view
        returns (bool active, bool sessionIsMintingPerp_, uint256 sessionBudgetUsdVal_, uint256 sessionOpenedAtSec_);
    function sessionIsMintingPerp() external view returns (bool);
    function sessionOpenedAtSec() external view returns (uint64);
    function totalSupply() external view returns (uint256);
    function usd() external view returns (address);
    function usdBalance() external view returns (uint256);
    function perpSrBalance() external view returns (uint256);
    function updateTargetDR(uint96 targetDR_, Range calldata eqDRRange_) external;
}

interface ITargetControllerDr {
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

/// @notice Evidence-only public Base fork probes. No target storage or balances are
///         changed with deal/store, no transaction is signed, and nothing is broadcast.
contract UsdVaultPhase3SessionCapacityProbe is Test {
    address private constant VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant VAULT_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;

    bytes32 private constant SINGLE_ASSET_DEPOSIT_TX =
        0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254;
    bytes32 private constant PAIR_DEPOSIT_TX = 0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7;

    uint256 private constant SINGLE_ASSET_DEPOSIT_BLOCK = 53_236_495;
    uint256 private constant PAIR_DEPOSIT_BLOCK = 52_951_098;
    uint256 private constant INACTIVE_PREVIEW_BLOCK = 53_526_143;
    uint256 private constant DIRECTION_CONFLICT_BLOCK = 53_490_000;
    uint256 private constant ACTIVE_EXPIRY_MINUS_ONE_BLOCK = 53_505_726;

    uint256 private constant EXPECTED_PREVIEW_BUDGET = 33_024_675_527_237_586_477_021;
    uint256 private constant EXPECTED_PREVIEW_OPENED_AT = 1_793_829_600;
    uint256 private constant EXPECTED_STORED_BUDGET = 29_251_188_032_403_425_541_687;
    uint256 private constant EXPECTED_STORED_OPENED_AT = 1_793_772_000;

    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(uint256,uint256,uint256)");

    struct SessionSnapshot {
        bool active;
        bool capacityDirection;
        uint256 capacityBudget;
        uint256 capacityOpenedAt;
        bool storedDirection;
        uint256 storedBudget;
        uint256 storedOpenedAt;
        uint256 tvl;
    }

    event TargetSession(
        uint256 indexed blockNumber,
        uint256 timestamp,
        bool active,
        bool mintingPerp,
        uint256 budgetUsdVal,
        uint256 openedAtSec,
        uint256 storedBudgetUsdVal,
        uint256 storedOpenedAtSec
    );
    event TargetDepositBoundary(
        bytes32 indexed label,
        uint256 usdMax,
        uint256 perpMax,
        uint256 usdIn,
        uint256 perpIn,
        uint256 notesMinted,
        uint256 sessionBudget,
        uint256 estimatedDepositValueLowerBound
    );

    function testTargetInactiveAndActiveHistoricalVectors() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), INACTIVE_PREVIEW_BLOCK);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        SessionSnapshot memory inactive = _session(vault);
        assertFalse(inactive.active);
        assertTrue(inactive.capacityDirection);
        assertEq(inactive.capacityBudget, EXPECTED_PREVIEW_BUDGET);
        assertEq(inactive.capacityOpenedAt, EXPECTED_PREVIEW_OPENED_AT);
        assertEq(
            inactive.capacityBudget, inactive.tvl * vault.maxDeploymentVelocityPerc() / 1e18, "inactive budget preview"
        );
        _emitSession(inactive);

        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53_495_000);
        vault = ITargetUsdVaultPhase3(VAULT);
        SessionSnapshot memory active = _session(vault);
        assertTrue(active.active);
        assertTrue(active.capacityDirection);
        assertEq(active.capacityBudget, EXPECTED_STORED_BUDGET);
        assertEq(active.capacityOpenedAt, EXPECTED_STORED_OPENED_AT);
        assertEq(active.capacityDirection, active.storedDirection);
        assertEq(active.capacityBudget, active.storedBudget);
        assertEq(active.capacityOpenedAt, active.storedOpenedAt);
        _emitSession(active);
    }

    function testTargetActiveSessionExpiresAtExactBoundary() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), ACTIVE_EXPIRY_MINUS_ONE_BLOCK);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        SessionSnapshot memory beforeBoundary = _session(vault);
        uint256 exactExpiry = beforeBoundary.storedOpenedAt + vault.rebalanceFreqSec();

        assertEq(block.timestamp, exactExpiry - 1, "fixture must be expiry - 1");
        assertTrue(beforeBoundary.active, "session inactive before expiry");
        assertEq(beforeBoundary.capacityBudget, beforeBoundary.storedBudget);
        _emitSession(beforeBoundary);

        vm.warp(exactExpiry);
        SessionSnapshot memory atBoundary = _session(vault);
        assertFalse(atBoundary.active, "session must be inactive at equality");
        assertEq(atBoundary.capacityOpenedAt, exactExpiry, "new preview opens at equality");
        assertEq(atBoundary.capacityBudget, atBoundary.tvl * vault.maxDeploymentVelocityPerc() / 1e18);
        _emitSession(atBoundary);

        vm.warp(exactExpiry + 1);
        SessionSnapshot memory afterBoundary = _session(vault);
        assertFalse(afterBoundary.active);
        assertEq(afterBoundary.capacityOpenedAt, exactExpiry);
        assertEq(afterBoundary.capacityBudget, atBoundary.capacityBudget);
        _emitSession(afterBoundary);
    }

    function testTargetDirectionAtExactDrEquality() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), INACTIVE_PREVIEW_BLOCK);
        (uint256 subDR,) = ITargetControllerDr(CONTROLLER).systemDeviations();
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)", "Equality Probe", "EQ-PROBE", USDC, CONTROLLER, DEX_STRATEGY
        );
        ITargetUsdVaultPhase3 fresh = ITargetUsdVaultPhase3(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        fresh.updateTargetDR(uint96(subDR), ITargetUsdVaultPhase3.Range({lower: uint96(subDR), upper: uint96(subDR)}));
        (,, bool isMintingPerp, uint256 currentDR,) = fresh.rebalanceCapacity();
        assertEq(currentDR, subDR);
        assertFalse(isMintingPerp, "target equality direction must be non-minting");
    }

    function testHistoricalDepositsDoNotConsumeOrOpenSession() public {
        _replayDepositAndAssertSessionStorageUnchanged(SINGLE_ASSET_DEPOSIT_TX, SINGLE_ASSET_DEPOSIT_BLOCK);
        _replayDepositAndAssertSessionStorageUnchanged(PAIR_DEPOSIT_TX, PAIR_DEPOSIT_BLOCK);
    }

    function testPositiveDepositBelowMinOpSucceeds() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), INACTIVE_PREVIEW_BLOCK);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        _approveNaturalVaultBalances(vault);

        uint256 usdMax = 1;
        uint256 perpMax = vault.perpSrBalance();
        (uint256 quotedNotes, uint256 usdIn, uint256 perpIn) = vault.computeMintAmt(usdMax, perpMax);
        uint256 upperBound = vault.getTVL() * (usdIn + 1) / vault.usdBalance();
        assertGt(quotedNotes, 0, "positive quote required");
        assertGt(usdIn, 0, "positive USD input required");
        assertGt(perpIn, 0, "positive Perp input required");
        assertLt(upperBound, vault.minOpUsdVal(), "fixture must be below minOpUsdVal");

        SessionSnapshot memory beforeSession = _session(vault);
        vm.prank(VAULT);
        uint256 notesMinted = vault.deposit(usdMax, perpMax);
        assertEq(notesMinted, quotedNotes);
        _assertStoredSessionUnchanged(beforeSession, _session(vault));
        emit TargetDepositBoundary(
            keccak256("below-min-op"), usdMax, perpMax, usdIn, perpIn, notesMinted, beforeSession.capacityBudget, 0
        );
    }

    function testDepositAboveInactivePreviewBudgetSucceeds() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), INACTIVE_PREVIEW_BLOCK);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        _approveNaturalVaultBalances(vault);

        uint256 usdMax = vault.usdBalance();
        uint256 perpMax = vault.perpSrBalance();
        uint256 supply = vault.totalSupply();
        uint256 tvl = vault.getTVL();
        (uint256 quotedNotes, uint256 usdIn, uint256 perpIn) = vault.computeMintAmt(usdMax, perpMax);
        SessionSnapshot memory beforeSession = _session(vault);
        uint256 depositValueLowerBound = quotedNotes * tvl / supply;
        assertFalse(beforeSession.active, "fixture must preview an inactive session");
        assertGt(depositValueLowerBound, beforeSession.capacityBudget, "fixture must exceed session budget");

        vm.prank(VAULT);
        uint256 notesMinted = vault.deposit(usdMax, perpMax);
        assertEq(notesMinted, quotedNotes);
        _assertStoredSessionUnchanged(beforeSession, _session(vault));
        emit TargetDepositBoundary(
            keccak256("above-session-budget"),
            usdMax,
            perpMax,
            usdIn,
            perpIn,
            notesMinted,
            beforeSession.capacityBudget,
            depositValueLowerBound
        );
    }

    function testDepositIgnoresActiveSessionDirectionConflict() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), DIRECTION_CONFLICT_BLOCK);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        SessionSnapshot memory beforeSession = _session(vault);
        (,, bool requiredDirection,,) = vault.rebalanceCapacity();
        assertTrue(beforeSession.active, "fixture requires active session");
        assertTrue(requiredDirection, "current capacity direction fixture");
        assertFalse(beforeSession.capacityDirection, "stored session direction fixture");

        _approveNaturalVaultBalances(vault);
        uint256 usdMax = 1;
        uint256 perpMax = vault.perpSrBalance();
        (uint256 quotedNotes, uint256 usdIn, uint256 perpIn) = vault.computeMintAmt(usdMax, perpMax);
        assertGt(quotedNotes, 0);
        vm.prank(VAULT);
        uint256 notesMinted = vault.deposit(usdMax, perpMax);
        assertEq(notesMinted, quotedNotes);
        _assertStoredSessionUnchanged(beforeSession, _session(vault));
        emit TargetDepositBoundary(
            keccak256("direction-conflict"),
            usdMax,
            perpMax,
            usdIn,
            perpIn,
            notesMinted,
            beforeSession.capacityBudget,
            0
        );
    }

    function _replayDepositAndAssertSessionStorageUnchanged(bytes32 txHash, uint256 expectedBlock) private {
        uint256 forkId = vm.createSelectFork(vm.envString("BASE_RPC_URL"), txHash);
        assertEq(block.number, expectedBlock);
        ITargetUsdVaultPhase3 vault = ITargetUsdVaultPhase3(VAULT);
        SessionSnapshot memory beforeSession = _session(vault);

        vm.recordLogs();
        vm.transact(forkId, txHash);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        SessionSnapshot memory afterSession = _session(vault);
        _assertStoredSessionUnchanged(beforeSession, afterSession);
        assertEq(afterSession.active, beforeSession.active);
        assertEq(afterSession.capacityDirection, beforeSession.capacityDirection);
        assertEq(afterSession.capacityOpenedAt, beforeSession.capacityOpenedAt);
        if (beforeSession.active) {
            assertEq(afterSession.capacityBudget, beforeSession.capacityBudget, "active budget consumed by deposit");
        } else {
            assertEq(
                afterSession.capacityBudget,
                afterSession.tvl * vault.maxDeploymentVelocityPerc() / 1e18,
                "inactive post-deposit preview"
            );
        }
        assertTrue(_hasVaultDeposit(logs), "historical transaction did not call Vault.deposit");
        _emitSession(afterSession);
    }

    function _approveNaturalVaultBalances(ITargetUsdVaultPhase3 vault) private {
        address usdToken = vault.usd();
        address perpToken = vault.perpSr();
        assertGt(IPhase3Token(usdToken).balanceOf(VAULT), 0, "natural USD balance");
        assertGt(IPhase3Token(perpToken).balanceOf(VAULT), 0, "natural Perp balance");
        vm.startPrank(VAULT);
        assertTrue(IPhase3Token(usdToken).approve(VAULT, type(uint256).max));
        assertTrue(IPhase3Token(perpToken).approve(VAULT, type(uint256).max));
        vm.stopPrank();
    }

    function _session(ITargetUsdVaultPhase3 vault) private view returns (SessionSnapshot memory snap) {
        (snap.active, snap.capacityDirection, snap.capacityBudget, snap.capacityOpenedAt) = vault.sessionCapacity();
        snap.storedDirection = vault.sessionIsMintingPerp();
        snap.storedBudget = vault.sessionBudgetUsdVal();
        snap.storedOpenedAt = vault.sessionOpenedAtSec();
        snap.tvl = vault.getTVL();
    }

    function _assertStoredSessionUnchanged(SessionSnapshot memory beforeSession, SessionSnapshot memory afterSession)
        private
        pure
    {
        assertEq(afterSession.storedDirection, beforeSession.storedDirection, "stored session direction changed");
        assertEq(afterSession.storedBudget, beforeSession.storedBudget, "stored session budget changed");
        assertEq(afterSession.storedOpenedAt, beforeSession.storedOpenedAt, "stored session timestamp changed");
    }

    function _hasVaultDeposit(Vm.Log[] memory logs) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VAULT && logs[i].topics.length == 1 && logs[i].topics[0] == DEPOSIT_TOPIC) {
                return true;
            }
        }
        return false;
    }

    function _emitSession(SessionSnapshot memory snap) private {
        emit TargetSession(
            block.number,
            block.timestamp,
            snap.active,
            snap.capacityDirection,
            snap.capacityBudget,
            snap.capacityOpenedAt,
            snap.storedBudget,
            snap.storedOpenedAt
        );
    }
}
