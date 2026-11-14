// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {UnderlyingSingleAssetRouter} from "../../src/router/UnderlyingSingleAssetRouter.sol";

interface IERC20UnderlyingRouterProbe {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUnderlyingVaultRouterProbe is IERC20UnderlyingRouterProbe {
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function isPerpSrVault() external view returns (bool);
    function underlyingBalance() external view returns (uint256);
    function perpBalance() external view returns (uint256);
}

interface IUnderlyingSingleAssetRouterProbe {
    function depositUnderlying(address vault, uint256 underlyingAmtIn, uint256 minNotesOut, uint256 maxIters)
        external
        returns (uint256 notesMinted);

    function redeemUnderlying(address vault, uint256 notesAmtIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingAmtOut);
}

interface IUnderlyingRouterControllerProbe {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function systemReserveState() external view returns (SystemState memory state);
}

contract UnderlyingSingleAssetRouterPhase1Probe is Test {
    address private constant ROUTER = 0xbf0f2aa8784a1a459C7E2eB87CF25E5cABF4d296;
    address private constant JUNIOR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address private constant SENIOR_VAULT = 0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant NATURAL_HOLDER = 0x5A42A1667d2E9656e364385fB1b982Fad805cdCa;
    address private constant SENIOR_HOLDER = 0xf582fC610600836534F59E641c808aB1810866eb;

    bytes32 private constant REAL_DEPOSIT_TX = 0x14d7b798cfd88264135cc1e343c6d4cdb0ce45ab461a9d9c1adae64b449361fa;
    bytes32 private constant JUNIOR_REDEEM_REBALANCE_TX =
        0x3562298f878658f89d970f77da8bc7ae8c0e0d14fa389ee6f794c8b814e9259b;
    bytes4 private constant SLIPPAGE_TOO_HIGH = 0x850c6f76;

    uint256 private constant FIXED_BLOCK = 54_990_962;
    uint256 private constant REAL_DEPOSIT_UNDERLYING = 166_464;
    uint256 private constant REAL_DEPOSIT_NOTES = 1_711_753_692_854_663;
    uint256 private constant NATURAL_REDEEM_NOTES = 1_000_000_000_000_000;
    uint256 private constant SENIOR_DEPOSIT_UNDERLYING = 100_000;
    uint256 private constant SENIOR_REDEEM_NOTES = 1_000_000_000_000_000;

    event VersionLock(bytes32 routerCodehash, bytes32 vaultCodehash, address controller);
    event DepositObservation(
        bytes32 indexed stateId,
        uint256 maxIters,
        bool ok,
        bytes4 errorSelector,
        uint256 underlyingSpent,
        uint256 notesOut,
        uint256 underlyingRefund,
        uint256 routerUnderlyingDust,
        uint256 routerPerpDust,
        uint256 returnWord
    );
    event RedeemObservation(
        uint256 notesIn,
        bool ok,
        bytes4 errorSelector,
        uint256 underlyingOut,
        uint256 returnWord,
        uint256 routerUnderlyingDust,
        uint256 routerPerpDust
    );
    event DepositModelInputs(
        uint256 vaultUnderlying, uint256 vaultPerp, uint256 perpSupply, uint256 perpReserveValue, uint256 amountIn
    );

    function testVersionLockAndJuniorTopology() public {
        vm.createSelectFork(_rpcUrl(), FIXED_BLOCK);
        IUnderlyingVaultRouterProbe vault = IUnderlyingVaultRouterProbe(JUNIOR_VAULT);
        assertEq(block.chainid, 8453);
        assertEq(vault.underlying(), CBBTC);
        assertEq(vault.perp(), PERP_JR);
        assertFalse(vault.isPerpSrVault());
        assertGt(ROUTER.code.length, 0);
        emit VersionLock(ROUTER.codehash, JUNIOR_VAULT.codehash, vault.perpController());
    }

    function testHistoricalJuniorDepositIterationAndMinOutBoundaries() public {
        vm.createSelectFork(_rpcUrl(), REAL_DEPOSIT_TX);
        assertGe(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER), REAL_DEPOSIT_UNDERLYING);
        vm.prank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(CBBTC).approve(ROUTER, type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        (bool twoOk,, uint256 twoNotes,,) = _runDeposit(bytes32("historical"), 2, 0);
        assertTrue(twoOk);
        assertEq(twoNotes, REAL_DEPOSIT_NOTES);

        assertTrue(vm.revertToState(snapshot));
        (bool zeroOk,, uint256 zeroNotes,,) = _runDeposit(bytes32("historical"), 0, 0);
        assertTrue(zeroOk);
        assertEq(zeroNotes, REAL_DEPOSIT_NOTES);

        assertTrue(vm.revertToState(snapshot));
        (bool exactOk,, uint256 exactNotes,,) = _runDeposit(bytes32("historical"), 2, REAL_DEPOSIT_NOTES);
        assertTrue(exactOk);
        assertEq(exactNotes, REAL_DEPOSIT_NOTES);

        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprint();
        (bool plusOneOk, bytes memory plusOneReason,,,) = _runDeposit(bytes32("historical"), 2, REAL_DEPOSIT_NOTES + 1);
        assertFalse(plusOneOk);
        assertEq(_selector(plusOneReason), SLIPPAGE_TOO_HIGH);
        assertEq(_fingerprint(), beforeFingerprint, "deposit slippage failure not atomic");
    }

    function testNaturalNotesRedeemAndMinOutBoundaries() public {
        vm.createSelectFork(_rpcUrl(), FIXED_BLOCK);
        assertGe(IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER), NATURAL_REDEEM_NOTES);
        vm.prank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(JUNIOR_VAULT).approve(ROUTER, type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        (bool baseOk,, uint256 underlyingOut) = _runRedeem(NATURAL_REDEEM_NOTES, 0);
        assertTrue(baseOk);
        assertGt(underlyingOut, 0);

        assertTrue(vm.revertToState(snapshot));
        (bool exactOk,, uint256 exactOut) = _runRedeem(NATURAL_REDEEM_NOTES, underlyingOut);
        assertTrue(exactOk);
        assertEq(exactOut, underlyingOut);

        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprint();
        (bool plusOneOk, bytes memory plusOneReason,) = _runRedeem(NATURAL_REDEEM_NOTES, underlyingOut + 1);
        assertFalse(plusOneOk);
        assertEq(_selector(plusOneReason), SLIPPAGE_TOO_HIGH);
        assertEq(_fingerprint(), beforeFingerprint, "redeem slippage failure not atomic");
    }

    function testPostRebalanceNonzeroUnderlyingIterationMatrix() public {
        uint256 forkId = vm.createSelectFork(_rpcUrl(), JUNIOR_REDEEM_REBALANCE_TX);
        vm.transact(forkId, JUNIOR_REDEEM_REBALANCE_TX);
        IUnderlyingVaultRouterProbe vault = IUnderlyingVaultRouterProbe(JUNIOR_VAULT);
        assertGt(vault.underlyingBalance(), 0);

        uint256 amountIn = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        if (amountIn > 100_000) amountIn = 100_000;
        assertGt(amountIn, 0, "natural depositor has no cbBTC");
        IUnderlyingRouterControllerProbe.SystemState memory state =
            IUnderlyingRouterControllerProbe(vault.perpController()).systemReserveState();
        emit DepositModelInputs(
            vault.underlyingBalance(),
            vault.perpBalance(),
            state.perpJr.totalSupply,
            state.perpJr.reserveValue,
            amountIn
        );
        vm.prank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(CBBTC).approve(ROUTER, type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        (bool zeroOk,, uint256 zeroNotes,,) = _runDepositAmount(bytes32("post-rebalance"), amountIn, 0, 0);
        assertTrue(zeroOk);

        assertTrue(vm.revertToState(snapshot));
        (bool oneOk,, uint256 oneNotes,,) = _runDepositAmount(bytes32("post-rebalance"), amountIn, 1, 0);
        assertTrue(oneOk);

        assertTrue(vm.revertToState(snapshot));
        (bool twoOk,, uint256 twoNotes,,) = _runDepositAmount(bytes32("post-rebalance"), amountIn, 2, 0);
        assertTrue(twoOk);
        assertGe(oneNotes, zeroNotes);
        assertGe(twoNotes, oneNotes);
    }

    function testLocalRouterMatchesHistoricalJuniorDepositExactly() public {
        vm.createSelectFork(_rpcUrl(), REAL_DEPOSIT_TX);
        UnderlyingSingleAssetRouter local = new UnderlyingSingleAssetRouter();
        vm.startPrank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(CBBTC).approve(ROUTER, type(uint256).max);
        IERC20UnderlyingRouterProbe(CBBTC).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        (uint256 targetReturn, uint256 targetNotes, uint256 targetSpent) =
            _measureDeposit(ROUTER, REAL_DEPOSIT_UNDERLYING, 2);
        assertTrue(vm.revertToState(snapshot));
        (uint256 localReturn, uint256 localNotes, uint256 localSpent) =
            _measureDeposit(address(local), REAL_DEPOSIT_UNDERLYING, 2);

        assertEq(localReturn, targetReturn, "historical deposit return differential");
        assertEq(localNotes, targetNotes, "historical deposit notes differential");
        assertEq(localSpent, targetSpent, "historical deposit spend differential");
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(address(local)), 0);
    }

    function testLocalRouterMatchesPostRebalanceSplitExactly() public {
        uint256 forkId = vm.createSelectFork(_rpcUrl(), JUNIOR_REDEEM_REBALANCE_TX);
        vm.transact(forkId, JUNIOR_REDEEM_REBALANCE_TX);
        UnderlyingSingleAssetRouter local = new UnderlyingSingleAssetRouter();
        vm.startPrank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(CBBTC).approve(ROUTER, type(uint256).max);
        IERC20UnderlyingRouterProbe(CBBTC).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        (uint256 targetReturn, uint256 targetNotes, uint256 targetSpent) = _measureDeposit(ROUTER, 100_000, 2);
        assertTrue(vm.revertToState(snapshot));
        (uint256 localReturn, uint256 localNotes, uint256 localSpent) = _measureDeposit(address(local), 100_000, 2);

        assertEq(localReturn, targetReturn, "post-rebalance return differential");
        assertEq(localNotes, targetNotes, "post-rebalance notes differential");
        assertEq(localSpent, targetSpent, "post-rebalance spend differential");
        assertEq(localSpent, 99_999);
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(address(local)), 0);
    }

    function testLocalRouterMatchesNaturalJuniorRedeemExactly() public {
        vm.createSelectFork(_rpcUrl(), FIXED_BLOCK);
        UnderlyingSingleAssetRouter local = new UnderlyingSingleAssetRouter();
        vm.startPrank(NATURAL_HOLDER);
        IERC20UnderlyingRouterProbe(JUNIOR_VAULT).approve(ROUTER, type(uint256).max);
        IERC20UnderlyingRouterProbe(JUNIOR_VAULT).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        (uint256 targetReturn, uint256 targetOut) = _measureRedeem(ROUTER, NATURAL_REDEEM_NOTES);
        assertTrue(vm.revertToState(snapshot));
        (uint256 localReturn, uint256 localOut) = _measureRedeem(address(local), NATURAL_REDEEM_NOTES);

        assertEq(localReturn, targetReturn, "redeem return differential");
        assertEq(localOut, targetOut, "redeem output differential");
        assertEq(localOut, 95_934);
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(address(local)), 0);
    }

    function testSameTargetRouterMatchesNaturalSeniorRedeemAndMinOutExactly() public {
        vm.createSelectFork(_rpcUrl(), FIXED_BLOCK);
        IUnderlyingVaultRouterProbe vault = IUnderlyingVaultRouterProbe(SENIOR_VAULT);
        assertTrue(vault.isPerpSrVault());
        assertEq(vault.perp(), PERP_SR);
        assertGe(IERC20UnderlyingRouterProbe(SENIOR_VAULT).balanceOf(SENIOR_HOLDER), SENIOR_REDEEM_NOTES);

        UnderlyingSingleAssetRouter local = new UnderlyingSingleAssetRouter();
        vm.startPrank(SENIOR_HOLDER);
        IERC20UnderlyingRouterProbe(SENIOR_VAULT).approve(ROUTER, type(uint256).max);
        IERC20UnderlyingRouterProbe(SENIOR_VAULT).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        (uint256 targetReturn, uint256 targetOut) =
            _measureRedeemFor(ROUTER, SENIOR_VAULT, SENIOR_HOLDER, SENIOR_REDEEM_NOTES);
        assertEq(targetOut, 205_750);
        emit log_named_uint("senior redeem cbBTC out", targetOut);
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(ROUTER), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_SR).balanceOf(ROUTER), 0);

        assertTrue(vm.revertToState(snapshot));
        (uint256 localReturn, uint256 localOut) =
            _measureRedeemFor(address(local), SENIOR_VAULT, SENIOR_HOLDER, SENIOR_REDEEM_NOTES);
        assertEq(localReturn, targetReturn, "senior redeem return differential");
        assertEq(localOut, targetOut, "senior redeem output differential");
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_SR).balanceOf(address(local)), 0);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(SENIOR_HOLDER);
        uint256 exactOut =
            IUnderlyingSingleAssetRouterProbe(ROUTER).redeemUnderlying(SENIOR_VAULT, SENIOR_REDEEM_NOTES, targetOut);
        assertEq(exactOut, targetOut);

        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprintFor(SENIOR_VAULT, PERP_SR, SENIOR_HOLDER, ROUTER);
        vm.prank(SENIOR_HOLDER);
        (bool plusOneOk, bytes memory plusOneReason) = ROUTER.call(
            abi.encodeCall(
                IUnderlyingSingleAssetRouterProbe.redeemUnderlying, (SENIOR_VAULT, SENIOR_REDEEM_NOTES, targetOut + 1)
            )
        );
        assertFalse(plusOneOk);
        assertEq(_selector(plusOneReason), SLIPPAGE_TOO_HIGH);
        assertEq(
            _fingerprintFor(SENIOR_VAULT, PERP_SR, SENIOR_HOLDER, ROUTER),
            beforeFingerprint,
            "senior redeem slippage failure not atomic"
        );
    }

    function testSameTargetRouterMatchesNaturalSeniorDepositAndMinOutExactly() public {
        vm.createSelectFork(_rpcUrl(), FIXED_BLOCK);
        assertGe(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(SENIOR_HOLDER), SENIOR_DEPOSIT_UNDERLYING);

        UnderlyingSingleAssetRouter local = new UnderlyingSingleAssetRouter();
        vm.startPrank(SENIOR_HOLDER);
        IERC20UnderlyingRouterProbe(CBBTC).approve(ROUTER, type(uint256).max);
        IERC20UnderlyingRouterProbe(CBBTC).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        (uint256 targetReturn, uint256 targetNotes, uint256 targetSpent) =
            _measureDepositFor(ROUTER, SENIOR_VAULT, SENIOR_HOLDER, SENIOR_DEPOSIT_UNDERLYING, 2);
        assertGt(targetNotes, 0);
        emit log_named_uint("senior deposit notes out", targetNotes);
        emit log_named_uint("senior deposit cbBTC spent", targetSpent);
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(ROUTER), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_SR).balanceOf(ROUTER), 0);

        assertTrue(vm.revertToState(snapshot));
        (uint256 localReturn, uint256 localNotes, uint256 localSpent) =
            _measureDepositFor(address(local), SENIOR_VAULT, SENIOR_HOLDER, SENIOR_DEPOSIT_UNDERLYING, 2);
        assertEq(localReturn, targetReturn, "senior deposit return differential");
        assertEq(localNotes, targetNotes, "senior deposit notes differential");
        assertEq(localSpent, targetSpent, "senior deposit spend differential");
        assertEq(IERC20UnderlyingRouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20UnderlyingRouterProbe(PERP_SR).balanceOf(address(local)), 0);

        assertTrue(vm.revertToState(snapshot));
        vm.prank(SENIOR_HOLDER);
        uint256 exactNotes = IUnderlyingSingleAssetRouterProbe(ROUTER)
            .depositUnderlying(SENIOR_VAULT, SENIOR_DEPOSIT_UNDERLYING, targetNotes, 2);
        assertEq(exactNotes, targetNotes);

        assertTrue(vm.revertToState(snapshot));
        bytes32 beforeFingerprint = _fingerprintFor(SENIOR_VAULT, PERP_SR, SENIOR_HOLDER, ROUTER);
        vm.prank(SENIOR_HOLDER);
        (bool plusOneOk, bytes memory plusOneReason) = ROUTER.call(
            abi.encodeCall(
                IUnderlyingSingleAssetRouterProbe.depositUnderlying,
                (SENIOR_VAULT, SENIOR_DEPOSIT_UNDERLYING, targetNotes + 1, 2)
            )
        );
        assertFalse(plusOneOk);
        assertEq(_selector(plusOneReason), SLIPPAGE_TOO_HIGH);
        assertEq(
            _fingerprintFor(SENIOR_VAULT, PERP_SR, SENIOR_HOLDER, ROUTER),
            beforeFingerprint,
            "senior deposit slippage failure not atomic"
        );
    }

    function _runDeposit(bytes32 stateId, uint256 maxIters, uint256 minNotes)
        private
        returns (bool ok, bytes memory reason, uint256 notesOut, uint256 underlyingSpent, uint256 returnWord)
    {
        return _runDepositAmount(stateId, REAL_DEPOSIT_UNDERLYING, maxIters, minNotes);
    }

    function _runDepositAmount(bytes32 stateId, uint256 amountIn, uint256 maxIters, uint256 minNotes)
        private
        returns (bool ok, bytes memory reason, uint256 notesOut, uint256 underlyingSpent, uint256 returnWord)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        uint256 notesBefore = IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        (ok, reason) = ROUTER.call(
            abi.encodeCall(
                IUnderlyingSingleAssetRouterProbe.depositUnderlying, (JUNIOR_VAULT, amountIn, minNotes, maxIters)
            )
        );
        if (ok) {
            underlyingSpent = underlyingBefore - IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
            notesOut = IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER) - notesBefore;
            returnWord = abi.decode(reason, (uint256));
        }
        emit DepositObservation(
            stateId,
            maxIters,
            ok,
            _selector(reason),
            underlyingSpent,
            notesOut,
            IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER) + underlyingSpent - underlyingBefore,
            IERC20UnderlyingRouterProbe(CBBTC).balanceOf(ROUTER),
            IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(ROUTER),
            returnWord
        );
    }

    function _runRedeem(uint256 notesIn, uint256 minUnderlying)
        private
        returns (bool ok, bytes memory reason, uint256 underlyingOut)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        (ok, reason) = ROUTER.call(
            abi.encodeCall(IUnderlyingSingleAssetRouterProbe.redeemUnderlying, (JUNIOR_VAULT, notesIn, minUnderlying))
        );
        if (ok) {
            underlyingOut = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER) - underlyingBefore;
        }
        _emitRedeemObservation(notesIn, ok, reason, underlyingOut);
    }

    function _measureDeposit(address router_, uint256 amountIn, uint256 maxIters)
        private
        returns (uint256 returnWord, uint256 notesOut, uint256 underlyingSpent)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        uint256 notesBefore = IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        returnWord = IUnderlyingSingleAssetRouterProbe(router_).depositUnderlying(JUNIOR_VAULT, amountIn, 0, maxIters);
        notesOut = IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER) - notesBefore;
        underlyingSpent = underlyingBefore - IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
    }

    function _measureDepositFor(address router_, address vault_, address holder_, uint256 amountIn, uint256 maxIters)
        private
        returns (uint256 returnWord, uint256 notesOut, uint256 underlyingSpent)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(holder_);
        uint256 notesBefore = IERC20UnderlyingRouterProbe(vault_).balanceOf(holder_);
        vm.prank(holder_);
        returnWord = IUnderlyingSingleAssetRouterProbe(router_).depositUnderlying(vault_, amountIn, 0, maxIters);
        notesOut = IERC20UnderlyingRouterProbe(vault_).balanceOf(holder_) - notesBefore;
        underlyingSpent = underlyingBefore - IERC20UnderlyingRouterProbe(CBBTC).balanceOf(holder_);
    }

    function _measureRedeem(address router_, uint256 notesIn)
        private
        returns (uint256 returnWord, uint256 underlyingOut)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        returnWord = IUnderlyingSingleAssetRouterProbe(router_).redeemUnderlying(JUNIOR_VAULT, notesIn, 0);
        underlyingOut = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER) - underlyingBefore;
    }

    function _measureRedeemFor(address router_, address vault_, address holder_, uint256 notesIn)
        private
        returns (uint256 returnWord, uint256 underlyingOut)
    {
        uint256 underlyingBefore = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(holder_);
        vm.prank(holder_);
        returnWord = IUnderlyingSingleAssetRouterProbe(router_).redeemUnderlying(vault_, notesIn, 0);
        underlyingOut = IERC20UnderlyingRouterProbe(CBBTC).balanceOf(holder_) - underlyingBefore;
    }

    function _emitRedeemObservation(uint256 notesIn, bool ok, bytes memory reason, uint256 underlyingOut) private {
        uint256 returnWord = ok ? abi.decode(reason, (uint256)) : 0;
        emit RedeemObservation(
            notesIn,
            ok,
            _selector(reason),
            underlyingOut,
            returnWord,
            IERC20UnderlyingRouterProbe(CBBTC).balanceOf(ROUTER),
            IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(ROUTER)
        );
    }

    function _fingerprint() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(NATURAL_HOLDER),
                IERC20UnderlyingRouterProbe(JUNIOR_VAULT).balanceOf(NATURAL_HOLDER),
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(JUNIOR_VAULT),
                IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(JUNIOR_VAULT),
                IERC20UnderlyingRouterProbe(JUNIOR_VAULT).totalSupply(),
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(ROUTER),
                IERC20UnderlyingRouterProbe(PERP_JR).balanceOf(ROUTER)
            )
        );
    }

    function _fingerprintFor(address vault_, address perp_, address holder_, address router_)
        private
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(holder_),
                IERC20UnderlyingRouterProbe(vault_).balanceOf(holder_),
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(vault_),
                IERC20UnderlyingRouterProbe(perp_).balanceOf(vault_),
                IERC20UnderlyingRouterProbe(vault_).totalSupply(),
                IERC20UnderlyingRouterProbe(CBBTC).balanceOf(router_),
                IERC20UnderlyingRouterProbe(perp_).balanceOf(router_)
            )
        );
    }

    function _rpcUrl() private view returns (string memory) {
        return vm.envString("BASE_RPC_URL");
    }

    function _selector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            selector := mload(add(reason, 32))
        }
    }
}
