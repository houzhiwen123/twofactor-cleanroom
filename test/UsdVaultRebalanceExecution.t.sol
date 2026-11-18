// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {UsdVault} from "../src/vault/UsdVault.sol";

error Phase5BDependencyFailure(uint8 dependency);

contract Phase5BToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != from) _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}

contract Phase5BOracle {
    uint256 public price;
    uint8 public failure;
    uint256 public cacheCalls;
    uint256 public resetCalls;

    constructor(uint256 price_) {
        price = price_;
    }

    function setFailure(uint8 failure_) external {
        failure = failure_;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function getValidPrice() external view returns (uint256) {
        if (failure == 1) revert Phase5BDependencyFailure(1);
        return price;
    }

    function cachePrice() external {
        ++cacheCalls;
        if (failure == 2) revert Phase5BDependencyFailure(2);
    }

    function resetCache() external {
        ++resetCalls;
        if (failure == 3) revert Phase5BDependencyFailure(3);
    }
}

contract Phase5BDex {
    address public immutable usd;
    address public immutable underlying;
    uint256 public referencePriceValue;
    bool public healthy = true;
    uint256 public fillSell;
    uint256 public fillBuy;
    uint256 public tradeBuy;
    bool public failTrade;
    bool public failMaxFillable;
    uint256 public tradeCalls;

    address public lastSellToken;
    address public lastBuyToken;
    uint256 public lastSellAmount;

    constructor(address usd_, address underlying_, uint256 referencePrice_) {
        usd = usd_;
        underlying = underlying_;
        referencePriceValue = referencePrice_;
    }

    function configureFill(uint256 sellAmount, uint256 buyAmount, uint256 tradeBuyAmount) external {
        fillSell = sellAmount;
        fillBuy = buyAmount;
        tradeBuy = tradeBuyAmount;
    }

    function setHealthy(bool healthy_) external {
        healthy = healthy_;
    }

    function setReferencePrice(uint256 referencePrice_) external {
        referencePriceValue = referencePrice_;
    }

    function setFailTrade(bool failTrade_) external {
        failTrade = failTrade_;
    }

    function setFailMaxFillable(bool failMaxFillable_) external {
        failMaxFillable = failMaxFillable_;
    }

    function isHealthy() external view returns (bool) {
        return healthy;
    }

    function referencePrice(address, address) external view returns (uint256) {
        return referencePriceValue;
    }

    function quote(address sellToken, address, uint256 sellAmount) public view returns (uint256) {
        if (sellToken == usd) return sellAmount * 1e20 / referencePriceValue;
        return sellAmount * referencePriceValue / 1e20;
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmount, uint256)
        external
        view
        returns (uint256 sellAmount, uint256 buyAmount)
    {
        if (failMaxFillable) revert Phase5BDependencyFailure(8);
        sellAmount = fillSell == 0 || fillSell > maxSellAmount ? maxSellAmount : fillSell;
        buyAmount = fillBuy == 0 ? quote(sellToken, buyToken, sellAmount) : fillBuy;
    }

    function trade(address sellToken, address buyToken, uint256 sellAmount) external returns (uint256 buyAmount) {
        ++tradeCalls;
        lastSellToken = sellToken;
        lastBuyToken = buyToken;
        lastSellAmount = sellAmount;
        IERC20(sellToken).transferFrom(msg.sender, address(this), sellAmount);
        if (failTrade) revert Phase5BDependencyFailure(4);
        buyAmount = tradeBuy == 0 ? quote(sellToken, buyToken, sellAmount) : tradeBuy;
        IERC20(buyToken).transfer(msg.sender, buyAmount);
    }
}

contract Phase5BController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
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

    address public immutable underlyingOracle;
    Phase5BToken public immutable underlying;
    Phase5BToken public immutable perp;
    address public redeemReserve;
    uint256 public targetSystemRatio = 2_847_475_019_000_000_000;

    SystemState private _state;
    uint256 private _subDR;
    uint256 private _vmDR;
    uint256 public mintGross;
    uint256 public mintNet;
    uint256 public redeemGross;
    uint256 public mintFeePerc;
    uint256 public redeemFeePerc;
    uint8 public failure;
    uint256 public lastMintUnderlying;
    uint256 public lastRedeemPerp;

    constructor(address oracle_, Phase5BToken underlying_, Phase5BToken perp_, address redeemReserve_) {
        underlyingOracle = oracle_;
        underlying = underlying_;
        perp = perp_;
        redeemReserve = redeemReserve_;
    }

    function setPerpSrState(uint256 supply, uint256 reserveValue, uint256 vm) external {
        _state.perpSr = PerpState({totalSupply: supply, reserveValue: reserveValue, vm: vm});
    }

    function setPerpJrState(uint256 supply, uint256 reserveValue, uint256 vm) external {
        _state.perpJr = PerpState({totalSupply: supply, reserveValue: reserveValue, vm: vm});
    }

    function setSystemDeviations(uint256 subDR, uint256 vmDR) external {
        _subDR = subDR;
        _vmDR = vmDR;
    }

    function configureExecution(uint256 mintGross_, uint256 mintNet_, uint256 redeemGross_) external {
        mintGross = mintGross_;
        mintNet = mintNet_;
        redeemGross = redeemGross_;
    }

    function configureFees(uint256 mintFeePerc_, uint256 redeemFeePerc_) external {
        mintFeePerc = mintFeePerc_;
        redeemFeePerc = redeemFeePerc_;
    }

    function setFailure(uint8 failure_) external {
        failure = failure_;
    }

    function systemReserveState() external view returns (SystemState memory state) {
        if (failure == 1) revert Phase5BDependencyFailure(5);
        return _state;
    }

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR) {
        return (_subDR, _vmDR);
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory srFee, FeePerc memory jrFee)
    {
        require(jrUnderlying == 0, "jr input");
        lastMintUnderlying = srUnderlying;
        underlying.transferFrom(msg.sender, address(perp), srUnderlying);
        if (failure == 2) revert Phase5BDependencyFailure(6);
        perp.mint(address(this), mintGross);
        perp.transfer(msg.sender, mintNet);
        _state.perpSr.totalSupply += mintGross;
        _state.perpSr.reserveValue += srUnderlying;
        srFee.totalFeePerc = mintFeePerc;
        return (mintNet, 0, srFee, jrFee);
    }

    function flashRedeem2(uint256 srPerp, uint256 jrPerp, uint256)
        external
        returns (uint256 underlyingAmt, FeePerc memory srFee, FeePerc memory jrFee)
    {
        require(jrPerp == 0, "jr input");
        lastRedeemPerp = srPerp;
        perp.burnFrom(msg.sender, srPerp);
        if (failure == 3) revert Phase5BDependencyFailure(7);
        underlying.transferFrom(redeemReserve, address(this), redeemGross);
        underlying.transfer(msg.sender, redeemGross);
        _state.perpSr.totalSupply -= srPerp;
        _state.perpSr.reserveValue -= redeemGross;
        srFee.totalFeePerc = redeemFeePerc;
        return (redeemGross, srFee, jrFee);
    }
}

contract UsdVaultRebalanceExecutionTest is Test {
    uint256 private constant MINT_PRICE = 77_759_215_172_770_000_000_000;
    uint256 private constant REDEEM_PRICE = 77_368_295_716_660_000_000_000;
    uint256 private constant MINT_OPENED_AT = 1_793_772_000;
    uint256 private constant REDEEM_OPENED_AT = 1_793_743_200;
    uint256 private constant MINT_BUDGET = 33_016_963_790_403_425_541_687;
    uint256 private constant REDEEM_BUDGET = 33_016_915_546_003_499_111_958;
    uint256 private constant MIN_BUY_BPS = 9_985;
    uint256 private constant BPS = 10_000;

    address private constant INVENTORY = address(0x1A2);
    address private constant REDEEM_RESERVE = address(0xB0B);
    address private constant OTHER_HOLDER = address(0xC0FFEE);
    address private constant RANDOM = address(0xBEEF);

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant REBALANCE_TOPIC = keccak256("Rebalance(uint256,uint256,uint256,bool)");

    struct Env {
        UsdVault vault;
        Phase5BToken usd;
        Phase5BToken perp;
        Phase5BToken underlying;
        Phase5BOracle usdOracle;
        Phase5BOracle underlyingOracle;
        Phase5BController controller;
        Phase5BDex dex;
    }

    struct ExpectedTransfer {
        address token;
        address from;
        address to;
        uint256 amount;
    }

    function testInventoryMintMatchesNaturalTargetVaultLegExactly() public {
        Env memory env = _deployMintVector();
        vm.recordLogs();
        vm.prank(INVENTORY);
        env.vault.swap(address(env.underlying), address(env.usd), 4_316_589, 3_390_111_185);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertMintState(env);
        _assertMintFlowOrder(env, logs);
        _assertMintRebalanceEvent(logs, address(env.vault));
    }

    function testInventoryRedeemMatchesNaturalTargetVaultLegExactly() public {
        Env memory env = _deployRedeemVector();
        vm.recordLogs();
        vm.prank(INVENTORY);
        env.vault.swap(address(env.usd), address(env.underlying), 731_851_567, 955_487);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertRedeemState(env);
        _assertRedeemFlowOrder(env, logs);
        _assertRedeemRebalanceEvent(logs, address(env.vault));
    }

    function testSwapRejectsUnauthorizedCallerWithExactSelector() public {
        Env memory env = _deployMintVector();
        bytes32 beforeFingerprint = _fingerprint(env);
        vm.prank(RANDOM);
        vm.expectRevert(UsdVault.UnauthorizedCall.selector);
        env.vault.swap(address(env.underlying), address(env.usd), 4_316_589, 3_390_111_185);
        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function testInventoryMintRejectsOracleDeviatingPriceAtomically() public {
        Env memory env = _deployMintVector();
        bytes32 beforeFingerprint = _fingerprint(env);

        vm.prank(INVENTORY);
        vm.expectRevert(UsdVault.SlippageTooHigh.selector);
        env.vault.swap(address(env.underlying), address(env.usd), 4_316_589, 33_901_111_850);

        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function testInventoryRedeemRejectsOracleDeviatingPriceAtomically() public {
        Env memory env = _deployRedeemVector();
        bytes32 beforeFingerprint = _fingerprint(env);

        vm.prank(INVENTORY);
        vm.expectRevert(UsdVault.SlippageTooHigh.selector);
        env.vault.swap(address(env.usd), address(env.underlying), 73_185_156, 955_487);

        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function testOwnerCanRevokeAndRotateInventorySwapper() public {
        Env memory env = _deployMintVector();
        env.vault.updateSwapper(INVENTORY, false);
        assertFalse(env.vault.isSwapper(INVENTORY));

        vm.prank(INVENTORY);
        vm.expectRevert(UsdVault.UnauthorizedCall.selector);
        env.vault.swap(address(env.underlying), address(env.usd), 4_316_589, 3_390_111_185);

        env.vault.updateSwapper(RANDOM, true);
        assertTrue(env.vault.isSwapper(RANDOM));
    }

    function testSwapperRotationRejectsUnauthorizedAndZeroAddress() public {
        Env memory env = _deployMintVector();

        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", RANDOM));
        env.vault.updateSwapper(RANDOM, true);
        assertFalse(env.vault.isSwapper(RANDOM));

        vm.expectRevert(UsdVault.InvalidParamDefn.selector);
        env.vault.updateSwapper(address(0), true);
        assertFalse(env.vault.isSwapper(address(0)));
    }

    function testDirectRebalanceDelayBoundary3599And3600() public {
        Env memory env = _deployMintVector();
        env.dex.configureFill(1_000, 1, 1);
        env.underlying.mint(address(env.dex), 1);

        uint256 snapshot = vm.snapshotState();
        vm.warp(MINT_OPENED_AT + 3_599);
        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "active delayed"));
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        vm.warp(MINT_OPENED_AT + 3_600);
        vm.prank(RANDOM);
        vm.expectRevert(UsdVault.SlippageTooHigh.selector);
        env.vault.rebalance();
    }

    function testDirectRebalanceDelayBoundary3601AlsoPassesGate() public {
        Env memory env = _deployMintVector();
        env.dex.configureFill(1_000, 1, 1);
        env.underlying.mint(address(env.dex), 1);
        vm.warp(MINT_OPENED_AT + 3_601);
        vm.prank(RANDOM);
        vm.expectRevert(UsdVault.SlippageTooHigh.selector);
        env.vault.rebalance();
    }

    function testDirectMintRebalanceExecutesAtomically() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 usdSell = capacity * MINT_PRICE / 1e20;
        env.dex.configureFill(usdSell, capacity, capacity);
        env.underlying.mint(address(env.dex), capacity);

        vm.warp(MINT_OPENED_AT + 3_600);
        vm.prank(RANDOM);
        env.vault.rebalance();

        assertEq(env.dex.lastSellToken(), address(env.usd));
        assertEq(env.dex.lastBuyToken(), address(env.underlying));
        assertEq(env.controller.lastMintUnderlying(), capacity);
        assertEq(MINT_BUDGET - env.vault.sessionBudgetUsdVal(), usdSell * 1e12);
        assertEq(env.underlyingOracle.cacheCalls(), 1);
        assertEq(env.underlyingOracle.resetCalls(), 1);
    }

    function testDirectMintPartialFillUsesTargetProportionalCeilMinimum() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 maxUsdSell = capacity * MINT_PRICE / 1e20;
        uint256 fullMinBuy = Math.mulDiv(maxUsdSell, MIN_BUY_BPS * 1e20, MINT_PRICE * BPS);
        uint256 partialSell = maxUsdSell / 3;
        uint256 partialMinBuy = Math.mulDiv(fullMinBuy, partialSell, maxUsdSell, Math.Rounding.Ceil);
        env.dex.configureFill(partialSell, 0, partialMinBuy);
        env.underlying.mint(address(env.dex), partialMinBuy);

        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertEq(env.dex.lastSellAmount(), partialSell);
        assertEq(env.controller.lastMintUnderlying(), partialMinBuy);
    }

    function testDirectMintPartialFillOneBelowMinimumRollsBack() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 maxUsdSell = capacity * MINT_PRICE / 1e20;
        uint256 fullMinBuy = Math.mulDiv(maxUsdSell, MIN_BUY_BPS * 1e20, MINT_PRICE * BPS);
        uint256 partialSell = maxUsdSell / 3;
        uint256 partialMinBuy = Math.mulDiv(fullMinBuy, partialSell, maxUsdSell, Math.Rounding.Ceil);
        env.dex.configureFill(partialSell, 0, partialMinBuy - 1);
        env.underlying.mint(address(env.dex), partialMinBuy - 1);

        bytes32 beforeFingerprint = _fingerprint(env);
        vm.warp(MINT_OPENED_AT + 3_600);
        vm.expectRevert(UsdVault.SlippageTooHigh.selector);
        env.vault.rebalance();
        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function testDirectRedeemRebalanceExecutesAtomically() public {
        Env memory env = _deployRedeemVector();
        uint256 usdBuy = 960_289 * REDEEM_PRICE / 1e20;
        env.dex.configureFill(960_289, usdBuy, usdBuy);
        env.usd.mint(address(env.dex), usdBuy);

        vm.warp(REDEEM_OPENED_AT + 3_600);
        vm.prank(RANDOM);
        env.vault.rebalance();

        assertEq(env.dex.lastSellToken(), address(env.underlying));
        assertEq(env.dex.lastBuyToken(), address(env.usd));
        assertEq(env.controller.lastRedeemPerp(), 73_659_360_073);
        assertEq(REDEEM_BUDGET - env.vault.sessionBudgetUsdVal(), 742_959_233_254_557_147_400);
        assertEq(env.underlyingOracle.cacheCalls(), 1);
        assertEq(env.underlyingOracle.resetCalls(), 1);
    }

    function testDirectRedeemQuotesBeforeControllerExecution() public {
        Env memory env = _deployRedeemVector();
        env.dex.setFailMaxFillable(true);
        env.controller.setFailure(3);
        _expectAtomicFailure(env, 8, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 8));
        assertEq(env.controller.lastRedeemPerp(), 0);
    }

    function testUpkeepIsPermissionlessAndBalancedStateReturnsNoOp() public {
        Env memory env = _deployMintVector();
        env.controller.setPerpSrState(9_574_802_087_802, 124_198_109, 0);
        env.controller.setPerpJrState(0, 376_005_808, 0);
        env.controller.setSystemDeviations(1_027_500_000_000_000_000, 1e18);
        vm.prank(RANDOM);
        vm.expectRevert(UsdVault.NoOp.selector);
        env.vault.upkeep();
    }

    function testUpkeepRedeemSettlesIdleUnderlyingWithoutSessionCommit() public {
        Env memory env = _deployRedeemVector();
        uint256 maxSell = env.underlying.balanceOf(address(env.vault));
        uint256 fullMinBuy = Math.mulDiv(maxSell, REDEEM_PRICE * MIN_BUY_BPS, 1e20 * BPS, Math.Rounding.Ceil);
        uint256 partialSell = maxSell / 2;
        uint256 partialMinBuy = Math.mulDiv(fullMinBuy, partialSell, maxSell, Math.Rounding.Ceil);
        env.dex.configureFill(partialSell, 0, partialMinBuy);
        env.usd.mint(address(env.dex), partialMinBuy);
        uint256 budgetBefore = env.vault.sessionBudgetUsdVal();
        uint256 openedAtBefore = env.vault.sessionOpenedAtSec();

        vm.recordLogs();
        vm.prank(RANDOM);
        env.vault.upkeep();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(env.dex.lastSellAmount(), partialSell);
        assertEq(env.underlying.balanceOf(address(env.vault)), maxSell - partialSell);
        assertEq(env.vault.sessionBudgetUsdVal(), budgetBefore);
        assertEq(env.vault.sessionOpenedAtSec(), openedAtBefore);
        assertFalse(env.vault.sessionIsMintingPerp());
        assertEq(env.controller.lastRedeemPerp(), 0);
        assertEq(env.underlyingOracle.cacheCalls(), 1);
        assertEq(env.underlyingOracle.resetCalls(), 0);
        assertFalse(_hasRebalance(logs, address(env.vault)));
    }

    function testUpkeepRedeemDexFailureBubblesAndRollsBack() public {
        Env memory env = _deployRedeemVector();
        uint256 maxSell = env.underlying.balanceOf(address(env.vault));
        uint256 fullMinBuy = Math.mulDiv(maxSell, REDEEM_PRICE * MIN_BUY_BPS, 1e20 * BPS, Math.Rounding.Ceil);
        env.dex.configureFill(maxSell, 0, fullMinBuy);
        env.dex.setFailTrade(true);
        env.usd.mint(address(env.dex), fullMinBuy);
        bytes32 beforeFingerprint = _fingerprint(env);

        vm.prank(RANDOM);
        vm.expectRevert(abi.encodeWithSelector(Phase5BDependencyFailure.selector, 4));
        env.vault.upkeep();
        assertEq(_fingerprint(env), beforeFingerprint);
        assertEq(env.underlyingOracle.cacheCalls(), 0);
    }

    function testOracleCacheFailureBubblesAndRollsBack() public {
        Env memory env = _deployMintVector();
        env.underlyingOracle.setFailure(2);
        _expectAtomicFailure(env, 2, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 2));
    }

    function testDexTradeFailureBubblesAndRollsBack() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 usdSell = capacity * MINT_PRICE / 1e20;
        env.dex.configureFill(usdSell, capacity, capacity);
        env.dex.setFailTrade(true);
        env.underlying.mint(address(env.dex), capacity);
        _expectAtomicFailure(env, 4, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 4));
    }

    function testControllerStateFailureBubblesAndRollsBack() public {
        Env memory env = _deployMintVector();
        env.controller.setFailure(1);
        _expectAtomicFailure(env, 5, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 5));
    }

    function testControllerExecutionFailureAfterDexTransferRollsBack() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 usdSell = capacity * MINT_PRICE / 1e20;
        env.dex.configureFill(usdSell, capacity, capacity);
        env.underlying.mint(address(env.dex), capacity);
        env.controller.setFailure(2);
        _expectAtomicFailure(env, 6, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 6));
    }

    function testOracleResetFailureAfterExecutionRollsEverythingBack() public {
        Env memory env = _deployMintVector();
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 usdSell = capacity * MINT_PRICE / 1e20;
        env.dex.configureFill(usdSell, capacity, capacity);
        env.underlying.mint(address(env.dex), capacity);
        env.underlyingOracle.setFailure(3);
        _expectAtomicFailure(env, 3, abi.encodeWithSelector(Phase5BDependencyFailure.selector, 3));
    }

    function testUsdPegDeviationBoundariesMatchTarget() public {
        Env memory env = _deployMintVector();
        _configureDirectMint(env);
        assertEq(env.vault.maxUsdDeviationPerc(), 5e15);
        uint256 snapshot = vm.snapshotState();

        env.usdOracle.setPrice(1e18 + 5e15);
        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.usdOracle.setPrice(1e18 + 5e15 + 1);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "usd peg"));
        assertTrue(vm.revertToState(snapshot));

        env.usdOracle.setPrice(1e18 - 5e15);
        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.usdOracle.setPrice(1e18 - 5e15 - 1);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "usd peg"));
    }

    function testUnderlyingOracleDeviationBoundariesMatchTarget() public {
        Env memory env = _deployMintVector();
        assertEq(env.vault.maxUnderlyingDeviationPerc(), 5e16);
        uint256 snapshot = vm.snapshotState();
        uint256 upper = MINT_PRICE * (1e18 + 5e16) / 1e18;
        uint256 lower = MINT_PRICE * (1e18 - 5e16) / 1e18;

        env.dex.setReferencePrice(upper);
        _configureDirectMint(env);
        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.dex.setReferencePrice(upper + 1);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "oracle divergence"));
        assertTrue(vm.revertToState(snapshot));

        env.dex.setReferencePrice(lower);
        _configureDirectMint(env);
        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.dex.setReferencePrice(lower - 1);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "oracle divergence"));
    }

    function testFlashMintFeeBoundaryMatchesTargetAndRollsBack() public {
        Env memory env = _deployMintVector();
        _configureDirectMint(env);
        assertEq(env.vault.maxFlashMintFeePerc(), 5e15);
        uint256 snapshot = vm.snapshotState();

        env.controller.configureFees(5e15, 0);
        vm.warp(MINT_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.controller.configureFees(5e15 + 1, 0);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "flash fee"));
    }

    function testFlashRedeemFeeBoundaryMatchesTargetAndRollsBack() public {
        Env memory env = _deployRedeemVector();
        _configureDirectRedeem(env);
        assertEq(env.vault.maxFlashRedeemFeePerc(), 5e15);
        uint256 snapshot = vm.snapshotState();

        env.controller.configureFees(0, 5e15);
        vm.warp(REDEEM_OPENED_AT + 3_600);
        env.vault.rebalance();
        assertTrue(vm.revertToState(snapshot));

        env.controller.configureFees(0, 5e15 + 1);
        _expectAtomicFailure(env, 1, abi.encodeWithSelector(UsdVault.OpUnavailable.selector, "flash fee"));
    }

    function _deployMintVector() private returns (Env memory env) {
        env = _deploy(MINT_PRICE);
        env.controller.setPerpSrState(9_574_802_087_802, 124_198_109, 0);
        env.controller.setPerpJrState(0, 376_005_808, 0);
        env.controller.setSystemDeviations(1_063_211_455_382_090_274, 1e18);
        env.controller.configureExecution(332_778_700_917, 331_220_012_568, 0);

        env.usd.mint(address(env.vault), 3_728_960_649);
        env.underlying.mint(address(env.vault), 61_287);
        env.perp.mint(address(env.vault), 9_544_991_123_949);
        env.perp.mint(OTHER_HOLDER, 29_810_963_853);
        env.underlying.mint(INVENTORY, 4_316_589);
        vm.prank(INVENTORY);
        env.underlying.approve(address(env.vault), type(uint256).max);
        _setSessionState(env.vault, true, uint128(MINT_BUDGET), uint64(MINT_OPENED_AT));
        vm.warp(MINT_OPENED_AT + 17);
    }

    function _deployRedeemVector() private returns (Env memory env) {
        env = _deploy(REDEEM_PRICE);
        env.controller.setPerpSrState(9_916_265_965_245, 129_277_272, 0);
        env.controller.setPerpJrState(0, 375_427_335, 0);
        env.controller.setSystemDeviations(1_019_867_585_526_484_997, 1e18);
        env.controller.configureExecution(0, 0, 960_289);

        env.usd.mint(address(env.vault), 302_318_628);
        env.underlying.mint(address(env.vault), 38_782);
        env.perp.mint(address(env.vault), 9_886_455_001_392);
        env.perp.mint(OTHER_HOLDER, 29_810_963_853);
        env.underlying.mint(REDEEM_RESERVE, 960_289);
        vm.prank(REDEEM_RESERVE);
        env.underlying.approve(address(env.controller), type(uint256).max);
        env.usd.mint(INVENTORY, 731_851_567);
        vm.prank(INVENTORY);
        env.usd.approve(address(env.vault), type(uint256).max);
        _setSessionState(env.vault, false, uint128(REDEEM_BUDGET), uint64(REDEEM_OPENED_AT));
        vm.warp(REDEEM_OPENED_AT + 7_215);
    }

    function _deploy(uint256 price) private returns (Env memory env) {
        env.usd = new Phase5BToken("USD", "USD", 6);
        env.perp = new Phase5BToken("Perp SR", "PSR", 8);
        env.underlying = new Phase5BToken("Underlying", "UND", 8);
        env.usdOracle = new Phase5BOracle(1e18);
        env.underlyingOracle = new Phase5BOracle(price);
        env.controller = new Phase5BController(address(env.underlyingOracle), env.underlying, env.perp, REDEEM_RESERVE);
        env.dex = new Phase5BDex(address(env.usd), address(env.underlying), price);

        UsdVault implementation = new UsdVault();
        bytes memory initData = abi.encodeCall(
            UsdVault.init,
            (
                "USD Senior Vault",
                "USD-SR",
                address(env.usd),
                address(env.perp),
                address(env.underlying),
                address(env.controller)
            )
        );
        env.vault = UsdVault(address(new ERC1967Proxy(address(implementation), initData)));
        _setExecutionDependencies(env);
    }

    function _expectAtomicFailure(Env memory env, uint8, bytes memory expectedRevert) private {
        bytes32 beforeFingerprint = _fingerprint(env);
        uint256 openedAt = env.vault.sessionOpenedAtSec();
        vm.warp(openedAt + 3_600);
        vm.prank(RANDOM);
        vm.expectRevert(expectedRevert);
        env.vault.rebalance();
        assertEq(_fingerprint(env), beforeFingerprint);
    }

    function _configureDirectMint(Env memory env) private {
        (uint256 capacity,,,,) = env.vault.rebalanceCapacity();
        uint256 usdSell = capacity * env.dex.referencePriceValue() / 1e20;
        env.dex.configureFill(usdSell, capacity, capacity);
        env.underlying.mint(address(env.dex), capacity);
    }

    function _configureDirectRedeem(Env memory env) private {
        uint256 usdBuy = 960_289 * env.dex.referencePriceValue() / 1e20;
        env.dex.configureFill(960_289, usdBuy, usdBuy);
        env.usd.mint(address(env.dex), usdBuy);
    }

    /// @dev Local-only fixture setup for the version-locked packed session slot.
    function _setSessionState(UsdVault vault, bool minting, uint128 budget, uint64 openedAt) private {
        bytes32 slot = bytes32(uint256(4));
        uint256 current = uint256(vm.load(address(vault), slot));
        uint256 lowerFieldsMask = (uint256(1) << 200) - 1;
        uint256 packed = uint256(budget) | (uint256(openedAt) << 128) | (uint256(minting ? 1 : 0) << 192);
        vm.store(address(vault), slot, bytes32((current & ~lowerFieldsMask) | packed));
    }

    /// @dev Local-only fixture setup for phase-5B appended dependency slots.
    function _setExecutionDependencies(Env memory env) private {
        bytes32 packedSlot = bytes32(uint256(7));
        uint256 current = uint256(vm.load(address(env.vault), packedSlot));
        uint256 low96Mask = (uint256(1) << 96) - 1;
        vm.store(
            address(env.vault), packedSlot, bytes32((current & low96Mask) | (uint256(uint160(address(env.dex))) << 96))
        );
        vm.store(address(env.vault), bytes32(uint256(8)), bytes32(uint256(uint160(address(env.usdOracle)))));
        bytes32 swapperSlot = keccak256(abi.encode(INVENTORY, uint256(9)));
        vm.store(address(env.vault), swapperSlot, bytes32(uint256(1)));
    }

    function _fingerprint(Env memory env) private view returns (bytes32) {
        bytes32 assetFingerprint = keccak256(
            abi.encode(
                env.usd.balanceOf(address(env.vault)),
                env.perp.balanceOf(address(env.vault)),
                env.underlying.balanceOf(address(env.vault)),
                env.usd.balanceOf(address(env.dex)),
                env.underlying.balanceOf(address(env.dex))
            )
        );
        bytes32 stateFingerprint = keccak256(
            abi.encode(
                env.perp.balanceOf(address(env.controller)),
                env.perp.totalSupply(),
                env.vault.sessionBudgetUsdVal(),
                env.vault.sessionOpenedAtSec(),
                env.vault.sessionIsMintingPerp()
            )
        );
        return keccak256(abi.encode(assetFingerprint, stateFingerprint));
    }

    function _assertMintFlowOrder(Env memory env, Vm.Log[] memory logs) private pure {
        uint256 cursor;
        ExpectedTransfer memory expected =
            ExpectedTransfer(address(env.underlying), INVENTORY, address(env.vault), 4_316_589);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.underlying), address(env.vault), address(env.perp), 4_316_589);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.perp), address(0), address(env.controller), 332_778_700_917);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.perp), address(env.controller), address(env.vault), 331_220_012_568);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.usd), address(env.vault), INVENTORY, 3_390_111_185);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        assertLt(cursor - 1, _findRebalance(logs, address(env.vault)));
    }

    function _assertMintState(Env memory env) private view {
        assertEq(env.underlying.balanceOf(address(env.vault)), 61_287);
        assertEq(env.usd.balanceOf(address(env.vault)), 338_849_464);
        assertEq(env.perp.balanceOf(address(env.vault)), 9_876_211_136_517);
        assertEq(env.perp.totalSupply(), 9_907_580_788_719);
        assertEq(env.perp.balanceOf(address(env.controller)), 1_558_688_349);
        assertEq(env.controller.lastMintUnderlying(), 4_316_589);
        assertEq(env.vault.sessionBudgetUsdVal(), 29_626_852_605_403_425_541_687);
    }

    function _assertRedeemState(Env memory env) private view {
        assertEq(env.usd.balanceOf(address(env.vault)), 1_034_170_195);
        assertEq(env.underlying.balanceOf(address(env.vault)), 43_584);
        assertEq(env.perp.balanceOf(address(env.vault)), 9_812_795_641_319);
        assertEq(env.perp.totalSupply(), 9_842_606_605_172);
        assertEq(env.controller.lastRedeemPerp(), 73_659_360_073);
        assertEq(env.vault.sessionBudgetUsdVal(), 32_273_956_312_748_941_964_558);
    }

    function _assertMintRebalanceEvent(Vm.Log[] memory logs, address vault) private pure {
        _assertRebalance(logs, vault, 1_063_211_455_382_090_274, MINT_PRICE, 3_390_111_185e12, true);
    }

    function _assertRedeemRebalanceEvent(Vm.Log[] memory logs, address vault) private pure {
        _assertRebalance(logs, vault, 1_019_867_585_526_484_997, REDEEM_PRICE, 742_959_233_254_557_147_400, false);
    }

    function _assertRedeemFlowOrder(Env memory env, Vm.Log[] memory logs) private pure {
        uint256 cursor;
        ExpectedTransfer memory expected =
            ExpectedTransfer(address(env.usd), INVENTORY, address(env.vault), 731_851_567);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.perp), address(env.vault), address(0), 73_659_360_073);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.underlying), REDEEM_RESERVE, address(env.controller), 960_289);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.underlying), address(env.controller), address(env.vault), 960_289);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        expected = ExpectedTransfer(address(env.underlying), address(env.vault), INVENTORY, 955_487);
        cursor = _findTransfer(logs, cursor, expected) + 1;
        assertLt(cursor - 1, _findRebalance(logs, address(env.vault)));
    }

    function _assertRebalance(
        Vm.Log[] memory logs,
        address vault,
        uint256 expectedDr,
        uint256 expectedPrice,
        uint256 expectedUsdValue,
        bool expectedMinting
    ) private pure {
        uint256 index = _findRebalance(logs, vault);
        (uint256 dr, uint256 price, uint256 usdValue, bool minting) =
            abi.decode(logs[index].data, (uint256, uint256, uint256, bool));
        assertEq(dr, expectedDr);
        assertEq(price, expectedPrice);
        assertEq(usdValue, expectedUsdValue);
        assertEq(minting, expectedMinting);
    }

    function _findTransfer(Vm.Log[] memory logs, uint256 start, ExpectedTransfer memory expected)
        private
        pure
        returns (uint256 index)
    {
        for (uint256 i = start; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != expected.token || entry.topics.length != 3 || entry.topics[0] != TRANSFER_TOPIC) {
                continue;
            }
            if (address(uint160(uint256(entry.topics[1]))) != expected.from) continue;
            if (address(uint160(uint256(entry.topics[2]))) != expected.to) continue;
            if (abi.decode(entry.data, (uint256)) != expected.amount) continue;
            return i;
        }
        revert("expected transfer not found");
    }

    function _findRebalance(Vm.Log[] memory logs, address vault) private pure returns (uint256 index) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == vault && logs[i].topics.length != 0 && logs[i].topics[0] == REBALANCE_TOPIC) {
                return i;
            }
        }
        revert("rebalance event not found");
    }

    function _hasRebalance(Vm.Log[] memory logs, address vault) private pure returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == vault && logs[i].topics.length != 0 && logs[i].topics[0] == REBALANCE_TOPIC) {
                return true;
            }
        }
        return false;
    }
}
