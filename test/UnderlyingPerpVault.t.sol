// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockUnderlyingPerpVaultController} from "./mocks/MockUnderlyingPerpVaultController.sol";

contract UnderlyingPerpVaultHarness is UnderlyingPerpVault {
    function forceInitializedForTest() external {
        _vaultInitialized = true;
    }

    function mintNotesForTest(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract UnderlyingPerpVaultTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Deposit(uint256 underlyingAmtIn, uint256 perpAmtIn, uint256 notesMinted);
    event Redeem(uint256 notesBurnt, uint256 underlyingAmtOut, uint256 perpAmtOut);

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant DEPOSIT_TOPIC = keccak256("Deposit(uint256,uint256,uint256)");
    bytes32 private constant REDEEM_TOPIC = keccak256("Redeem(uint256,uint256,uint256)");

    address private constant USER = address(0xA11CE);
    address private constant KEEPER = address(0xBEEF);

    MockERC20 private underlying;
    MockERC20 private perpSr;
    MockERC20 private perpJr;
    MockUnderlyingPerpVaultController private controller;

    function setUp() public {
        underlying = new MockERC20("Coinbase Wrapped BTC", "cbBTC", 8);
        perpSr = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        perpJr = new MockERC20("cbBTC Junior", "cbBTC-JR", 8);
        controller = new MockUnderlyingPerpVaultController(address(perpSr), address(perpJr));
    }

    function testSharedImplementationSelectsTargetSideAndMetadata() public {
        UnderlyingPerpVaultHarness jr = _deploy(false, false, "cbBTC Junior Keeper", "cbBTC-Jr-Keeper");
        UnderlyingPerpVaultHarness sr = _deploy(true, true, "cbBTC Senior Keeper", "cbBTC-Sr-Keeper");

        assertEq(jr.name(), "cbBTC Junior Keeper");
        assertEq(jr.symbol(), "cbBTC-Jr-Keeper");
        assertEq(jr.decimals(), 18);
        assertEq(jr.underlying(), address(underlying));
        assertEq(jr.perp(), address(perpJr));
        assertEq(jr.perpController(), address(controller));
        assertFalse(jr.isPerpSrVault());
        assertFalse(jr.mintsAboveTarget());

        assertEq(sr.name(), "cbBTC Senior Keeper");
        assertEq(sr.symbol(), "cbBTC-Sr-Keeper");
        assertEq(sr.underlying(), address(underlying));
        assertEq(sr.perp(), address(perpSr));
        assertTrue(sr.isPerpSrVault());
        assertTrue(sr.mintsAboveTarget());
        assertEq(sr.underlyingUnitAmt(), 1e8);
        assertEq(sr.MINIMUM_LIQUIDITY(), 1e10);
        assertEq(sr.ONE(), 1e18);
        assertEq(sr.keeper(), address(this));
    }

    function testTargetInitDepositLocksMinimumLiquidityAndEventOrder() public {
        UnderlyingPerpVaultHarness vault = _deploy(true, true, "cbBTC Senior Keeper", "cbBTC-Sr-Keeper");
        underlying.mint(address(this), 100_000);
        underlying.approve(address(vault), 100_000);

        vm.recordLogs();
        uint256 returnedNotes = vault.initDeposit(100_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(returnedNotes, 1e15);
        assertEq(vault.totalSupply(), 1e15);
        assertEq(vault.balanceOf(address(vault)), 1e10);
        assertEq(vault.balanceOf(address(this)), 999_990_000_000_000);
        assertEq(vault.underlyingBalance(), 100_000);
        assertEq(logs.length, 5);
        _assertLog(logs[0], address(underlying), TRANSFER_TOPIC);
        _assertLog(logs[1], address(vault), TRANSFER_TOPIC);
        _assertLog(logs[2], address(vault), TRANSFER_TOPIC);
        _assertLog(logs[3], address(vault), DEPOSIT_TOPIC);
        _assertLog(logs[4], address(vault), DEPOSIT_TOPIC);
        (uint256 lockedUnderlying, uint256 lockedPerp, uint256 lockedNotes) =
            abi.decode(logs[3].data, (uint256, uint256, uint256));
        assertEq(lockedUnderlying, 0);
        assertEq(lockedPerp, 0);
        assertEq(lockedNotes, 1e10);
        (uint256 userUnderlying, uint256 userPerp, uint256 userNotes) =
            abi.decode(logs[4].data, (uint256, uint256, uint256));
        assertEq(userUnderlying, 100_000);
        assertEq(userPerp, 0);
        assertEq(userNotes, 999_990_000_000_000);

        (uint256 quotedNotes, uint256 quotedUnderlying, uint256 quotedPerp) = vault.computeMintAmt(100_000, 0);
        assertEq(quotedNotes, 1e15);
        assertEq(quotedUnderlying, 100_000);
        assertEq(quotedPerp, 0);

        vm.expectRevert(UnderlyingPerpVault.VaultInitialized.selector);
        vault.initDeposit(100_000);
    }

    function testInitDepositZeroAndOneAreNoOpsButTwoInitializes() public {
        UnderlyingPerpVaultHarness zeroVault = _deploy(false, false, "JR0", "JR0");
        assertEq(zeroVault.initDeposit(0), 0);
        vm.expectRevert(UnderlyingPerpVault.VaultNotInitialized.selector);
        zeroVault.deposit(0, 0);

        UnderlyingPerpVaultHarness oneVault = _deploy(false, false, "JR1", "JR1");
        underlying.mint(address(this), 1);
        underlying.approve(address(oneVault), 1);
        assertEq(oneVault.initDeposit(1), 0);
        assertEq(oneVault.totalSupply(), 0);
        assertEq(oneVault.underlyingBalance(), 0);
        vm.expectRevert(UnderlyingPerpVault.VaultNotInitialized.selector);
        oneVault.deposit(0, 0);

        UnderlyingPerpVaultHarness twoVault = _deploy(false, false, "JR2", "JR2");
        underlying.mint(address(this), 2);
        underlying.approve(address(twoVault), 2);
        assertEq(twoVault.initDeposit(2), 2e10);
        assertEq(twoVault.totalSupply(), 2e10);
        assertEq(twoVault.balanceOf(address(twoVault)), 1e10);
        assertEq(twoVault.balanceOf(address(this)), 1e10);
        assertEq(twoVault.deposit(0, 0), 0);
    }

    function testTargetCurrentTvlVectorsMatchBothSidesExactly() public {
        controller.setPerpSrState(10_091_631_737_151, 126_885_687, 234_991_043_552_453);
        controller.setPerpJrState(32_509_969_817_791, 380_247_094, 1_333_614_305_018_199_560);

        UnderlyingPerpVaultHarness jr = _rawVault(false, 3_813_064_395_481_201_456, 0, 32_102_063_162_351);
        UnderlyingPerpVaultHarness sr = _rawVault(true, 121_588_631_786_949_865, 10_259_975, 170_465_061_177);

        assertEq(jr.getTVL(), 375_476_086);
        assertEq(sr.getTVL(), 12_403_293);
    }

    function testTargetJuniorPerpOnlyMintVectorMatchesExactly() public {
        UnderlyingPerpVaultHarness vault = _rawVault(false, 3_813_064_395_481_201_456, 0, 32_102_063_162_351);

        (uint256 notes, uint256 underlyingIn, uint256 perpIn) = vault.computeMintAmt(100_000, 10_000_000_000);
        assertEq(notes, 1_187_794_185_126_745);
        assertEq(underlyingIn, 0);
        assertEq(perpIn, 10_000_000_000);
    }

    function testTargetHistoricalJuniorDirectDepositMatchesExactly() public {
        UnderlyingPerpVaultHarness vault = _rawVault(false, 10_010_350_000_000_000, 0, 84_239_786_870);
        uint256 perpMax = 1_636_069_530_773;
        perpJr.mint(USER, perpMax);

        vm.startPrank(USER);
        perpJr.approve(address(vault), perpMax);
        vm.recordLogs();
        uint256 notes = vault.deposit(0, perpMax);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(notes, 194_416_786_128_004_843);
        assertEq(vault.balanceOf(USER), 10_010_350_000_000_000 + notes);
        assertEq(vault.perpBalance(), 84_239_786_870 + perpMax);
        assertEq(logs.length, 3);
        _assertLog(logs[0], address(perpJr), TRANSFER_TOPIC);
        _assertLog(logs[1], address(vault), TRANSFER_TOPIC);
        _assertLog(logs[2], address(vault), DEPOSIT_TOPIC);
    }

    function testTargetHistoricalSeniorLimitingLegAndDepositMatchExactly() public {
        UnderlyingPerpVaultHarness vault = _rawVault(true, 1_379_300_000_000_000, 27_196, 9_257_448_029);
        uint256 underlyingMax = 1_590_000;
        uint256 perpMax = 540_252_299_306;

        (uint256 quotedNotes, uint256 underlyingIn, uint256 perpIn) = vault.computeMintAmt(underlyingMax, perpMax);
        assertEq(quotedNotes, 80_494_093_785_850_860);
        assertEq(underlyingIn, 1_587_122);
        assertEq(perpIn, perpMax);

        underlying.mint(USER, underlyingMax);
        perpSr.mint(USER, perpMax);
        vm.startPrank(USER);
        underlying.approve(address(vault), underlyingMax);
        perpSr.approve(address(vault), perpMax);
        vm.recordLogs();
        uint256 notes = vault.deposit(underlyingMax, perpMax);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(notes, quotedNotes);
        assertEq(logs.length, 4);
        _assertLog(logs[0], address(underlying), TRANSFER_TOPIC);
        _assertLog(logs[1], address(perpSr), TRANSFER_TOPIC);
        _assertLog(logs[2], address(vault), TRANSFER_TOPIC);
        _assertLog(logs[3], address(vault), DEPOSIT_TOPIC);
    }

    function testTargetCurrentSeniorLimitingLegExactAndPlusMinusOne() public {
        UnderlyingPerpVaultHarness vault = _rawVault(true, 121_588_631_786_949_865, 10_259_975, 170_465_061_177);
        _assertMintQuote(vault, 10_259_975, 170_465_061_176, 121_588_619_936_177_149, 10_259_974, 170_465_061_176);
        _assertMintQuote(vault, 10_259_975, 170_465_061_177, 121_588_631_786_949_865, 10_259_975, 170_465_061_177);
        _assertMintQuote(vault, 10_259_975, 170_465_061_178, 121_588_631_786_949_865, 10_259_975, 170_465_061_177);
    }

    function testTinyDepositReturningZeroMovesNothingAndEmitsNothing() public {
        UnderlyingPerpVaultHarness vault = _rawVault(true, 1_379_300_000_000_000, 27_196, 9_257_448_029);
        perpSr.mint(USER, 1);
        vm.prank(USER);
        perpSr.approve(address(vault), 1);
        bytes32 beforeFingerprint = _fingerprint(vault, USER);

        vm.recordLogs();
        vm.prank(USER);
        assertEq(vault.deposit(1, 1), 0);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(_fingerprint(vault, USER), beforeFingerprint);
    }

    function testHistoricalJuniorAndSeniorRedeemsMatchExactly() public {
        UnderlyingPerpVaultHarness jr = _rawVault(false, 51_572_640_000_000_000, 4_412_145, 62_639_427_178);
        (uint256 jrUnderlying, uint256 jrPerp) = jr.computeRedemptionAmts(41_562_290_000_000_000);
        assertEq(jrUnderlying, 3_555_739);
        assertEq(jrPerp, 50_480_992_204);

        vm.recordLogs();
        vm.prank(USER);
        (uint256 jrUnderlyingActual, uint256 jrPerpActual) = jr.redeem(41_562_290_000_000_000);
        Vm.Log[] memory jrLogs = vm.getRecordedLogs();
        assertEq(jrUnderlyingActual, jrUnderlying);
        assertEq(jrPerpActual, jrPerp);
        _assertRedeemLogOrder(jr, address(perpJr), jrLogs);

        UnderlyingPerpVaultHarness sr = _rawVault(true, 51_000_000_000_000_000, 5_043_416, 4_785_545_326);
        (uint256 srUnderlying, uint256 srPerp) = sr.computeRedemptionAmts(49_620_700_000_000_000);
        assertEq(srUnderlying, 4_907_016);
        assertEq(srPerp, 4_656_119_783);

        vm.recordLogs();
        vm.prank(USER);
        (uint256 srUnderlyingActual, uint256 srPerpActual) = sr.redeem(49_620_700_000_000_000);
        Vm.Log[] memory srLogs = vm.getRecordedLogs();
        assertEq(srUnderlyingActual, srUnderlying);
        assertEq(srPerpActual, srPerp);
        _assertRedeemLogOrder(sr, address(perpSr), srLogs);
    }

    function testSecondLegAllowanceFailureRollsBackFirstTransferAndMint() public {
        UnderlyingPerpVaultHarness vault = _rawVault(true, 1_379_300_000_000_000, 27_196, 9_257_448_029);
        uint256 underlyingMax = 1_590_000;
        uint256 perpMax = 540_252_299_306;
        underlying.mint(USER, underlyingMax);
        perpSr.mint(USER, perpMax);
        vm.prank(USER);
        underlying.approve(address(vault), underlyingMax);
        bytes32 beforeFingerprint = _fingerprint(vault, USER);

        vm.expectRevert();
        vm.prank(USER);
        vault.deposit(underlyingMax, perpMax);
        assertEq(_fingerprint(vault, USER), beforeFingerprint);
    }

    function testPauseAndRepeatedInitializerGuards() public {
        UnderlyingPerpVaultHarness vault = _rawVault(false, 1e15, 100_000, 0);
        vm.expectRevert(UnderlyingPerpVault.UnauthorizedCall.selector);
        vm.prank(USER);
        vault.pause();

        vault.updateKeeper(address(0));
        assertEq(vault.keeper(), address(0));
        vault.updateKeeper(KEEPER);
        assertEq(vault.keeper(), KEEPER);

        vm.expectRevert(UnderlyingPerpVault.UnauthorizedCall.selector);
        vault.pause();
        vm.prank(KEEPER);
        vault.pause();
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(USER);
        vault.deposit(0, 0);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(USER);
        vault.redeem(1);
        vm.prank(KEEPER);
        vault.unpause();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.init("x", "x", address(underlying), address(controller), false, false);
    }

    function testFuzzRedemptionUsesIndependentFloorRounding(uint96 notesRaw) public {
        uint256 supply = 51_572_640_000_000_000;
        uint256 notes = bound(uint256(notesRaw), 0, supply);
        UnderlyingPerpVaultHarness vault = _rawVault(false, supply, 4_412_145, 62_639_427_178);
        (uint256 underlyingOut, uint256 perpOut) = vault.computeRedemptionAmts(notes);
        assertEq(underlyingOut, Math.mulDiv(notes, 4_412_145, supply));
        assertEq(perpOut, Math.mulDiv(notes, 62_639_427_178, supply));
    }

    function _deploy(bool senior, bool mintsAbove, string memory name_, string memory symbol_)
        private
        returns (UnderlyingPerpVaultHarness vault)
    {
        UnderlyingPerpVaultHarness implementation = new UnderlyingPerpVaultHarness();
        bytes memory initData = abi.encodeCall(
            UnderlyingPerpVault.init, (name_, symbol_, address(underlying), address(controller), senior, mintsAbove)
        );
        vault = UnderlyingPerpVaultHarness(address(new ERC1967Proxy(address(implementation), initData)));
    }

    function _rawVault(bool senior, uint256 supply, uint256 underlyingBal, uint256 perpBal)
        private
        returns (UnderlyingPerpVaultHarness vault)
    {
        vault = _deploy(senior, senior, senior ? "SR" : "JR", senior ? "SR" : "JR");
        vault.forceInitializedForTest();
        vault.mintNotesForTest(USER, supply);
        underlying.mint(address(vault), underlyingBal);
        (senior ? perpSr : perpJr).mint(address(vault), perpBal);
    }

    function _assertRedeemLogOrder(UnderlyingPerpVaultHarness vault, address perpToken, Vm.Log[] memory logs)
        private
        view
    {
        assertEq(logs.length, 4);
        _assertLog(logs[0], address(vault), TRANSFER_TOPIC);
        _assertLog(logs[1], address(underlying), TRANSFER_TOPIC);
        _assertLog(logs[2], perpToken, TRANSFER_TOPIC);
        _assertLog(logs[3], address(vault), REDEEM_TOPIC);
    }

    function _assertMintQuote(
        UnderlyingPerpVaultHarness vault,
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

    function _assertLog(Vm.Log memory entry, address emitter, bytes32 topic) private pure {
        assertEq(entry.emitter, emitter);
        assertEq(entry.topics[0], topic);
    }

    function _fingerprint(UnderlyingPerpVaultHarness vault, address user) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.totalSupply(),
                vault.balanceOf(user),
                vault.underlyingBalance(),
                vault.perpBalance(),
                underlying.balanceOf(user),
                MockERC20(vault.perp()).balanceOf(user)
            )
        );
    }
}
