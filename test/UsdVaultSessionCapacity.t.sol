// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UsdVault} from "../src/vault/UsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract UsdVaultSessionHarness is UsdVault {
    function mintNotes(address to, uint256 amount) external {
        _mintNotes(to, amount);
    }

    function setSessionState(bool isMintingPerp, uint128 budgetUsdVal, uint64 openedAtSec) external {
        _setSessionState(isMintingPerp, budgetUsdVal, openedAtSec);
    }
}

contract UsdVaultSessionCapacityTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant TARGET_DR = 1_027_500_000_000_000_000;
    uint256 private constant TARGET_SUB_DR = 1_052_430_305_854_682_822;
    uint256 private constant TARGET_VM_DR = 1_000_210_729_013_702_352;
    uint256 private constant TARGET_TVL = 100_074_774_324_962_383_263_700;
    uint256 private constant TARGET_PREVIEW_BUDGET = 33_024_675_527_237_586_477_021;
    uint256 private constant TARGET_WINDOW_OPEN = 1_793_829_600;
    uint256 private constant NOTES_SUPPLY = 99_448_990_873_551_042_788_206;
    uint256 private constant USD_BALANCE = 3_732_531;
    uint256 private constant PERP_BALANCE = 9_913_086_977_476;
    uint256 private constant IDLE_UNDERLYING = 61_287;
    uint256 private constant SR_SUPPLY = 10_091_631_737_151;
    uint256 private constant SR_RESERVE_VALUE = 126_885_687;
    uint256 private constant UNDERLYING_PRICE = 80_248_101_897_110_000_000_000;
    address private constant SEED = address(0x5EED);
    address private constant USER = address(0xA11CE);

    struct Env {
        UsdVaultSessionHarness vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockUsdVaultController controller;
    }

    function testDefaultSessionConfigMatchesVersionLockedTarget() public {
        Env memory env = _deploy();
        assertEq(env.vault.rebalanceFreqSec(), 28_800);
        assertEq(env.vault.rebalanceOffsetSec(), 21_600);
        assertEq(env.vault.maxDeploymentVelocityPerc(), 330_000_000_000_000_000);
        assertEq(env.vault.targetDR(), TARGET_DR);
        assertEq(env.vault.sessionBudgetUsdVal(), 0);
        assertEq(env.vault.sessionOpenedAtSec(), 0);
        assertFalse(env.vault.sessionIsMintingPerp());
    }

    function testInactivePreviewMatchesTargetVectorExactly() public {
        Env memory env = _deploy();
        env.controller.setSystemDeviations(TARGET_SUB_DR, TARGET_VM_DR);
        vm.warp(TARGET_WINDOW_OPEN);

        (bool active, bool minting, uint256 budget, uint256 openedAt) = env.vault.sessionCapacity();
        assertFalse(active);
        assertTrue(minting);
        assertEq(env.vault.getTVL(), TARGET_TVL);
        assertEq(budget, TARGET_PREVIEW_BUDGET);
        assertEq(openedAt, TARGET_WINDOW_OPEN);
        assertEq(budget, env.vault.getTVL() * env.vault.maxDeploymentVelocityPerc() / WAD);
    }

    function testInactiveDirectionUsesStrictGreaterThanTargetDr() public {
        Env memory env = _deploy();
        vm.warp(TARGET_WINDOW_OPEN);

        env.controller.setSystemDeviations(TARGET_DR - 1, TARGET_VM_DR);
        (, bool below,,) = env.vault.sessionCapacity();
        assertFalse(below);

        env.controller.setSystemDeviations(TARGET_DR, TARGET_VM_DR);
        (, bool equal,,) = env.vault.sessionCapacity();
        assertFalse(equal);

        env.controller.setSystemDeviations(TARGET_DR + 1, TARGET_VM_DR);
        (, bool above,,) = env.vault.sessionCapacity();
        assertTrue(above);
    }

    function testActiveSessionReusesStoredStateUntilButNotAtExpiry() public {
        Env memory env = _deploy();
        uint64 openedAt = uint64(TARGET_WINDOW_OPEN);
        uint128 storedBudget = 29_251_188_032_403_425_541_687;
        env.vault.setSessionState(false, storedBudget, openedAt);
        env.controller.setSystemDeviations(TARGET_DR + 1, TARGET_VM_DR);

        uint256 expiry = uint256(openedAt) + env.vault.rebalanceFreqSec();
        vm.warp(expiry - 1);
        (bool beforeActive, bool beforeDirection, uint256 beforeBudget, uint256 beforeOpenedAt) =
            env.vault.sessionCapacity();
        assertTrue(beforeActive);
        assertFalse(beforeDirection);
        assertEq(beforeBudget, storedBudget);
        assertEq(beforeOpenedAt, openedAt);

        vm.warp(expiry);
        (bool atActive, bool atDirection, uint256 atBudget, uint256 atOpenedAt) = env.vault.sessionCapacity();
        assertFalse(atActive);
        assertTrue(atDirection);
        assertEq(atBudget, TARGET_PREVIEW_BUDGET);
        assertEq(atOpenedAt, expiry);
        _assertStoredSession(env.vault, false, storedBudget, openedAt);

        vm.warp(expiry + 1);
        (bool afterActive, bool afterDirection, uint256 afterBudget, uint256 afterOpenedAt) =
            env.vault.sessionCapacity();
        assertFalse(afterActive);
        assertTrue(afterDirection);
        assertEq(afterBudget, atBudget);
        assertEq(afterOpenedAt, expiry);
        _assertStoredSession(env.vault, false, storedBudget, openedAt);
    }

    function testDepositDoesNotUseOrConsumeSessionBudgetOrDirection() public {
        Env memory env = _deploy();
        vm.warp(TARGET_WINDOW_OPEN + 1);
        env.controller.setSystemDeviations(TARGET_DR + 1, TARGET_VM_DR);
        env.vault.setSessionState(false, 1, uint64(TARGET_WINDOW_OPEN));

        env.usd.mint(USER, 1e6);
        env.perp.mint(USER, 10_000_000_000);
        vm.startPrank(USER);
        env.usd.approve(address(env.vault), type(uint256).max);
        env.perp.approve(address(env.vault), type(uint256).max);
        uint256 notesMinted = env.vault.deposit(1e6, 10_000_000_000);
        vm.stopPrank();

        assertGt(notesMinted, 0);
        _assertStoredSession(env.vault, false, 1, uint64(TARGET_WINDOW_OPEN));
        (bool active, bool storedDirection, uint256 storedBudget, uint256 openedAt) = env.vault.sessionCapacity();
        assertTrue(active);
        assertFalse(storedDirection);
        assertEq(storedBudget, 1);
        assertEq(openedAt, TARGET_WINDOW_OPEN);
    }

    function testTinyPositiveDepositSucceedsWithoutSessionMinimum() public {
        Env memory env = _deploy();
        vm.warp(TARGET_WINDOW_OPEN);
        (uint256 quotedNotes, uint256 usdIn, uint256 perpIn) = env.vault.computeMintAmt(1, PERP_BALANCE);
        assertGt(quotedNotes, 0);
        assertEq(usdIn, 1);
        assertGt(perpIn, 0);
        env.usd.mint(USER, usdIn);
        env.perp.mint(USER, perpIn);
        vm.startPrank(USER);
        env.usd.approve(address(env.vault), usdIn);
        env.perp.approve(address(env.vault), perpIn);
        assertEq(env.vault.deposit(1, PERP_BALANCE), quotedNotes);
        vm.stopPrank();
    }

    function testDepositFailureRollsBackAssetsNotesAndSession() public {
        Env memory env = _deploy();
        vm.warp(TARGET_WINDOW_OPEN + 1);
        env.vault.setSessionState(true, 123, uint64(TARGET_WINDOW_OPEN));
        env.usd.mint(USER, 1e6);
        env.perp.mint(USER, 10_000_000_000);
        vm.prank(USER);
        env.usd.approve(address(env.vault), type(uint256).max);
        bytes32 beforeFingerprint = _fingerprint(env);

        vm.expectRevert();
        vm.prank(USER);
        env.vault.deposit(1e6, 10_000_000_000);
        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function _deploy() private returns (Env memory env) {
        env.usd = new MockERC20("USD Coin", "USDC", 6);
        env.perp = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        env.underlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        MockPriceOracle oracle = new MockPriceOracle(UNDERLYING_PRICE);
        env.controller = new MockUsdVaultController(address(oracle));
        env.controller.setPerpSrState(SR_SUPPLY, SR_RESERVE_VALUE, 0);

        UsdVaultSessionHarness implementation = new UsdVaultSessionHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(
                UsdVault.init,
                (
                    "cbBTC Senior USDC Keeper",
                    "cbBTC-Sr-USDC-Keeper",
                    address(env.usd),
                    address(env.perp),
                    address(env.underlying),
                    address(env.controller)
                )
            )
        );
        env.vault = UsdVaultSessionHarness(address(proxy));
        env.vault.mintNotes(SEED, NOTES_SUPPLY);
        env.usd.mint(address(env.vault), USD_BALANCE);
        env.perp.mint(address(env.vault), PERP_BALANCE);
        env.underlying.mint(address(env.vault), IDLE_UNDERLYING);
    }

    function _assertStoredSession(UsdVaultSessionHarness vault, bool direction, uint128 budget, uint64 openedAt)
        private
        view
    {
        assertEq(vault.sessionIsMintingPerp(), direction);
        assertEq(vault.sessionBudgetUsdVal(), budget);
        assertEq(vault.sessionOpenedAtSec(), openedAt);
    }

    function _fingerprint(Env memory env) private view returns (bytes32) {
        return keccak256(
            abi.encode(
                env.vault.totalSupply(),
                env.vault.balanceOf(USER),
                env.vault.usdBalance(),
                env.vault.perpSrBalance(),
                env.usd.balanceOf(USER),
                env.perp.balanceOf(USER),
                env.vault.sessionIsMintingPerp(),
                env.vault.sessionBudgetUsdVal(),
                env.vault.sessionOpenedAtSec()
            )
        );
    }
}
