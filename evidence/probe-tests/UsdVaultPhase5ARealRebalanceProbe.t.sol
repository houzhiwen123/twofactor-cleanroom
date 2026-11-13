// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockPriceOracle} from "../../test/mocks/MockPriceOracle.sol";

interface IERC20Phase5A {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface ITargetUsdVaultPhase5A {
    struct Range {
        uint96 lower;
        uint96 upper;
    }

    function owner() external view returns (address);
    function keeper() external view returns (address);
    function isSwapper(address account) external view returns (bool);
    function activeRebalanceDelaySec() external view returns (uint32);
    function maxUsdDeviationPerc() external view returns (uint64);
    function maxUnderlyingDeviationPerc() external view returns (uint64);
    function maxFlashMintFeePerc() external view returns (uint64);
    function maxFlashRedeemFeePerc() external view returns (uint64);
    function dexStrategy() external view returns (address);
    function perpController() external view returns (address);
    function usdOracle() external view returns (address);
    function perpSr() external view returns (address);
    function underlying() external view returns (address);
    function sessionCapacity()
        external
        view
        returns (bool active, bool isMintingPerp, uint256 budgetUsdVal, uint256 openedAtSec);
    function rebalance() external;
    function upkeep() external;
    function swap(address tokenIn, address tokenOut, uint256 tokenInAmt, uint256 tokenOutAmt) external;
    function initDeposit(uint256 usdAmt) external returns (uint256 notesMinted);
    function updateHealthCheckParams(address usdOracle_, uint64 maxUsdDeviation, uint64 maxUnderlyingDeviation) external;
    function updateOpLimits(uint128 minOpUsdVal_, uint64 maxFlashMintFeePerc, uint64 maxFlashRedeemFeePerc) external;
    function updateSessionParams(uint32 freqSec, uint32 offsetSec, uint32 activeDelaySec, uint64 velocity) external;
    function updateTargetDR(uint96 targetDR_, Range calldata range) external;
    function updateSwapper(address account, bool allowed) external;
}

interface ITargetControllerPhase5A {
    function underlyingOracle() external view returns (address);
}

interface ITargetPriceOraclePhase5A {
    function getValidPrice() external view returns (uint256);
}

interface ITargetDexStrategyPhase5A {
    function isHealthy() external view returns (bool);
    function quote(address sellToken, address buyToken, uint256 sellAmt) external view returns (uint256);
    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);
}

contract Phase5AFunctionalDex {
    address public immutable usd;
    address public immutable underlying;
    uint256 public immutable price;
    uint256 public maxSellPerTrade;

    constructor(address usd_, address underlying_, uint256 price_, uint256 maxSellPerTrade_) {
        usd = usd_;
        underlying = underlying_;
        price = price_;
        maxSellPerTrade = maxSellPerTrade_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function referencePrice(address, address) external view returns (uint256) {
        return price;
    }

    function quote(address sellToken, address, uint256 sellAmt) public view returns (uint256) {
        if (sellToken == usd) return sellAmt * 1e20 / price;
        return sellAmt * price / 1e20;
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt)
    {
        sellAmt = maxSellAmt < maxSellPerTrade ? maxSellAmt : maxSellPerTrade;
        buyAmt = quote(sellToken, buyToken, sellAmt);
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        buyAmt = quote(sellToken, buyToken, sellAmt);
        IERC20Phase5A(sellToken).transferFrom(msg.sender, address(this), sellAmt);
        IERC20Phase5A(buyToken).transfer(msg.sender, buyAmt);
    }
}

contract UsdVaultPhase5ARealRebalanceProbe is Test {
    error SyntheticDependencyFailure(uint8 dependency);

    address private constant VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant VAULT_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant INVENTORY = 0x7f3D9cA062371429666018E949FbCB39fa602e25;
    address private constant BATCH_EXECUTOR = 0x60Bf78233f48eC42eE3F101b9a05eC7878728006;
    address private constant PERP_JR_RESERVE = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;

    bytes32 private constant REDEEM_TX = 0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e;
    bytes32 private constant MINT_TX = 0x4adb0572701aa84dabb661ad72d31617cf80a441f5696f69825b8a4ee5b80276;

    bytes32 private constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");
    bytes32 private constant REBALANCE_TOPIC = keccak256("Rebalance(uint256,uint256,uint256,bool)");
    bytes32 private constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);

    struct VaultSnapshot {
        uint256 usd;
        uint256 underlying;
        uint256 perp;
        uint256 controllerPerp;
        uint256 perpSupply;
        uint256 usdSupply;
        uint256 underlyingSupply;
        bool active;
        bool minting;
        uint256 budget;
        uint256 openedAt;
    }

    struct SyntheticContext {
        ITargetUsdVaultPhase5A vault;
        MockERC20 usd;
        MockPriceOracle usdOracle;
        Phase5AFunctionalDex dex;
        address underlyingOracle;
        uint256 targetPrice;
        uint256 timestamp;
    }

    struct SyntheticRedeemContext {
        ITargetUsdVaultPhase5A vault;
        MockERC20 usd;
        MockERC20 perp;
        MockERC20 underlying;
        MockPriceOracle usdOracle;
        MockPriceOracle underlyingOracle;
        Phase5AFunctionalDex dex;
        uint256 targetPrice;
        uint256 timestamp;
    }

    function testProbeNaturalRedeemRebalance() public {
        _selectStrictFork(REDEEM_TX, 53_480_534);
        _assertVersionAndRoles();
        VaultSnapshot memory beforeState = _snapshot();

        vm.recordLogs();
        vm.transact(REDEEM_TX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VaultSnapshot memory afterState = _snapshot();

        _printSnapshot("redeem", beforeState, afterState);
        _printRelevantLogs(logs);

        assertFalse(beforeState.active);
        assertTrue(afterState.active);
        assertFalse(afterState.minting);
        assertEq(beforeState.budget, 33_016_915_546_003_499_111_958);
        assertEq(afterState.budget, 32_273_956_312_748_941_964_558);
        assertEq(beforeState.budget - afterState.budget, 742_959_233_254_557_147_400);
        assertEq(afterState.openedAt, 1_793_743_200);
        assertEq(beforeState.usd, 302_318_628);
        assertEq(afterState.usd, 1_041_621_777);
        assertEq(afterState.usd - beforeState.usd, 739_303_149);
        assertEq(beforeState.underlying, 38_782);
        assertEq(afterState.underlying, 43_584);
        assertEq(afterState.underlying - beforeState.underlying, 4_802);
        assertEq(beforeState.perp - afterState.perp, 73_659_360_073);
        assertEq(beforeState.perpSupply - afterState.perpSupply, 73_659_360_073);
        assertEq(beforeState.controllerPerp, afterState.controllerPerp);
        assertEq(beforeState.usdSupply, afterState.usdSupply);
        assertEq(beforeState.underlyingSupply, afterState.underlyingSupply);
        _assertRedeemFlowOrder(logs);
        _assertRebalanceEvent(
            logs, 1_019_867_585_526_484_997, 77_368_295_716_660_000_000_000, 742_959_233_254_557_147_400, false
        );
    }

    function testProbeNaturalMintRebalance() public {
        _selectStrictFork(MINT_TX, 53_491_335);
        _assertVersionAndRoles();
        VaultSnapshot memory beforeState = _snapshot();

        vm.recordLogs();
        vm.transact(MINT_TX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        VaultSnapshot memory afterState = _snapshot();

        _printSnapshot("mint", beforeState, afterState);
        _printRelevantLogs(logs);

        assertFalse(beforeState.active);
        assertTrue(afterState.active);
        assertTrue(afterState.minting);
        assertEq(beforeState.budget, 33_016_963_790_403_425_541_687);
        assertEq(afterState.budget, 29_626_852_605_403_425_541_687);
        assertEq(beforeState.budget - afterState.budget, 3_390_111_185_000_000_000_000);
        assertEq(afterState.openedAt, 1_793_772_000);
        assertEq(beforeState.usd, 3_728_960_649);
        assertEq(afterState.usd, 375_768_789);
        assertEq(beforeState.usd - afterState.usd, 3_353_191_860);
        assertEq(beforeState.underlying, 61_287);
        assertEq(afterState.underlying, 61_287);
        assertEq(afterState.perp - beforeState.perp, 331_220_012_568);
        assertEq(afterState.perpSupply - beforeState.perpSupply, 332_778_700_917);
        assertEq(afterState.controllerPerp - beforeState.controllerPerp, 1_558_688_349);
        assertEq(beforeState.usdSupply, afterState.usdSupply);
        assertEq(beforeState.underlyingSupply, afterState.underlyingSupply);
        _assertMintFlowOrder(logs);
        _assertRebalanceEvent(
            logs, 1_063_211_455_382_090_274, 77_759_215_172_770_000_000_000, 3_390_111_185_000_000_000_000, true
        );
    }

    function testProbeDexViewsForNaturalVectors() public {
        _selectStrictFork(REDEEM_TX, 53_480_534);
        ITargetDexStrategyPhase5A dex = ITargetDexStrategyPhase5A(DEX_STRATEGY);
        assertTrue(dex.isHealthy());
        uint256 redeemQuote = dex.quote(CBBTC, USDC, 955_487);
        console2.log("redeem quote cbBTC to USDC", redeemQuote);
        assertEq(redeemQuote, 739_076_600);
        (uint256 redeemSell, uint256 redeemBuy) = dex.maxFillable(CBBTC, USDC, 960_289, 0);
        console2.log("redeem maxFillable sell", redeemSell);
        console2.log("redeem maxFillable buy", redeemBuy);
        assertEq(redeemSell, 960_289);
        assertEq(redeemBuy, 742_790_479);

        _selectStrictFork(MINT_TX, 53_491_335);
        dex = ITargetDexStrategyPhase5A(DEX_STRATEGY);
        assertTrue(dex.isHealthy());
        uint256 mintQuote = dex.quote(USDC, CBBTC, 3_390_111_185);
        console2.log("mint quote USDC to cbBTC", mintQuote);
        assertEq(mintQuote, 4_362_680);
        (uint256 mintSell, uint256 mintBuy) = dex.maxFillable(USDC, CBBTC, 3_390_111_185, 0);
        console2.log("mint maxFillable sell", mintSell);
        console2.log("mint maxFillable buy", mintBuy);
        assertEq(mintSell, 3_390_111_185);
        assertEq(mintBuy, 4_362_680);
    }

    function testTargetSwapRejectsNonSwapper() public {
        _selectStrictFork(MINT_TX, 53_491_335);
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(VAULT);
        assertTrue(vault.isSwapper(INVENTORY));
        assertFalse(vault.isSwapper(0x000000000000000000000000000000000000bEEF));
        vm.prank(0x000000000000000000000000000000000000bEEF);
        vm.expectRevert(bytes4(keccak256("UnauthorizedCall()")));
        vault.swap(CBBTC, USDC, 4_316_589, 3_390_111_185);
    }

    function testProbeNaturalDelayBoundaryBlocks() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53_493_126);
        assertEq(block.timestamp, 1_793_775_599);
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(VAULT);
        (bool active, bool minting,, uint256 openedAt) = vault.sessionCapacity();
        assertTrue(active);
        assertTrue(minting);
        assertEq(openedAt, 1_793_772_000);
        uint256 delay = vault.activeRebalanceDelaySec();
        assertEq(delay, 3_600);

        bytes4 noOp = bytes4(keccak256("NoOp()"));
        (bool ok, bytes memory result) = _probeNaturalCall(
            "random rebalance delay-1",
            0x000000000000000000000000000000000000bEEF,
            openedAt + delay - 1,
            abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) = _probeNaturalCall(
            "owner rebalance delay-1", vault.owner(), openedAt + delay - 1, abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) = _probeNaturalCall(
            "random rebalance delay",
            0x000000000000000000000000000000000000bEEF,
            openedAt + delay,
            abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) = _probeNaturalCall(
            "owner rebalance delay", vault.owner(), openedAt + delay, abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) = _probeNaturalCall(
            "random rebalance delay+1",
            0x000000000000000000000000000000000000bEEF,
            openedAt + delay + 1,
            abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) = _probeNaturalCall(
            "owner rebalance delay+1", vault.owner(), openedAt + delay + 1, abi.encodeCall(vault.rebalance, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);

        (ok, result) = _probeNaturalCall(
            "random upkeep delay",
            0x000000000000000000000000000000000000bEEF,
            openedAt + delay,
            abi.encodeCall(vault.upkeep, ())
        );
        assertFalse(ok);
        assertEq(_selector(result), noOp);
        (ok, result) =
            _probeNaturalCall("owner upkeep delay", vault.owner(), openedAt + delay, abi.encodeCall(vault.upkeep, ()));
        assertFalse(ok);
        assertEq(_selector(result), noOp);
    }

    function testProbeSyntheticActiveDelayWithResidualCapacity() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53_526_143);
        uint256 targetPrice = 80_248_101_897_110_000_000_000;
        MockERC20 usd = new MockERC20("Phase5A USD", "P5USD", 6);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        Phase5AFunctionalDex dex = new Phase5AFunctionalDex(address(usd), CBBTC, targetPrice, 1_000);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "Phase5A Delay",
            "P5-DELAY",
            address(usd),
            CONTROLLER,
            address(dex)
        );
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        vault.updateHealthCheckParams(address(usdOracle), uint64(1e18), uint64(1e18));
        vault.updateOpLimits(0, uint64(1e18 - 1), uint64(1e18 - 1));
        vault.updateSessionParams(28_800, 21_600, 3_600, uint64(1e18 - 1));
        vault.updateTargetDR(
            1_027_500_000_000_000_000,
            ITargetUsdVaultPhase5A.Range({lower: 1_022_000_000_000_000_000, upper: 1_033_000_000_000_000_000})
        );

        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        vault.initDeposit(10_001);
        deal(CBBTC, address(dex), 1_000_000);

        address underlyingOracle = ITargetControllerPhase5A(CONTROLLER).underlyingOracle();
        vm.mockCall(
            underlyingOracle,
            abi.encodeWithSelector(ITargetPriceOraclePhase5A.getValidPrice.selector),
            abi.encode(targetPrice)
        );
        vm.mockCall(underlyingOracle, abi.encodeWithSignature("cachePrice()"), abi.encode(targetPrice));
        uint256 sessionStart = ((block.timestamp - 21_600) / 28_800) * 28_800 + 21_600;
        (bool beforeOk, bytes memory beforeResult) =
            _probeSyntheticCall("synthetic rebalance delay-1", vault, sessionStart + 3_599);
        assertFalse(beforeOk);
        assertEq(_selector(beforeResult), bytes4(keccak256("OpUnavailable(string)")));
        assertEq(abi.decode(_sliceAfterSelector(beforeResult), (string)), "active delayed");

        (bool equalOk, bytes memory equalResult) =
            _probeSyntheticCall("synthetic rebalance delay", vault, sessionStart + 3_600);
        assertFalse(equalOk);
        assertEq(_selector(equalResult), bytes4(keccak256("SlippageTooHigh()")));
        (bool afterOk, bytes memory afterResult) =
            _probeSyntheticCall("synthetic rebalance delay+1", vault, sessionStart + 3_601);
        assertFalse(afterOk);
        assertEq(_selector(afterResult), bytes4(keccak256("SlippageTooHigh()")));

        SyntheticContext memory context = SyntheticContext({
            vault: vault,
            usd: usd,
            usdOracle: usdOracle,
            dex: dex,
            underlyingOracle: underlyingOracle,
            targetPrice: targetPrice,
            timestamp: sessionStart + 3_600
        });
        _assertSyntheticFailureAtomicity(context, 1);
        _assertSyntheticFailureAtomicity(context, 2);
        _assertSyntheticFailureAtomicity(context, 3);
    }

    function testProbeSyntheticHealthAndFeeGuards() public {
        SyntheticContext memory context = _deploySyntheticHealthContext();
        uint256 usdDeviation = 5e15;
        uint256 underlyingDeviation = 5e16;
        uint256 feeLimit = 5e15;

        _probeAndAssert("baseline", context, 1e18, context.targetPrice, 0, true, "");
        _probeAndAssert("usd upper exact", context, 1e18 + usdDeviation, context.targetPrice, 0, true, "");
        _probeAndAssert(
            "usd upper plus one", context, 1e18 + usdDeviation + 1, context.targetPrice, 0, false, "usd peg"
        );
        _probeAndAssert("usd lower exact", context, 1e18 - usdDeviation, context.targetPrice, 0, true, "");
        _probeAndAssert(
            "usd lower minus one", context, 1e18 - usdDeviation - 1, context.targetPrice, 0, false, "usd peg"
        );

        uint256 refUpper = context.targetPrice * (1e18 + underlyingDeviation) / 1e18;
        uint256 refLower = context.targetPrice * (1e18 - underlyingDeviation) / 1e18;
        _probeAndAssert("underlying upper", context, 1e18, refUpper, 0, true, "");
        _probeAndAssert("underlying upper plus one", context, 1e18, refUpper + 1, 0, false, "oracle divergence");
        _probeAndAssert("underlying lower", context, 1e18, refLower, 0, true, "");
        _probeAndAssert("underlying lower minus one", context, 1e18, refLower - 1, 0, false, "oracle divergence");
        _probeAndAssert("fee exact", context, 1e18, context.targetPrice, feeLimit, true, "");
        _probeAndAssert("fee plus one", context, 1e18, context.targetPrice, feeLimit + 1, false, "flash fee");
    }

    function testProbeSyntheticRedeemFeeGuard() public {
        SyntheticRedeemContext memory context = _deploySyntheticRedeemContext();
        uint256 feeLimit = 5e15;

        (bool exactOk, bytes memory exactResult) = _probeRedeemFee(context, feeLimit);
        _logGuardResult("redeem fee exact", exactOk, exactResult);
        assertTrue(exactOk);
        assertEq(exactResult.length, 0);
        (bool plusOneOk, bytes memory plusOneResult) = _probeRedeemFee(context, feeLimit + 1);
        _logGuardResult("redeem fee plus one", plusOneOk, plusOneResult);
        assertFalse(plusOneOk);
        assertEq(_selector(plusOneResult), bytes4(keccak256("OpUnavailable(string)")));
        assertEq(abi.decode(_sliceAfterSelector(plusOneResult), (string)), "flash fee");
    }

    function testProbeSyntheticSwapGuards() public {
        SyntheticRedeemContext memory context = _deploySyntheticRedeemContext();
        uint256 feeLimit = 5e15;
        uint256 refUpper = context.targetPrice * (1e18 + 5e16) / 1e18;

        _assertSwapGuard("swap baseline", context, 1e18, context.targetPrice, feeLimit, true, "");
        _assertSwapGuard("swap usd bad", context, 1e18 + 5e15 + 1, context.targetPrice, feeLimit, false, "usd peg");
        _assertSwapGuard("swap reference bad", context, 1e18, refUpper + 1, feeLimit, false, "oracle divergence");
        _assertSwapGuard("swap fee bad", context, 1e18, context.targetPrice, feeLimit + 1, false, "flash fee");
    }

    function _deploySyntheticHealthContext() private returns (SyntheticContext memory context) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 53_526_143);
        uint256 targetPrice = 80_248_101_897_110_000_000_000;
        MockERC20 usd = new MockERC20("Phase5B USD", "P5BUSD", 6);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        Phase5AFunctionalDex dex = new Phase5AFunctionalDex(address(usd), CBBTC, targetPrice, type(uint256).max);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "Phase5B Guards",
            "P5B-GUARD",
            address(usd),
            CONTROLLER,
            address(dex)
        );
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        vault.updateHealthCheckParams(address(usdOracle), 5e15, 5e16);
        vault.updateOpLimits(0, 5e15, 5e15);
        vault.updateSessionParams(28_800, 21_600, 3_600, uint64(1e18 - 1));
        vault.updateTargetDR(
            1_027_500_000_000_000_000,
            ITargetUsdVaultPhase5A.Range({lower: 1_022_000_000_000_000_000, upper: 1_033_000_000_000_000_000})
        );

        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        vault.initDeposit(10_001);
        deal(CBBTC, address(dex), 1_000_000);

        uint256 sessionStart = ((block.timestamp - 21_600) / 28_800) * 28_800 + 21_600;
        context = SyntheticContext({
            vault: vault,
            usd: usd,
            usdOracle: usdOracle,
            dex: dex,
            underlyingOracle: ITargetControllerPhase5A(CONTROLLER).underlyingOracle(),
            targetPrice: targetPrice,
            timestamp: sessionStart + 3_600
        });
    }

    function _probeGuard(SyntheticContext memory context, uint256 usdPrice, uint256 referencePrice, uint256 feePerc)
        private
        returns (bool ok, bytes memory result)
    {
        uint256 snapshotId = vm.snapshotState();
        context.usdOracle.setPrice(usdPrice);
        vm.mockCall(
            context.underlyingOracle,
            abi.encodeWithSelector(ITargetPriceOraclePhase5A.getValidPrice.selector),
            abi.encode(context.targetPrice)
        );
        vm.mockCall(context.underlyingOracle, abi.encodeWithSignature("cachePrice()"), abi.encode(context.targetPrice));
        vm.mockCall(
            address(context.dex),
            abi.encodeWithSelector(Phase5AFunctionalDex.referencePrice.selector, CBBTC, address(context.usd)),
            abi.encode(referencePrice)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(bytes4(keccak256("flashMint2(uint256,uint256,uint256,uint256)"))),
            abi.encode(uint256(12), uint256(0), feePerc, uint256(0), uint256(0), uint256(0))
        );
        vm.warp(context.timestamp);
        (ok, result) = address(context.vault).call(abi.encodeCall(context.vault.rebalance, ()));
        assertTrue(vm.revertToState(snapshotId));
        vm.clearMockedCalls();
    }

    function _deploySyntheticRedeemContext() private returns (SyntheticRedeemContext memory context) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), REDEEM_TX);
        uint256 targetPrice = 77_368_295_716_660_000_000_000;
        MockERC20 usd = new MockERC20("Phase5B Redeem USD", "P5BRUSD", 6);
        MockERC20 perp = new MockERC20("Phase5B Redeem Perp", "P5BRPERP", 8);
        MockERC20 underlying = new MockERC20("Phase5B Redeem Underlying", "P5BRUND", 8);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        MockPriceOracle underlyingOracle = new MockPriceOracle(targetPrice);
        Phase5AFunctionalDex dex =
            new Phase5AFunctionalDex(address(usd), address(underlying), targetPrice, type(uint256).max);

        _mockSyntheticControllerTokens(perp, underlying, underlyingOracle);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "Phase5B Redeem Guards",
            "P5B-R-GUARD",
            address(usd),
            CONTROLLER,
            address(dex)
        );
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        assertEq(vault.perpSr(), address(perp));
        assertEq(vault.underlying(), address(underlying));
        vault.updateHealthCheckParams(address(usdOracle), 5e15, 5e16);
        vault.updateOpLimits(0, 5e15, 5e15);
        vault.updateSessionParams(28_800, 21_600, 3_600, uint64(1e18 - 1));
        vault.updateSwapper(address(this), true);
        vault.updateTargetDR(
            1_027_500_000_000_000_000,
            ITargetUsdVaultPhase5A.Range({lower: 1_022_000_000_000_000_000, upper: 1_033_000_000_000_000_000})
        );

        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        vault.initDeposit(10_001);
        usd.mint(address(this), 1_000_000_000);
        usd.approve(address(vault), type(uint256).max);
        perp.mint(address(vault), 10_000_000_000_000);
        underlying.mint(address(vault), 1_000_000);
        usd.mint(address(dex), 1_000_000_000);

        context = SyntheticRedeemContext({
            vault: vault,
            usd: usd,
            perp: perp,
            underlying: underlying,
            usdOracle: usdOracle,
            underlyingOracle: underlyingOracle,
            dex: dex,
            targetPrice: targetPrice,
            timestamp: block.timestamp
        });
    }

    function _assertSwapGuard(
        string memory label,
        SyntheticRedeemContext memory context,
        uint256 usdPrice,
        uint256 referencePrice,
        uint256 feePerc,
        bool expectedOk,
        string memory expectedReason
    ) private {
        uint256 snapshotId = vm.snapshotState();
        context.usdOracle.setPrice(usdPrice);
        _mockSyntheticControllerTokens(context.perp, context.underlying, context.underlyingOracle);
        vm.mockCall(
            address(context.dex),
            abi.encodeWithSelector(
                Phase5AFunctionalDex.referencePrice.selector, address(context.underlying), address(context.usd)
            ),
            abi.encode(referencePrice)
        );
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(bytes4(keccak256("flashRedeem2(uint256,uint256,uint256)"))),
            abi.encode(uint256(1_000), feePerc, uint256(0), uint256(0), uint256(0))
        );
        vm.warp(context.timestamp);
        (bool ok, bytes memory result) = address(context.vault)
            .call(
                abi.encodeCall(
                    context.vault.swap, (address(context.usd), address(context.underlying), uint256(1_000), uint256(1))
                )
            );
        _logGuardResult(label, ok, result);
        assertEq(ok, expectedOk);
        if (expectedOk) {
            assertEq(result.length, 0);
        } else {
            assertEq(_selector(result), bytes4(keccak256("OpUnavailable(string)")));
            assertEq(abi.decode(_sliceAfterSelector(result), (string)), expectedReason);
        }
        assertTrue(vm.revertToState(snapshotId));
        vm.clearMockedCalls();
    }

    function _probeRedeemFee(SyntheticRedeemContext memory context, uint256 feePerc)
        private
        returns (bool ok, bytes memory result)
    {
        uint256 snapshotId = vm.snapshotState();
        _mockSyntheticControllerTokens(context.perp, context.underlying, context.underlyingOracle);
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(bytes4(keccak256("flashRedeem2(uint256,uint256,uint256)"))),
            abi.encode(uint256(1_000), feePerc, uint256(0), uint256(0), uint256(0))
        );
        vm.warp(context.timestamp);
        (ok, result) = address(context.vault).call(abi.encodeCall(context.vault.rebalance, ()));
        assertTrue(vm.revertToState(snapshotId));
        vm.clearMockedCalls();
    }

    function _mockSyntheticControllerTokens(MockERC20 perp, MockERC20 underlying, MockPriceOracle underlyingOracle)
        private
    {
        bytes memory reserveDataCall = abi.encodeWithSignature("reserveData()");
        (bool reserveDataOk, bytes memory reserveDataResult) = PERP_SR.staticcall(reserveDataCall);
        assertTrue(reserveDataOk);
        vm.mockCall(address(perp), reserveDataCall, reserveDataResult);
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("perpSr()"), abi.encode(address(perp)));
        vm.mockCall(CONTROLLER, abi.encodeWithSignature("underlying()"), abi.encode(address(underlying)));
        vm.mockCall(
            CONTROLLER,
            abi.encodeWithSelector(ITargetControllerPhase5A.underlyingOracle.selector),
            abi.encode(address(underlyingOracle))
        );
    }

    function _logGuardResult(string memory label, bool ok, bytes memory result) private pure {
        console2.log(label);
        console2.log("ok", ok);
        console2.log("selector");
        console2.logBytes4(_selector(result));
        if (!ok && result.length >= 100 && _selector(result) == bytes4(keccak256("OpUnavailable(string)"))) {
            console2.log("reason", abi.decode(_sliceAfterSelector(result), (string)));
        }
    }

    function _probeAndAssert(
        string memory label,
        SyntheticContext memory context,
        uint256 usdPrice,
        uint256 referencePrice,
        uint256 feePerc,
        bool expectedOk,
        string memory expectedReason
    ) private {
        (bool ok, bytes memory result) = _probeGuard(context, usdPrice, referencePrice, feePerc);
        _logGuardResult(label, ok, result);
        assertEq(ok, expectedOk);
        if (expectedOk) {
            assertEq(result.length, 0);
            return;
        }
        assertEq(_selector(result), bytes4(keccak256("OpUnavailable(string)")));
        assertEq(abi.decode(_sliceAfterSelector(result), (string)), expectedReason);
    }

    function _assertVersionAndRoles() private view {
        ITargetUsdVaultPhase5A vault = ITargetUsdVaultPhase5A(VAULT);
        assertEq(address(uint160(uint256(vm.load(VAULT, IMPLEMENTATION_SLOT)))), VAULT_IMPLEMENTATION);
        assertEq(VAULT_IMPLEMENTATION.codehash, 0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4);
        assertEq(vault.perpController(), CONTROLLER);
        assertEq(vault.dexStrategy(), DEX_STRATEGY);
        assertTrue(vault.isSwapper(INVENTORY));
        assertFalse(vault.isSwapper(BATCH_EXECUTOR));
        assertEq(vault.owner(), 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d);
        assertEq(vault.keeper(), 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d);
        assertEq(vault.activeRebalanceDelaySec(), 3_600);
        assertEq(vault.maxUsdDeviationPerc(), 5e15);
        assertEq(vault.maxUnderlyingDeviationPerc(), 5e16);
        assertEq(vault.maxFlashMintFeePerc(), 5e15);
        assertEq(vault.maxFlashRedeemFeePerc(), 5e15);
        console2.log("vault owner", vault.owner());
        console2.log("vault keeper", vault.keeper());
        console2.log("inventory is swapper", vault.isSwapper(INVENTORY));
        console2.log("batch executor is swapper", vault.isSwapper(BATCH_EXECUTOR));
        console2.log("active delay", vault.activeRebalanceDelaySec());
    }

    function _snapshot() private view returns (VaultSnapshot memory state) {
        state.usd = IERC20Phase5A(USDC).balanceOf(VAULT);
        state.underlying = IERC20Phase5A(CBBTC).balanceOf(VAULT);
        state.perp = IERC20Phase5A(PERP_SR).balanceOf(VAULT);
        state.controllerPerp = IERC20Phase5A(PERP_SR).balanceOf(CONTROLLER);
        state.perpSupply = IERC20Phase5A(PERP_SR).totalSupply();
        state.usdSupply = IERC20Phase5A(USDC).totalSupply();
        state.underlyingSupply = IERC20Phase5A(CBBTC).totalSupply();
        (state.active, state.minting, state.budget, state.openedAt) = ITargetUsdVaultPhase5A(VAULT).sessionCapacity();
    }

    function _printSnapshot(string memory label, VaultSnapshot memory beforeState, VaultSnapshot memory afterState)
        private
        pure
    {
        console2.log(label);
        console2.log("pre usd", beforeState.usd);
        console2.log("post usd", afterState.usd);
        console2.log("pre cbBTC", beforeState.underlying);
        console2.log("post cbBTC", afterState.underlying);
        console2.log("pre perp", beforeState.perp);
        console2.log("post perp", afterState.perp);
        console2.log("pre perp supply", beforeState.perpSupply);
        console2.log("post perp supply", afterState.perpSupply);
        console2.log("pre budget", beforeState.budget);
        console2.log("post budget", afterState.budget);
    }

    function _printRelevantLogs(Vm.Log[] memory logs) private pure {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0) continue;
            if (entry.emitter == VAULT && entry.topics[0] == REBALANCE_TOPIC) {
                (uint256 drBefore, uint256 price, uint256 usdValue, bool minting) =
                    abi.decode(entry.data, (uint256, uint256, uint256, bool));
                console2.log("rebalance log index", i);
                console2.log("dr before", drBefore);
                console2.log("underlying price", price);
                console2.log("rebalance usd value", usdValue);
                console2.log("minting", minting);
            }
            if (entry.topics[0] != TRANSFER_TOPIC || entry.topics.length != 3) continue;
            address from = address(uint160(uint256(entry.topics[1])));
            address to = address(uint160(uint256(entry.topics[2])));
            if (
                from != VAULT && to != VAULT && from != CONTROLLER && to != CONTROLLER && from != INVENTORY
                    && to != INVENTORY
            ) continue;
            console2.log("transfer log index", i);
            console2.log("token", entry.emitter);
            console2.log("from", from);
            console2.log("to", to);
            console2.log("amount", abi.decode(entry.data, (uint256)));
        }
    }

    function _assertRebalanceEvent(
        Vm.Log[] memory logs,
        uint256 expectedDr,
        uint256 expectedPrice,
        uint256 expectedUsdValue,
        bool expectedMinting
    ) private pure {
        uint256 matches;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != VAULT || entry.topics.length == 0 || entry.topics[0] != REBALANCE_TOPIC) continue;
            (uint256 dr, uint256 price, uint256 usdValue, bool minting) =
                abi.decode(entry.data, (uint256, uint256, uint256, bool));
            assertEq(dr, expectedDr);
            assertEq(price, expectedPrice);
            assertEq(usdValue, expectedUsdValue);
            assertEq(minting, expectedMinting);
            ++matches;
        }
        assertEq(matches, 1);
    }

    function _assertRedeemFlowOrder(Vm.Log[] memory logs) private pure {
        uint256 cursor;
        cursor = _findTransfer(logs, cursor, USDC, INVENTORY, VAULT, 731_851_567) + 1;
        cursor = _findTransfer(logs, cursor, PERP_SR, VAULT, address(0), 73_659_360_073) + 1;
        cursor = _findTransfer(logs, cursor, CBBTC, PERP_JR_RESERVE, CONTROLLER, 960_289) + 1;
        cursor = _findTransfer(logs, cursor, CBBTC, CONTROLLER, VAULT, 960_289) + 1;
        cursor = _findTransfer(logs, cursor, CBBTC, VAULT, INVENTORY, 955_487) + 1;
        assertLt(cursor - 1, _findRebalance(logs));
    }

    function _assertMintFlowOrder(Vm.Log[] memory logs) private pure {
        uint256 cursor;
        cursor = _findTransfer(logs, cursor, CBBTC, INVENTORY, VAULT, 4_316_589) + 1;
        cursor = _findTransfer(logs, cursor, CBBTC, VAULT, PERP_SR, 4_316_589) + 1;
        cursor = _findTransfer(logs, cursor, PERP_SR, address(0), CONTROLLER, 332_778_700_917) + 1;
        cursor = _findTransfer(logs, cursor, PERP_SR, CONTROLLER, VAULT, 331_220_012_568) + 1;
        cursor = _findTransfer(logs, cursor, USDC, VAULT, INVENTORY, 3_390_111_185) + 1;
        assertLt(cursor - 1, _findRebalance(logs));
    }

    function _findTransfer(Vm.Log[] memory logs, uint256 start, address token, address from, address to, uint256 amount)
        private
        pure
        returns (uint256 index)
    {
        for (uint256 i = start; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != token || entry.topics.length != 3 || entry.topics[0] != TRANSFER_TOPIC) continue;
            if (address(uint160(uint256(entry.topics[1]))) != from) continue;
            if (address(uint160(uint256(entry.topics[2]))) != to) continue;
            if (abi.decode(entry.data, (uint256)) != amount) continue;
            return i;
        }
        revert("expected transfer not found");
    }

    function _findRebalance(Vm.Log[] memory logs) private pure returns (uint256 index) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == VAULT && logs[i].topics.length != 0 && logs[i].topics[0] == REBALANCE_TOPIC) {
                return i;
            }
        }
        revert("rebalance event not found");
    }

    function _probeNaturalCall(string memory label, address caller, uint256 timestamp, bytes memory data)
        private
        returns (bool ok, bytes memory result)
    {
        uint256 snapshotId = vm.snapshotState();
        vm.warp(timestamp);
        vm.prank(caller);
        (ok, result) = VAULT.call(data);
        console2.log(label);
        console2.log("ok", ok);
        console2.log("selector");
        console2.logBytes4(_selector(result));
        if (!ok && result.length >= 100 && _selector(result) == bytes4(keccak256("OpUnavailable(string)"))) {
            console2.log("reason", abi.decode(_sliceAfterSelector(result), (string)));
        }
        assertTrue(vm.revertToState(snapshotId));
    }

    function _probeSyntheticCall(string memory label, ITargetUsdVaultPhase5A vault, uint256 timestamp)
        private
        returns (bool ok, bytes memory result)
    {
        uint256 snapshotId = vm.snapshotState();
        vm.warp(timestamp);
        (ok, result) = address(vault).call(abi.encodeCall(vault.rebalance, ()));
        console2.log(label);
        console2.log("ok", ok);
        console2.log("selector");
        console2.logBytes4(_selector(result));
        if (!ok && result.length >= 100 && _selector(result) == bytes4(keccak256("OpUnavailable(string)"))) {
            console2.log("reason", abi.decode(_sliceAfterSelector(result), (string)));
        }
        assertTrue(vm.revertToState(snapshotId));
    }

    function _assertSyntheticFailureAtomicity(SyntheticContext memory context, uint8 dependency) private {
        uint256 snapshotId = vm.snapshotState();
        bytes memory marker = abi.encodeWithSelector(SyntheticDependencyFailure.selector, dependency);
        vm.clearMockedCalls();
        vm.mockCall(
            context.underlyingOracle,
            abi.encodeWithSelector(ITargetPriceOraclePhase5A.getValidPrice.selector),
            abi.encode(context.targetPrice)
        );
        vm.mockCall(context.underlyingOracle, abi.encodeWithSignature("cachePrice()"), abi.encode(context.targetPrice));
        if (dependency == 1) {
            vm.mockCallRevert(context.underlyingOracle, abi.encodeWithSignature("cachePrice()"), marker);
        } else if (dependency == 2) {
            vm.mockCallRevert(address(context.dex), abi.encodeWithSelector(Phase5AFunctionalDex.trade.selector), marker);
        } else {
            vm.mockCallRevert(CONTROLLER, abi.encodeWithSelector(bytes4(keccak256("systemReserveState()"))), marker);
        }
        vm.warp(context.timestamp);
        bytes32 beforeFingerprint = _syntheticFingerprint(context.vault, context.usd, context.dex);
        (bool ok, bytes memory result) = address(context.vault).call(abi.encodeCall(context.vault.rebalance, ()));
        console2.log("dependency", dependency);
        console2.log("dependency result selector");
        console2.logBytes4(_selector(result));
        assertFalse(ok);
        assertEq(keccak256(result), keccak256(marker));
        assertEq(_syntheticFingerprint(context.vault, context.usd, context.dex), beforeFingerprint);
        assertTrue(vm.revertToState(snapshotId));
    }

    function _syntheticFingerprint(ITargetUsdVaultPhase5A vault, MockERC20 usd, Phase5AFunctionalDex dex)
        private
        view
        returns (bytes32)
    {
        (bool active, bool minting, uint256 budget, uint256 openedAt) = vault.sessionCapacity();
        return keccak256(
            abi.encode(
                usd.balanceOf(address(vault)),
                IERC20Phase5A(CBBTC).balanceOf(address(vault)),
                IERC20Phase5A(PERP_SR).balanceOf(address(vault)),
                usd.balanceOf(address(dex)),
                IERC20Phase5A(CBBTC).balanceOf(address(dex)),
                IERC20Phase5A(PERP_SR).totalSupply(),
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
        for (uint256 i; i < sliced.length; ++i) {
            sliced[i] = data[i + 4];
        }
    }

    function _selectStrictFork(bytes32 txHash, uint256 expectedBlock) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), txHash);
        assertEq(block.chainid, 8453);
        assertEq(block.number, expectedBlock);
    }
}
