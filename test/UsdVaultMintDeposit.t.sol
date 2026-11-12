// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract UsdVaultMintHarness is UsdVault {
    function mintNotes(address to, uint256 amount) external {
        _mintNotes(to, amount);
    }
}

contract FailingTransferFromToken is MockERC20 {
    error ForcedFailure();

    bool public transfersFromFail;

    constructor() MockERC20("Failing Senior", "fSR", 8) {}

    function setTransfersFromFail(bool fail) external {
        transfersFromFail = fail;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (transfersFromFail) revert ForcedFailure();
        return super.transferFrom(from, to, value);
    }
}

contract UsdVaultMintDepositTest is Test {
    using Math for uint256;

    event Deposit(uint256 usdAmtIn, uint256 perpSrAmtIn, uint256 notesMinted);

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(uint256,uint256,uint256)");
    uint256 private constant WAD = 1e18;
    uint256 private constant USD_UNIT = 1e6;
    uint256 private constant UNDERLYING_UNIT = 1e8;
    string private constant TARGET_NAME = "cbBTC Senior USDC Keeper";
    string private constant TARGET_SYMBOL = "cbBTC-Sr-USDC-Keeper";
    address private constant SEED = address(0x5EED);
    address private constant USER = address(0xA11CE);

    struct Vector {
        uint256 blockNumber;
        uint256 notesSupply;
        uint256 usdBalance;
        uint256 perpBalance;
        uint256 idleUnderlying;
        uint256 srSupply;
        uint256 srReserveValue;
        uint256 underlyingPrice;
        uint256 tvl;
        uint256 notesOut;
        uint256 usdIn;
        uint256 perpIn;
    }

    struct Env {
        UsdVaultMintHarness vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockPriceOracle oracle;
        MockUsdVaultController controller;
    }

    function testFiveHistoricalComputeMintVectorsMatchExactly() public {
        for (uint256 i; i < 5; ++i) {
            Vector memory vector = _vector(i);
            Env memory env = _deploy(vector);

            assertEq(env.vault.getTVL(), vector.tvl, "historical TVL mismatch");
            (uint256 notesOut, uint256 usdIn, uint256 perpIn) = env.vault.computeMintAmt(1e6, 10_000_000_000);
            assertEq(notesOut, vector.notesOut, "historical notes mismatch");
            assertEq(usdIn, vector.usdIn, "historical USDC mismatch");
            assertEq(perpIn, vector.perpIn, "historical Perp SR mismatch");
        }
    }

    function testTwoStagePerpValuationRoundingCounterexample() public {
        Vector memory vector = _vector(4);
        Env memory env = _deploy(vector);

        (uint256 notesOut, uint256 usdIn, uint256 perpIn) = env.vault.computeMintAmt(1e6, 10_000_000_000);
        uint256 twoStageUnderlying = Math.mulDiv(perpIn, vector.srReserveValue, vector.srSupply);
        uint256 twoStageValue = Math.mulDiv(usdIn, WAD, USD_UNIT)
            + Math.mulDiv(twoStageUnderlying, vector.underlyingPrice, UNDERLYING_UNIT);
        uint256 twoStageNotes = Math.mulDiv(twoStageValue, vector.notesSupply, vector.tvl);

        uint256 collapsedPerpValue =
            Math.mulDiv(perpIn, vector.srReserveValue * vector.underlyingPrice, vector.srSupply * UNDERLYING_UNIT);
        uint256 collapsedNotes =
            Math.mulDiv(Math.mulDiv(usdIn, WAD, USD_UNIT) + collapsedPerpValue, vector.notesSupply, vector.tvl);

        assertEq(notesOut, 100_271_154_039_568_388_009);
        assertEq(twoStageNotes, notesOut);
        assertEq(collapsedNotes, 100_271_607_373_576_495_882);
        assertEq(collapsedNotes - notesOut, 453_334_008_107_873);
    }

    function testDepositUsesTargetConfirmedTransferMintAndEventOrder() public {
        Vector memory vector = _vector(2);
        Env memory env = _deploy(vector);
        env.usd.mint(USER, 1e6);
        env.perp.mint(USER, 10_000_000_000);
        vm.startPrank(USER);
        env.usd.approve(address(env.vault), type(uint256).max);
        env.perp.approve(address(env.vault), type(uint256).max);
        vm.stopPrank();

        vm.recordLogs();
        vm.prank(USER);
        uint256 notesMinted = env.vault.deposit(1e6, 10_000_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(notesMinted, vector.notesOut);
        assertEq(env.usd.balanceOf(USER), 1e6 - vector.usdIn);
        assertEq(env.perp.balanceOf(USER), 0);
        assertEq(env.vault.usdBalance(), vector.usdBalance + vector.usdIn);
        assertEq(env.vault.perpSrBalance(), vector.perpBalance + vector.perpIn);
        assertEq(env.vault.balanceOf(USER), vector.notesOut);
        assertEq(env.vault.totalSupply(), vector.notesSupply + vector.notesOut);
        _assertDepositLogOrder(logs, env, vector.usdIn, vector.perpIn, vector.notesOut);
    }

    function testZeroAndTinyInputsDoNotMoveAssets() public {
        Env memory env = _deploy(_vector(4));
        bytes32 beforeFingerprint = _fingerprint(env, USER);

        (uint256 notes0, uint256 usd0, uint256 perp0) = env.vault.computeMintAmt(0, 0);
        assertEq(notes0, 0);
        assertEq(usd0, 0);
        assertEq(perp0, 0);
        vm.recordLogs();
        vm.prank(USER);
        assertEq(env.vault.deposit(0, 0), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_fingerprint(env, USER), beforeFingerprint);

        (uint256 notesUsdTiny, uint256 usdTiny, uint256 perpForUsdTiny) = env.vault.computeMintAmt(1, 0);
        assertEq(notesUsdTiny, 0);
        assertEq(usdTiny, 0);
        assertEq(perpForUsdTiny, 0);

        (uint256 notesPerpTiny, uint256 usdForPerpTiny, uint256 perpTiny) = env.vault.computeMintAmt(0, 1);
        assertEq(notesPerpTiny, 0);
        assertEq(usdForPerpTiny, 0);
        assertEq(perpTiny, 0);
    }

    function testEachBalanceRatioBranchUsesTheLimitingLeg() public {
        Vector memory vector = _vector(4);
        Env memory env = _deploy(vector);

        (uint256 notesPerpLimited, uint256 usdPerpLimited, uint256 perpLimited) =
            env.vault.computeMintAmt(1e6, 10_000_000_000);
        assertEq(notesPerpLimited, vector.notesOut);
        assertEq(usdPerpLimited, 3_765);
        assertEq(perpLimited, 10_000_000_000);

        (uint256 notesUsdLimited, uint256 usdLimited, uint256 perpUsdLimited) =
            env.vault.computeMintAmt(1, 10_000_000_000);
        assertEq(usdLimited, 1);
        assertEq(perpUsdLimited, vector.perpBalance / vector.usdBalance);
        (uint256 modelNotes,,) = _modelQuote(vector, 1, 10_000_000_000);
        assertEq(notesUsdLimited, modelNotes);
    }

    function testDonationsUseActualBalancesAndIdleUnderlyingOnlyChangesDenominator() public {
        Vector memory vector = _vector(4);
        Env memory env = _deploy(vector);
        (uint256 notesBefore, uint256 usdBefore, uint256 perpBefore) = env.vault.computeMintAmt(1e6, 10_000_000_000);

        env.underlying.mint(address(env.vault), 1e8);
        (uint256 notesAfterUnderlying, uint256 usdAfterUnderlying, uint256 perpAfterUnderlying) =
            env.vault.computeMintAmt(1e6, 10_000_000_000);
        assertEq(env.vault.getTVL(), vector.tvl + vector.underlyingPrice);
        assertEq(usdAfterUnderlying, usdBefore);
        assertEq(perpAfterUnderlying, perpBefore);
        assertLt(notesAfterUnderlying, notesBefore);

        uint256 tvlBeforeUsdDonation = env.vault.getTVL();
        env.usd.mint(address(env.vault), 1e6);
        assertEq(env.vault.getTVL(), tvlBeforeUsdDonation + 1e18);
        (uint256 notesAfterUsd, uint256 usdAfterUsd, uint256 perpAfterUsd) =
            env.vault.computeMintAmt(1e6, 10_000_000_000);
        (uint256 modelNotesUsd, uint256 modelUsd, uint256 modelPerp) = _modelCurrent(env, vector, 1e6, 10_000_000_000);
        assertEq(notesAfterUsd, modelNotesUsd);
        assertEq(usdAfterUsd, modelUsd);
        assertEq(perpAfterUsd, modelPerp);

        env.perp.mint(address(env.vault), 10_000_000_000);
        (uint256 notesAfterPerp, uint256 usdAfterPerp, uint256 perpAfterPerp) =
            env.vault.computeMintAmt(1e6, 10_000_000_000);
        (uint256 modelNotesPerp, uint256 modelUsdPerp, uint256 modelPerpPerp) =
            _modelCurrent(env, vector, 1e6, 10_000_000_000);
        assertEq(notesAfterPerp, modelNotesPerp);
        assertEq(usdAfterPerp, modelUsdPerp);
        assertEq(perpAfterPerp, modelPerpPerp);
    }

    function testSecondLegFailureRollsBackFirstTransferAndMint() public {
        Vector memory vector = _vector(4);
        MockERC20 usd = new MockERC20("USD Coin", "USDC", 6);
        FailingTransferFromToken perp = new FailingTransferFromToken();
        MockERC20 underlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        MockPriceOracle oracle = new MockPriceOracle(vector.underlyingPrice);
        MockUsdVaultController controller = new MockUsdVaultController(address(oracle));
        controller.setPerpSrState(vector.srSupply, vector.srReserveValue, 0);
        UsdVaultMintHarness vault = _deployVault(address(usd), address(perp), address(underlying), address(controller));
        vault.mintNotes(SEED, vector.notesSupply);
        usd.mint(address(vault), vector.usdBalance);
        perp.mint(address(vault), vector.perpBalance);
        underlying.mint(address(vault), vector.idleUnderlying);
        usd.mint(USER, 1e6);
        perp.mint(USER, 10_000_000_000);
        vm.startPrank(USER);
        usd.approve(address(vault), type(uint256).max);
        perp.approve(address(vault), type(uint256).max);
        vm.stopPrank();
        perp.setTransfersFromFail(true);

        bytes32 beforeFingerprint = keccak256(
            abi.encode(
                vault.totalSupply(),
                vault.balanceOf(USER),
                usd.balanceOf(USER),
                perp.balanceOf(USER),
                vault.usdBalance(),
                vault.perpSrBalance()
            )
        );
        vm.expectRevert(FailingTransferFromToken.ForcedFailure.selector);
        vm.prank(USER);
        vault.deposit(1e6, 10_000_000_000);
        assertEq(
            keccak256(
                abi.encode(
                    vault.totalSupply(),
                    vault.balanceOf(USER),
                    usd.balanceOf(USER),
                    perp.balanceOf(USER),
                    vault.usdBalance(),
                    vault.perpSrBalance()
                )
            ),
            beforeFingerprint
        );
    }

    function testSingleEmptyReserveBranchesAndBothEmptyPositiveInputReverts() public {
        Vector memory vector = _vector(4);
        vector.usdBalance = 0;
        Env memory noUsd = _deploy(vector);
        (, uint256 usdNoUsd, uint256 perpNoUsd) = noUsd.vault.computeMintAmt(1_000, 2_000);
        assertEq(usdNoUsd, 0);
        assertEq(perpNoUsd, 2_000);

        vector = _vector(4);
        vector.perpBalance = 0;
        Env memory noPerp = _deploy(vector);
        (, uint256 usdNoPerp, uint256 perpNoPerp) = noPerp.vault.computeMintAmt(1_000, 2_000);
        assertEq(usdNoPerp, 1_000);
        assertEq(perpNoPerp, 0);

        vector.usdBalance = 0;
        Env memory bothEmpty = _deploy(vector);
        vm.expectRevert(stdError.divisionError);
        bothEmpty.vault.computeMintAmt(1_000, 2_000);
    }

    function _deploy(Vector memory vector) private returns (Env memory env) {
        env.usd = new MockERC20("USD Coin", "USDC", 6);
        env.perp = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        env.underlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        env.oracle = new MockPriceOracle(vector.underlyingPrice);
        env.controller = new MockUsdVaultController(address(env.oracle));
        env.controller.setPerpSrState(vector.srSupply, vector.srReserveValue, 0);
        env.vault = _deployVault(address(env.usd), address(env.perp), address(env.underlying), address(env.controller));
        env.vault.mintNotes(SEED, vector.notesSupply);
        env.usd.mint(address(env.vault), vector.usdBalance);
        env.perp.mint(address(env.vault), vector.perpBalance);
        env.underlying.mint(address(env.vault), vector.idleUnderlying);
    }

    function _deployVault(address usd, address perp, address underlying, address controller)
        private
        returns (UsdVaultMintHarness result)
    {
        UsdVaultMintHarness implementation = new UsdVaultMintHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(UsdVault.init, (TARGET_NAME, TARGET_SYMBOL, usd, perp, underlying, controller))
        );
        result = UsdVaultMintHarness(address(proxy));
    }

    function _modelQuote(Vector memory vector, uint256 usdMax, uint256 perpMax)
        private
        pure
        returns (uint256 notesOut, uint256 usdIn, uint256 perpIn)
    {
        return _modelQuoteWithBalances(
            vector, vector.usdBalance, vector.perpBalance, vector.idleUnderlying, usdMax, perpMax
        );
    }

    function _modelCurrent(Env memory env, Vector memory vector, uint256 usdMax, uint256 perpMax)
        private
        view
        returns (uint256 notesOut, uint256 usdIn, uint256 perpIn)
    {
        return _modelQuoteWithBalances(
            vector, env.vault.usdBalance(), env.vault.perpSrBalance(), env.vault.underlyingBalance(), usdMax, perpMax
        );
    }

    function _modelQuoteWithBalances(
        Vector memory vector,
        uint256 usdBalance,
        uint256 perpBalance,
        uint256 idleUnderlying,
        uint256 usdMax,
        uint256 perpMax
    ) private pure returns (uint256 notesOut, uint256 usdIn, uint256 perpIn) {
        if (usdMax * perpBalance <= perpMax * usdBalance) {
            usdIn = usdMax;
            perpIn = usdMax * perpBalance / usdBalance;
        } else {
            perpIn = perpMax;
            usdIn = perpMax * usdBalance / perpBalance;
        }
        uint256 vaultPerpUnderlying = Math.mulDiv(perpBalance, vector.srReserveValue, vector.srSupply);
        uint256 tvl = Math.mulDiv(usdBalance, WAD, USD_UNIT)
            + Math.mulDiv(idleUnderlying, vector.underlyingPrice, UNDERLYING_UNIT)
            + Math.mulDiv(vaultPerpUnderlying, vector.underlyingPrice, UNDERLYING_UNIT);
        uint256 depositPerpUnderlying = Math.mulDiv(perpIn, vector.srReserveValue, vector.srSupply);
        uint256 depositValue = Math.mulDiv(usdIn, WAD, USD_UNIT)
            + Math.mulDiv(depositPerpUnderlying, vector.underlyingPrice, UNDERLYING_UNIT);
        notesOut = Math.mulDiv(depositValue, vector.notesSupply, tvl);
    }

    function _fingerprint(Env memory env, address user) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                env.vault.totalSupply(),
                env.vault.balanceOf(user),
                env.usd.balanceOf(user),
                env.perp.balanceOf(user),
                env.vault.usdBalance(),
                env.vault.perpSrBalance(),
                env.vault.underlyingBalance()
            )
        );
    }

    function _assertDepositLogOrder(
        Vm.Log[] memory logs,
        Env memory env,
        uint256 usdIn,
        uint256 perpIn,
        uint256 notesMinted
    ) private pure {
        assertEq(logs.length, 4);
        _assertTransfer(logs[0], address(env.usd), USER, address(env.vault), usdIn);
        _assertTransfer(logs[1], address(env.perp), USER, address(env.vault), perpIn);
        _assertTransfer(logs[2], address(env.vault), address(0), USER, notesMinted);
        assertEq(logs[3].emitter, address(env.vault));
        assertEq(logs[3].topics.length, 1);
        assertEq(logs[3].topics[0], DEPOSIT_TOPIC);
        (uint256 eventUsd, uint256 eventPerp, uint256 eventNotes) =
            abi.decode(logs[3].data, (uint256, uint256, uint256));
        assertEq(eventUsd, usdIn);
        assertEq(eventPerp, perpIn);
        assertEq(eventNotes, notesMinted);
    }

    function _assertTransfer(Vm.Log memory log, address emitter, address from, address to, uint256 amount)
        private
        pure
    {
        assertEq(log.emitter, emitter);
        assertEq(log.topics.length, 3);
        assertEq(log.topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(log.topics[1]))), from);
        assertEq(address(uint160(uint256(log.topics[2]))), to);
        assertEq(abi.decode(log.data, (uint256)), amount);
    }

    function _vector(uint256 index) private pure returns (Vector memory vector) {
        if (index == 0) {
            return Vector({
                blockNumber: 52_915_437,
                notesSupply: 38_573_922_792_474_201_257_394,
                usdBalance: 13_273_505,
                perpBalance: 3_846_191_368_848,
                idleUnderlying: 0,
                srSupply: 4_086_084_443_262,
                srReserveValue: 48_529_480,
                underlyingPrice: 84_736_829_512_060_000_000_000,
                tvl: 38_721_332_620_804_922_195_000,
                notesOut: 100_290_640_708_916_173_358,
                usdIn: 34_510,
                perpIn: 10_000_000_000
            });
        }
        if (index == 1) {
            return Vector({
                blockNumber: 52_951_097,
                notesSupply: 59_685_176_998_854_211_901_260,
                usdBalance: 20_538_007,
                perpBalance: 5_951_186_612_484,
                idleUnderlying: 0,
                srSupply: 5_952_509_513_110,
                srReserveValue: 73_797_927,
                underlyingPrice: 81_175_649_509_330_000_000_000,
                tvl: 59_913_170_143_638_691_282_500,
                notesOut: 100_290_542_230_908_439_944,
                usdIn: 34_510,
                perpIn: 10_000_000_000
            });
        }
        if (index == 2) {
            return Vector({
                blockNumber: 53_236_494,
                notesSupply: 79_937_409_643_534_650_788_582,
                usdBalance: 27_506_914,
                perpBalance: 7_970_529_505_535,
                idleUnderlying: 0,
                srSupply: 7_978_609_218_527,
                srReserveValue: 100_702_952,
                underlyingPrice: 79_834_954_319_220_000_000_000,
                tvl: 80_342_246_954_891_302_818_400,
                notesOut: 100_291_078_925_391_285_697,
                usdIn: 34_510,
                perpIn: 10_000_000_000
            });
        }
        if (index == 3) {
            return Vector({
                blockNumber: 53_469_759,
                notesSupply: 80_041_967_211_714_639_460_967,
                usdBalance: 1_285_056_998,
                perpBalance: 7_853_455_614_839,
                idleUnderlying: 38_782,
                srSupply: 7_861_538_816_846,
                srReserveValue: 102_212_247,
                underlyingPrice: 77_569_737_555_120_000_000_000,
                tvl: 80_519_389_925_026_088_820_800,
                notesOut: 62_263_207_820_484_804_771,
                usdIn: 1_000_000,
                perpIn: 6_111_367_532
            });
        }
        return Vector({
            blockNumber: 53_526_143,
            notesSupply: 99_448_990_873_551_042_788_206,
            usdBalance: 3_732_531,
            perpBalance: 9_913_086_977_476,
            idleUnderlying: 61_287,
            srSupply: 10_091_631_737_151,
            srReserveValue: 126_885_687,
            underlyingPrice: 80_248_101_897_110_000_000_000,
            tvl: 100_074_774_324_962_383_263_700,
            notesOut: 100_271_154_039_568_388_009,
            usdIn: 3_765,
            perpIn: 10_000_000_000
        });
    }
}
