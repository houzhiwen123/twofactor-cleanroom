// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

struct Phase3DRRange {
    uint96 lower;
    uint96 upper;
}

interface ITargetUnderlyingPerpVaultPhase3 {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function paused() external view returns (bool);
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function totalSupply() external view returns (uint256);
    function targetDR() external view returns (uint96);
    function eqDRRange() external view returns (uint96 lower, uint96 upper);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceOffsetSec() external view returns (uint32);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function minRebalanceVal() external view returns (uint128);
    function maxFlashFeePerc() external view returns (uint64);

    function init(
        string calldata name_,
        string calldata symbol_,
        address underlying_,
        address perpController_,
        bool isPerpSrVault_,
        bool mintsAboveTarget_
    ) external;

    function initDeposit(uint256 underlyingAmt) external returns (uint256 notesMinted);
    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted);
    function redeem(uint256 notesAmt) external returns (uint256 underlyingAmtOut, uint256 perpAmtOut);
    function rebalance() external;

    function updateKeeper(address keeper_) external;
    function updateTargetDR(uint96 targetDR_, Phase3DRRange calldata eqDRRange_) external;
    function updateRebalanceTimingParams(uint32 freqSec_, uint32 offsetSec_) external;
    function updateMinRebalanceAmt(uint128 minRebalanceVal_) external;
    function updateMaxFlashFeePerc(uint64 maxFlashFeePerc_) external;
    function pause() external;
    function unpause() external;

    function transferOwnership(address newOwner) external;
}

contract UnderlyingPerpVaultPhase3ProbeTest is Test {
    address internal constant SENIOR_VAULT = 0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB;
    address internal constant IMPLEMENTATION = 0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea;
    uint256 internal constant FIXED_BLOCK = 53_526_143;
    bytes32 internal constant SENIOR_MINT_TX = 0x07114c7e3baca7be676b961fe55548e688f830b0a6d99116cdc04c25b8c542ff;
    bytes32 internal constant SENIOR_REDEEM_TX = 0x2c23758afef541c51d2e290e533ab77f9396bf99e3cb9c632e7eec5f6fccd5c0;
    uint64 internal constant SENIOR_REDEEM_TOTAL_FEE = 1_637_628_506_141_442;

    address internal constant SEPARATED_KEEPER = address(0xCA11);
    address internal constant SECOND_KEEPER = address(0xCA12);
    address internal constant RANDOM = address(0xBEEF);
    address internal constant NEW_OWNER = address(0xD00D);

    event ProbeResult(string label, bool success, bytes result);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FIXED_BLOCK);
    }

    function testSyntheticForkUpdateKeeperAndOwnershipMatrix() public {
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();

        _assertFailedAndUnchanged(
            vault,
            SEPARATED_KEEPER,
            abi.encodeCall(vault.updateKeeper, (SEPARATED_KEEPER)),
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", SEPARATED_KEEPER),
            "updateKeeper.keeper"
        );
        _assertFailedAndUnchanged(
            vault,
            RANDOM,
            abi.encodeCall(vault.updateKeeper, (SEPARATED_KEEPER)),
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", RANDOM),
            "updateKeeper.random"
        );

        vm.prank(owner);
        vault.updateKeeper(address(0));
        assertEq(vault.keeper(), address(0), "zero keeper rejected");
        vm.prank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);
        assertEq(vault.keeper(), SEPARATED_KEEPER);

        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.transferOwnership, (address(0))),
            abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)),
            "ownership.zero"
        );

        vm.prank(owner);
        vault.transferOwnership(NEW_OWNER);
        assertEq(vault.owner(), NEW_OWNER, "ownership transfer was not immediate");

        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.updateMinRebalanceAmt, (uint128(7))),
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", owner),
            "oldOwner.setter"
        );
        vm.prank(NEW_OWNER);
        vault.updateMinRebalanceAmt(7);
        assertEq(vault.minRebalanceVal(), 7);
    }

    function testSyntheticForkAllSetterAuthorizationAndFailureAtomicity() public {
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();
        vm.prank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);

        bytes[] memory validPayloads = new bytes[](5);
        validPayloads[0] = abi.encodeCall(vault.updateKeeper, (SECOND_KEEPER));
        validPayloads[1] = abi.encodeCall(vault.updateTargetDR, (uint96(1e18), Phase3DRRange(1e18, 1e18)));
        validPayloads[2] = abi.encodeCall(vault.updateRebalanceTimingParams, (uint32(100), uint32(0)));
        validPayloads[3] = abi.encodeCall(vault.updateMinRebalanceAmt, (uint128(9)));
        validPayloads[4] = abi.encodeCall(vault.updateMaxFlashFeePerc, (uint64(1)));

        for (uint256 i; i < validPayloads.length; ++i) {
            _assertFailedAndUnchanged(
                vault,
                SEPARATED_KEEPER,
                validPayloads[i],
                abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", SEPARATED_KEEPER),
                "setter.keeper"
            );
            _assertFailedAndUnchanged(
                vault,
                RANDOM,
                validPayloads[i],
                abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", RANDOM),
                "setter.random"
            );
        }

        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.updateTargetDR, (uint96(0), Phase3DRRange(0, 0))),
            abi.encodeWithSignature("InvalidParamDefn()"),
            "setter.target.invalid"
        );
        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.updateTargetDR, (uint96(1e18), Phase3DRRange(1e18 + 1, 1e18 - 1))),
            abi.encodeWithSignature("InvalidRange()"),
            "setter.range.invalid"
        );
        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.updateRebalanceTimingParams, (uint32(0), uint32(0))),
            abi.encodeWithSignature("InvalidParamDefn()"),
            "setter.timing.invalid"
        );
        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.updateMaxFlashFeePerc, (uint64(1e18 + 1))),
            abi.encodeWithSignature("InvalidPerc()"),
            "setter.fee.invalid"
        );
    }

    function testSyntheticForkPauseMatrixAndAdminAvailability() public {
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();
        vm.prank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);
        vm.prank(SEPARATED_KEEPER);
        vault.pause();
        assertTrue(vault.paused());

        bytes memory pauseError = abi.encodeWithSignature("EnforcedPause()");
        _assertFailedAndUnchanged(
            vault,
            owner,
            abi.encodeCall(vault.initDeposit, (uint256(0))),
            abi.encodeWithSignature("VaultInitialized()"),
            "paused.initDeposit.alreadyInitialized"
        );
        _assertFailedAndUnchanged(
            vault, RANDOM, abi.encodeCall(vault.deposit, (uint256(0), uint256(0))), pauseError, "paused.deposit"
        );
        _assertFailedAndUnchanged(
            vault, RANDOM, abi.encodeCall(vault.redeem, (uint256(0))), pauseError, "paused.redeem"
        );
        _assertFailedAndUnchanged(vault, RANDOM, abi.encodeCall(vault.rebalance, ()), pauseError, "paused.rebalance");

        vm.startPrank(owner);
        vault.updateTargetDR(1e18, Phase3DRRange(1e18, 1e18));
        vault.updateRebalanceTimingParams(100, 0);
        vault.updateMinRebalanceAmt(9);
        vault.updateMaxFlashFeePerc(1);
        vault.updateKeeper(SECOND_KEEPER);
        vm.stopPrank();
        assertTrue(vault.paused(), "admin call unpaused vault");

        _assertFailedAndUnchanged(
            vault,
            SEPARATED_KEEPER,
            abi.encodeCall(vault.unpause, ()),
            abi.encodeWithSignature("UnauthorizedCall()"),
            "oldKeeper.unpause"
        );
        vm.prank(SECOND_KEEPER);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function testSyntheticFreshPausedInitDepositChecksInitializationThenPause() public {
        ITargetUnderlyingPerpVaultPhase3 deployed = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        ITargetUnderlyingPerpVaultPhase3 fresh = ITargetUnderlyingPerpVaultPhase3(
            address(
                new TransparentUpgradeableProxy(
                    IMPLEMENTATION,
                    address(this),
                    abi.encodeCall(
                        ITargetUnderlyingPerpVaultPhase3.init,
                        ("Phase3 fresh senior", "P3-SR", deployed.underlying(), deployed.perpController(), true, true)
                    )
                )
            )
        );

        fresh.pause();
        assertTrue(fresh.paused());
        bytes memory pauseError = abi.encodeWithSignature("EnforcedPause()");
        _assertFailedAndUnchanged(
            fresh,
            address(this),
            abi.encodeCall(fresh.initDeposit, (uint256(0))),
            pauseError,
            "fresh.paused.initDeposit"
        );
        _assertFailedAndUnchanged(
            fresh,
            RANDOM,
            abi.encodeCall(fresh.deposit, (uint256(0), uint256(0))),
            abi.encodeWithSignature("VaultNotInitialized()"),
            "fresh.paused.deposit"
        );
        _assertFailedAndUnchanged(
            fresh, RANDOM, abi.encodeCall(fresh.redeem, (uint256(0))), pauseError, "fresh.paused.redeem"
        );
        _assertFailedAndUnchanged(
            fresh, RANDOM, abi.encodeCall(fresh.rebalance, ()), pauseError, "fresh.paused.rebalance"
        );
    }

    function testSyntheticForkPausePrecedesCooldown() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_MINT_TX);
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();
        vm.prank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);

        vault.rebalance();
        vm.prank(SEPARATED_KEEPER);
        vault.pause();
        _assertFailedAndUnchanged(
            vault,
            RANDOM,
            abi.encodeCall(vault.rebalance, ()),
            abi.encodeWithSignature("EnforcedPause()"),
            "paused.cooldown"
        );
        vm.prank(SEPARATED_KEEPER);
        vault.unpause();
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSignature("LastRebalanceTooRecent()"));
        vault.rebalance();
    }

    function testSyntheticForkPausePrecedesNoCapacity() public {
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();
        vm.prank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);
        vm.prank(SEPARATED_KEEPER);
        vault.pause();
        _assertFailedAndUnchanged(
            vault,
            RANDOM,
            abi.encodeCall(vault.rebalance, ()),
            abi.encodeWithSignature("EnforcedPause()"),
            "paused.noCapacity"
        );
        vm.prank(SEPARATED_KEEPER);
        vault.unpause();
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSignature("NoOp()"));
        vault.rebalance();
    }

    function testSyntheticForkPausePrecedesExcessiveFee() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_REDEEM_TX);
        ITargetUnderlyingPerpVaultPhase3 vault = ITargetUnderlyingPerpVaultPhase3(SENIOR_VAULT);
        address owner = vault.owner();
        vm.startPrank(owner);
        vault.updateKeeper(SEPARATED_KEEPER);
        vault.updateMaxFlashFeePerc(SENIOR_REDEEM_TOTAL_FEE - 1);
        vm.stopPrank();
        vm.prank(SEPARATED_KEEPER);
        vault.pause();
        _assertFailedAndUnchanged(
            vault,
            RANDOM,
            abi.encodeCall(vault.rebalance, ()),
            abi.encodeWithSignature("EnforcedPause()"),
            "paused.excessiveFee"
        );
        vm.prank(SEPARATED_KEEPER);
        vault.unpause();
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSignature("SlippageTooHigh()"));
        vault.rebalance();
    }

    function _assertFailedAndUnchanged(
        ITargetUnderlyingPerpVaultPhase3 vault,
        address caller,
        bytes memory payload,
        bytes memory expected,
        string memory label
    ) private {
        bytes32 beforeFingerprint = _fingerprint(vault);
        vm.prank(caller);
        (bool success, bytes memory result) = address(vault).call(payload);
        emit ProbeResult(label, success, result);
        assertFalse(success, label);
        assertEq(result, expected, label);
        assertEq(_fingerprint(vault), beforeFingerprint, string.concat(label, ".state"));
    }

    function _fingerprint(ITargetUnderlyingPerpVaultPhase3 vault) private view returns (bytes32) {
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        return keccak256(
            abi.encode(
                vault.owner(),
                vault.keeper(),
                vault.paused(),
                vault.targetDR(),
                lower,
                upper,
                vault.rebalanceFreqSec(),
                vault.rebalanceOffsetSec(),
                vault.lastRebalanceTimestampSec(),
                vault.minRebalanceVal(),
                vault.maxFlashFeePerc(),
                IERC20(vault.underlying()).balanceOf(address(vault)),
                IERC20(vault.perp()).balanceOf(address(vault)),
                vault.totalSupply()
            )
        );
    }
}
