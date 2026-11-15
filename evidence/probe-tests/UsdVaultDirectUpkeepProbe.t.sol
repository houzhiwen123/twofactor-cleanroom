// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockPriceOracle} from "../../test/mocks/MockPriceOracle.sol";

interface ITargetUsdVaultDirectProbe {
    struct Range {
        uint96 lower;
        uint96 upper;
    }

    function rebalance() external;
    function upkeep() external;
    function initDeposit(uint256 usdAmt) external returns (uint256 notesMinted);
    function sessionCapacity()
        external
        view
        returns (bool active, bool isMintingPerp, uint256 budgetUsdVal, uint256 openedAtSec);
    function updateHealthCheckParams(address usdOracle_, uint64 maxUsdDeviation, uint64 maxUnderlyingDeviation)
        external;
    function updateOpLimits(uint128 minOpUsdVal_, uint64 maxFlashMintFeePerc, uint64 maxFlashRedeemFeePerc)
        external;
    function updateSessionParams(uint32 freqSec, uint32 offsetSec, uint32 activeDelaySec, uint64 velocity)
        external;
    function updateTargetDR(uint96 targetDR_, Range calldata range) external;
}

interface ITargetControllerDirectProbe {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function underlyingOracle() external view returns (address);
    function systemReserveState() external view returns (SystemState memory state);
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function targetSystemRatio() external view returns (uint256);
}

contract DirectProbeDex {
    error ObservedMaxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt);
    error ObservedTrade(address sellToken, address buyToken, uint256 sellAmt);

    enum Mode {
        Execute,
        RevertMaxFillable,
        RevertTrade
    }

    uint256 public referencePriceValue;
    uint256 public maxSellReturn;
    uint256 public maxBuyReturn;
    uint256 public tradeBuyReturn;
    Mode public mode;

    constructor(uint256 referencePrice_) {
        referencePriceValue = referencePrice_;
    }

    function configure(Mode mode_, uint256 maxSellReturn_, uint256 maxBuyReturn_, uint256 tradeBuyReturn_)
        external
    {
        mode = mode_;
        maxSellReturn = maxSellReturn_;
        maxBuyReturn = maxBuyReturn_;
        tradeBuyReturn = tradeBuyReturn_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function referencePrice(address, address) external view returns (uint256) {
        return referencePriceValue;
    }

    function quote(address sellToken, address, uint256 sellAmt) external view returns (uint256) {
        return sellToken == address(0) ? 0 : sellAmt * 1e20 / referencePriceValue;
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt)
    {
        if (mode == Mode.RevertMaxFillable) {
            revert ObservedMaxFillable(sellToken, buyToken, maxSellAmt, minBuyAmt);
        }
        return (maxSellReturn, maxBuyReturn);
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        if (mode == Mode.RevertTrade) revert ObservedTrade(sellToken, buyToken, sellAmt);
        MockERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
        MockERC20(buyToken).transfer(msg.sender, tradeBuyReturn);
        return tradeBuyReturn;
    }
}

contract UsdVaultDirectUpkeepProbe is Test {
    address private constant VAULT_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant TARGET_PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    bytes32 private constant REDEEM_TX = 0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e;

    uint256 private constant MINT_BLOCK = 53_526_143;
    uint256 private constant MINT_PRICE = 80_248_101_897_110_000_000_000;
    uint256 private constant REDEEM_PRICE = 77_368_295_716_660_000_000_000;

    struct Context {
        ITargetUsdVaultDirectProbe vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockPriceOracle usdOracle;
        MockPriceOracle underlyingOracle;
        DirectProbeDex dex;
        uint256 timestamp;
        bool minting;
    }

    function testObserveDirectMintArgumentsAndPartialFillBoundary() public {
        Context memory context = _deployMintContext();
        (uint256 maxSell, uint256 minBuy) = _observeMaxFillable(context, false);
        console2.log("mint maxSell", maxSell);
        console2.log("mint minBuy", minBuy);

        uint256 partialSell = maxSell / 2;
        _assertTradeReceives(context, partialSell, minBuy);
        _assertResult(context, partialSell, minBuy, minBuy / 2 + 1, true, bytes4(0));
        _assertResult(context, partialSell, minBuy - 1, minBuy / 2, false, bytes4(keccak256("SlippageTooHigh()")));
        _assertResult(context, partialSell, minBuy - 1, minBuy, true, bytes4(0));
        _assertResult(context, partialSell, minBuy, 0, false, bytes4(keccak256("SlippageTooHigh()")));
    }

    function testObserveDirectRedeemArgumentsAndPartialFillBoundary() public {
        Context memory context = _deployRedeemContext();
        (uint256 maxSell, uint256 minBuy) = _observeMaxFillable(context, false);
        console2.log("redeem maxSell", maxSell);
        console2.log("redeem minBuy", minBuy);

        uint256 partialSell = maxSell / 2;
        _assertTradeReceives(context, partialSell, minBuy);
        _assertResult(context, partialSell, minBuy, minBuy / 2 + 1, true, bytes4(0));
        _assertResult(context, partialSell, minBuy - 1, minBuy / 2, true, bytes4(0));
        _assertResult(context, partialSell, minBuy - 1, minBuy, true, bytes4(0));
        _assertResult(context, partialSell, minBuy, 0, false, bytes4(keccak256("SlippageTooHigh()")));
    }

    function testObserveUpkeepWithMintCapacityBeforeAtAndAfterDelay() public {
        Context memory context = _deployMintContext();
        (,,, uint256 openedAt) = context.vault.sessionCapacity();
        bytes4 noOp = bytes4(keccak256("NoOp()"));

        _assertUpkeepResult(context, openedAt + 3_599, false, noOp);
        _assertUpkeepResult(context, openedAt + 3_600, false, noOp);
        _assertUpkeepResult(context, openedAt + 3_601, false, noOp);
    }

    function testObserveUpkeepWithRedeemCapacity() public {
        Context memory context = _deployRedeemContext();
        _assertUpkeepResult(context, context.timestamp, false, DirectProbeDex.ObservedMaxFillable.selector);
    }

    function testObserveStateChangingUpkeepRedeemPath() public {
        Context memory context = _deployRedeemContext();
        (, uint256 minBuy) = _observeMaxFillable(context, false);
        uint256 snapshotId = vm.snapshotState();
        uint256 executableSell = context.underlying.balanceOf(address(context.vault)) / 2;
        context.dex.configure(DirectProbeDex.Mode.Execute, executableSell, minBuy, minBuy);
        vm.warp(context.timestamp);
        bytes32 beforeFingerprint = _fingerprint(context);
        _logState(context, "before");
        (bool ok, bytes memory result) = address(context.vault).call(abi.encodeCall(context.vault.upkeep, ()));
        console2.log("state-changing upkeep success", ok);
        console2.logBytes4(_selector(result));
        console2.logBytes32(beforeFingerprint);
        _logState(context, "after");
        console2.logBytes32(_fingerprint(context));
        assertTrue(ok);
        assertEq(_selector(result), bytes4(0));
        assertTrue(_fingerprint(context) != beforeFingerprint);
        assertTrue(vm.revertToState(snapshotId));
    }

    function _logState(Context memory context, string memory label) private view {
        (bool active, bool minting, uint256 budget, uint256 openedAt) = context.vault.sessionCapacity();
        console2.log(label, "usd", context.usd.balanceOf(address(context.vault)));
        console2.log(label, "perp", context.perp.balanceOf(address(context.vault)));
        console2.log(label, "underlying", context.underlying.balanceOf(address(context.vault)));
        console2.log(label, "active", active);
        console2.log(label, "minting", minting);
        console2.log(label, "budget", budget);
        console2.log(label, "openedAt", openedAt);
    }

    function _deployMintContext() private returns (Context memory context) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), MINT_BLOCK);
        context = _deployCommon(MINT_PRICE, true);
        (bool active, bool minting, uint256 budget, uint256 openedAt) = context.vault.sessionCapacity();
        assertFalse(active);
        assertFalse(minting);
        assertGt(budget, 0);
        context.timestamp = openedAt + 3_600;
    }

    function _deployRedeemContext() private returns (Context memory context) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), REDEEM_TX);
        context = _deployCommon(REDEEM_PRICE, false);
        context.perp.mint(address(context.vault), 10_000_000_000_000);
        context.underlying.mint(address(context.vault), 2_000_000_000_000);
        context.usd.mint(address(context.dex), 2_000_000_000_000_000_000);

        (bool active, bool minting, uint256 budget, uint256 openedAt) = context.vault.sessionCapacity();
        assertFalse(active);
        assertFalse(minting);
        assertGt(budget, 0);
        context.timestamp = block.timestamp > openedAt + 3_600 ? block.timestamp : openedAt + 3_600;
    }

    function _deployCommon(uint256 targetPrice, bool minting) private returns (Context memory context) {
        MockERC20 usd = new MockERC20("Direct Probe USD", "DP-USD", 6);
        MockERC20 perp = new MockERC20("Direct Probe Perp", "DP-PERP", 8);
        MockERC20 underlying = new MockERC20("Direct Probe Underlying", "DP-UND", 8);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        MockPriceOracle underlyingOracle = new MockPriceOracle(targetPrice);
        DirectProbeDex dex = new DirectProbeDex(targetPrice);

        _mockControllerTokens(perp, underlying, underlyingOracle, minting);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "Direct Probe Vault",
            "DP-V",
            address(usd),
            CONTROLLER,
            address(dex)
        );
        ITargetUsdVaultDirectProbe vault =
            ITargetUsdVaultDirectProbe(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        vault.updateHealthCheckParams(address(usdOracle), uint64(1e18), uint64(1e18));
        vault.updateOpLimits(0, uint64(1e18 - 1), uint64(1e18 - 1));
        vault.updateSessionParams(28_800, 21_600, 3_600, uint64(1e18 - 1));
        vault.updateTargetDR(
            1_027_500_000_000_000_000,
            ITargetUsdVaultDirectProbe.Range({
                lower: 1_022_000_000_000_000_000,
                upper: 1_033_000_000_000_000_000
            })
        );

        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        vault.initDeposit(10_001);
        usd.mint(address(vault), 1_000_000_000_000);
        underlying.mint(address(dex), 1_000_000_000_000);
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(bytes4(keccak256("flashMint2(uint256,uint256,uint256,uint256)"))),
            abi.encode(uint256(12), uint256(0), uint256(0), uint256(0), uint256(0), uint256(0))
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(bytes4(keccak256("flashRedeem2(uint256,uint256,uint256)"))),
            abi.encode(uint256(minting ? 1_000 : 711_398_192), uint256(0), uint256(0), uint256(0), uint256(0))
        );

        context = Context({
            vault: vault,
            usd: usd,
            perp: perp,
            underlying: underlying,
            usdOracle: usdOracle,
            underlyingOracle: underlyingOracle,
            dex: dex,
            timestamp: block.timestamp,
            minting: minting
        });
    }

    function _mockControllerTokens(
        MockERC20 perp,
        MockERC20 underlying,
        MockPriceOracle underlyingOracle,
        bool minting
    )
        private
    {
        (bool ok, bytes memory reserveData) = TARGET_PERP_SR.staticcall(abi.encodeWithSignature("reserveData()"));
        assertTrue(ok);
        vm.mockCall(address(perp), abi.encodeWithSignature("reserveData()"), reserveData);
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("perpSr()"), abi.encode(address(perp)));
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("underlying()"), abi.encode(address(underlying)));
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(ITargetControllerDirectProbe.underlyingOracle.selector),
            abi.encode(address(underlyingOracle))
        );
        (bool stateOk, bytes memory stateReturn) =
            CONTROLLER.staticcall(abi.encodeWithSelector(ITargetControllerDirectProbe.systemReserveState.selector));
        assertTrue(stateOk);
        _patchSystemState(stateReturn, minting);
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(ITargetControllerDirectProbe.systemReserveState.selector), stateReturn);
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(ITargetControllerDirectProbe.systemDeviations.selector),
            abi.encode(minting ? 2e18 : 9e17, 1e18)
        );
        vm.mockCall(CONTROLLER, abi.encodeWithSelector(ITargetControllerDirectProbe.targetSystemRatio.selector), abi.encode(2e18));
    }

    function _patchSystemState(bytes memory stateReturn, bool minting) private pure {
        // Keep the target controller's dynamic reserve-data tails intact while
        // replacing only the six scalar SystemState words used by the Vault.
        assembly {
            mstore(add(stateReturn, 0x20), 3000000000000000000)
            mstore(add(stateReturn, 0x40), 1000000000000000000)
            mstore(add(stateReturn, 0x60), 1000000000000000000)
            mstore(add(stateReturn, 0x80), 3000000000000000000)
            mstore(add(stateReturn, 0xa0), 3000000000000000000)
            mstore(add(stateReturn, 0xc0), 1000000000000000000)
        }
        if (!minting) {
            assembly {
                mstore(add(stateReturn, 0x40), 3000000000000000000)
            }
        }
    }

    function _observeMaxFillable(Context memory context, bool upkeep)
        private
        returns (uint256 maxSell, uint256 minBuy)
    {
        uint256 snapshotId = vm.snapshotState();
        context.dex.configure(DirectProbeDex.Mode.RevertMaxFillable, 0, 0, 0);
        vm.warp(context.timestamp);
        (bool ok, bytes memory result) = address(context.vault).call(
            upkeep ? abi.encodeCall(context.vault.upkeep, ()) : abi.encodeCall(context.vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), DirectProbeDex.ObservedMaxFillable.selector);
        (address sellToken, address buyToken, uint256 observedMaxSell, uint256 observedMinBuy) =
            abi.decode(_sliceAfterSelector(result), (address, address, uint256, uint256));
        assertEq(sellToken, context.minting ? address(context.usd) : address(context.underlying));
        assertEq(buyToken, context.minting ? address(context.underlying) : address(context.usd));
        assertTrue(vm.revertToState(snapshotId));
        return (observedMaxSell, observedMinBuy);
    }

    function _assertTradeReceives(Context memory context, uint256 sellAmt, uint256 minBuy) private {
        uint256 snapshotId = vm.snapshotState();
        context.dex.configure(DirectProbeDex.Mode.RevertTrade, sellAmt, minBuy, 0);
        vm.warp(context.timestamp);
        (bool ok, bytes memory result) = address(context.vault).call(abi.encodeCall(context.vault.rebalance, ()));
        assertFalse(ok);
        assertEq(_selector(result), DirectProbeDex.ObservedTrade.selector);
        (address sellToken, address buyToken, uint256 observedSell) =
            abi.decode(_sliceAfterSelector(result), (address, address, uint256));
        assertEq(sellToken, context.minting ? address(context.usd) : address(context.underlying));
        assertEq(buyToken, context.minting ? address(context.underlying) : address(context.usd));
        assertEq(observedSell, context.minting ? sellAmt : 711_398_192);
        assertTrue(vm.revertToState(snapshotId));
    }

    function _assertResult(
        Context memory context,
        uint256 sellAmt,
        uint256 advertisedBuy,
        uint256 tradeBuy,
        bool expectedOk,
        bytes4 expectedSelector
    ) private {
        uint256 snapshotId = vm.snapshotState();
        context.dex.configure(DirectProbeDex.Mode.Execute, sellAmt, advertisedBuy, tradeBuy);
        vm.warp(context.timestamp);
        (bool ok, bytes memory result) = address(context.vault).call(abi.encodeCall(context.vault.rebalance, ()));
        console2.log("trade buy", tradeBuy);
        console2.log("success", ok);
        console2.logBytes4(_selector(result));
        assertEq(ok, expectedOk);
        if (!expectedOk) assertEq(_selector(result), expectedSelector);
        assertTrue(vm.revertToState(snapshotId));
    }

    function _assertUpkeepResult(Context memory context, uint256 timestamp, bool expectedOk, bytes4 expectedSelector)
        private
    {
        uint256 snapshotId = vm.snapshotState();
        context.dex.configure(DirectProbeDex.Mode.RevertMaxFillable, 0, 0, 0);
        vm.warp(timestamp);
        bytes32 beforeFingerprint = _fingerprint(context);
        (bool ok, bytes memory result) = address(context.vault).call(abi.encodeCall(context.vault.upkeep, ()));
        console2.log("upkeep timestamp", timestamp);
        console2.log("upkeep success", ok);
        console2.logBytes4(_selector(result));
        assertEq(ok, expectedOk);
        if (!expectedOk) assertEq(_selector(result), expectedSelector);
        assertEq(_fingerprint(context), beforeFingerprint);
        assertTrue(vm.revertToState(snapshotId));
    }

    function _fingerprint(Context memory context) private view returns (bytes32) {
        (bool active, bool minting, uint256 budget, uint256 openedAt) = context.vault.sessionCapacity();
        return keccak256(
            abi.encode(
                context.usd.balanceOf(address(context.vault)),
                context.perp.balanceOf(address(context.vault)),
                context.underlying.balanceOf(address(context.vault)),
                active,
                minting,
                budget,
                openedAt
            )
        );
    }

    function _selector(bytes memory data) private pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly {
            value := mload(add(data, 0x20))
        }
    }

    function _sliceAfterSelector(bytes memory data) private pure returns (bytes memory sliced) {
        sliced = new bytes(data.length - 4);
        for (uint256 i; i < sliced.length; ++i) sliced[i] = data[i + 4];
    }
}
