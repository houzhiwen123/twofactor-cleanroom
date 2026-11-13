// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeePolicy} from "../../src/policy/FeePolicy.sol";

interface ITargetUnderlyingPerpVaultPhase2 {
    function totalSupply() external view returns (uint256);
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function underlyingBalance() external view returns (uint256);
    function perpBalance() external view returns (uint256);
    function getTVL() external view returns (uint256);
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function paused() external view returns (bool);
    function isPerpSrVault() external view returns (bool);
    function mintsAboveTarget() external view returns (bool);
    function targetDR() external view returns (uint96);
    function eqDRRange() external view returns (uint96 lower, uint96 upper);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceOffsetSec() external view returns (uint32);
    function minRebalanceVal() external view returns (uint128);
    function maxFlashFeePerc() external view returns (uint64);
    function computeRebalanceAmount() external view returns (uint256 underlyingAmt, bool isMintingPerp);
    function rebalance() external;
    function updateKeeper(address keeper_) external;
    function updateTargetDR(uint96 targetDR_, DRRange calldata eqDRRange_) external;
    function updateRebalanceTimingParams(uint32 freqSec_, uint32 offsetSec_) external;
    function updateMinRebalanceAmt(uint128 minRebalanceVal_) external;
    function updateMaxFlashFeePerc(uint64 maxFlashFeePerc_) external;
}

struct DRRange {
    uint96 lower;
    uint96 upper;
}

struct ReplayExpectation {
    uint256 drBefore;
    uint256 grossUnderlying;
    uint256 actualUnderlying;
    bool minting;
    bytes controllerCalldata;
}

struct ReplaySnapshot {
    uint256 subDr;
    uint256 vmDr;
    uint256 underlying;
    uint256 perp;
    uint256 notes;
    uint256 last;
}

interface ITargetUnderlyingVaultControllerPhase2 {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function systemReserveState() external view returns (SystemState memory state);
    function targetSystemRatio() external view returns (uint256);
    function feePolicy() external view returns (address);
}

contract UnderlyingPerpVaultPhase2ProbeTest is Test {
    uint256 internal constant FIXED_BLOCK = 53_526_143;
    address internal constant JUNIOR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address internal constant SENIOR_VAULT = 0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB;
    address internal constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address internal constant IMPLEMENTATION = 0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea;
    bytes32 internal constant IMPLEMENTATION_CODEHASH =
        0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645;
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bytes32 internal constant JUNIOR_MINT_TX = 0x8eda4df97e08f8afc1d16ac0685f0d47527ebde30fbd4bbc8b5c177c97e778e0;
    bytes32 internal constant JUNIOR_MINT_UNCAPPED_TX =
        0xc91cf6221ad5409a89e4b7367af87ee9568eff6587a7e668eb769be9f594d554;
    bytes32 internal constant SENIOR_MINT_TX = 0x07114c7e3baca7be676b961fe55548e688f830b0a6d99116cdc04c25b8c542ff;
    bytes32 internal constant JUNIOR_REDEEM_TX = 0x3562298f878658f89d970f77da8bc7ae8c0e0d14fa389ee6f794c8b814e9259b;
    bytes32 internal constant SENIOR_REDEEM_TX = 0x2c23758afef541c51d2e290e533ab77f9396bf99e3cb9c632e7eec5f6fccd5c0;
    uint64 internal constant SENIOR_REDEEM_TOTAL_FEE = 1_637_628_506_141_442;

    bytes32 internal constant REBALANCE_TOPIC = 0xd2412c662f48f974143bb2428ce115c948201145d7b96f0eded33ccc43db383d;
    bytes4 internal constant FLASH_MINT_SELECTOR = 0x00a9fae0;
    bytes4 internal constant FLASH_REDEEM_SELECTOR = 0x6366884c;
    bytes4 internal constant LAST_REBALANCE_TOO_RECENT_SELECTOR = 0xa3b3f090;
    bytes4 internal constant NO_OP_SELECTOR = 0x00219cf1;

    event FixedConfig(
        address indexed vault,
        uint256 targetDR,
        uint256 eqLower,
        uint256 eqUpper,
        uint256 lastRebalance,
        uint256 frequency,
        uint256 offset,
        uint256 minimum,
        uint256 maxFlashFee,
        uint256 quote,
        bool minting
    );
    event ReplayState(
        bytes32 indexed txHash,
        address indexed vault,
        uint256 subDrBefore,
        uint256 subDrAfter,
        uint256 vmDrBefore,
        uint256 vmDrAfter,
        uint256 underlyingBefore,
        uint256 underlyingAfter,
        uint256 perpBefore,
        uint256 perpAfter,
        uint256 lastBefore,
        uint256 lastAfter
    );
    event ControllerCall(bytes32 indexed txHash, uint256 indexed ordinal, bytes4 selector, bytes data);
    event TargetDrQuote(
        address indexed vault,
        uint256 configuredTarget,
        uint256 lower,
        uint256 upper,
        uint256 systemDr,
        uint256 underlyingAmount,
        bool isMintingPerp
    );
    event SetterObservation(string label, bool success, bytes result);

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FIXED_BLOCK);
    }

    function testObserveFixedPhase2ConfigBothSides() public {
        (uint256 subDR, uint256 vmDR) = ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemDeviations();
        assertEq(subDR, 1_052_430_305_854_682_822);
        assertEq(vmDR, 1_000_210_729_013_702_352);
        assertEq(ITargetUnderlyingVaultControllerPhase2(CONTROLLER).targetSystemRatio(), 2_847_475_019_000_000_000);
        emit log_named_uint("controller.subDR", subDR);
        emit log_named_uint("controller.vmDR", vmDR);
        emit log_named_uint(
            "controller.targetSystemRatio", ITargetUnderlyingVaultControllerPhase2(CONTROLLER).targetSystemRatio()
        );
        _logControllerState("fixed");
        _observeConfig(ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT));
        _observeConfig(ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT));
        _assertFixedJuniorConfig();
        _assertFixedSeniorConfig();
    }

    function testObserveDeploymentDefaultsBothSides() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 51_749_808);
        _assertDeploymentDefaults(ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT));
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 51_749_809);
        _assertDeploymentDefaults(ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT));
    }

    function testReplayNaturalJuniorMintRebalance() public {
        _replay(
            JUNIOR_MINT_TX,
            JUNIOR_VAULT,
            ReplayExpectation(
                1_025_799_406_232_600_248,
                856_406,
                856_406,
                true,
                abi.encodeWithSelector(FLASH_MINT_SELECTOR, 0, 856_406, 0, 0)
            )
        );
    }

    function testObserveNaturalJuniorMintUncappedFormula() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 51_774_759);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT);
        ITargetUnderlyingVaultControllerPhase2 controller = ITargetUnderlyingVaultControllerPhase2(CONTROLLER);
        (uint256 quote, bool minting) = vault.computeRebalanceAmount();
        assertEq(quote, 745_119);
        assertTrue(minting);
        assertGt(vault.underlyingBalance(), quote, "candidate remained asset capped");
        _assertIndependentQuoteModel(vault, controller, quote, minting);
        emit log_named_bytes32("nextBlock.rebalanceTx", JUNIOR_MINT_UNCAPPED_TX);
    }

    function testReplayNaturalSeniorMintRebalance() public {
        _replay(
            SENIOR_MINT_TX,
            SENIOR_VAULT,
            ReplayExpectation(
                1_062_913_147_046_080_812,
                56_584,
                56_584,
                true,
                abi.encodeWithSelector(FLASH_MINT_SELECTOR, 56_584, 0, 0, 0)
            )
        );
    }

    function testReplayNaturalJuniorRedeemRebalance() public {
        _replay(
            JUNIOR_REDEEM_TX,
            JUNIOR_VAULT,
            ReplayExpectation(
                1_074_832_671_032_280_587,
                2_896_807,
                2_896_806,
                false,
                abi.encodeWithSelector(FLASH_REDEEM_SELECTOR, 0, 244_104_743_210, 0)
            )
        );
    }

    function testReplayNaturalSeniorRedeemRebalance() public {
        _replay(
            SENIOR_REDEEM_TX,
            SENIOR_VAULT,
            ReplayExpectation(
                1_041_814_726_540_642_981,
                129_350,
                129_138,
                false,
                abi.encodeWithSelector(FLASH_REDEEM_SELECTOR, 10_890_264_276, 0, 0)
            )
        );
    }

    function testSyntheticForkTargetDrDirectionAndQuoteMatrix() public {
        (uint256 subDR,) = ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemDeviations();
        uint96 currentDr = uint96(subDR);
        uint96 delta = 1e16;

        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT), currentDr - delta, 3_613_038, false);
        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT), currentDr, 0, false);
        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT), currentDr + delta, 0, true);
        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT), currentDr - delta, 1_217_210, true);
        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT), currentDr, 0, false);
        _observeTargetDrQuote(ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT), currentDr + delta, 1_194_296, false);
    }

    function testSyntheticForkSeniorEqRangeEdgesAreInclusive() public {
        (uint256 rawDr,) = ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemDeviations();
        uint96 dr = uint96(rawDr);
        uint96 delta = 1e16;
        ITargetUnderlyingPerpVaultPhase2 senior = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);

        _assertRangeQuote(senior, dr - delta, dr - delta, dr, 0, true);
        _assertRangeQuote(senior, dr - delta, dr - delta, dr - 1, 1_217_210, true);
        _assertRangeQuote(senior, dr + delta, dr, dr + delta, 0, false);
        _assertRangeQuote(senior, dr + delta, dr + 1, dr + delta, 1_194_296, false);
    }

    function testSyntheticForkJuniorEqRangeEdgesAreInclusive() public {
        (uint256 rawDr,) = ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemDeviations();
        uint96 dr = uint96(rawDr);
        uint96 delta = 1e16;
        ITargetUnderlyingPerpVaultPhase2 junior = ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT);
        _assertRangeQuote(junior, dr - delta, dr - delta, dr, 0, false);
        _assertRangeQuote(junior, dr - delta, dr - delta, dr - 1, 3_613_038, false);
        _assertRangeQuote(junior, dr + delta, dr, dr + delta, 0, true);
        _assertRangeQuote(junior, dr + delta, dr + 1, dr + delta, 0, true);
    }

    function testSyntheticForkRebalanceIsPermissionlessForOwnerKeeperAndRandom() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_MINT_TX);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        address configuredKeeper = address(0xCA11);
        address random = address(0xBEEF);
        address owner = vault.owner();
        vm.prank(owner);
        vault.updateKeeper(configuredKeeper);
        uint256 snapshot = vm.snapshotState();

        _callRebalanceAs(vault, owner);
        assertTrue(vm.revertToState(snapshot));
        _callRebalanceAs(vault, configuredKeeper);
        assertTrue(vm.revertToState(snapshot));
        _callRebalanceAs(vault, random);
    }

    function testSyntheticForkTimingUsesAlignedBucketAndExactCooldownBoundary() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_MINT_TX);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        vm.prank(vault.owner());
        vault.updateRebalanceTimingParams(100, 50);
        uint256 callTimestamp = block.timestamp;

        vm.prank(address(0xBEEF));
        vault.rebalance();
        uint64 aligned = uint64(((callTimestamp - 50) / 100) * 100 + 50);
        assertEq(vault.lastRebalanceTimestampSec(), aligned);

        vm.warp(uint256(aligned) + 99);
        vm.prank(address(0xBEEF));
        vm.expectRevert(LAST_REBALANCE_TOO_RECENT_SELECTOR);
        vault.rebalance();

        vm.warp(uint256(aligned) + 100);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSignature("OpUnavailable(string)", "no capacity"));
        vault.rebalance();
    }

    function testSyntheticForkMinimumAmountBoundary() public {
        _assertMinimumBoundary(856_405, true);
        _assertMinimumBoundary(856_406, true);
        _assertMinimumBoundary(856_407, false);
    }

    function testSyntheticForkMaxFlashFeeBoundaryAndAtomicFailure() public {
        _assertMaxFlashFeeBoundary(SENIOR_REDEEM_TOTAL_FEE - 1, false);
        _assertMaxFlashFeeBoundary(SENIOR_REDEEM_TOTAL_FEE, true);
    }

    function testObserveTargetDrSetterValidation() public {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        address owner = vault.owner();
        uint96 wad = 1e18;
        _assertSetterSuccess(
            "target.valid.equal", address(vault), owner, abi.encodeCall(vault.updateTargetDR, (wad, DRRange(wad, wad)))
        );
        _assertSetterFailure(
            "target.zero",
            address(vault),
            owner,
            abi.encodeCall(vault.updateTargetDR, (0, DRRange(0, 0))),
            abi.encodeWithSignature("InvalidParamDefn()")
        );
        _assertSetterFailure(
            "target.lower.gt.upper",
            address(vault),
            owner,
            abi.encodeCall(vault.updateTargetDR, (wad, DRRange(wad + 1, wad - 1))),
            abi.encodeWithSignature("InvalidRange()")
        );
        _assertSetterFailure(
            "target.below.range",
            address(vault),
            owner,
            abi.encodeCall(vault.updateTargetDR, (wad, DRRange(wad + 1, wad + 2))),
            abi.encodeWithSignature("InvalidRange()")
        );
        _assertSetterFailure(
            "target.above.range",
            address(vault),
            owner,
            abi.encodeCall(vault.updateTargetDR, (wad, DRRange(wad - 2, wad - 1))),
            abi.encodeWithSignature("InvalidRange()")
        );
    }

    function testObserveTimingSetterValidation() public {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        address owner = vault.owner();
        _assertSetterFailure(
            "timing.zero",
            address(vault),
            owner,
            abi.encodeCall(vault.updateRebalanceTimingParams, (0, 0)),
            abi.encodeWithSignature("InvalidParamDefn()")
        );
        _assertSetterSuccess(
            "timing.one", address(vault), owner, abi.encodeCall(vault.updateRebalanceTimingParams, (1, 0))
        );
        _assertSetterSuccess(
            "timing.offset.minus.one",
            address(vault),
            owner,
            abi.encodeCall(vault.updateRebalanceTimingParams, (100, 99))
        );
        _assertSetterFailure(
            "timing.offset.equal",
            address(vault),
            owner,
            abi.encodeCall(vault.updateRebalanceTimingParams, (100, 100)),
            abi.encodeWithSignature("InvalidParamDefn()")
        );
        _assertSetterFailure(
            "timing.offset.plus.one",
            address(vault),
            owner,
            abi.encodeCall(vault.updateRebalanceTimingParams, (100, 101)),
            abi.encodeWithSignature("InvalidParamDefn()")
        );
    }

    function testObserveMinimumAndFeeSetterValidation() public {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        address owner = vault.owner();
        _assertSetterSuccess("minimum.zero", address(vault), owner, abi.encodeCall(vault.updateMinRebalanceAmt, (0)));
        _assertSetterSuccess("minimum.one", address(vault), owner, abi.encodeCall(vault.updateMinRebalanceAmt, (1)));
        _assertSetterSuccess(
            "minimum.max", address(vault), owner, abi.encodeCall(vault.updateMinRebalanceAmt, (type(uint128).max))
        );
        _assertSetterSuccess("fee.zero", address(vault), owner, abi.encodeCall(vault.updateMaxFlashFeePerc, (0)));
        _assertSetterSuccess(
            "fee.wad", address(vault), owner, abi.encodeCall(vault.updateMaxFlashFeePerc, (uint64(1e18)))
        );
        _assertSetterFailure(
            "fee.wad.plus.one",
            address(vault),
            owner,
            abi.encodeCall(vault.updateMaxFlashFeePerc, (uint64(1e18 + 1))),
            abi.encodeWithSignature("InvalidPerc()")
        );
    }

    function testObserveSetterAuthorization() public {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        _assertSetterAuthorization(vault, abi.encodeCall(vault.updateMinRebalanceAmt, (1)));
        _assertSetterAuthorization(vault, abi.encodeCall(vault.updateMaxFlashFeePerc, (uint64(1))));
        _assertSetterAuthorization(vault, abi.encodeCall(vault.updateRebalanceTimingParams, (100, 0)));
        _assertSetterAuthorization(vault, abi.encodeCall(vault.updateTargetDR, (uint96(1e18), DRRange(1e18, 1e18))));
    }

    function _observeConfig(ITargetUnderlyingPerpVaultPhase2 vault) private {
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        (uint256 quote, bool minting) = vault.computeRebalanceAmount();
        assertEq(address(uint160(uint256(vm.load(address(vault), IMPLEMENTATION_SLOT)))), IMPLEMENTATION);
        assertEq(IMPLEMENTATION.codehash, IMPLEMENTATION_CODEHASH);
        emit FixedConfig(
            address(vault),
            vault.targetDR(),
            lower,
            upper,
            vault.lastRebalanceTimestampSec(),
            vault.rebalanceFreqSec(),
            vault.rebalanceOffsetSec(),
            vault.minRebalanceVal(),
            vault.maxFlashFeePerc(),
            quote,
            minting
        );
        emit log_named_address("vault", address(vault));
        emit log_named_uint("targetDR", vault.targetDR());
        emit log_named_uint("eq.lower", lower);
        emit log_named_uint("eq.upper", upper);
        emit log_named_uint("lastRebalanceTimestampSec", vault.lastRebalanceTimestampSec());
        emit log_named_uint("rebalanceFreqSec", vault.rebalanceFreqSec());
        emit log_named_uint("rebalanceOffsetSec", vault.rebalanceOffsetSec());
        emit log_named_uint("minRebalanceVal", vault.minRebalanceVal());
        emit log_named_uint("maxFlashFeePerc", vault.maxFlashFeePerc());
        emit log_named_uint("quote.underlying", quote);
        emit log_named_uint("quote.minting", minting ? 1 : 0);
    }

    function _assertFixedJuniorConfig() private view {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        (uint256 quote, bool minting) = vault.computeRebalanceAmount();
        assertEq(vault.targetDR(), 1_053_564_994_000_000_000);
        assertEq(lower, 1_053_564_994_000_000_000);
        assertEq(upper, 1_230_000_000_000_000_000);
        assertEq(vault.lastRebalanceTimestampSec(), 1_793_318_400);
        assertEq(vault.rebalanceFreqSec(), 28_800);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.minRebalanceVal(), 100_000);
        assertEq(vault.maxFlashFeePerc(), 5_000_000_000_000_000);
        assertEq(quote, 0);
        assertTrue(minting);
    }

    function _assertFixedSeniorConfig() private view {
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        (uint256 quote, bool minting) = vault.computeRebalanceAmount();
        assertEq(vault.targetDR(), 1_053_564_994_000_000_000);
        assertEq(lower, 1_043_029_344_100_000_000);
        assertEq(upper, 1_064_100_643_900_000_000);
        assertEq(vault.lastRebalanceTimestampSec(), 1_793_785_200);
        assertEq(vault.rebalanceFreqSec(), 28_800);
        assertEq(vault.rebalanceOffsetSec(), 6_000);
        assertEq(vault.minRebalanceVal(), 100_000);
        assertEq(vault.maxFlashFeePerc(), 5_000_000_000_000_000);
        assertEq(quote, 0);
        assertFalse(minting);
    }

    function _assertDeploymentDefaults(ITargetUnderlyingPerpVaultPhase2 vault) private view {
        (uint96 lower, uint96 upper) = vault.eqDRRange();
        assertEq(vault.targetDR(), 1e18);
        assertEq(lower, 1e18);
        assertEq(upper, 1e18);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
        assertEq(vault.rebalanceFreqSec(), 86_400);
        assertEq(vault.rebalanceOffsetSec(), 0);
        assertEq(vault.minRebalanceVal(), 0);
        assertEq(vault.maxFlashFeePerc(), 1e16);
    }

    function _replay(bytes32 txHash, address vaultAddress, ReplayExpectation memory expected) private {
        uint256 forkId = vm.createSelectFork(vm.envString("BASE_RPC_URL"), txHash);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(vaultAddress);
        ITargetUnderlyingVaultControllerPhase2 controller = ITargetUnderlyingVaultControllerPhase2(CONTROLLER);

        (uint256 quote, bool minting) = vault.computeRebalanceAmount();
        ReplaySnapshot memory beforeState = _readReplaySnapshot(vault, controller);
        _logControllerState("replay.before");
        assertEq(quote, expected.grossUnderlying, "historical quote");
        assertEq(minting, expected.minting, "historical quote direction");
        assertEq(beforeState.subDr, expected.drBefore, "historical pre-DR");
        _assertIndependentQuoteModel(vault, controller, quote, minting);

        vm.recordLogs();
        vm.startStateDiffRecording();
        vm.transact(forkId, txHash);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        ReplaySnapshot memory afterState = _readReplaySnapshot(vault, controller);
        _logControllerState("replay.after");
        _logTargetFlashFee(vault, controller, beforeState, afterState);
        assertEq(afterState.notes, beforeState.notes, "rebalance changed notes supply");
        if (expected.minting) {
            assertEq(beforeState.underlying - afterState.underlying, expected.actualUnderlying, "mint underlying delta");
            assertGt(afterState.perp, beforeState.perp, "mint did not add Perp");
        } else {
            assertEq(
                afterState.underlying - beforeState.underlying, expected.actualUnderlying, "redeem underlying delta"
            );
            assertLt(afterState.perp, beforeState.perp, "redeem did not consume Perp");
        }
        assertGt(afterState.last, beforeState.last, "rebalance timestamp not advanced");
        _assertRebalanceEvent(logs, vaultAddress, expected.drBefore, expected.grossUnderlying, expected.minting);
        _assertControllerCall(accesses, txHash, expected.controllerCalldata);

        emit ReplayState(
            txHash,
            vaultAddress,
            beforeState.subDr,
            afterState.subDr,
            beforeState.vmDr,
            afterState.vmDr,
            beforeState.underlying,
            afterState.underlying,
            beforeState.perp,
            afterState.perp,
            beforeState.last,
            afterState.last
        );
        emit log_named_bytes32("replay.tx", txHash);
        emit log_named_uint("replay.subDrAfter", afterState.subDr);
        emit log_named_uint("replay.vmDrBefore", beforeState.vmDr);
        emit log_named_uint("replay.vmDrAfter", afterState.vmDr);
        emit log_named_uint("replay.underlyingBefore", beforeState.underlying);
        emit log_named_uint("replay.underlyingAfter", afterState.underlying);
        emit log_named_uint("replay.perpBefore", beforeState.perp);
        emit log_named_uint("replay.perpAfter", afterState.perp);
        emit log_named_uint("replay.lastBefore", beforeState.last);
        emit log_named_uint("replay.lastAfter", afterState.last);
    }

    function _readReplaySnapshot(
        ITargetUnderlyingPerpVaultPhase2 vault,
        ITargetUnderlyingVaultControllerPhase2 controller
    ) private view returns (ReplaySnapshot memory state) {
        (state.subDr, state.vmDr) = controller.systemDeviations();
        state.underlying = vault.underlyingBalance();
        state.perp = vault.perpBalance();
        state.notes = vault.totalSupply();
        state.last = vault.lastRebalanceTimestampSec();
    }

    function _assertIndependentQuoteModel(
        ITargetUnderlyingPerpVaultPhase2 vault,
        ITargetUnderlyingVaultControllerPhase2 controller,
        uint256 observedQuote,
        bool minting
    ) private view {
        ITargetUnderlyingVaultControllerPhase2.SystemState memory state = controller.systemReserveState();
        ITargetUnderlyingVaultControllerPhase2.PerpState memory selected =
            vault.isPerpSrVault() ? state.perpSr : state.perpJr;
        uint256 denominator = controller.targetSystemRatio() * uint256(vault.targetDR());
        uint256 targetReserve;
        uint256 systemCapacity;
        if (vault.isPerpSrVault()) {
            targetReserve = minting
                ? Math.mulDiv(state.perpJr.reserveValue, 1e36, denominator)
                : Math.mulDiv(state.perpJr.reserveValue, 1e36, denominator, Math.Rounding.Ceil);
        } else {
            targetReserve = minting
                ? Math.mulDiv(state.perpSr.reserveValue, denominator, 1e36)
                : Math.mulDiv(state.perpSr.reserveValue, denominator, 1e36, Math.Rounding.Ceil);
        }
        if (minting) {
            systemCapacity = targetReserve > selected.reserveValue ? targetReserve - selected.reserveValue : 0;
        } else {
            systemCapacity = selected.reserveValue > targetReserve ? selected.reserveValue - targetReserve : 0;
        }
        uint256 assetCapacity = minting
            ? vault.underlyingBalance()
            : Math.mulDiv(vault.perpBalance(), selected.reserveValue, selected.totalSupply);
        assertEq(observedQuote, Math.min(systemCapacity, assetCapacity), "independent quote model");
    }

    function _logTargetFlashFee(
        ITargetUnderlyingPerpVaultPhase2 vault,
        ITargetUnderlyingVaultControllerPhase2 controller,
        ReplaySnapshot memory beforeState,
        ReplaySnapshot memory afterState
    ) private {
        FeePolicy.OpSystemChange memory change = FeePolicy.OpSystemChange({
            subDRPre: beforeState.subDr,
            subDRPost: afterState.subDr,
            vmDRPre: beforeState.vmDr,
            vmDRPost: afterState.vmDr
        });
        FeePolicy.OpFees memory fee = FeePolicy(controller.feePolicy())
            .computeOpFees(
                FeePolicy.OpFeeInput({isPerpSrOp: vault.isPerpSrVault(), isFlashOp: true, systemDeviation: change})
            );
        emit log_named_uint("replay.targetTotalFeePerc", fee.totalFeePerc);
        emit log_named_uint("replay.targetProtocolFeePerc", fee.protocolFeePerc);
        assertLe(fee.totalFeePerc, vault.maxFlashFeePerc());
    }

    function _assertRebalanceEvent(
        Vm.Log[] memory logs,
        address vault,
        uint256 expectedDr,
        uint256 expectedUnderlying,
        bool expectedMinting
    ) private pure {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].emitter != vault || logs[i].topics[0] != REBALANCE_TOPIC) {
                continue;
            }
            (uint256 drBefore, uint256 underlyingAmt, bool minting) = abi.decode(logs[i].data, (uint256, uint256, bool));
            assertEq(drBefore, expectedDr);
            assertEq(underlyingAmt, expectedUnderlying);
            assertEq(minting, expectedMinting);
            ++matches;
        }
        assertEq(matches, 1, "unexpected Rebalance event count");
    }

    function _observeTargetDrQuote(
        ITargetUnderlyingPerpVaultPhase2 vault,
        uint96 configuredTarget,
        uint256 expectedAmount,
        bool expectedMinting
    ) private {
        uint256 snapshot = vm.snapshotState();
        DRRange memory range = DRRange({lower: configuredTarget - 1, upper: configuredTarget + 1});
        vm.prank(vault.owner());
        vault.updateTargetDR(configuredTarget, range);
        (uint256 subDR,) = ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemDeviations();
        (uint256 underlyingAmount, bool isMintingPerp) = vault.computeRebalanceAmount();
        assertEq(underlyingAmount, expectedAmount);
        assertEq(isMintingPerp, expectedMinting);
        emit TargetDrQuote(
            address(vault), configuredTarget, range.lower, range.upper, subDR, underlyingAmount, isMintingPerp
        );
        emit log_named_address("matrix.vault", address(vault));
        emit log_named_uint("matrix.target", configuredTarget);
        emit log_named_uint("matrix.underlying", underlyingAmount);
        emit log_named_uint("matrix.minting", isMintingPerp ? 1 : 0);
        assertTrue(vm.revertToState(snapshot));
    }

    function _assertRangeQuote(
        ITargetUnderlyingPerpVaultPhase2 vault,
        uint96 target,
        uint96 lower,
        uint96 upper,
        uint256 expectedAmount,
        bool expectedMinting
    ) private {
        uint256 snapshot = vm.snapshotState();
        vm.prank(vault.owner());
        vault.updateTargetDR(target, DRRange({lower: lower, upper: upper}));
        (uint256 amount, bool minting) = vault.computeRebalanceAmount();
        assertEq(amount, expectedAmount);
        assertEq(minting, expectedMinting);
        assertTrue(vm.revertToState(snapshot));
    }

    function _callRebalanceAs(ITargetUnderlyingPerpVaultPhase2 vault, address caller) private {
        vm.prank(caller);
        vault.rebalance();
    }

    function _assertMinimumBoundary(uint128 minimum, bool shouldSucceed) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), JUNIOR_MINT_TX);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(JUNIOR_VAULT);
        vm.prank(vault.owner());
        vault.updateMinRebalanceAmt(minimum);
        if (shouldSucceed) {
            vm.prank(address(0xBEEF));
            vault.rebalance();
        } else {
            vm.prank(address(0xBEEF));
            vm.expectRevert(abi.encodeWithSignature("OpUnavailable(string)", "no capacity"));
            vault.rebalance();
        }
    }

    function _assertMaxFlashFeeBoundary(uint64 maximum, bool shouldSucceed) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), SENIOR_REDEEM_TX);
        ITargetUnderlyingPerpVaultPhase2 vault = ITargetUnderlyingPerpVaultPhase2(SENIOR_VAULT);
        vm.prank(vault.owner());
        vault.updateMaxFlashFeePerc(maximum);
        bytes32 beforeFingerprint = _fingerprint(vault);
        uint64 beforeTimestamp = vault.lastRebalanceTimestampSec();
        if (shouldSucceed) {
            vm.prank(address(0xBEEF));
            vault.rebalance();
            assertGt(vault.lastRebalanceTimestampSec(), beforeTimestamp);
        } else {
            vm.prank(address(0xBEEF));
            vm.expectRevert(abi.encodeWithSignature("SlippageTooHigh()"));
            vault.rebalance();
            assertEq(_fingerprint(vault), beforeFingerprint, "flash-fee failure not atomic");
        }
    }

    function _fingerprint(ITargetUnderlyingPerpVaultPhase2 vault) private view returns (bytes32) {
        ITargetUnderlyingVaultControllerPhase2 controller = ITargetUnderlyingVaultControllerPhase2(CONTROLLER);
        ITargetUnderlyingVaultControllerPhase2.SystemState memory state = controller.systemReserveState();
        (uint256 subDR, uint256 vmDR) = controller.systemDeviations();
        return keccak256(
            abi.encode(
                vault.underlyingBalance(),
                vault.perpBalance(),
                vault.totalSupply(),
                vault.lastRebalanceTimestampSec(),
                subDR,
                vmDR,
                state
            )
        );
    }

    function _assertSetterSuccess(string memory label, address target, address caller, bytes memory payload) private {
        (bool success, bytes memory result) = _observeSetter(label, target, caller, payload);
        assertTrue(success);
        assertEq(result, bytes(""));
    }

    function _assertSetterFailure(
        string memory label,
        address target,
        address caller,
        bytes memory payload,
        bytes memory expectedResult
    ) private {
        (bool success, bytes memory result) = _observeSetter(label, target, caller, payload);
        assertFalse(success);
        assertEq(result, expectedResult);
    }

    function _assertSetterAuthorization(ITargetUnderlyingPerpVaultPhase2 vault, bytes memory payload) private {
        address owner = vault.owner();
        address separatedKeeper = address(0xCA11);
        if (vault.keeper() != separatedKeeper) {
            vm.prank(owner);
            vault.updateKeeper(separatedKeeper);
        }
        assertTrue(owner != separatedKeeper, "roles not separated");
        _assertSetterSuccess("auth.owner", address(vault), owner, payload);
        _assertSetterFailure(
            "auth.keeper",
            address(vault),
            separatedKeeper,
            payload,
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", separatedKeeper)
        );
        address random = address(0xBEEF);
        _assertSetterFailure(
            "auth.random",
            address(vault),
            random,
            payload,
            abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", random)
        );
    }

    function _observeSetter(string memory label, address target, address caller, bytes memory payload)
        private
        returns (bool success, bytes memory result)
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (success, result) = target.call(payload);
        emit SetterObservation(label, success, result);
        emit log_string(label);
        emit log_named_uint("setter.success", success ? 1 : 0);
        emit log_named_bytes("setter.result", result);
        assertTrue(vm.revertToState(snapshot));
    }

    function _assertControllerCall(Vm.AccountAccess[] memory accesses, bytes32 txHash, bytes memory expectedCalldata)
        private
    {
        bytes4 expectedSelector = bytes4(expectedCalldata);
        uint256 matches;
        uint256 ordinal;
        for (uint256 i; i < accesses.length; ++i) {
            if (accesses[i].account != CONTROLLER || accesses[i].data.length < 4) continue;
            bytes4 selector = bytes4(accesses[i].data);
            emit ControllerCall(txHash, ordinal++, selector, accesses[i].data);
            _logControllerCalldata(selector, accesses[i].data);
            if (selector == expectedSelector) {
                emit log_named_bytes("controller.actualCalldata", accesses[i].data);
                emit log_named_bytes("controller.expectedCalldata", expectedCalldata);
            }
            if (
                selector == expectedSelector && keccak256(accesses[i].data) == keccak256(expectedCalldata)
                    && !accesses[i].reverted
            ) ++matches;
        }
        assertEq(matches, 1, "expected Controller execution call");
    }

    function _logControllerCalldata(bytes4 selector, bytes memory data) private {
        if (selector == FLASH_MINT_SELECTOR) {
            _logFlashMintCalldata(data);
        } else if (selector == FLASH_REDEEM_SELECTOR) {
            _logFlashRedeemCalldata(data);
        }
    }

    function _logFlashMintCalldata(bytes memory data) private {
        (uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut) =
            abi.decode(_withoutSelector(data), (uint256, uint256, uint256, uint256));
        emit log_named_uint("controller.flashMint.srUnderlying", srUnderlying);
        emit log_named_uint("controller.flashMint.jrUnderlying", jrUnderlying);
        emit log_named_uint("controller.flashMint.minSrOut", minSrOut);
        emit log_named_uint("controller.flashMint.minJrOut", minJrOut);
    }

    function _logFlashRedeemCalldata(bytes memory data) private {
        (uint256 srIn, uint256 jrIn, uint256 minUnderlyingOut) =
            abi.decode(_withoutSelector(data), (uint256, uint256, uint256));
        emit log_named_uint("controller.flashRedeem.srIn", srIn);
        emit log_named_uint("controller.flashRedeem.jrIn", jrIn);
        emit log_named_uint("controller.flashRedeem.minUnderlyingOut", minUnderlyingOut);
    }

    function _withoutSelector(bytes memory input) private pure returns (bytes memory output) {
        assertGe(input.length, 4, "selector missing");
        output = new bytes(input.length - 4);
        for (uint256 i; i < output.length; ++i) {
            output[i] = input[i + 4];
        }
    }

    function _logControllerState(string memory label) private {
        ITargetUnderlyingVaultControllerPhase2.SystemState memory state =
            ITargetUnderlyingVaultControllerPhase2(CONTROLLER).systemReserveState();
        emit log_string(label);
        emit log_named_uint("reserve.srSupply", state.perpSr.totalSupply);
        emit log_named_uint("reserve.srValue", state.perpSr.reserveValue);
        emit log_named_uint("reserve.srVm", state.perpSr.vm);
        emit log_named_uint("reserve.jrSupply", state.perpJr.totalSupply);
        emit log_named_uint("reserve.jrValue", state.perpJr.reserveValue);
        emit log_named_uint("reserve.jrVm", state.perpJr.vm);
    }
}
