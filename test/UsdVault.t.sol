// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUsdVault} from "../src/interfaces/IUsdVault.sol";
import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract UsdVaultHarness is UsdVault {
    function mintNotes(address to, uint256 amount) external {
        _mintNotes(to, amount);
    }
}

contract RevertingTransferToken is ERC20 {
    error ForcedFailure();

    bool public transfersFail;

    constructor() ERC20("Reverting USD", "rUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransfersFail(bool fail) external {
        transfersFail = fail;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (transfersFail) revert ForcedFailure();
        return super.transfer(to, value);
    }
}

contract UsdVaultTest is Test {
    event Redeem(uint256 notesAmt, uint256 usdAmtOut, uint256 perpSrAmtOut);

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant REDEEM_TOPIC = keccak256("Redeem(uint256,uint256,uint256)");

    string private constant TARGET_NAME = "cbBTC Senior USDC Keeper";
    string private constant TARGET_SYMBOL = "cbBTC-Sr-USDC-Keeper";

    uint256 private constant NOTES_SUPPLY_BEFORE = 11_196_354_068_000_000_000_000;
    uint256 private constant HOLDER_NOTES_BEFORE = 11_196_344_068_000_000_000_000;
    uint256 private constant SEED_NOTES = 10_000_000_000_000_000;
    uint256 private constant NOTES_IN = 11_042_700_000_000_000_000_000;
    uint256 private constant USD_BEFORE = 10_929_657_330;
    uint256 private constant PERP_SR_BEFORE = 26_615_667_277;
    uint256 private constant USD_OUT = 10_779_663_296;
    uint256 private constant PERP_SR_OUT = 26_250_405_020;
    uint256 private constant NOTES_SUPPLY_AFTER = 153_654_068_000_000_000_000;
    uint256 private constant USD_AFTER = 149_994_034;
    uint256 private constant PERP_SR_AFTER = 365_262_257;

    address private constant HOLDER = address(0xA11CE);
    address private constant SEED = address(0x5EED);
    address private constant ROUTER = address(0xB0B);

    MockERC20 private usd;
    MockERC20 private perpSr;
    UsdVaultHarness private vault;

    function setUp() public {
        usd = new MockERC20("USD Coin", "USDC", 6);
        perpSr = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        vault = _deployVault(address(usd), address(perpSr));

        vault.mintNotes(HOLDER, HOLDER_NOTES_BEFORE);
        vault.mintNotes(SEED, SEED_NOTES);
        usd.mint(address(vault), USD_BEFORE);
        perpSr.mint(address(vault), PERP_SR_BEFORE);
    }

    function testTargetMetadataReserveViewsAndHistoricalQuote() public view {
        assertEq(vault.name(), TARGET_NAME);
        assertEq(vault.symbol(), TARGET_SYMBOL);
        assertEq(vault.decimals(), 18);
        assertEq(vault.totalSupply(), NOTES_SUPPLY_BEFORE);
        assertEq(vault.usdBalance(), USD_BEFORE);
        assertEq(vault.perpSrBalance(), PERP_SR_BEFORE);
        assertEq(vault.usdBalance(), usd.balanceOf(address(vault)));
        assertEq(vault.perpSrBalance(), perpSr.balanceOf(address(vault)));

        (uint256 usdOut, uint256 perpSrOut) = vault.computeRedemptionAmts(NOTES_IN);
        assertEq(usdOut, USD_OUT);
        assertEq(perpSrOut, PERP_SR_OUT);
    }

    function testHistoricalNaturalHolderVectorMatchesExactly() public {
        vm.recordLogs();
        vm.prank(HOLDER);
        (uint256 usdOut, uint256 perpSrOut) = vault.redeem(NOTES_IN);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(usdOut, USD_OUT);
        assertEq(perpSrOut, PERP_SR_OUT);
        assertEq(vault.totalSupply(), NOTES_SUPPLY_AFTER);
        assertEq(vault.balanceOf(HOLDER), HOLDER_NOTES_BEFORE - NOTES_IN);
        assertEq(vault.balanceOf(SEED), SEED_NOTES);
        assertEq(usd.balanceOf(HOLDER), USD_OUT);
        assertEq(perpSr.balanceOf(HOLDER), PERP_SR_OUT);
        assertEq(vault.usdBalance(), USD_AFTER);
        assertEq(vault.perpSrBalance(), PERP_SR_AFTER);
        _assertHistoricalLogOrder(logs);
    }

    function testNaturalBalancePlusOneRevertsWithTargetSelectorAndIsAtomic() public {
        uint256 invalidNotes = HOLDER_NOTES_BEFORE + 1;
        bytes32 beforeFingerprint = _fingerprint(HOLDER);

        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, HOLDER, HOLDER_NOTES_BEFORE, invalidNotes
            )
        );
        vm.prank(HOLDER);
        vault.redeem(invalidNotes);

        assertEq(_fingerprint(HOLDER), beforeFingerprint);
        assertEq(IERC20Errors.ERC20InsufficientBalance.selector, bytes4(0xe450d38c));
    }

    function testRouterAllowanceTransferAndRedeemPath() public {
        uint256 notesIn = 3_762_930_374_354_620_392;
        (uint256 expectedUsd, uint256 expectedPerpSr) = vault.computeRedemptionAmts(notesIn);

        vm.prank(HOLDER);
        vault.approve(ROUTER, notesIn);
        vm.prank(ROUTER);
        assertTrue(vault.transferFrom(HOLDER, ROUTER, notesIn));

        assertEq(vault.allowance(HOLDER, ROUTER), 0);
        assertEq(vault.balanceOf(ROUTER), notesIn);

        vm.prank(ROUTER);
        (uint256 usdOut, uint256 perpSrOut) = vault.redeem(notesIn);

        assertEq(vault.balanceOf(ROUTER), 0);
        assertEq(usdOut, expectedUsd);
        assertEq(perpSrOut, expectedPerpSr);
        assertEq(usd.balanceOf(ROUTER), expectedUsd);
        assertEq(perpSr.balanceOf(ROUTER), expectedPerpSr);
    }

    function testFullSupplyExitDrainsBothReserveAssetsExactly() public {
        vm.prank(SEED);
        assertTrue(vault.transfer(HOLDER, SEED_NOTES));

        vm.prank(HOLDER);
        (uint256 usdOut, uint256 perpSrOut) = vault.redeem(NOTES_SUPPLY_BEFORE);

        assertEq(usdOut, USD_BEFORE);
        assertEq(perpSrOut, PERP_SR_BEFORE);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.balanceOf(HOLDER), 0);
        assertEq(vault.usdBalance(), 0);
        assertEq(vault.perpSrBalance(), 0);
        assertEq(usd.balanceOf(HOLDER), USD_BEFORE);
        assertEq(perpSr.balanceOf(HOLDER), PERP_SR_BEFORE);
    }

    function testTransferFailureRollsBackBurnAndAllBalances() public {
        RevertingTransferToken revertingUsd = new RevertingTransferToken();
        MockERC20 localPerp = new MockERC20("Senior", "SR", 8);
        UsdVaultHarness localVault = _deployVault(address(revertingUsd), address(localPerp));
        localVault.mintNotes(HOLDER, 100e18);
        revertingUsd.mint(address(localVault), 1_000e18);
        localPerp.mint(address(localVault), 2_000e8);
        revertingUsd.setTransfersFail(true);

        bytes32 beforeFingerprint = keccak256(
            abi.encode(
                localVault.totalSupply(),
                localVault.balanceOf(HOLDER),
                localVault.usdBalance(),
                localVault.perpSrBalance(),
                revertingUsd.balanceOf(HOLDER),
                localPerp.balanceOf(HOLDER)
            )
        );

        vm.expectRevert(RevertingTransferToken.ForcedFailure.selector);
        vm.prank(HOLDER);
        localVault.redeem(50e18);

        assertEq(
            keccak256(
                abi.encode(
                    localVault.totalSupply(),
                    localVault.balanceOf(HOLDER),
                    localVault.usdBalance(),
                    localVault.perpSrBalance(),
                    revertingUsd.balanceOf(HOLDER),
                    localPerp.balanceOf(HOLDER)
                )
            ),
            beforeFingerprint
        );
    }

    function testInitializerCannotBeReused() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.init(TARGET_NAME, TARGET_SYMBOL, address(usd), address(perpSr), address(1), address(2));
    }

    function testFuzzQuoteUsesExactFloorRounding(uint256 notesIn) public view {
        notesIn = bound(notesIn, 0, NOTES_SUPPLY_BEFORE);
        (uint256 usdOut, uint256 perpSrOut) = vault.computeRedemptionAmts(notesIn);

        assertEq(usdOut, Math.mulDiv(notesIn, USD_BEFORE, NOTES_SUPPLY_BEFORE));
        assertEq(perpSrOut, Math.mulDiv(notesIn, PERP_SR_BEFORE, NOTES_SUPPLY_BEFORE));
    }

    function _deployVault(address usdToken, address perpSrToken) private returns (UsdVaultHarness result) {
        MockERC20 localUnderlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        MockPriceOracle localOracle = new MockPriceOracle(80_000e18);
        MockUsdVaultController localController = new MockUsdVaultController(address(localOracle));
        localController.setPerpSrState(1e8, 1e8, 1e18);
        UsdVaultHarness implementation = new UsdVaultHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                UsdVault.init,
                (TARGET_NAME, TARGET_SYMBOL, usdToken, perpSrToken, address(localUnderlying), address(localController))
            )
        );
        result = UsdVaultHarness(address(proxy));
    }

    function _fingerprint(address holder) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                vault.totalSupply(),
                vault.balanceOf(holder),
                usd.balanceOf(holder),
                perpSr.balanceOf(holder),
                vault.usdBalance(),
                vault.perpSrBalance()
            )
        );
    }

    function _assertHistoricalLogOrder(Vm.Log[] memory logs) private view {
        assertEq(logs.length, 4);

        assertEq(logs[0].emitter, address(vault));
        assertEq(logs[0].topics.length, 3);
        assertEq(logs[0].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[0].topics[1]))), HOLDER);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(0));
        assertEq(abi.decode(logs[0].data, (uint256)), NOTES_IN);

        assertEq(logs[1].emitter, address(usd));
        assertEq(logs[1].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[1].topics[1]))), address(vault));
        assertEq(address(uint160(uint256(logs[1].topics[2]))), HOLDER);
        assertEq(abi.decode(logs[1].data, (uint256)), USD_OUT);

        assertEq(logs[2].emitter, address(perpSr));
        assertEq(logs[2].topics[0], TRANSFER_TOPIC);
        assertEq(address(uint160(uint256(logs[2].topics[1]))), address(vault));
        assertEq(address(uint160(uint256(logs[2].topics[2]))), HOLDER);
        assertEq(abi.decode(logs[2].data, (uint256)), PERP_SR_OUT);

        assertEq(logs[3].emitter, address(vault));
        assertEq(logs[3].topics.length, 1);
        assertEq(logs[3].topics[0], REDEEM_TOPIC);
        (uint256 notesIn, uint256 usdOut, uint256 perpSrOut) = abi.decode(logs[3].data, (uint256, uint256, uint256));
        assertEq(notesIn, NOTES_IN);
        assertEq(usdOut, USD_OUT);
        assertEq(perpSrOut, PERP_SR_OUT);
    }
}
