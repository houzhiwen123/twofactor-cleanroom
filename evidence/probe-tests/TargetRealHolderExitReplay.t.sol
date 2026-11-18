// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {FeePolicy} from "../../src/policy/FeePolicy.sol";

interface IERC20Replay {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface ITargetControllerReplay {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function collectedFeeBal(address token) external view returns (uint256);
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function systemReserveState()
        external
        view
        returns (SystemState memory state, ReserveData memory perpSrRd, ReserveData memory perpJrRd);
    function redeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minValOut)
        external
        returns (
            ReserveAmounts memory returnedPerpSrReserveAmounts,
            ReserveAmounts memory returnedPerpJrReserveAmounts,
            FeePerc memory perpSrFeePerc,
            FeePerc memory perpJrFeePerc
        );
    function flashRedeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minUnderlyingAmtOut)
        external
        returns (uint256 underlyingAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
}

interface IUsdVaultReplay {
    function computeRedemptionAmts(uint256 notesAmt) external view returns (uint256 usdAmtOut, uint256 perpSrAmtOut);
    function perpSrBalance() external view returns (uint256);
    function redeem(uint256 notesAmt) external returns (uint256 usdAmtOut, uint256 perpSrAmtOut);
    function usdBalance() external view returns (uint256);
}

/// @notice Strict transaction-index prestate replays using only public Base state and natural balances.
/// @dev No deal/store target mutation is used. Vault and Router observations are target-only because the
///      clean-room project does not yet implement those production modules.
contract TargetRealHolderExitReplayTest is Test {
    bytes32 private constant ADVANCED_REDEEM_TX = 0x98fceb34a3ddb3b6ac1ed396fbb5250ce05cfb75c8827910aa4e13d6cee92173;
    bytes32 private constant USD_VAULT_REDEEM_TX = 0x69303607f150b7ccd9e3137a1e621cc18437405f7788dfc35dc122537148be44;
    bytes32 private constant SINGLE_ASSET_REDEEM_TX =
        0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab;

    uint256 private constant ADVANCED_REDEEM_BLOCK = 51_777_385;
    uint256 private constant USD_VAULT_REDEEM_BLOCK = 51_820_780;
    uint256 private constant SINGLE_ASSET_REDEEM_BLOCK = 53_243_583;
    uint256 private constant ADVANCED_REDEEM_TX_INDEX = 125;
    uint256 private constant USD_VAULT_REDEEM_TX_INDEX = 61;
    uint256 private constant SINGLE_ASSET_REDEEM_TX_INDEX = 77;

    address private constant REAL_HOLDER = 0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b;
    address private constant SMART_ACCOUNT = 0x11649A794F918508027765F6280c1b396EE59F8F;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant USD_VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant SINGLE_ASSET_ROUTER = 0x8e868C1f8F82b84a6B0D19d235d50c47b253559f;
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;

    uint256 private constant CONTROLLER_JR_IN = 21_200_000_000;
    uint256 private constant CONTROLLER_EXACT_MIN_VALUE = 251_879;
    uint256 private constant VAULT_NOTES_IN = 11_042_700_000_000_000_000_000;
    uint256 private constant VAULT_USD_OUT = 10_779_663_296;
    uint256 private constant VAULT_PERP_SR_OUT = 26_250_405_020;
    uint256 private constant ROUTER_NOTES_IN = 3_762_930_374_354_620_392;
    uint256 private constant ROUTER_HISTORICAL_MIN_USD_OUT = 3_761_293;
    uint256 private constant ROUTER_EXACT_USD_OUT = 3_780_194;
    uint256 private constant ROUTER_DIRECT_VAULT_USD_OUT = 1_294;
    uint256 private constant ROUTER_VAULT_PERP_SR_OUT = 375_200_394;
    uint256 private constant ROUTER_DEX_USD_OUT = 3_778_900;

    bytes4 private constant SLIPPAGE_EXCEEDED_LIMIT = 0xbc3944e7;
    bytes4 private constant REDEEM_USD_SELECTOR = 0xbc944eae;
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant CONTROLLER_PROXY_CODEHASH =
        0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e;
    address private constant CONTROLLER_IMPLEMENTATION = 0x16e324BAe2098317477129a5E71f770bFf51f02a;
    bytes32 private constant CONTROLLER_IMPLEMENTATION_CODEHASH =
        0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31;
    bytes32 private constant FEE_POLICY_PROXY_CODEHASH =
        0x2a16f92d0d60ffb240c4be576111b0e8a195a4c5b0f98856380c8943b9bbaa44;
    address private constant FEE_POLICY_IMPLEMENTATION = 0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900;
    bytes32 private constant FEE_POLICY_IMPLEMENTATION_CODEHASH =
        0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755;
    bytes32 private constant USD_VAULT_PROXY_CODEHASH =
        0x09099f0c6e5a45bc0cb72ba0f8f08f637304a410ae758b21a88589ad7240242b;
    address private constant USD_VAULT_OLD_IMPLEMENTATION = 0x569021bc0975AD5B67793Cd31D9E2b0707A9f626;
    bytes32 private constant USD_VAULT_OLD_IMPLEMENTATION_CODEHASH =
        0x39e3ae92930befdd960644c662c9386f98f17a80117974b84d15371ebe354c21;
    address private constant USD_VAULT_NEW_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    bytes32 private constant USD_VAULT_NEW_IMPLEMENTATION_CODEHASH =
        0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4;
    bytes32 private constant SINGLE_ASSET_ROUTER_CODEHASH =
        0x33f265f8c51da59240326566d89a19548bf6ebeb9bb225cb1ab8079d701d71bf;
    bytes32 private constant DEX_STRATEGY_CODEHASH = 0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302;
    bytes32 private constant REDEEM_EVENT = keccak256("Redeem(uint256,uint256,uint256)");
    bytes32 private constant OP_FEES_EVENT = keccak256("OpFees(address,uint256,uint256)");
    bytes32 private constant TRANSFER_EVENT = keccak256("Transfer(address,address,uint256)");

    struct SystemSnapshot {
        uint256 subDR;
        uint256 vmDR;
        uint256 srSupply;
        uint256 jrSupply;
        uint256 srReserveValue;
        uint256 jrReserveValue;
        bytes32 srReserveHash;
        bytes32 jrReserveHash;
    }

    event ReplayVector(
        uint8 indexed layer,
        bytes32 indexed txHash,
        uint256 blockNumber,
        uint256 transactionIndex,
        address naturalHolder
    );
    event ComponentVersion(
        uint8 indexed layer,
        uint8 indexed component,
        address target,
        address implementation,
        bytes32 targetCodehash,
        bytes32 implementationCodehash
    );
    event ControllerExitResult(
        uint256 jrIn,
        uint256 minValue,
        uint256 preSubDR,
        uint256 postSubDR,
        uint256 preVmDR,
        uint256 postVmDR,
        uint256 jrTotalFee,
        uint256 jrProtocolFee,
        uint256 underlyingOut,
        uint256 trancheCount,
        uint256 jrSupplyBefore,
        uint256 jrSupplyAfter,
        uint256 collectedFeeBefore,
        uint256 collectedFeeAfter
    );
    event ControllerReserveAsset(
        uint256 indexed assetIndex,
        address indexed token,
        uint256 reserveBefore,
        uint256 reserveAfter,
        uint256 userDelta,
        uint256 returnedAmount,
        uint256 valueBefore,
        uint256 valueAfter
    );
    event FeeCompatibility(
        uint8 indexed side,
        uint256 targetTotal,
        uint256 targetProtocol,
        uint256 cleanroomTotal,
        uint256 cleanroomProtocol,
        bool exactMatch
    );
    event SrExitLiquiditySource(
        uint256 srUnderlyingBefore,
        uint256 srUnderlyingAfter,
        uint256 jrUnderlyingBefore,
        uint256 jrUnderlyingAfter,
        uint256 controllerUnderlyingBefore,
        uint256 controllerUnderlyingAfter,
        uint256 srReserveValueBefore,
        uint256 srReserveValueAfter,
        uint256 jrReserveValueBefore,
        uint256 jrReserveValueAfter
    );
    event SrReserveTransferredToJr(address indexed tranche, uint256 amountMoved);
    event ControllerEventResult(
        uint8 indexed side,
        bytes32 indexed eventTopic,
        address indexed token,
        uint256 totalFeeAmount,
        uint256 protocolFeeAmount
    );
    event VaultExitResult(
        uint256 notesIn,
        uint256 quoteUsd,
        uint256 quotePerpSr,
        uint256 actualUsd,
        uint256 actualPerpSr,
        uint256 noteSupplyBefore,
        uint256 noteSupplyAfter,
        uint256 vaultUsdBefore,
        uint256 vaultUsdAfter,
        uint256 vaultPerpSrBefore,
        uint256 vaultPerpSrAfter
    );
    event RouterExitResult(
        uint256 notesIn,
        uint256 historicalMinOut,
        uint256 actualUsdOut,
        uint256 directVaultUsdOut,
        uint256 vaultPerpSrOut,
        uint256 dexUsdOut,
        bool healthCheck,
        bool maxItersPresent,
        address strategy
    );
    event FailureBoundary(
        uint8 indexed layer, uint256 attemptedInput, uint256 boundaryValue, bytes4 selector, bool stateUnchanged
    );

    function testControllerDirectNaturalHolderExitAndBoundary() public {
        _selectStrictFork(ADVANCED_REDEEM_TX, ADVANCED_REDEEM_BLOCK);
        emit ReplayVector(0, ADVANCED_REDEEM_TX, block.number, ADVANCED_REDEEM_TX_INDEX, REAL_HOLDER);
        _assertAndEmitVersion(
            0, 0, CONTROLLER, CONTROLLER_IMPLEMENTATION, CONTROLLER_PROXY_CODEHASH, CONTROLLER_IMPLEMENTATION_CODEHASH
        );
        _assertAndEmitVersion(
            0, 1, FEE_POLICY, FEE_POLICY_IMPLEMENTATION, FEE_POLICY_PROXY_CODEHASH, FEE_POLICY_IMPLEMENTATION_CODEHASH
        );

        assertGe(IERC20Replay(PERP_JR).balanceOf(REAL_HOLDER), CONTROLLER_JR_IN, "natural JR balance");
        vm.prank(REAL_HOLDER);
        assertTrue(IERC20Replay(PERP_JR).approve(CONTROLLER, CONTROLLER_JR_IN), "JR approval");

        uint256 cleanSnapshot = vm.snapshotState();
        _runControllerSuccess();
        assertTrue(vm.revertToState(cleanSnapshot), "restore controller prestate");

        bytes32 beforeFingerprint = _controllerFingerprint(REAL_HOLDER);
        vm.prank(REAL_HOLDER);
        (bool ok, bytes memory reason) = CONTROLLER.call(
            abi.encodeCall(
                ITargetControllerReplay.redeem2, (uint256(0), CONTROLLER_JR_IN, CONTROLLER_EXACT_MIN_VALUE + 1)
            )
        );
        assertFalse(ok, "controller min value + 1 unexpectedly succeeded");
        bytes4 selector = _selector(reason);
        assertEq(selector, SLIPPAGE_EXCEEDED_LIMIT, "controller failure selector");
        bool unchanged = _controllerFingerprint(REAL_HOLDER) == beforeFingerprint;
        assertTrue(unchanged, "controller failure was not atomic");
        emit FailureBoundary(0, CONTROLLER_JR_IN, CONTROLLER_EXACT_MIN_VALUE + 1, selector, unchanged);
    }

    function testVaultHistoricalNaturalHolderExitAndBalanceBoundary() public {
        uint256 forkId = _selectStrictFork(USD_VAULT_REDEEM_TX, USD_VAULT_REDEEM_BLOCK);
        emit ReplayVector(1, USD_VAULT_REDEEM_TX, block.number, USD_VAULT_REDEEM_TX_INDEX, REAL_HOLDER);
        _assertAndEmitVersion(
            1,
            0,
            USD_VAULT,
            USD_VAULT_OLD_IMPLEMENTATION,
            USD_VAULT_PROXY_CODEHASH,
            USD_VAULT_OLD_IMPLEMENTATION_CODEHASH
        );

        IUsdVaultReplay vault = IUsdVaultReplay(USD_VAULT);
        assertGe(IERC20Replay(USD_VAULT).balanceOf(REAL_HOLDER), VAULT_NOTES_IN, "natural vault notes");
        (uint256 quoteUsd, uint256 quotePerpSr) = vault.computeRedemptionAmts(VAULT_NOTES_IN);
        assertEq(quoteUsd, VAULT_USD_OUT, "vault quote USD");
        assertEq(quotePerpSr, VAULT_PERP_SR_OUT, "vault quote Perp SR");

        uint256 noteSupplyBefore = IERC20Replay(USD_VAULT).totalSupply();
        uint256 vaultUsdBefore = vault.usdBalance();
        uint256 vaultPerpBefore = vault.perpSrBalance();
        uint256 userUsdBefore = IERC20Replay(USDC).balanceOf(REAL_HOLDER);
        uint256 userPerpBefore = IERC20Replay(PERP_SR).balanceOf(REAL_HOLDER);
        uint256 replaySnapshot = vm.snapshotState();

        vm.recordLogs();
        vm.transact(forkId, USD_VAULT_REDEEM_TX);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 actualUsd = IERC20Replay(USDC).balanceOf(REAL_HOLDER) - userUsdBefore;
        uint256 actualPerp = IERC20Replay(PERP_SR).balanceOf(REAL_HOLDER) - userPerpBefore;
        uint256 noteSupplyAfter = IERC20Replay(USD_VAULT).totalSupply();
        uint256 vaultUsdAfter = vault.usdBalance();
        uint256 vaultPerpAfter = vault.perpSrBalance();
        assertEq(actualUsd, VAULT_USD_OUT, "vault actual USD");
        assertEq(actualPerp, VAULT_PERP_SR_OUT, "vault actual Perp SR");
        assertEq(noteSupplyBefore - noteSupplyAfter, VAULT_NOTES_IN, "vault notes supply burn");
        assertEq(vaultUsdBefore - vaultUsdAfter, actualUsd, "vault USD conservation");
        assertEq(vaultPerpBefore - vaultPerpAfter, actualPerp, "vault Perp conservation");
        _assertVaultRedeemEvent(logs);
        emit VaultExitResult(
            VAULT_NOTES_IN,
            quoteUsd,
            quotePerpSr,
            actualUsd,
            actualPerp,
            noteSupplyBefore,
            noteSupplyAfter,
            vaultUsdBefore,
            vaultUsdAfter,
            vaultPerpBefore,
            vaultPerpAfter
        );

        assertTrue(vm.revertToState(replaySnapshot), "restore vault prestate");
        uint256 invalidNotes = IERC20Replay(USD_VAULT).balanceOf(REAL_HOLDER) + 1;
        bytes32 beforeFingerprint = _vaultFingerprint(REAL_HOLDER);
        vm.prank(REAL_HOLDER);
        (bool ok, bytes memory reason) = USD_VAULT.call(abi.encodeCall(IUsdVaultReplay.redeem, (invalidNotes)));
        assertFalse(ok, "vault balance + 1 unexpectedly succeeded");
        bytes4 selector = _selector(reason);
        bool unchanged = _vaultFingerprint(REAL_HOLDER) == beforeFingerprint;
        assertTrue(unchanged, "vault failure was not atomic");
        emit FailureBoundary(1, invalidNotes, invalidNotes - 1, selector, unchanged);
    }

    function testRouterHistoricalNaturalHolderExitAndExactMinOutBoundary() public {
        uint256 forkId = _selectStrictFork(SINGLE_ASSET_REDEEM_TX, SINGLE_ASSET_REDEEM_BLOCK);
        emit ReplayVector(2, SINGLE_ASSET_REDEEM_TX, block.number, SINGLE_ASSET_REDEEM_TX_INDEX, SMART_ACCOUNT);
        _assertAndEmitVersion(2, 0, SINGLE_ASSET_ROUTER, address(0), SINGLE_ASSET_ROUTER_CODEHASH, bytes32(0));
        _assertAndEmitVersion(
            2,
            1,
            USD_VAULT,
            USD_VAULT_NEW_IMPLEMENTATION,
            USD_VAULT_PROXY_CODEHASH,
            USD_VAULT_NEW_IMPLEMENTATION_CODEHASH
        );
        _assertAndEmitVersion(2, 2, DEX_STRATEGY, address(0), DEX_STRATEGY_CODEHASH, bytes32(0));

        assertGe(IERC20Replay(USD_VAULT).balanceOf(SMART_ACCOUNT), ROUTER_NOTES_IN, "natural router notes");
        uint256 userUsdBefore = IERC20Replay(USDC).balanceOf(SMART_ACCOUNT);
        uint256 userNotesBefore = IERC20Replay(USD_VAULT).balanceOf(SMART_ACCOUNT);
        (uint256 directVaultUsdOut, uint256 vaultPerpSrOut) =
            IUsdVaultReplay(USD_VAULT).computeRedemptionAmts(ROUTER_NOTES_IN);
        assertEq(directVaultUsdOut, ROUTER_DIRECT_VAULT_USD_OUT, "router direct Vault USD");
        assertEq(vaultPerpSrOut, ROUTER_VAULT_PERP_SR_OUT, "router Vault Perp SR");
        uint256 replaySnapshot = vm.snapshotState();
        vm.transact(forkId, SINGLE_ASSET_REDEEM_TX);
        uint256 historicalUsdOut = IERC20Replay(USDC).balanceOf(SMART_ACCOUNT) - userUsdBefore;
        assertEq(historicalUsdOut, ROUTER_EXACT_USD_OUT, "router historical USD output");
        assertEq(
            userNotesBefore - IERC20Replay(USD_VAULT).balanceOf(SMART_ACCOUNT), ROUTER_NOTES_IN, "router notes burn"
        );
        emit RouterExitResult(
            ROUTER_NOTES_IN,
            ROUTER_HISTORICAL_MIN_USD_OUT,
            historicalUsdOut,
            directVaultUsdOut,
            vaultPerpSrOut,
            historicalUsdOut - directVaultUsdOut,
            true,
            false,
            DEX_STRATEGY
        );
        assertEq(historicalUsdOut - directVaultUsdOut, ROUTER_DEX_USD_OUT, "router DEX USD output");

        assertTrue(vm.revertToState(replaySnapshot), "restore router prestate");
        uint256 exactSnapshot = vm.snapshotState();
        _approveRouterNotes();
        uint256 exactBefore = IERC20Replay(USDC).balanceOf(SMART_ACCOUNT);
        vm.prank(SMART_ACCOUNT);
        (bool exactOk, bytes memory exactReason) = SINGLE_ASSET_ROUTER.call(_routerRedeemCalldata(ROUTER_EXACT_USD_OUT));
        if (!exactOk) revert(string(exactReason));
        assertEq(
            IERC20Replay(USDC).balanceOf(SMART_ACCOUNT) - exactBefore,
            ROUTER_EXACT_USD_OUT,
            "router exact minOut must be inclusive"
        );

        assertTrue(vm.revertToState(exactSnapshot), "restore router exact prestate");
        _approveRouterNotes();
        bytes32 beforeFingerprint = _routerFingerprint(SMART_ACCOUNT);
        vm.prank(SMART_ACCOUNT);
        (bool ok, bytes memory reason) = SINGLE_ASSET_ROUTER.call(_routerRedeemCalldata(ROUTER_EXACT_USD_OUT + 1));
        assertFalse(ok, "router minOut + 1 unexpectedly succeeded");
        bytes4 selector = _selector(reason);
        bool unchanged = _routerFingerprint(SMART_ACCOUNT) == beforeFingerprint;
        assertTrue(unchanged, "router failure was not atomic");
        emit FailureBoundary(2, ROUTER_NOTES_IN, ROUTER_EXACT_USD_OUT + 1, selector, unchanged);
    }

    /// @notice Proves where the target obtains cbBTC for an SR-only flash redemption.
    /// @dev Starts from the historical transaction prestate, redeems the natural holder's Vault
    ///      notes into its natural Perp SR output, then invokes the Controller directly. No target
    ///      balance or storage is manufactured.
    function testRouterHistoricalSrExitLiquiditySource() public {
        _selectStrictFork(SINGLE_ASSET_REDEEM_TX, SINGLE_ASSET_REDEEM_BLOCK);
        ITargetControllerReplay controller = ITargetControllerReplay(CONTROLLER);

        vm.prank(SMART_ACCOUNT);
        (, uint256 perpSrOut) = IUsdVaultReplay(USD_VAULT).redeem(ROUTER_NOTES_IN);
        assertEq(perpSrOut, ROUTER_VAULT_PERP_SR_OUT, "natural Vault Perp SR output");
        vm.prank(SMART_ACCOUNT);
        assertTrue(IERC20Replay(PERP_SR).approve(CONTROLLER, perpSrOut), "Controller approval");

        (ITargetControllerReplay.SystemState memory preState, ITargetControllerReplay.ReserveData memory srBefore,) =
            controller.systemReserveState();

        uint256 srUnderlyingBefore = IERC20Replay(CBBTC).balanceOf(PERP_SR);
        uint256 jrUnderlyingBefore = IERC20Replay(CBBTC).balanceOf(PERP_JR);
        uint256 controllerUnderlyingBefore = IERC20Replay(CBBTC).balanceOf(CONTROLLER);
        uint256 userUnderlyingBefore = IERC20Replay(CBBTC).balanceOf(SMART_ACCOUNT);
        vm.recordLogs();
        vm.prank(SMART_ACCOUNT);
        (
            uint256 underlyingOut,
            ITargetControllerReplay.FeePerc memory srFee,
            ITargetControllerReplay.FeePerc memory jrFee
        ) = controller.flashRedeem2(perpSrOut, 0, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (ITargetControllerReplay.SystemState memory postState,,) = controller.systemReserveState();
        uint256 srUnderlyingAfter = IERC20Replay(CBBTC).balanceOf(PERP_SR);
        uint256 jrUnderlyingAfter = IERC20Replay(CBBTC).balanceOf(PERP_JR);
        uint256 controllerUnderlyingAfter = IERC20Replay(CBBTC).balanceOf(CONTROLLER);

        assertEq(srUnderlyingBefore, 0, "target SR starts with no idle cbBTC");
        assertEq(srUnderlyingAfter, 0, "target SR does not fund exit with idle cbBTC");
        assertEq(jrFee.totalFeePerc, 0, "inactive JR total fee return");
        assertEq(jrFee.protocolFeePerc, 0, "inactive JR protocol fee return");
        assertEq(
            IERC20Replay(CBBTC).balanceOf(SMART_ACCOUNT) - userUnderlyingBefore,
            underlyingOut,
            "holder receives the JR-funded cbBTC"
        );
        assertEq(
            controllerUnderlyingBefore, controllerUnderlyingAfter, "Controller only routes cbBTC during the atomic exit"
        );

        (uint256 cbbtcIntoJr, uint256 grossFromJr, uint256 paidToHolder, uint256 movedTrancheCount) =
            _assertSrFlashLiquidityTrace(logs, srBefore, underlyingOut);
        assertGt(movedTrancheCount, 0, "SR must compensate JR with reserve assets");
        assertEq(
            jrUnderlyingBefore + cbbtcIntoJr,
            jrUnderlyingAfter + grossFromJr,
            "JR cbBTC must reconcile recovery and payout"
        );

        emit log_named_uint("target SR idle cbBTC before", srUnderlyingBefore);
        emit log_named_uint("target SR idle cbBTC after", srUnderlyingAfter);
        emit log_named_uint("target JR idle cbBTC before", jrUnderlyingBefore);
        emit log_named_uint("target JR idle cbBTC after", jrUnderlyingAfter);
        emit log_named_uint("cbBTC entering JR during redemption call", cbbtcIntoJr);
        emit log_named_uint("cbBTC transferred JR to Controller", grossFromJr);
        emit log_named_uint("cbBTC transferred Controller to holder", paidToHolder);
        emit log_named_uint("SR tranche transfers into JR", movedTrancheCount);
        emit log_named_uint("active SR total fee WAD", srFee.totalFeePerc);
        emit log_named_uint("inactive JR total fee WAD", jrFee.totalFeePerc);

        emit SrExitLiquiditySource(
            srUnderlyingBefore,
            srUnderlyingAfter,
            jrUnderlyingBefore,
            jrUnderlyingAfter,
            controllerUnderlyingBefore,
            controllerUnderlyingAfter,
            preState.perpSr.reserveValue,
            postState.perpSr.reserveValue,
            preState.perpJr.reserveValue,
            postState.perpJr.reserveValue
        );
    }

    function _assertSrFlashLiquidityTrace(
        Vm.Log[] memory logs,
        ITargetControllerReplay.ReserveData memory srBefore,
        uint256 underlyingOut
    ) private returns (uint256 cbbtcIntoJr, uint256 grossFromJr, uint256 paidToHolder, uint256 movedTrancheCount) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 3 || logs[i].topics[0] != TRANSFER_EVENT) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            address to = address(uint160(uint256(logs[i].topics[2])));
            uint256 amount = abi.decode(logs[i].data, (uint256));

            if (logs[i].emitter == CBBTC && from == PERP_JR && to == CONTROLLER) {
                grossFromJr += amount;
            }
            if (logs[i].emitter == CBBTC && to == PERP_JR && from != PERP_JR) {
                cbbtcIntoJr += amount;
            }
            if (logs[i].emitter == CBBTC && from == CONTROLLER && to == SMART_ACCOUNT) {
                paidToHolder += amount;
            }
            if (from != PERP_SR || to != PERP_JR) continue;
            for (uint256 j; j < srBefore.trancheData.length; ++j) {
                if (logs[i].emitter != srBefore.trancheData[j].data.tranche) continue;
                ++movedTrancheCount;
                emit SrReserveTransferredToJr(logs[i].emitter, amount);
                break;
            }
        }

        assertGt(grossFromJr, 0, "missing cbBTC transfer from JR to Controller");
        assertGe(grossFromJr, underlyingOut, "JR gross transfer below holder output");
        assertEq(paidToHolder, underlyingOut, "Controller-to-holder cbBTC trace mismatch");
    }

    function _runControllerSuccess() private {
        ITargetControllerReplay controller = ITargetControllerReplay(CONTROLLER);
        SystemSnapshot memory pre = _systemSnapshot();
        (, ITargetControllerReplay.ReserveData memory srBefore, ITargetControllerReplay.ReserveData memory jrBefore) =
            controller.systemReserveState();
        uint256 collectedBefore = controller.collectedFeeBal(PERP_JR);
        uint256 cbBtcBefore = IERC20Replay(CBBTC).balanceOf(REAL_HOLDER);
        uint256[] memory userTrancheBefore = new uint256[](jrBefore.trancheData.length);
        for (uint256 i; i < jrBefore.trancheData.length; ++i) {
            userTrancheBefore[i] = IERC20Replay(jrBefore.trancheData[i].data.tranche).balanceOf(REAL_HOLDER);
        }

        vm.recordLogs();
        vm.prank(REAL_HOLDER);
        (
            ITargetControllerReplay.ReserveAmounts memory srOut,
            ITargetControllerReplay.ReserveAmounts memory jrOut,
            ITargetControllerReplay.FeePerc memory srFee,
            ITargetControllerReplay.FeePerc memory jrFee
        ) = controller.redeem2(0, CONTROLLER_JR_IN, CONTROLLER_EXACT_MIN_VALUE);
        Vm.Log[] memory controllerLogs = vm.getRecordedLogs();

        SystemSnapshot memory post = _systemSnapshot();
        (, ITargetControllerReplay.ReserveData memory srAfter, ITargetControllerReplay.ReserveData memory jrAfter) =
            controller.systemReserveState();
        uint256 collectedAfter = controller.collectedFeeBal(PERP_JR);
        assertEq(srOut.underlyingAmt, 0, "unexpected SR underlying");
        assertEq(srOut.trancheAmts.length, 0, "unexpected SR tranches");
        assertEq(srFee.totalFeePerc, 0, "zero-input SR fee");
        assertEq(pre.srReserveHash, post.srReserveHash, "SR reserve changed");
        assertEq(pre.srSupply, post.srSupply, "SR supply changed");
        assertEq(keccak256(abi.encode(srBefore)), keccak256(abi.encode(srAfter)), "SR basket changed");
        assertEq(IERC20Replay(CBBTC).balanceOf(REAL_HOLDER) - cbBtcBefore, jrOut.underlyingAmt);

        _assertFeeCompatibility(pre, post, srFee, jrFee);
        _assertControllerFeeEvents(controllerLogs);
        _emitControllerAssets(jrBefore, jrAfter, jrOut, userTrancheBefore);
        emit ControllerExitResult(
            CONTROLLER_JR_IN,
            CONTROLLER_EXACT_MIN_VALUE,
            pre.subDR,
            post.subDR,
            pre.vmDR,
            post.vmDR,
            jrFee.totalFeePerc,
            jrFee.protocolFeePerc,
            jrOut.underlyingAmt,
            jrOut.trancheAmts.length,
            pre.jrSupply,
            post.jrSupply,
            collectedBefore,
            collectedAfter
        );
    }

    function _assertFeeCompatibility(
        SystemSnapshot memory pre,
        SystemSnapshot memory post,
        ITargetControllerReplay.FeePerc memory srReturned,
        ITargetControllerReplay.FeePerc memory jrReturned
    ) private {
        FeePolicy target = FeePolicy(FEE_POLICY);
        FeePolicy cleanroom = _deployConfiguredCleanroomPolicy(target);
        FeePolicy.OpSystemChange memory change = FeePolicy.OpSystemChange({
            subDRPre: pre.subDR, subDRPost: post.subDR, vmDRPre: pre.vmDR, vmDRPost: post.vmDR
        });
        FeePolicy.OpFees memory targetSr =
            target.computeOpFees(FeePolicy.OpFeeInput({isPerpSrOp: true, isFlashOp: false, systemDeviation: change}));
        FeePolicy.OpFees memory targetJr =
            target.computeOpFees(FeePolicy.OpFeeInput({isPerpSrOp: false, isFlashOp: false, systemDeviation: change}));
        FeePolicy.OpFees memory localSr = cleanroom.computeOpFees(
            FeePolicy.OpFeeInput({isPerpSrOp: true, isFlashOp: false, systemDeviation: change})
        );
        FeePolicy.OpFees memory localJr = cleanroom.computeOpFees(
            FeePolicy.OpFeeInput({isPerpSrOp: false, isFlashOp: false, systemDeviation: change})
        );
        assertEq(targetSr.totalFeePerc, localSr.totalFeePerc, "SR total fee differential");
        assertEq(targetSr.protocolFeePerc, localSr.protocolFeePerc, "SR protocol fee differential");
        assertEq(targetJr.totalFeePerc, localJr.totalFeePerc, "JR total fee differential");
        assertEq(targetJr.protocolFeePerc, localJr.protocolFeePerc, "JR protocol fee differential");
        assertEq(srReturned.totalFeePerc, 0, "zero-input returned SR total fee");
        assertEq(srReturned.protocolFeePerc, 0, "zero-input returned SR protocol fee");
        assertEq(jrReturned.totalFeePerc, targetJr.totalFeePerc, "returned JR total fee");
        assertEq(jrReturned.protocolFeePerc, targetJr.protocolFeePerc, "returned JR protocol fee");
        emit FeeCompatibility(
            0, targetSr.totalFeePerc, targetSr.protocolFeePerc, localSr.totalFeePerc, localSr.protocolFeePerc, true
        );
        emit FeeCompatibility(
            1, targetJr.totalFeePerc, targetJr.protocolFeePerc, localJr.totalFeePerc, localJr.protocolFeePerc, true
        );
    }

    function _emitControllerAssets(
        ITargetControllerReplay.ReserveData memory beforeData,
        ITargetControllerReplay.ReserveData memory afterData,
        ITargetControllerReplay.ReserveAmounts memory returned,
        uint256[] memory userBalancesBefore
    ) private {
        uint256 underlyingUserDelta = returned.underlyingAmt;
        assertEq(beforeData.underlyingBal, afterData.underlyingBal + underlyingUserDelta, "underlying conservation");
        emit ControllerReserveAsset(
            0,
            CBBTC,
            beforeData.underlyingBal,
            afterData.underlyingBal,
            underlyingUserDelta,
            returned.underlyingAmt,
            beforeData.underlyingBal,
            afterData.underlyingBal
        );

        for (uint256 i; i < beforeData.trancheData.length; ++i) {
            address token = beforeData.trancheData[i].data.tranche;
            (uint256 afterBalance, uint256 afterValue) = _reserveAsset(afterData, token);
            uint256 returnedAmount = _returnedAmount(returned, token);
            uint256 userDelta = IERC20Replay(token).balanceOf(REAL_HOLDER) - userBalancesBefore[i];
            assertEq(userDelta, returnedAmount, "returned tranche user delta");
            assertEq(beforeData.trancheData[i].balance, afterBalance + userDelta, "tranche conservation");
            emit ControllerReserveAsset(
                i + 1,
                token,
                beforeData.trancheData[i].balance,
                afterBalance,
                userDelta,
                returnedAmount,
                beforeData.trancheData[i].value,
                afterValue
            );
        }
    }

    function _deployConfiguredCleanroomPolicy(FeePolicy target) private returns (FeePolicy local) {
        FeePolicy implementation = new FeePolicy();
        local = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        FeePolicy.Fees memory srFees = _fees(target, true);
        FeePolicy.Fees memory jrFees = _fees(target, false);
        local.updateFeeParams(srFees, jrFees);
        local.updateProtocolFeeConfig(target.protocolMaxOpFeePerc(), target.protocolFeeCollector());
    }

    function _fees(FeePolicy policy, bool isSr) private view returns (FeePolicy.Fees memory fees) {
        if (isSr) {
            (fees.subDRUp, fees.subDRDown, fees.vmDRUp, fees.vmDRDown, fees.basePerc, fees.flashBasePerc) =
                policy.perpSrFees();
        } else {
            (fees.subDRUp, fees.subDRDown, fees.vmDRUp, fees.vmDRDown, fees.basePerc, fees.flashBasePerc) =
                policy.perpJrFees();
        }
    }

    function _systemSnapshot() private view returns (SystemSnapshot memory snap) {
        ITargetControllerReplay controller = ITargetControllerReplay(CONTROLLER);
        (
            ITargetControllerReplay.SystemState memory state,
            ITargetControllerReplay.ReserveData memory srRd,
            ITargetControllerReplay.ReserveData memory jrRd
        ) = controller.systemReserveState();
        (snap.subDR, snap.vmDR) = controller.systemDeviations();
        snap.srSupply = state.perpSr.totalSupply;
        snap.jrSupply = state.perpJr.totalSupply;
        snap.srReserveValue = state.perpSr.reserveValue;
        snap.jrReserveValue = state.perpJr.reserveValue;
        snap.srReserveHash = keccak256(abi.encode(srRd));
        snap.jrReserveHash = keccak256(abi.encode(jrRd));
    }

    function _controllerFingerprint(address holder) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                _systemSnapshot(),
                IERC20Replay(PERP_JR).balanceOf(holder),
                IERC20Replay(CBBTC).balanceOf(holder),
                ITargetControllerReplay(CONTROLLER).collectedFeeBal(PERP_JR)
            )
        );
    }

    function _vaultFingerprint(address holder) private view returns (bytes32) {
        IUsdVaultReplay vault = IUsdVaultReplay(USD_VAULT);
        return keccak256(
            abi.encode(
                IERC20Replay(USD_VAULT).totalSupply(),
                IERC20Replay(USD_VAULT).balanceOf(holder),
                IERC20Replay(USDC).balanceOf(holder),
                IERC20Replay(PERP_SR).balanceOf(holder),
                vault.usdBalance(),
                vault.perpSrBalance()
            )
        );
    }

    function _routerFingerprint(address holder) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                IERC20Replay(USD_VAULT).totalSupply(),
                IERC20Replay(USD_VAULT).balanceOf(holder),
                IERC20Replay(USDC).balanceOf(holder),
                IERC20Replay(PERP_SR).balanceOf(holder),
                IERC20Replay(CBBTC).balanceOf(holder),
                _systemSnapshot()
            )
        );
    }

    function _reserveAsset(ITargetControllerReplay.ReserveData memory data, address token)
        private
        pure
        returns (uint256 balance, uint256 value)
    {
        for (uint256 i; i < data.trancheData.length; ++i) {
            if (data.trancheData[i].data.tranche == token) {
                return (data.trancheData[i].balance, data.trancheData[i].value);
            }
        }
    }

    function _returnedAmount(ITargetControllerReplay.ReserveAmounts memory returned, address token)
        private
        pure
        returns (uint256 amount)
    {
        for (uint256 i; i < returned.trancheAmts.length; ++i) {
            if (returned.trancheAmts[i].token == token) return returned.trancheAmts[i].amount;
        }
    }

    function _assertVaultRedeemEvent(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == USD_VAULT && logs[i].topics.length == 1 && logs[i].topics[0] == REDEEM_EVENT) {
                (uint256 notes, uint256 usdOut, uint256 perpOut) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                require(notes == VAULT_NOTES_IN, "vault event notes");
                require(usdOut == VAULT_USD_OUT, "vault event USD");
                require(perpOut == VAULT_PERP_SR_OUT, "vault event Perp SR");
                return;
            }
        }
        revert("missing vault Redeem event");
    }

    function _assertControllerFeeEvents(Vm.Log[] memory logs) private {
        bool sawJr;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != CONTROLLER || logs[i].topics.length != 2 || logs[i].topics[0] != OP_FEES_EVENT) {
                continue;
            }
            address token = address(uint160(uint256(logs[i].topics[1])));
            (uint256 totalFeeAmount, uint256 protocolFeeAmount) = abi.decode(logs[i].data, (uint256, uint256));
            uint8 side = token == PERP_SR ? 0 : token == PERP_JR ? 1 : type(uint8).max;
            emit ControllerEventResult(side, logs[i].topics[0], token, totalFeeAmount, protocolFeeAmount);
            if (token == PERP_JR) {
                sawJr = true;
                assertEq(totalFeeAmount, 0, "JR OpFees total amount");
                assertEq(protocolFeeAmount, 0, "JR OpFees protocol amount");
            }
        }
        assertTrue(sawJr, "missing Controller JR OpFees event");
    }

    function _approveRouterNotes() private {
        vm.prank(SMART_ACCOUNT);
        assertTrue(IERC20Replay(USD_VAULT).approve(SINGLE_ASSET_ROUTER, ROUTER_NOTES_IN), "router note approval");
    }

    function _routerRedeemCalldata(uint256 minUsdOut) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                REDEEM_USD_SELECTOR, USD_VAULT, DEX_STRATEGY, ROUTER_NOTES_IN, minUsdOut, false, true
            );
    }

    function _selectStrictFork(bytes32 txHash, uint256 expectedBlock) private returns (uint256 forkId) {
        forkId = vm.createSelectFork(vm.envString("BASE_RPC_URL"), txHash);
        assertEq(block.chainid, 8453, "Base chain ID");
        assertEq(block.number, expectedBlock, "strict transaction prestate block");
    }

    function _assertAndEmitVersion(
        uint8 layer,
        uint8 component,
        address target,
        address expectedImplementation,
        bytes32 expectedTargetCodehash,
        bytes32 expectedImplementationCodehash
    ) private {
        address implementation = address(uint160(uint256(vm.load(target, EIP1967_IMPLEMENTATION_SLOT))));
        bytes32 implementationCodehash = implementation == address(0) ? bytes32(0) : implementation.codehash;
        assertEq(implementation, expectedImplementation, "implementation version drift");
        assertEq(target.codehash, expectedTargetCodehash, "target codehash drift");
        assertEq(implementationCodehash, expectedImplementationCodehash, "implementation codehash drift");
        emit ComponentVersion(layer, component, target, implementation, target.codehash, implementationCodehash);
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 0x20))
        }
    }
}
