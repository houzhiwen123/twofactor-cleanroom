// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PairRouter} from "../../src/router/PairRouter.sol";
import {IPairRouter} from "../../src/interfaces/IPairRouter.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

contract PairPhase3Recorder {
    uint256[] private _calls;

    function record(uint256 code) external {
        _calls.push(code);
    }

    function length() external view returns (uint256) {
        return _calls.length;
    }

    function at(uint256 index) external view returns (uint256) {
        return _calls[index];
    }
}

contract PairPhase3UsdVault is ERC20 {
    MockERC20 public immutable usdToken;
    MockERC20 public immutable underlyingToken;
    MockERC20 public immutable srToken;
    address public immutable controller;
    PairPhase3Recorder public immutable recorder;

    uint256 public upkeepCalls;

    constructor(
        MockERC20 usd_,
        MockERC20 underlying_,
        MockERC20 sr_,
        address controller_,
        PairPhase3Recorder recorder_
    ) ERC20("Phase 3 USD notes", "p3USD") {
        usdToken = usd_;
        underlyingToken = underlying_;
        srToken = sr_;
        controller = controller_;
        recorder = recorder_;
    }

    function usd() external view returns (address) {
        return address(usdToken);
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function perpSr() external view returns (address) {
        return address(srToken);
    }

    function perpController() external view returns (address) {
        return controller;
    }

    function isPerpSrVault() external pure returns (bool) {
        return false;
    }

    function mintNotes(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function upkeep() external {
        recorder.record(20);
        upkeepCalls++;
    }

    function redeem(uint256 notes) external returns (uint256 usdOut, uint256 srOut) {
        recorder.record(30);
        _burn(msg.sender, notes);
        usdOut = notes * 2;
        srOut = notes * 3;
        usdToken.mint(msg.sender, usdOut);
        srToken.mint(msg.sender, srOut);
    }
}

contract PairPhase3UnderlyingVault is ERC20 {
    MockERC20 public immutable underlyingToken;
    MockERC20 public immutable jrToken;
    address public immutable controller;
    PairPhase3Recorder public immutable recorder;

    constructor(MockERC20 underlying_, MockERC20 jr_, address controller_, PairPhase3Recorder recorder_)
        ERC20("Phase 3 JR notes", "p3JR")
    {
        underlyingToken = underlying_;
        jrToken = jr_;
        controller = controller_;
        recorder = recorder_;
    }

    function underlying() external view returns (address) {
        return address(underlyingToken);
    }

    function perp() external view returns (address) {
        return address(jrToken);
    }

    function perpController() external view returns (address) {
        return controller;
    }

    function isPerpSrVault() external pure returns (bool) {
        return false;
    }

    function mintNotes(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function redeem(uint256 notes) external returns (uint256 underlyingOut, uint256 jrOut) {
        recorder.record(40);
        _burn(msg.sender, notes);
        underlyingOut = notes * 4;
        jrOut = notes * 5;
        underlyingToken.mint(msg.sender, underlyingOut);
        jrToken.mint(msg.sender, jrOut);
    }
}

contract PairPhase3Controller {
    MockERC20 public immutable underlying;
    MockERC20 public immutable sr;
    MockERC20 public immutable jr;
    PairPhase3Recorder public immutable recorder;

    constructor(MockERC20 underlying_, MockERC20 sr_, MockERC20 jr_, PairPhase3Recorder recorder_) {
        underlying = underlying_;
        sr = sr_;
        jr = jr_;
        recorder = recorder_;
    }

    function perpSr() external view returns (address) {
        return address(sr);
    }

    function perpJr() external view returns (address) {
        return address(jr);
    }

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256)
        external
        returns (uint256 underlyingOut, IPairRouterProbeTypes.FeePerc memory srFee, IPairRouterProbeTypes.FeePerc memory jrFee)
    {
        recorder.record(50);
        if (srIn != 0) sr.transferFrom(msg.sender, address(this), srIn);
        if (jrIn != 0) jr.transferFrom(msg.sender, address(this), jrIn);
        underlyingOut = srIn + jrIn;
        underlying.mint(msg.sender, underlyingOut);
        srFee = IPairRouterProbeTypes.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = IPairRouterProbeTypes.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
    }

    function systemDeviations() external pure returns (uint256 subDR, uint256 vmDR) {
        return (1e18, 1e18);
    }
}

interface IPairRouterProbeTypes {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }
}

contract PairPhase3Strategy {
    MockERC20 public immutable usd;
    MockERC20 public immutable underlying;
    PairPhase3Recorder public immutable recorder;

    uint256 public spend;
    uint256 public output;
    uint256 public requested;

    constructor(MockERC20 usd_, MockERC20 underlying_, PairPhase3Recorder recorder_) {
        usd = usd_;
        underlying = underlying_;
        recorder = recorder_;
    }

    function configure(uint256 spend_, uint256 output_) external {
        spend = spend_;
        output = output_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        recorder.record(60);
        requested = sellAmt;
        require(spend <= sellAmt, "spend");
        if (sellToken == address(underlying) && buyToken == address(usd)) {
            if (spend != 0) underlying.transferFrom(msg.sender, address(this), spend);
            usd.mint(msg.sender, output);
        } else if (sellToken == address(usd) && buyToken == address(underlying)) {
            if (spend != 0) usd.transferFrom(msg.sender, address(this), spend);
            underlying.mint(msg.sender, output);
        } else {
            revert("pair");
        }
        return output;
    }
}

contract PairRouterPhase3TargetProbe is Test {
    address private constant TARGET_ROUTER = 0x97c521D21468022E205d8A57b2fcaeE33d6714d6;
    bytes4 private constant TARGET_REDEEM_SELECTOR = 0xb2a72016;
    bytes4 private constant SLIPPAGE_TOO_HIGH_SELECTOR = 0x850c6f76;
    address private constant USER = address(0xBEEF);

    MockERC20 private underlying;
    MockERC20 private usd;
    MockERC20 private sr;
    MockERC20 private jr;
    PairPhase3Recorder private recorder;
    PairPhase3Controller private controller;
    PairPhase3UsdVault private usdVault;
    PairPhase3UnderlyingVault private jrVault;
    PairPhase3Strategy private strategy;
    PairRouter private localRouter;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 57_015_384);
        assertEq(block.chainid, 8453);
        assertEq(TARGET_ROUTER.codehash, 0x487610478a620be27092ff42bf2dea6bfc08275af635abdc27245329f9801218);

        underlying = new MockERC20("cbBTC", "cbBTC", 8);
        usd = new MockERC20("USDC", "USDC", 6);
        sr = new MockERC20("SR", "SR", 8);
        jr = new MockERC20("JR", "JR", 8);
        recorder = new PairPhase3Recorder();
        controller = new PairPhase3Controller(underlying, sr, jr, recorder);
        usdVault = new PairPhase3UsdVault(usd, underlying, sr, address(controller), recorder);
        jrVault = new PairPhase3UnderlyingVault(underlying, jr, address(controller), recorder);
        strategy = new PairPhase3Strategy(usd, underlying, recorder);
        localRouter = new PairRouter();

        usdVault.mintNotes(USER, 10);
        jrVault.mintNotes(USER, 10);
        vm.startPrank(USER);
        usdVault.approve(TARGET_ROUTER, type(uint256).max);
        jrVault.approve(TARGET_ROUTER, type(uint256).max);
        usdVault.approve(address(localRouter), type(uint256).max);
        jrVault.approve(address(localRouter), type(uint256).max);
        vm.stopPrank();
    }

    function testObservePartialStrategySpendAccounting() public {
        strategy.configure(40, 400);
        (bool success, bytes memory result) = _callRouter(TARGET_ROUTER, false, type(uint256).max, 100);
        assertTrue(success, "target partial-spend call");

        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        assertEq(usdOut, 420);
        assertEq(underlyingOut, 80);
        assertEq(usd.balanceOf(USER), 420);
        assertEq(underlying.balanceOf(USER), 80);
        assertEq(underlying.balanceOf(TARGET_ROUTER), 0);
        assertEq(strategy.requested(), 100);
        assertEq(underlying.balanceOf(address(strategy)), 40);
        emit log_named_uint("partial USD out", usdOut);
        emit log_named_uint("partial underlying out", underlyingOut);
        emit log_named_uint("partial user USD delta", usd.balanceOf(USER));
        emit log_named_uint("partial user underlying delta", underlying.balanceOf(USER));
        emit log_named_uint("partial router underlying dust", underlying.balanceOf(TARGET_ROUTER));
        emit log_named_uint("partial strategy requested", strategy.requested());
        emit log_named_uint("partial strategy spent", underlying.balanceOf(address(strategy)));
    }

    function testTargetReverseTradePartialSpendUsesActualBalances() public {
        strategy.configure(6, 9);
        (bool success, bytes memory result) = _callRouter(TARGET_ROUTER, false, 5, 0);
        assertTrue(success, "target reverse partial-spend call");

        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        assertEq(usdOut, 14);
        assertEq(underlyingOut, 129);
        assertEq(usd.balanceOf(USER), 14);
        assertEq(underlying.balanceOf(USER), 129);
        assertEq(usd.balanceOf(TARGET_ROUTER), 0);
        assertEq(strategy.requested(), 15);
        assertEq(usd.balanceOf(address(strategy)), 6);
    }

    function testTargetPartialSpendUsesActualBalanceMinimums() public {
        strategy.configure(40, 400);
        uint256 snapshot = vm.snapshotState();
        (bool success,) = _callRouterWithMinimums(TARGET_ROUTER, false, type(uint256).max, 100, 420, 80);
        assertTrue(success, "exact actual-balance minimums");
        assertTrue(vm.revertToState(snapshot));

        bytes memory usdFailure;
        (success, usdFailure) = _callRouterWithMinimums(TARGET_ROUTER, false, type(uint256).max, 100, 421, 80);
        assertFalse(success, "USD minimum plus one");
        assertEq(_selector(usdFailure), SLIPPAGE_TOO_HIGH_SELECTOR);
        assertTrue(vm.revertToState(snapshot));

        bytes memory underlyingFailure;
        (success, underlyingFailure) =
            _callRouterWithMinimums(TARGET_ROUTER, false, type(uint256).max, 100, 420, 81);
        assertFalse(success, "underlying minimum plus one");
        assertEq(_selector(underlyingFailure), SLIPPAGE_TOO_HIGH_SELECTOR);
    }

    function testObserveSuccessfulRunUpkeepCallOrder() public {
        strategy.configure(100, 400);
        (bool success, bytes memory result) = _callRouter(TARGET_ROUTER, true, type(uint256).max, 100);
        assertTrue(success, "target successful upkeep call");
        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        assertEq(usdOut, 420);
        assertEq(underlyingOut, 20);
        assertEq(usdVault.upkeepCalls(), 1);
        assertEq(recorder.length(), 5);
        assertEq(recorder.at(0), 20);
        assertEq(recorder.at(1), 30);
        assertEq(recorder.at(2), 40);
        assertEq(recorder.at(3), 50);
        assertEq(recorder.at(4), 60);
        emit log_named_uint("upkeep USD out", usdOut);
        emit log_named_uint("upkeep underlying out", underlyingOut);
        emit log_named_uint("upkeep calls", usdVault.upkeepCalls());
        for (uint256 i; i < recorder.length(); ++i) {
            emit log_named_uint("call code", recorder.at(i));
        }
    }

    function testCleanRoomMatchesTargetPartialSpendAndSuccessfulUpkeep() public {
        strategy.configure(40, 400);
        uint256 snapshot = vm.snapshotState();
        (bool targetSuccess, bytes memory targetResult) =
            _callRouter(TARGET_ROUTER, true, type(uint256).max, 100);
        uint256 targetUsd = usd.balanceOf(USER);
        uint256 targetUnderlying = underlying.balanceOf(USER);
        uint256 targetUpkeepCalls = usdVault.upkeepCalls();
        assertTrue(vm.revertToState(snapshot));

        (bool localSuccess, bytes memory localResult) =
            _callRouter(address(localRouter), true, type(uint256).max, 100);
        assertEq(localSuccess, targetSuccess);
        assertEq(keccak256(localResult), keccak256(targetResult));
        assertEq(usd.balanceOf(USER), targetUsd);
        assertEq(underlying.balanceOf(USER), targetUnderlying);
        assertEq(usdVault.upkeepCalls(), targetUpkeepCalls);
        assertEq(usd.balanceOf(address(localRouter)), 0);
        assertEq(underlying.balanceOf(address(localRouter)), 0);
    }

    function testCleanRoomMatchesTargetReversePartialSpend() public {
        strategy.configure(6, 9);
        uint256 snapshot = vm.snapshotState();
        (bool targetSuccess, bytes memory targetResult) = _callRouter(TARGET_ROUTER, false, 5, 0);
        uint256 targetUsd = usd.balanceOf(USER);
        uint256 targetUnderlying = underlying.balanceOf(USER);
        assertTrue(vm.revertToState(snapshot));

        (bool localSuccess, bytes memory localResult) = _callRouter(address(localRouter), false, 5, 0);
        assertEq(localSuccess, targetSuccess);
        assertEq(keccak256(localResult), keccak256(targetResult));
        assertEq(usd.balanceOf(USER), targetUsd);
        assertEq(underlying.balanceOf(USER), targetUnderlying);
        assertEq(usd.balanceOf(address(localRouter)), 0);
        assertEq(underlying.balanceOf(address(localRouter)), 0);
    }

    function _callRouter(address router, bool runUpkeep, uint256 maxUsdRetained, uint256 underlyingToTrade)
        private
        returns (bool success, bytes memory result)
    {
        return _callRouterWithMinimums(router, runUpkeep, maxUsdRetained, underlyingToTrade, 0, 0);
    }

    function _callRouterWithMinimums(
        address router,
        bool runUpkeep,
        uint256 maxUsdRetained,
        uint256 underlyingToTrade,
        uint256 minUsdOut,
        uint256 minUnderlyingOut
    ) private returns (bool success, bytes memory result)
    {
        IPairRouter.RedeemParams memory params = IPairRouter.RedeemParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(strategy),
            usdNotes: 10,
            underlyingNotes: 10,
            maxUsdRetained: maxUsdRetained,
            underlyingToTrade: underlyingToTrade,
            runUpkeep: runUpkeep,
            minUsdOut: minUsdOut,
            minUnderlyingOut: minUnderlyingOut,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: true
        });
        vm.prank(USER);
        return router.call(abi.encodePacked(TARGET_REDEEM_SELECTOR, abi.encode(params)));
    }

    function _selector(bytes memory data) private pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 32))
        }
    }
}
