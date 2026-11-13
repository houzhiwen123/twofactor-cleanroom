// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {UsdVault} from "../src/vault/UsdVault.sol";
import {IUsdVault} from "../src/interfaces/IUsdVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {MockUsdVaultController} from "./mocks/MockUsdVaultController.sol";

contract UsdVaultRebalanceHarness is UsdVault {
    function setSessionState(bool isMintingPerp, uint128 budgetUsdVal, uint64 openedAtSec) external {
        _setSessionState(isMintingPerp, budgetUsdVal, openedAtSec);
    }

    function setCapacityConfig(uint96 lower, uint96 upper, uint128 minUsdVal) external {
        _eqDRLower = lower;
        _eqDRUpper = upper;
        _minOpUsdVal = minUsdVal;
    }

    function validatedPlan() external view returns (RebalancePlan memory) {
        return _validatedRebalancePlan();
    }

    function validateAndCommit(uint256 consumedUsdVal) external {
        RebalancePlan memory plan = _validatedRebalancePlan();
        _commitRebalanceSession(plan, consumedUsdVal);
    }
}

contract UsdVaultRebalanceCapacityTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant TARGET_DR = 1_027_500_000_000_000_000;
    uint256 private constant TARGET_SYSTEM_RATIO = 2_847_475_019_000_000_000;
    uint256 private constant WINDOW_OPEN = 1_793_829_600;
    bytes4 private constant NO_OP = bytes4(keccak256("NoOp()"));
    bytes4 private constant OP_UNAVAILABLE = bytes4(keccak256("OpUnavailable(string)"));

    struct Env {
        UsdVaultRebalanceHarness vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockPriceOracle oracle;
        MockUsdVaultController controller;
    }

    function testDefaultCapacityConfigMatchesVersionLockedTarget() public {
        Env memory env = _deploy(80_248_101_897_110_000_000_000);
        IUsdVault.Range memory range = env.vault.eqDRRange();
        assertEq(range.lower, 1_022_000_000_000_000_000);
        assertEq(range.upper, 1_033_000_000_000_000_000);
        assertEq(env.vault.minOpUsdVal(), 50e18);
        assertEq(env.vault.activeRebalanceDelaySec(), 3_600);
    }

    function testMintingCapacityMatchesTargetAssetLimitedVectorExactly() public {
        Env memory env = _targetMintVector();
        (uint256 maxUnderlying, uint256 price, bool minting, uint256 currentDR, IUsdVault.SystemState memory state) =
            env.vault.rebalanceCapacity();

        assertEq(maxUnderlying, 4_651);
        assertEq(price, 80_248_101_897_110_000_000_000);
        assertTrue(minting);
        assertEq(currentDR, 1_052_430_305_854_682_822);
        assertEq(state.perpSr.totalSupply, 10_091_631_737_151);
        assertEq(state.perpSr.reserveValue, 126_885_687);
        assertEq(state.perpJr.reserveValue, 380_247_094);
    }

    function testMintingCapacityMatchesTargetSystemLimitedVectorExactly() public {
        Env memory env = _deploy(77_344_261_079_000_000_000_000);
        env.controller.setPerpSrState(9_574_802_087_802, 124_864_436, 0);
        env.controller.setPerpJrState(32_582_302_440_954, 375_339_481, 1_332_670_668_343_573_481);
        env.controller.setSystemDeviations(1_055_663_647_561_289_239, 0);
        env.usd.mint(address(env.vault), 3_728_960_649);

        (uint256 maxUnderlying,, bool minting,,) = env.vault.rebalanceCapacity();
        assertTrue(minting);
        assertEq(maxUnderlying, 3_422_518);
    }

    function testRedeemingCapacityUsesCeilingAndMatchesTargetExactly() public {
        Env memory env = _deploy(77_368_295_716_660_000_000_000);
        env.controller.setPerpSrState(9_916_265_965_245, 129_277_272, 5_300_939_518_587_613);
        env.controller.setPerpJrState(32_582_302_440_954, 375_427_335, 1_342_521_625_389_904_014);
        env.controller.setSystemDeviations(1_019_867_585_526_484_997, 0);
        env.perp.mint(address(env.vault), 9_886_455_001_392);

        (uint256 maxUnderlying,, bool minting,,) = env.vault.rebalanceCapacity();
        assertFalse(minting);
        assertEq(maxUnderlying, 960_289);
    }

    function testCapacityIsZeroInsideInclusiveEqualityRange() public {
        Env memory env = _deploy(77_698_759_540_950_000_000_000);
        env.controller.setPerpSrState(9_907_580_788_719, 128_614_693, 0);
        env.controller.setPerpJrState(32_582_302_440_954, 375_905_813, 1_342_146_060_401_571_922);
        env.controller.setSystemDeviations(1_026_428_101_402_202_294, 0);
        env.usd.mint(address(env.vault), 1_000_000_000);
        env.perp.mint(address(env.vault), 9_876_211_136_517);

        (uint256 maxUnderlying,,, uint256 currentDR,) = env.vault.rebalanceCapacity();
        assertEq(currentDR, 1_026_428_101_402_202_294);
        assertEq(maxUnderlying, 0);
    }

    function testNoOpPrecedesStoredDirectionCheck() public {
        Env memory env = _deploy(77_698_759_540_950_000_000_000);
        env.controller.setPerpSrState(1, 128_614_693, 0);
        env.controller.setPerpJrState(1, 375_905_813, 0);
        env.controller.setSystemDeviations(1_026_428_101_402_202_294, 0);
        env.vault.setSessionState(true, type(uint128).max, uint64(WINDOW_OPEN));
        vm.warp(WINDOW_OPEN);

        vm.expectRevert(NO_OP);
        env.vault.validatedPlan();
    }

    function testActiveSessionRejectsOppositeDirection() public {
        Env memory env = _systemLimitedMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        env.vault.setSessionState(false, type(uint128).max, uint64(WINDOW_OPEN));
        vm.warp(WINDOW_OPEN);

        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "direction"));
        env.vault.validatedPlan();
    }

    function testMinimumSizeMatchesObservedFailureVector() public {
        Env memory env = _targetMintVector();
        vm.warp(WINDOW_OPEN);

        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "min size"));
        env.vault.validatedPlan();
    }

    function testSessionBudgetIsInclusiveAndOneWeiLessClipsOneUnderlyingUnit() public {
        Env memory env = _targetMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        vm.warp(WINDOW_OPEN);
        (uint256 amount, uint256 price,,,) = env.vault.rebalanceCapacity();
        uint256 required = amount * price / 1e8;

        env.vault.setSessionState(true, uint128(required), uint64(WINDOW_OPEN));
        UsdVault.RebalancePlan memory exact = env.vault.validatedPlan();
        assertEq(exact.rebalanceUsdVal, required);
        assertEq(exact.sessionBudgetUsdVal, required);
        assertEq(exact.maxRebalanceUnderlying, amount);

        env.vault.setSessionState(true, uint128(required - 1), uint64(WINDOW_OPEN));
        UsdVault.RebalancePlan memory clipped = env.vault.validatedPlan();
        assertEq(clipped.maxRebalanceUnderlying, amount - 1);
        assertLt(clipped.rebalanceUsdVal, required);
    }

    function testZeroSessionBudgetRejectsWithNoCapacity() public {
        Env memory env = _targetMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        vm.warp(WINDOW_OPEN);
        env.vault.setSessionState(true, 0, uint64(WINDOW_OPEN));
        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "no capacity"));
        env.vault.validatedPlan();
    }

    function testNewSessionCommitInitializesThenSubtractsActualValue() public {
        Env memory env = _systemLimitedMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        env.usd.mint(address(env.vault), 100_000_000_000);
        vm.warp(WINDOW_OPEN);
        (,, uint256 previewBudget,) = _session(env.vault);
        uint256 consumed = 3_390_111_185e12;
        assertLt(consumed, previewBudget);

        env.vault.validateAndCommit(consumed);
        assertTrue(env.vault.sessionIsMintingPerp());
        assertEq(env.vault.sessionBudgetUsdVal(), previewBudget - consumed);
        assertEq(env.vault.sessionOpenedAtSec(), WINDOW_OPEN);
    }

    function testActiveSessionCommitOnlyDecrementsBudget() public {
        Env memory env = _targetMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        vm.warp(WINDOW_OPEN);
        uint128 budget = 10_000e18;
        uint256 consumed = 375_664_573e12;
        env.vault.setSessionState(true, budget, uint64(WINDOW_OPEN));

        env.vault.validateAndCommit(consumed);
        assertTrue(env.vault.sessionIsMintingPerp());
        assertEq(env.vault.sessionBudgetUsdVal(), uint256(budget) - consumed);
        assertEq(env.vault.sessionOpenedAtSec(), WINDOW_OPEN);
    }

    function testCommitMayUseExactBudgetButOneWeiMoreIsAtomic() public {
        Env memory env = _targetMintVector();
        env.vault.setCapacityConfig(1_022_000_000_000_000_000, 1_033_000_000_000_000_000, 0);
        vm.warp(WINDOW_OPEN);
        (uint256 amount, uint256 price,,,) = env.vault.rebalanceCapacity();
        uint128 required = uint128(amount * price / 1e8);

        env.vault.setSessionState(true, required, uint64(WINDOW_OPEN));
        env.vault.validateAndCommit(required);
        assertEq(env.vault.sessionBudgetUsdVal(), 0);

        env.vault.setSessionState(true, required, uint64(WINDOW_OPEN));
        bytes32 beforeState = _sessionFingerprint(env.vault);
        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "capacity"));
        env.vault.validateAndCommit(uint256(required) + 1);
        assertEq(_sessionFingerprint(env.vault), beforeState);
    }

    function _targetMintVector() private returns (Env memory env) {
        env = _deploy(80_248_101_897_110_000_000_000);
        env.controller.setPerpSrState(10_091_631_737_151, 126_885_687, 234_991_043_552_453);
        env.controller.setPerpJrState(32_509_969_817_791, 380_247_094, 1_333_614_305_018_199_560);
        env.controller.setSystemDeviations(1_052_430_305_854_682_822, 1_000_210_729_013_702_352);
        env.usd.mint(address(env.vault), 3_732_531);
        env.perp.mint(address(env.vault), 9_913_086_977_476);
        env.underlying.mint(address(env.vault), 61_287);
    }

    function _systemLimitedMintVector() private returns (Env memory env) {
        env = _deploy(77_344_261_079_000_000_000_000);
        env.controller.setPerpSrState(9_574_802_087_802, 124_864_436, 0);
        env.controller.setPerpJrState(32_582_302_440_954, 375_339_481, 1_332_670_668_343_573_481);
        env.controller.setSystemDeviations(1_055_663_647_561_289_239, 0);
        env.usd.mint(address(env.vault), 3_728_960_649);
    }

    function _deploy(uint256 price) private returns (Env memory env) {
        env.usd = new MockERC20("USD Coin", "USDC", 6);
        env.perp = new MockERC20("cbBTC Senior", "cbBTC-SR", 8);
        env.underlying = new MockERC20("Wrapped BTC", "cbBTC", 8);
        env.oracle = new MockPriceOracle(price);
        env.controller = new MockUsdVaultController(address(env.oracle));
        env.controller.setTargetSystemRatio(TARGET_SYSTEM_RATIO);

        UsdVaultRebalanceHarness implementation = new UsdVaultRebalanceHarness();
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
        env.vault = UsdVaultRebalanceHarness(address(proxy));
    }

    function _session(UsdVaultRebalanceHarness vault)
        private
        view
        returns (bool active, bool direction, uint256 budget, uint256 openedAt)
    {
        return vault.sessionCapacity();
    }

    function _sessionFingerprint(UsdVaultRebalanceHarness vault) private view returns (bytes32) {
        return
            keccak256(abi.encode(vault.sessionIsMintingPerp(), vault.sessionBudgetUsdVal(), vault.sessionOpenedAtSec()));
    }
}
