// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPerpToken} from "src/interfaces/IPerpToken.sol";
import {PerpBalancer} from "src/policy/PerpBalancer.sol";
import {SingleAssetRouter} from "src/router/SingleAssetRouter.sol";
import {UniswapV3DexStrategy} from "src/strategy/UniswapV3DexStrategy.sol";

interface IERC20RouterProbe {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IUsdVaultRouterProbe {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function usdBalance() external view returns (uint256);
    function perpSrBalance() external view returns (uint256);
    function usdUnitAmt() external view returns (uint256);
    function underlyingUnitAmt() external view returns (uint256);
}

interface IDexStrategyRouterProbe {
    function isHealthy() external view returns (bool);
    function pool() external view returns (address);
    function poolFee() external view returns (uint24);
    function minLiquidity() external view returns (uint128);
    function referencePrice(address sellToken, address buyToken) external view returns (uint256);
    function quote(address sellToken, address buyToken, uint256 sellAmt) external view returns (uint256);
    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);
    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt);
}

contract UnhealthyRouterProbeStrategy {
    function isHealthy() external pure returns (bool) {
        return false;
    }
}

contract RouterDexPhase1Probe is Test {
    address private constant ROUTER = 0x8e868C1f8F82b84a6B0D19d235d50c47b253559f;
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant USD_VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant NATURAL_HOLDER = 0x11649A794F918508027765F6280c1b396EE59F8F;
    address private constant NATURAL_DEPOSITOR = 0x5A42A1667d2E9656e364385fB1b982Fad805cdCa;
    address private constant POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;

    bytes32 private constant EXIT_TX = 0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab;
    bytes32 private constant DEPOSIT_TX = 0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254;
    bytes32 private constant ROUTER_CODEHASH = 0x33f265f8c51da59240326566d89a19548bf6ebeb9bb225cb1ab8079d701d71bf;
    bytes32 private constant STRATEGY_CODEHASH = 0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302;

    bytes4 private constant DEPOSIT_USD = bytes4(keccak256("depositUsd(address,address,uint256,uint256,uint256,bool)"));
    bytes4 private constant REDEEM_USD = bytes4(keccak256("redeemUsd(address,address,uint256,uint256,bool,bool)"));
    bytes4 private constant SLIPPAGE_TOO_HIGH = 0x850c6f76;
    bytes4 private constant UNEXPECTED_AMOUNT = 0x312f6ffa;
    uint256 private constant NATURAL_DEPOSIT_USD = 110_126_511;

    event DepositProbe(
        uint256 maxIters,
        bool ok,
        bytes4 errorSelector,
        uint256 usdSpent,
        uint256 notesOut,
        uint256 routerUsdDust,
        uint256 routerUnderlyingDust,
        uint256 routerPerpDust,
        uint256 returnWord
    );
    event RedeemFlagProbe(bool firstFlag, bool ok, bytes4 errorSelector, uint256 usdOut, uint256 returnWord);
    event HealthFlagProbe(bool healthCheck, bool ok, bytes4 errorSelector);
    event CallbackProbe(bytes4 errorSelector);
    event StrategyTradeDifferential(
        uint256 targetUnderlyingOut, uint256 targetUsdOut, uint256 localUnderlyingOut, uint256 localUsdOut
    );
    event DepositModelInputs(
        uint256 vaultUsd,
        uint256 vaultPerp,
        uint256 perpReserveValue,
        uint256 perpSupply,
        uint256 referencePrice,
        uint256 usdUnit,
        uint256 underlyingUnit
    );

    function testCurrentDepositNaturalBalanceAndIterationMatrix() public {
        vm.createSelectFork(_rpcUrl(), DEPOSIT_TX);
        assertEq(block.chainid, 8453, "Base chain ID");
        assertEq(block.number, 53_236_495, "strict deposit prestate block");
        assertEq(ROUTER.codehash, ROUTER_CODEHASH, "router version drift");
        assertEq(DEX_STRATEGY.codehash, STRATEGY_CODEHASH, "strategy version drift");
        assertGe(IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR), NATURAL_DEPOSIT_USD, "natural USDC balance");
        _emitDepositModelInputs();

        vm.prank(NATURAL_DEPOSITOR);
        IERC20RouterProbe(USDC).approve(ROUTER, type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        (bool zeroOk,, uint256 zeroNotes, uint256 zeroSpent,) = _runDeposit(0, 0);
        assertTrue(zeroOk, "zero-extra-iteration deposit failed");
        assertEq(zeroNotes, 108_320_498_554_343_292_777, "zero-extra-iteration notes");
        assertEq(zeroSpent, 110_126_154, "zero-extra-iteration spend");

        assertTrue(vm.revertToState(snapshot), "restore iteration one");
        bytes32 oneBefore = _fingerprint(NATURAL_DEPOSITOR);
        (bool oneOk, bytes memory oneReason,,,) = _runDeposit(1, 0);
        assertFalse(oneOk, "one extra iteration unexpectedly succeeded");
        assertEq(_selector(oneReason), UNEXPECTED_AMOUNT, "one extra iteration selector");
        assertEq(_fingerprint(NATURAL_DEPOSITOR), oneBefore, "one extra iteration not atomic");

        assertTrue(vm.revertToState(snapshot), "restore iteration two");
        bytes32 twoBefore = _fingerprint(NATURAL_DEPOSITOR);
        (bool twoOk, bytes memory twoReason,,,) = _runDeposit(2, 0);
        assertFalse(twoOk, "two extra iterations unexpectedly succeeded");
        assertEq(_selector(twoReason), UNEXPECTED_AMOUNT, "two extra iterations selector");
        assertEq(_fingerprint(NATURAL_DEPOSITOR), twoBefore, "two extra iterations not atomic");

        assertTrue(vm.revertToState(snapshot), "restore exact boundary");
        (bool exactOk,, uint256 exactNotes,,) = _runDeposit(0, zeroNotes);
        assertTrue(exactOk, "inclusive min notes failed");
        assertEq(exactNotes, zeroNotes, "inclusive min notes output");

        assertTrue(vm.revertToState(snapshot), "restore plus-one boundary");
        bytes32 plusOneBefore = _fingerprint(NATURAL_DEPOSITOR);
        (bool plusOneOk, bytes memory plusOneReason,,,) = _runDeposit(0, zeroNotes + 1);
        assertFalse(plusOneOk, "min notes + 1 unexpectedly succeeded");
        assertEq(_selector(plusOneReason), SLIPPAGE_TOO_HIGH, "min notes + 1 selector");
        assertEq(_fingerprint(NATURAL_DEPOSITOR), plusOneBefore, "min notes + 1 not atomic");

        assertTrue(vm.revertToState(snapshot), "restore final");
    }

    function testRedeemFirstFlagMatrixUsesNaturalNotes() public {
        _selectStrictPrestate();
        uint256 notesIn = 3_762_930_374_354_620_392;
        assertGe(IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_HOLDER), notesIn, "natural notes");
        vm.prank(NATURAL_HOLDER);
        IERC20RouterProbe(USD_VAULT).approve(ROUTER, type(uint256).max);
        uint256 snapshot = vm.snapshotState();

        _runRedeem(notesIn, false);
        assertTrue(vm.revertToState(snapshot), "restore redeem true");
        _runRedeem(notesIn, true);
    }

    function testHealthFlagAndCallbackAuthorization() public {
        _selectStrictPrestate();
        UnhealthyRouterProbeStrategy unhealthy = new UnhealthyRouterProbeStrategy();

        vm.prank(NATURAL_HOLDER);
        (bool checkedOk, bytes memory checkedReason) =
            ROUTER.call(abi.encodeWithSelector(DEPOSIT_USD, USD_VAULT, address(unhealthy), 0, 0, 0, true));
        emit HealthFlagProbe(true, checkedOk, _selector(checkedReason));
        assertFalse(checkedOk, "unhealthy strategy accepted with check");

        vm.prank(NATURAL_HOLDER);
        (bool uncheckedOk, bytes memory uncheckedReason) =
            ROUTER.call(abi.encodeWithSelector(DEPOSIT_USD, USD_VAULT, address(unhealthy), 0, 0, 0, false));
        emit HealthFlagProbe(false, uncheckedOk, _selector(uncheckedReason));

        vm.prank(address(0xBEEF));
        (bool callbackOk, bytes memory callbackReason) =
            DEX_STRATEGY.call(abi.encodeWithSelector(bytes4(0xfa461e33), int256(1), int256(0), bytes("")));
        assertFalse(callbackOk, "unauthorized callback succeeded");
        emit CallbackProbe(_selector(callbackReason));
    }

    function testDexConfigurationAndKnownQuotes() public {
        _selectStrictPrestate();
        IDexStrategyRouterProbe dex = IDexStrategyRouterProbe(DEX_STRATEGY);
        assertTrue(dex.isHealthy());
        assertEq(dex.pool(), POOL);
        assertEq(dex.poolFee(), 500);
        assertEq(dex.minLiquidity(), 200_000_000_000);
        assertEq(dex.referencePrice(CBBTC, USDC), 80_061_462_195_552_451_024_100);
        assertEq(dex.quote(CBBTC, USDC, 4_723), 3_778_900);
        (uint256 sellAmt, uint256 buyAmt) = dex.maxFillable(CBBTC, USDC, 4_723, 0);
        assertEq(sellAmt, 4_723);
        assertEq(buyAmt, 3_778_900);
    }

    function testLocalStrategyMatchesTargetViewsQuotesTradesAndCallback() public {
        _selectStrictPrestate();
        UniswapV3DexStrategy local = new UniswapV3DexStrategy(USDC, CBBTC, POOL, 200_000_000_000);
        IDexStrategyRouterProbe target = IDexStrategyRouterProbe(DEX_STRATEGY);

        assertEq(local.pool(), target.pool());
        assertEq(local.poolFee(), target.poolFee());
        assertEq(local.minLiquidity(), target.minLiquidity());
        assertEq(local.isHealthy(), target.isHealthy());
        assertEq(local.referencePrice(CBBTC, USDC), target.referencePrice(CBBTC, USDC));
        assertEq(local.referencePrice(USDC, CBBTC), target.referencePrice(USDC, CBBTC));
        assertEq(local.quote(CBBTC, USDC, 4_723), target.quote(CBBTC, USDC, 4_723));
        assertEq(local.quote(USDC, CBBTC, 1_000_000), target.quote(USDC, CBBTC, 1_000_000));

        vm.startPrank(NATURAL_HOLDER);
        IERC20RouterProbe(USDC).approve(DEX_STRATEGY, type(uint256).max);
        IERC20RouterProbe(USDC).approve(address(local), type(uint256).max);
        IERC20RouterProbe(CBBTC).approve(DEX_STRATEGY, type(uint256).max);
        IERC20RouterProbe(CBBTC).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        uint256 targetUnderlyingBefore = IERC20RouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        uint256 targetUnderlyingOut = target.trade(USDC, CBBTC, 1_000_000);
        assertEq(IERC20RouterProbe(CBBTC).balanceOf(NATURAL_HOLDER) - targetUnderlyingBefore, targetUnderlyingOut);
        uint256 targetUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        uint256 targetUsdOut = target.trade(CBBTC, USDC, targetUnderlyingOut);
        assertEq(IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER) - targetUsdBefore, targetUsdOut);

        assertTrue(vm.revertToState(snapshot), "restore local strategy path");
        uint256 localUnderlyingBefore = IERC20RouterProbe(CBBTC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        uint256 localUnderlyingOut = local.trade(USDC, CBBTC, 1_000_000);
        assertEq(IERC20RouterProbe(CBBTC).balanceOf(NATURAL_HOLDER) - localUnderlyingBefore, localUnderlyingOut);
        uint256 localUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        uint256 localUsdOut = local.trade(CBBTC, USDC, localUnderlyingOut);
        assertEq(IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER) - localUsdBefore, localUsdOut);
        assertEq(localUnderlyingOut, targetUnderlyingOut, "forward trade differential");
        assertEq(localUsdOut, targetUsdOut, "reverse trade differential");
        emit StrategyTradeDifferential(targetUnderlyingOut, targetUsdOut, localUnderlyingOut, localUsdOut);

        vm.prank(address(0xBEEF));
        (bool callbackOk, bytes memory callbackReason) =
            address(local).call(abi.encodeWithSelector(bytes4(0xfa461e33), int256(1), int256(0), bytes("")));
        assertFalse(callbackOk);
        assertEq(_selector(callbackReason), bytes4(0x7bf6a16f));
    }

    function testLocalRouterMatchesTargetNaturalDepositAndRedeem() public {
        _assertLocalRouterDepositDifferential();
        _assertLocalRouterRedeemDifferential();
    }

    function _runDeposit(uint256 maxIters, uint256 minNotes)
        private
        returns (bool ok, bytes memory reason, uint256 notesOut, uint256 usdSpent, uint256 returnWord)
    {
        uint256 usdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
        uint256 notesBefore = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR);
        vm.prank(NATURAL_DEPOSITOR);
        (ok, reason) = ROUTER.call(
            abi.encodeWithSelector(DEPOSIT_USD, USD_VAULT, DEX_STRATEGY, NATURAL_DEPOSIT_USD, minNotes, maxIters, true)
        );
        if (ok) {
            usdSpent = usdBefore - IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
            notesOut = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR) - notesBefore;
            if (reason.length >= 32) returnWord = abi.decode(reason, (uint256));
        }
        emit DepositProbe(
            maxIters,
            ok,
            _selector(reason),
            usdSpent,
            notesOut,
            IERC20RouterProbe(USDC).balanceOf(ROUTER),
            IERC20RouterProbe(CBBTC).balanceOf(ROUTER),
            IERC20RouterProbe(PERP_SR).balanceOf(ROUTER),
            returnWord
        );
    }

    function _runRedeem(uint256 notesIn, bool firstFlag) private {
        uint256 usdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        (bool ok, bytes memory reason) =
            ROUTER.call(abi.encodeWithSelector(REDEEM_USD, USD_VAULT, DEX_STRATEGY, notesIn, 0, firstFlag, true));
        uint256 usdOut;
        uint256 returnWord;
        if (ok) {
            usdOut = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER) - usdBefore;
            if (reason.length >= 32) returnWord = abi.decode(reason, (uint256));
        }
        emit RedeemFlagProbe(firstFlag, ok, _selector(reason), usdOut, returnWord);
    }

    function _assertLocalRouterDepositDifferential() private {
        vm.createSelectFork(_rpcUrl(), DEPOSIT_TX);
        SingleAssetRouter local = new SingleAssetRouter();
        vm.startPrank(NATURAL_DEPOSITOR);
        IERC20RouterProbe(USDC).approve(ROUTER, type(uint256).max);
        IERC20RouterProbe(USDC).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        uint256 targetUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
        uint256 targetNotesBefore = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR);
        vm.prank(NATURAL_DEPOSITOR);
        (bool targetOk, bytes memory targetResult) =
            ROUTER.call(abi.encodeWithSelector(DEPOSIT_USD, USD_VAULT, DEX_STRATEGY, NATURAL_DEPOSIT_USD, 0, 0, true));
        assertTrue(targetOk, "target deposit");
        uint256 targetReturn = abi.decode(targetResult, (uint256));
        uint256 targetSpent = targetUsdBefore - IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
        uint256 targetNotes = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR) - targetNotesBefore;

        assertTrue(vm.revertToState(snapshot), "restore local deposit");
        uint256 localUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
        uint256 localNotesBefore = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR);
        vm.prank(NATURAL_DEPOSITOR);
        uint256 localReturn = local.depositUsd(USD_VAULT, DEX_STRATEGY, NATURAL_DEPOSIT_USD, 0, 0, true);
        uint256 localSpent = localUsdBefore - IERC20RouterProbe(USDC).balanceOf(NATURAL_DEPOSITOR);
        uint256 localNotes = IERC20RouterProbe(USD_VAULT).balanceOf(NATURAL_DEPOSITOR) - localNotesBefore;

        assertEq(localReturn, targetReturn, "deposit return differential");
        assertEq(localSpent, targetSpent, "deposit spend differential");
        assertEq(localNotes, targetNotes, "deposit notes differential");
        assertEq(IERC20RouterProbe(USDC).balanceOf(address(local)), 0);
        assertEq(IERC20RouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20RouterProbe(PERP_SR).balanceOf(address(local)), 0);
    }

    function _assertLocalRouterRedeemDifferential() private {
        _selectStrictPrestate();
        SingleAssetRouter local = new SingleAssetRouter();
        uint256 notesIn = 3_762_930_374_354_620_392;
        vm.startPrank(NATURAL_HOLDER);
        IERC20RouterProbe(USD_VAULT).approve(ROUTER, type(uint256).max);
        IERC20RouterProbe(USD_VAULT).approve(address(local), type(uint256).max);
        vm.stopPrank();
        uint256 snapshot = vm.snapshotState();

        uint256 targetUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        (bool targetOk, bytes memory targetResult) =
            ROUTER.call(abi.encodeWithSelector(REDEEM_USD, USD_VAULT, DEX_STRATEGY, notesIn, 0, false, true));
        assertTrue(targetOk, "target redeem");
        uint256 targetReturn = abi.decode(targetResult, (uint256));
        uint256 targetOut = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER) - targetUsdBefore;

        assertTrue(vm.revertToState(snapshot), "restore local redeem");
        uint256 localUsdBefore = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER);
        vm.prank(NATURAL_HOLDER);
        uint256 localReturn = local.redeemUsd(USD_VAULT, DEX_STRATEGY, notesIn, 0, false, true);
        uint256 localOut = IERC20RouterProbe(USDC).balanceOf(NATURAL_HOLDER) - localUsdBefore;

        assertEq(localReturn, targetReturn, "redeem return differential");
        assertEq(localOut, targetOut, "redeem output differential");
        assertEq(IERC20RouterProbe(USDC).balanceOf(address(local)), 0);
        assertEq(IERC20RouterProbe(CBBTC).balanceOf(address(local)), 0);
        assertEq(IERC20RouterProbe(PERP_SR).balanceOf(address(local)), 0);
    }

    function _selectStrictPrestate() private {
        uint256 forkId = vm.createSelectFork(vm.envString("BASE_RPC_URL"), EXIT_TX);
        vm.selectFork(forkId);
        assertEq(block.chainid, 8453, "Base chain ID");
        assertEq(block.number, 53_243_583, "strict prestate block");
    }

    function _fingerprint(address account) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                IERC20RouterProbe(USDC).balanceOf(account),
                IERC20RouterProbe(USD_VAULT).balanceOf(account),
                IERC20RouterProbe(USDC).balanceOf(USD_VAULT),
                IERC20RouterProbe(PERP_SR).balanceOf(USD_VAULT),
                IERC20RouterProbe(USD_VAULT).totalSupply(),
                IERC20RouterProbe(PERP_SR).totalSupply(),
                IERC20RouterProbe(USDC).balanceOf(ROUTER),
                IERC20RouterProbe(CBBTC).balanceOf(ROUTER),
                IERC20RouterProbe(PERP_SR).balanceOf(ROUTER)
            )
        );
    }

    function _emitDepositModelInputs() private {
        IUsdVaultRouterProbe vault = IUsdVaultRouterProbe(USD_VAULT);
        PerpBalancer.ReserveData memory reserve = IPerpToken(PERP_SR).reserveData();
        uint256 reserveValue = reserve.underlyingBal;
        for (uint256 i; i < reserve.trancheData.length; ++i) {
            reserveValue += reserve.trancheData[i].value;
        }
        emit DepositModelInputs(
            vault.usdBalance(),
            vault.perpSrBalance(),
            reserveValue,
            IPerpToken(PERP_SR).totalSupply(),
            IDexStrategyRouterProbe(DEX_STRATEGY).referencePrice(CBBTC, USDC),
            vault.usdUnitAmt(),
            vault.underlyingUnitAmt()
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
