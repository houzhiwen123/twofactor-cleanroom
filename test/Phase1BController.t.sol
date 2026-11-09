// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {PerpController, IFeePolicyController, IBondIssuerController} from "../src/controller/PerpController.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";

contract MockPhase1BFeePolicy is IFeePolicyController {
    uint256 public srFeePerc;
    uint256 public jrFeePerc;
    uint256 public protocolPerc;
    uint256 public rebalanceValue;
    bool public srPays;
    uint64 public override perpSrAUMFeePerc;
    uint64 public override perpJrAUMFeePerc;
    address public override protocolFeeCollector = address(0xCAFE);

    function setFees(uint256 srFee, uint256 jrFee, uint256 protocol) external {
        srFeePerc = srFee;
        jrFeePerc = jrFee;
        protocolPerc = protocol;
    }

    function setAum(uint64 srFee, uint64 jrFee) external {
        perpSrAUMFeePerc = srFee;
        perpJrAUMFeePerc = jrFee;
    }

    function setRebalance(uint256 value, bool srPays_) external {
        rebalanceValue = value;
        srPays = srPays_;
    }

    function computeOpFees(OpFeeInput calldata input) external view override returns (OpFees memory) {
        return OpFees(input.isPerpSrOp ? srFeePerc : jrFeePerc, protocolPerc);
    }

    function computeRebalanceVal(uint256, uint256, uint256) external view override returns (uint256, bool) {
        return (rebalanceValue, srPays);
    }
}

contract MockReserveTranche is ERC20 {
    IBondsManager.TrancheData private _trancheData;

    constructor() ERC20("Mock tranche", "mTR") {}

    function setData(IBondsManager.TrancheData calldata data_) external {
        _trancheData = data_;
    }

    function data() external view returns (IBondsManager.TrancheData memory) {
        return _trancheData;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPhase1BIssuer is IBondIssuerController {
    BondInfo private _bondInfo;
    uint256 public issueCalls;

    constructor(address srTranche, address jrTranche) {
        _bondInfo = BondInfo(address(0xD00D), bytes32(uint256(1)), srTranche, jrTranche);
    }

    function issue() external override returns (bool issued, BondInfo memory info) {
        ++issueCalls;
        return (false, _bondInfo);
    }

    function latestBondInfo() external view override returns (BondInfo memory) {
        return _bondInfo;
    }
}

contract Phase1BControllerTest is Test {
    uint256 private constant WAD = 1e18;
    address private constant USER = address(0xBEEF);

    struct RebalanceFees {
        uint256 sr;
        uint256 jr;
        uint256 underlying;
    }

    struct RebalanceLogState {
        uint256 stage;
        uint256 aumCount;
        uint256 reserveSyncedCount;
    }

    MockERC20 private underlying;
    PerpToken private sr;
    PerpToken private jr;
    PerpController private controller;
    MockPhase1BFeePolicy private feePolicy;

    function setUp() public {
        (underlying, sr, jr, controller, feePolicy) = _deployFixture();
    }

    function testFlashMint2GoldenNetShares() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        underlying.mint(USER, 2_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        (uint256 srOut, uint256 jrOut,,) = controller.flashMint2(1_000_000, 1_000_000, 0, 0);
        vm.stopPrank();
        assertEq(srOut, 74_102_043_524);
        assertEq(jrOut, 87_590_731_854);
    }

    function testFlashMint2PerSideFeeDivergence() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setFees(203_820_479_010_835, 303_820_479_010_835, 0);
        underlying.mint(USER, 2_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        (,, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
            controller.flashMint2(1_000_000, 1_000_000, 0, 0);
        vm.stopPrank();
        assertEq(srFee.totalFeePerc, 203_820_479_010_835);
        assertEq(jrFee.totalFeePerc, 303_820_479_010_835);
    }

    function testFlashRedeem2Gross999999GoldenCases() public {
        _assertFlashRedeem2Gross(9_655_414_018_003, 130_298_890, 74_102_043_524, true);
        _assertFlashRedeem2Gross(33_850_817_003_440, 386_465_740, 87_590_731_854, false);
    }

    function testFlashRedeem2TwoSidedGoldenSettlement() public {
        _seed(9_581_319_667_788, 130_298_890, 33_850_835_190_863, 388_465_740);
        feePolicy.setFees(663_118_837_574_245, 663_118_837_574_245, 0);
        vm.prank(address(controller));
        sr.mintTo(USER, 74_094_350_215);
        vm.prank(address(controller));
        jr.mintTo(USER, 175_163_276_286);
        vm.startPrank(USER);
        sr.approve(address(controller), type(uint256).max);
        jr.approve(address(controller), type(uint256).max);
        vm.recordLogs();
        (uint256 underlyingOut,,) = controller.flashRedeem2(74_094_350_215, 175_163_276_286, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        assertEq(underlyingOut, 2_997_699);
        assertEq(underlying.balanceOf(USER), 2_997_699);
        assertEq(underlying.balanceOf(address(controller)), 1_989);
        assertEq(controller.collectedFeeBal(address(underlying)), 1_989);
        assertEq(sr.totalSupply(), 9_581_319_667_788);
        assertEq(jr.totalSupply(), 33_850_835_190_863);
        assertEq(underlying.balanceOf(address(sr)), 129_298_994);
        assertEq(underlying.balanceOf(address(jr)), 386_465_948);

        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 feesTopic = keccak256("OpFees(address,uint256,uint256)");
        uint256[] memory transferIndices = new uint256[](4);
        uint256[] memory feeIndices = new uint256[](2);
        address[4] memory expectedFrom = [address(sr), address(jr), address(controller), address(controller)];
        address[4] memory expectedTo = [address(jr), address(controller), USER, USER];
        uint256[4] memory expectedAmounts = [uint256(999_896), 2_999_688, 999_233, 1_998_466];
        uint256 transferCount;
        uint256 feeCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(underlying) && logs[i].topics[0] == transferTopic) {
                assertTrue(transferCount < 4);
                assertEq(address(uint160(uint256(logs[i].topics[1]))), expectedFrom[transferCount]);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), expectedTo[transferCount]);
                assertEq(abi.decode(logs[i].data, (uint256)), expectedAmounts[transferCount]);
                transferIndices[transferCount++] = i;
            }
            if (logs[i].emitter == address(controller) && logs[i].topics[0] == feesTopic) {
                assertTrue(feeCount < 2);
                (uint256 totalFeeAmt, uint256 protocolFeeAmt) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(totalFeeAmt, feeCount == 0 ? 663 : 1_326);
                assertEq(protocolFeeAmt, 0);
                feeIndices[feeCount++] = i;
            }
        }
        assertEq(transferCount, 4);
        assertEq(feeCount, 2);
        assertTrue(transferIndices[0] < transferIndices[1]);
        assertTrue(transferIndices[1] < transferIndices[2]);
        assertTrue(transferIndices[2] < feeIndices[0]);
        assertTrue(feeIndices[0] < transferIndices[3]);
        assertTrue(transferIndices[3] < feeIndices[1]);
    }

    function testMint2PerSideFloorGoldenVector() public {
        _seed(9_581_311_974_479, 0, 33_850_817_003_440, 271_549_615);
        MockReserveTranche srLatest = _addMint2Tranche(sr, 3_187_156_008_450, 3_149_185_188_264, 42_592_294, 0, true);
        _addMint2Tranche(sr, 3_133_547_705_520, 3_133_547_705_520, 41_875_890, 0, true);
        _addMint2Tranche(sr, 3_392_625_737_181, 3_392_625_737_181, 45_338_138, 0, true);
        MockReserveTranche jrLatest =
            _addMint2Tranche(jr, 3_187_156_008_453, 3_149_185_188_266, 41_344_688, 2_030_175_726_564_921_717, false);
        _addMint2Tranche(jr, 3_133_547_705_527, 3_133_547_705_527, 35_357_092, 2_184_370_309_639_718_108, false);
        _addMint2Tranche(jr, 3_392_625_573_183, 3_392_625_573_183, 38_706_913, 2_171_318_880_428_413_397, false);
        MockPhase1BIssuer issuer = new MockPhase1BIssuer(address(srLatest), address(jrLatest));
        controller.updateIssuer(address(issuer));
        feePolicy.setFees(2_515_394_810_867_535, 2_515_394_810_867_535, 0);
        (uint256 subDR, uint256 vmDR) = controller.systemDeviations();
        assertEq(subDR, 1_049_678_446_100_688_299);
        assertEq(vmDR, 1_000_925_650_943_956_250);

        vm.startPrank(USER);
        srLatest.approve(address(controller), type(uint256).max);
        jrLatest.approve(address(controller), type(uint256).max);
        (uint256 srOut, uint256 jrOut, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) = controller.mint2(
            PerpController.TokenAmount(address(srLatest), 37_970_820_186),
            PerpController.TokenAmount(address(jrLatest), 37_970_820_187),
            0,
            0
        );
        vm.stopPrank();

        assertEq(srOut, 37_507_090_992);
        assertEq(jrOut, 43_035_866_540);
        assertEq(srFee.totalFeePerc, 2_515_394_810_867_535);
        assertEq(jrFee.totalFeePerc, 2_515_394_810_867_535);
        assertEq(sr.balanceOf(address(controller)), 94_583_055);
        assertEq(jr.balanceOf(address(controller)), 108_525_179);
        assertEq(issuer.issueCalls(), 1);
    }

    function testFlashMint2ProtocolSplitGoldenVector() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setFees(41_476_256_828_777_681, 41_476_256_828_777_681, 50_000_000_000_000);
        underlying.mint(USER, 150_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        (uint256 srOut, uint256 jrOut,,) = controller.flashMint2(50_000_000, 100_000_000, 0, 0);
        vm.stopPrank();
        assertEq(srOut, 3_551_428_406_798);
        assertEq(jrOut, 8_395_779_616_465);
        assertEq(controller.collectedFeeBal(address(sr)), 153_488_514_330);
        assertEq(controller.protocolFeeBals(address(sr)), 185_255_108);
        assertEq(controller.collectedFeeBal(address(jr)), 362_855_615_364);
        assertEq(controller.protocolFeeBals(address(jr)), 437_953_659);
        assertEq(sr.balanceOf(address(controller)), 153_673_769_438);
        assertEq(jr.balanceOf(address(controller)), 363_293_569_023);

        vm.expectRevert(PerpController.UnauthorizedCall.selector);
        controller.pullProtocolFees(address(sr), USER, 1);
        address collector = feePolicy.protocolFeeCollector();
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        vm.prank(collector);
        controller.pullProtocolFees(address(jr), USER, 437_953_660);
        vm.prank(collector);
        controller.pullProtocolFees(address(jr), USER, 437_953_659);
        assertEq(controller.protocolFeeBals(address(jr)), 0);
    }

    function testRedeem2FloorsAndRetainsFeePerps() public {
        _seed(90_000, 100_000, 180_000, 200_000);
        feePolicy.setFees(1e17, 1e17, 5e16);
        vm.prank(address(controller));
        sr.mintTo(USER, 10_000);
        vm.prank(address(controller));
        jr.mintTo(USER, 20_000);
        vm.startPrank(USER);
        sr.approve(address(controller), type(uint256).max);
        jr.approve(address(controller), type(uint256).max);
        (PerpBalancer.ReserveAmounts memory srOut, PerpBalancer.ReserveAmounts memory jrOut,,) =
            controller.redeem2(10_000, 20_000, 27_000);
        vm.stopPrank();
        assertEq(srOut.underlyingAmt, 9_000);
        assertEq(jrOut.underlyingAmt, 18_000);
        assertEq(sr.totalSupply(), 91_000);
        assertEq(jr.totalSupply(), 182_000);
        assertEq(sr.balanceOf(address(controller)), 1_000);
        assertEq(jr.balanceOf(address(controller)), 2_000);
        assertEq(controller.collectedFeeBal(address(sr)), 500);
        assertEq(controller.protocolFeeBals(address(sr)), 500);
    }

    function testRedeem2SecondFeeBearingGoldenVector() public {
        _seed(99_000, 100_000, 198_000, 200_000);
        feePolicy.setFees(1e17, 1e17, 5e16);
        vm.prank(address(controller));
        sr.mintTo(USER, 1_000);
        vm.prank(address(controller));
        jr.mintTo(USER, 2_000);
        vm.startPrank(USER);
        sr.approve(address(controller), type(uint256).max);
        jr.approve(address(controller), type(uint256).max);
        (PerpBalancer.ReserveAmounts memory srOut, PerpBalancer.ReserveAmounts memory jrOut,,) =
            controller.redeem2(1_000, 2_000, 2_700);
        vm.stopPrank();
        assertEq(srOut.underlyingAmt, 900);
        assertEq(jrOut.underlyingAmt, 1_800);
        assertEq(sr.totalSupply(), 99_100);
        assertEq(jr.totalSupply(), 198_200);
        assertEq(controller.collectedFeeBal(address(sr)), 50);
        assertEq(controller.protocolFeeBals(address(sr)), 50);
        assertEq(controller.collectedFeeBal(address(jr)), 100);
        assertEq(controller.protocolFeeBals(address(jr)), 100);
    }

    function testZeroInputSideFeeDoesNotDisableOperations() public {
        _assertZeroInputSideFeeIgnored(true, 0);
        _assertZeroInputSideFeeIgnored(true, 1);
        _assertZeroInputSideFeeIgnored(true, 2);
        _assertZeroInputSideFeeIgnored(false, 0);
        _assertZeroInputSideFeeIgnored(false, 1);
        _assertZeroInputSideFeeIgnored(false, 2);
    }

    function testFlashMint2IssuesOnlyForSeniorInput() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        MockPhase1BIssuer issuer = _configureMockIssuer();
        underlying.mint(USER, 1_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        (uint256 srOut, uint256 jrOut,,) = controller.flashMint2(1_000_000, 0, 0, 0);
        vm.stopPrank();
        assertGt(srOut, 0);
        assertEq(jrOut, 0);
        assertEq(issuer.issueCalls(), 1);
    }

    function testFlashMint2JuniorOnlyDoesNotIssue() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        MockPhase1BIssuer issuer = _configureMockIssuer();
        underlying.mint(USER, 1_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        (uint256 srOut, uint256 jrOut,,) = controller.flashMint2(0, 1_000_000, 0, 0);
        vm.stopPrank();
        assertEq(srOut, 0);
        assertGt(jrOut, 0);
        assertEq(issuer.issueCalls(), 0);
    }

    function testMint2RejectsRegisteredNonLatestTranche() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        MockReserveTranche oldSr = _addMint2Tranche(sr, 1, 0, 1, 0, true);
        _addMint2Tranche(jr, 1, 0, 1, 0, false);
        _configureMockIssuer();
        vm.expectRevert(PerpController.UnexpectedAsset.selector);
        vm.prank(USER);
        controller.mint2(PerpController.TokenAmount(address(oldSr), 1), PerpController.TokenAmount(address(0), 0), 0, 0);
    }

    function testAumFeeZeroAmountMintsZeroAndEmits() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setAum(1, 1);
        uint256 srSupply = sr.totalSupply();
        uint256 jrSupply = jr.totalSupply();
        vm.warp(64_800 + 86_400 * 10);
        vm.recordLogs();
        controller.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 aumEventCount;
        uint256 zeroMintCount;
        bytes32 aumTopic = keccak256("AumFees(address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(controller) && logs[i].topics.length != 0 && logs[i].topics[0] == aumTopic) {
                ++aumEventCount;
                uint256 amount =
                    logs[i].topics.length > 1 ? abi.decode(logs[i].data, (uint256)) : _decodeAumAmount(logs[i].data);
                assertEq(amount, 0);
            }
            if (
                (logs[i].emitter == address(sr) || logs[i].emitter == address(jr)) && logs[i].topics.length == 3
                    && logs[i].topics[0] == transferTopic && address(uint160(uint256(logs[i].topics[1]))) == address(0)
            ) {
                ++zeroMintCount;
            }
        }
        assertEq(aumEventCount, 2);
        assertEq(zeroMintCount, 2);
        assertEq(sr.totalSupply(), srSupply);
        assertEq(jr.totalSupply(), jrSupply);
    }

    function testAumFeeZeroRateDoesNotEmit() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setAum(0, 0);
        vm.warp(64_800 + 86_400 * 10);
        vm.recordLogs();
        controller.rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 aumTopic = keccak256("AumFees(address,uint256)");
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        uint256 zeroMintCount;
        for (uint256 i; i < logs.length; ++i) {
            assertFalse(
                logs[i].emitter == address(controller) && logs[i].topics.length != 0 && logs[i].topics[0] == aumTopic
            );
            if (
                (logs[i].emitter == address(sr) || logs[i].emitter == address(jr)) && logs[i].topics.length == 3
                    && logs[i].topics[0] == transferTopic && address(uint160(uint256(logs[i].topics[1]))) == address(0)
            ) {
                ++zeroMintCount;
            }
        }
        assertEq(zeroMintCount, 0);
    }

    function testValueCapBalancedPreSubWadAboveCapReverts() public {
        _seed(1_000_000, 100_000_000, 1_000_000, 100_000_000);
        feePolicy.setFees(0, 0, 0);
        controller.updateDRTargets(WAD, WAD);
        controller.updateValueCap(199_999_999);
        (uint256 preSub,) = controller.systemDeviations();
        assertEq(preSub, WAD);
        underlying.mint(USER, 1_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        vm.expectRevert(PerpController.ValueCapExceeded.selector);
        controller.flashMint2(1_000, 0, 0, 0);
        vm.stopPrank();
    }

    function testValueCapUnderCapPostOverCapAllowsOnlyCorrectiveSide() public {
        _seed(1_000_000, 100_000_000, 1_000_000, 106_423_365);
        feePolicy.setFees(0, 0, 0);
        controller.updateDRTargets(WAD, WAD);
        (uint256 preSub,) = controller.systemDeviations();
        assertGt(preSub, WAD);
        uint256 preValue = 206_423_365;
        controller.updateValueCap(preValue);
        assertGt(preValue + 1, controller.valueCap());
        underlying.mint(USER, 2);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        vm.expectRevert(PerpController.ValueCapExceeded.selector);
        controller.flashMint2(0, 1, 0, 0);
        controller.flashMint2(1, 0, 0, 0);
        vm.stopPrank();
        (PerpController.SystemState memory state,,) = controller.systemReserveState();
        assertGt(state.perpSr.reserveValue + state.perpJr.reserveValue, controller.valueCap());
    }

    function testRebalanceAllowsRandomCallerWhenKeeperDiffers() public {
        _assertPermissionlessRebalance(USER);
    }

    function testRebalanceAllowsOwnerCallerWhenKeeperDiffers() public {
        _assertPermissionlessRebalance(address(this));
    }

    function testRebalanceAllowsConfiguredKeeperCaller() public {
        _assertPermissionlessRebalance(address(0xCAFE));
    }

    function testRebalanceCooldownWindowStartAndFrequencyBoundaries() public {
        _assertRebalanceCooldownBoundary(0);
        _assertRebalanceCooldownBoundary(1);
        _assertRebalanceCooldownBoundary(2);
    }

    function testRebalanceSecondCallInSameWindowIsTooRecent() public {
        vm.warp(64_800 + 86_400 * 20);
        controller.rebalance();
        vm.expectRevert(PerpController.LastRebalanceTooRecent.selector);
        controller.rebalance();
    }

    function testRebalanceSettlesCollectedFeesAndMintsAumOnZeroPlan() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setFees(41_476_256_828_777_681, 41_476_256_828_777_681, 50_000_000_000_000);
        feePolicy.setAum(1e17, 5e16);
        underlying.mint(USER, 150_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        controller.flashMint2(50_000_000, 100_000_000, 0, 0);
        vm.stopPrank();

        uint256 srBefore = sr.totalSupply();
        uint256 jrBefore = jr.totalSupply();
        uint256 srProtocol = controller.protocolFeeBals(address(sr));
        uint256 jrProtocol = controller.protocolFeeBals(address(jr));
        uint256 srCollected = controller.collectedFeeBal(address(sr));
        uint256 jrCollected = controller.collectedFeeBal(address(jr));
        vm.warp(64_800 + 86_400 * 10);
        controller.rebalance();

        uint256 srAfterSettlement = srBefore - srCollected;
        uint256 jrAfterSettlement = jrBefore - jrCollected;
        assertEq(sr.totalSupply(), srAfterSettlement + _mulDiv(srAfterSettlement, 1e17, 9e17));
        assertEq(jr.totalSupply(), jrAfterSettlement + _mulDiv(jrAfterSettlement, 5e16, 95e16));
        assertEq(sr.balanceOf(address(controller)), srProtocol);
        assertEq(jr.balanceOf(address(controller)), jrProtocol);
        assertEq(controller.collectedFeeBal(address(sr)), 0);
        assertEq(controller.collectedFeeBal(address(jr)), 0);
        assertEq(controller.protocolFeeBals(address(sr)), srProtocol);
        assertEq(controller.protocolFeeBals(address(jr)), jrProtocol);
    }

    function testRebalanceOrdersFeeSettlementPlanAndAumLogs() public {
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setFees(41_476_256_828_777_681, 41_476_256_828_777_681, 50_000_000_000_000);
        feePolicy.setAum(1e17, 5e16);
        feePolicy.setRebalance(100, false);
        underlying.mint(USER, 150_000_000);
        vm.startPrank(USER);
        underlying.approve(address(controller), type(uint256).max);
        controller.flashMint2(50_000_000, 100_000_000, 0, 0);
        controller.flashRedeem2(1_000_000_000, 1_000_000_000, 0);
        vm.stopPrank();

        RebalanceFees memory fees = RebalanceFees({
            sr: controller.collectedFeeBal(address(sr)),
            jr: controller.collectedFeeBal(address(jr)),
            underlying: controller.collectedFeeBal(address(underlying))
        });
        assertGt(fees.sr, 0);
        assertGt(fees.jr, 0);
        assertGt(fees.underlying, 0);

        vm.warp(64_800 + 86_400 * 10);
        vm.recordLogs();
        controller.rebalance();
        _assertRebalanceLogOrder(vm.getRecordedLogs(), fees);
    }

    function testValueCapCorrectiveBoundaries() public {
        _assertValueCapCase(true, 6_423_365, false);
        _assertValueCapCase(true, 6_423_366, true);
        _assertValueCapCase(false, 10_184_377, false);
        _assertValueCapCase(false, 10_184_378, true);
    }

    function testJrLiquidityAndFeePriority() public {
        _seed(1_000_000, 100_000, 1_000_000, 100_000);
        vm.prank(address(controller));
        jr.mintTo(USER, 10_000);
        controller.updateLiquidityThresholds(99_901, 0);
        vm.expectRevert(PerpController.InsufficientLiquidity.selector);
        vm.prank(USER);
        controller.flashRedeem2(0, 10_000, 0);

        feePolicy.setFees(WAD, WAD, 0);
        vm.expectRevert(PerpController.OpDisabled.selector);
        vm.prank(USER);
        controller.flashRedeem2(0, 10_000, 0);
    }

    function testPauseSelectorsAndRebalanceWindowEdges() public {
        controller.pauseUserOps(true);
        vm.expectRevert(PerpController.UserOpsPaused.selector);
        controller.flashMint2(0, 0, 0, 0);
        controller.pauseUserOps(false);
        controller.pauseSystemOps(true);
        vm.expectRevert(PerpController.SystemOpsPaused.selector);
        controller.rebalance();
        controller.pauseSystemOps(false);

        uint256 center = 64_800 + 86_400 * 20;
        uint256[5] memory timestamps = [center - 1, center, center + 3_599, center + 3_600, center + 3_601];
        for (uint256 i; i < timestamps.length; ++i) {
            (MockERC20 u, PerpToken s, PerpToken j, PerpController c, MockPhase1BFeePolicy f) = _deployFixture();
            u;
            s;
            j;
            f;
            c.updateRebalanceWindow(86_400, 64_800, 3_600);
            vm.warp(timestamps[i]);
            if (i == 0 || i >= 3) vm.expectRevert(PerpController.OutOfRebalanceWindow.selector);
            c.rebalance();
        }
    }

    function testControllerAdminRoleAndValidationMatrix() public {
        address keeper = address(0xCA11);
        address random = address(0xBEEF);
        controller.updateKeeper(keeper);

        bytes memory pauseUser = abi.encodeWithSignature("pauseUserOps(bool)", true);
        bytes memory pauseSystem = abi.encodeWithSignature("pauseSystemOps(bool)", true);
        bytes4 unauthorized = PerpController.UnauthorizedCall.selector;
        _assertAdminCall(address(controller), address(this), pauseUser, false, unauthorized);
        _assertAdminCall(address(controller), keeper, pauseUser, true, bytes4(0));
        _assertAdminCall(address(controller), random, pauseUser, false, unauthorized);
        assertTrue(controller.userOpsPaused());
        _assertAdminCall(address(controller), address(this), pauseSystem, false, unauthorized);
        _assertAdminCall(address(controller), keeper, pauseSystem, true, bytes4(0));
        _assertAdminCall(address(controller), random, pauseSystem, false, unauthorized);
        assertTrue(controller.systemOpsPaused());

        bytes memory updateValueCap = abi.encodeWithSignature("updateValueCap(uint256)", 123);
        _assertAdminCall(address(controller), address(this), updateValueCap, false, unauthorized);
        _assertAdminCall(address(controller), keeper, updateValueCap, true, bytes4(0));
        _assertAdminCall(address(controller), random, updateValueCap, false, unauthorized);
        assertEq(controller.valueCap(), 123);

        bytes[] memory ownerOnlySetters = new bytes[](9);
        ownerOnlySetters[0] = abi.encodeWithSignature(
            "updateDRTargets(uint256,uint256)", controller.targetSystemRatio(), controller.targetPerpJrVM()
        );
        ownerOnlySetters[1] = abi.encodeWithSignature("updateFeePolicy(address)", address(feePolicy));
        ownerOnlySetters[2] = abi.encodeWithSignature("updateIssuer(address)", address(0x1234));
        ownerOnlySetters[3] = abi.encodeWithSignature("updateKeeper(address)", keeper);
        ownerOnlySetters[4] = abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 0, 1e18);
        ownerOnlySetters[5] = abi.encodeWithSignature("updateMinCleanupVal(uint256)", 123);
        ownerOnlySetters[6] = abi.encodeWithSignature("updatePerpBalancer(address)", address(0x9999));
        ownerOnlySetters[7] = abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_400, 3_600);
        ownerOnlySetters[8] = abi.encodeWithSignature("updateRolloverEligibility(uint32)", 123);
        bytes4 ownerUnauthorized = Ownable.OwnableUnauthorizedAccount.selector;
        for (uint256 i; i < ownerOnlySetters.length; ++i) {
            _assertAdminCall(address(controller), address(this), ownerOnlySetters[i], true, bytes4(0));
            _assertAdminCall(address(controller), keeper, ownerOnlySetters[i], false, ownerUnauthorized);
            _assertAdminCall(address(controller), random, ownerOnlySetters[i], false, ownerUnauthorized);
        }

        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateRebalanceWindow(0, 0, 1);
        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateRebalanceWindow(86_400, 86_401, 3_600);
        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateRebalanceWindow(86_400, 64_800, 0);
        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateRebalanceWindow(86_400, 64_800, 86_401);
        controller.updateRebalanceWindow(86_400, 86_400, 3_600);
        assertEq(controller.rebalanceWindowOffsetSec(), 86_400);

        vm.expectRevert(PerpController.InvalidPerc.selector);
        controller.updateLiquidityThresholds(0, uint64(WAD + 1));
        controller.updateLiquidityThresholds(0, uint64(WAD));

        uint256 targetSystemRatio = controller.targetSystemRatio();
        uint256 targetPerpJrVM = controller.targetPerpJrVM();
        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateDRTargets(0, targetPerpJrVM);
        vm.expectRevert(PerpController.InvalidParamDefn.selector);
        controller.updateDRTargets(targetSystemRatio, 0);
        controller.updateDRTargets(targetSystemRatio, targetPerpJrVM);
    }

    function testPerpPermissionsCapDuplicateAndJuniorApproval() public {
        address manager = address(0x1234);
        PerpToken token = new PerpToken("SR", "SR", address(underlying), manager, address(this), false, address(this));
        PerpToken junior = new PerpToken("JR", "JR", address(underlying), manager, address(this), true, address(this));
        assertEq(token.decimals(), 8);
        assertEq(token.maxTrancheCount(), 50);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(PerpToken.UnauthorizedCall.selector);
        token.registerTranche(address(0x100));
        vm.stopPrank();
        for (uint160 i = 1; i <= 50; ++i) {
            token.registerTranche(address(i));
        }
        token.registerTranche(address(1));
        assertEq(token.trancheTokens().length, 50);
        vm.expectRevert(PerpToken.ReserveOverflow.selector);
        token.registerTranche(address(1000));

        (bool srApproval,) = address(token).call(abi.encodeWithSignature("primeApproval(address)", manager));
        assertFalse(srApproval);
        (bool jrApproval,) = address(junior).call(abi.encodeWithSignature("primeApproval(address)", manager));
        assertTrue(jrApproval);
        assertEq(underlying.allowance(address(junior), manager), type(uint256).max);
        (bool revoked,) = address(junior).call(abi.encodeWithSignature("revokeApproval(address)", manager));
        assertTrue(revoked);
        assertEq(underlying.allowance(address(junior), manager), 0);
    }

    function testPerpControllerReplacementPermissionMatrix() public {
        address oldController = address(0xD00D);
        address newController = address(0xCA11);
        address random = address(0xBEEF);
        address manager = address(0x1234);
        PerpToken senior = new PerpToken(
            "SR", "SR", address(underlying), manager, oldController, false, address(this)
        );
        PerpToken junior = new PerpToken(
            "JR", "JR", address(underlying), manager, oldController, true, address(this)
        );
        MockReserveTranche tranche = new MockReserveTranche();
        senior.updateController(newController);
        junior.updateController(newController);

        address[4] memory callers = [address(this), oldController, newController, random];
        bytes memory updateCall = abi.encodeWithSignature("updateController(address)", newController);
        for (uint256 i; i < callers.length; ++i) {
            address caller = callers[i];
            vm.prank(caller);
            (bool success, bytes memory returndata) = address(senior).call(updateCall);
            if (caller == address(this)) {
                assertTrue(success);
            } else {
                assertFalse(success);
                assertEq(_selector(returndata), Ownable.OwnableUnauthorizedAccount.selector);
            }

            vm.prank(caller);
            (success, returndata) = address(junior).call(updateCall);
            if (caller == address(this)) {
                assertTrue(success);
            } else {
                assertFalse(success);
                assertEq(_selector(returndata), Ownable.OwnableUnauthorizedAccount.selector);
            }
        }

        PerpBalancer.ReserveAmounts memory emptyAmounts;
        emptyAmounts.trancheAmts = new PerpBalancer.TokenAmount[](0);
        bytes[] memory seniorActions = new bytes[](6);
        seniorActions[0] = abi.encodeWithSignature("mintTo(address,uint256)", USER, 0);
        seniorActions[1] = abi.encodeWithSignature("burnFrom(address,uint256)", USER, 0);
        seniorActions[2] = abi.encodeWithSignature("registerTranche(address)", address(tranche));
        seniorActions[3] =
            abi.encodeWithSignature("transferReservesTo(address,(uint256,(address,uint256)[]))", USER, emptyAmounts);
        seniorActions[4] = abi.encodeWithSignature("handleTransferReservesIn((uint256,(address,uint256)[]))", emptyAmounts);
        seniorActions[5] = abi.encodeWithSignature("logBalance(address)", address(underlying));

        _assertControllerActionMatrix(address(senior), callers, seniorActions, newController);
        _assertControllerActionMatrix(address(junior), callers, seniorActions, newController);

        bytes[] memory juniorApprovalActions = new bytes[](2);
        juniorApprovalActions[0] = abi.encodeWithSignature("primeApproval(address)", manager);
        juniorApprovalActions[1] = abi.encodeWithSignature("revokeApproval(address)", manager);
        _assertControllerActionMatrix(address(junior), callers, juniorApprovalActions, newController);
        assertEq(underlying.allowance(address(junior), manager), 0);

        vm.prank(newController);
        (bool primeSuccess,) = address(junior).call(abi.encodeWithSignature("primeApproval(address)", manager));
        assertTrue(primeSuccess);
        assertEq(underlying.allowance(address(junior), manager), type(uint256).max);
        vm.prank(newController);
        (bool revokeSuccess,) = address(junior).call(abi.encodeWithSignature("revokeApproval(address)", manager));
        assertTrue(revokeSuccess);
        assertEq(underlying.allowance(address(junior), manager), 0);

        (bool seniorPrimeSuccess, bytes memory seniorPrimeReturndata) =
            address(senior).call(abi.encodeWithSignature("primeApproval(address)", manager));
        assertFalse(seniorPrimeSuccess);
        assertEq(seniorPrimeReturndata.length, 0);
    }

    function testPerpOwnable2StepAndHolderTransfers() public {
        address oldController = address(0xD00D);
        address nextOwner = address(0xCA11);
        PerpToken token = new PerpToken(
            "SR", "SR", address(underlying), address(0x1234), oldController, false, address(this)
        );
        assertEq(token.decimals(), 8);
        token.transferOwnership(nextOwner);
        assertEq(token.pendingOwner(), nextOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, USER));
        vm.prank(USER);
        token.acceptOwnership();
        vm.prank(nextOwner);
        token.acceptOwnership();
        assertEq(token.owner(), nextOwner);
        vm.prank(nextOwner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));

        PerpToken transferable = new PerpToken(
            "SR", "SR", address(underlying), address(0x1234), address(this), false, address(this)
        );
        assertEq(transferable.decimals(), 8);
        transferable.mintTo(USER, 1_000);
        vm.startPrank(USER);
        transferable.transfer(address(0xCAFE), 400);
        transferable.approve(address(0xD00D), 500);
        vm.stopPrank();
        vm.prank(address(0xD00D));
        transferable.transferFrom(USER, address(this), 300);
        assertEq(transferable.balanceOf(USER), 300);
        assertEq(transferable.balanceOf(address(0xCAFE)), 400);
        assertEq(transferable.balanceOf(address(this)), 300);
    }

    function testReserveDataTrancheValueFloors() public {
        PerpToken token =
            new PerpToken("SR", "SR", address(underlying), address(0xD00D), address(this), false, address(this));
        MockReserveTranche tranche = new MockReserveTranche();
        tranche.setData(
            IBondsManager.TrancheData({
                trancheSupply: 3,
                trancheClaim: 2,
                totalClaim: 3,
                volatilityMultiplier: WAD,
                underlyingOpenPrice: WAD,
                isMature: false,
                secondsToMaturity: 1,
                trancheRatio: 5e17,
                valueRatio: 5e17,
                bondID: bytes32(uint256(1)),
                isSenior: true,
                tranche: address(tranche),
                counterpart: address(0),
                manager: address(0xD00D)
            })
        );
        token.registerTranche(address(tranche));
        tranche.mint(address(token), 5);
        underlying.mint(address(token), 123);
        (bool reservesSuccess, bytes memory reservesReturndata) =
            address(token).staticcall(abi.encodeWithSignature("reserves()"));
        assertTrue(reservesSuccess);
        IPerpToken.ReserveTokens memory reserves =
            abi.decode(reservesReturndata, (IPerpToken.ReserveTokens));
        assertEq(reserves.underlyingBal, 123);
        assertEq(reserves.trancheTokens.length, 1);
        assertEq(reserves.trancheTokens[0].token, address(tranche));
        assertEq(reserves.trancheTokens[0].amount, 5);

        (bool reserveDataSuccess, bytes memory reserveDataReturndata) =
            address(token).staticcall(abi.encodeWithSignature("reserveData()"));
        assertTrue(reserveDataSuccess);
        PerpBalancer.ReserveData memory reserve =
            abi.decode(reserveDataReturndata, (PerpBalancer.ReserveData));
        assertEq(reserve.trancheData.length, 1);
        assertEq(reserve.trancheData[0].balance, 5);
        assertEq(reserve.trancheData[0].value, 3);
    }

    function _assertValueCapCase(bool srPayer, uint256 amount, bool shouldFail) private {
        (MockERC20 u, PerpToken s, PerpToken j, PerpController c, MockPhase1BFeePolicy f) = _deployFixture();
        f.setFees(0, 0, 0);
        c.updateDRTargets(WAD, WAD);
        c.updateValueCap(1);
        uint256 srReserve = 100_000_000;
        uint256 jrReserve = srPayer ? 106_423_365 : 89_815_623;
        u.mint(address(s), srReserve);
        u.mint(address(j), jrReserve);
        (uint256 preSub,) = c.systemDeviations();
        assertEq(srPayer ? preSub > WAD : preSub < WAD, true);
        vm.prank(address(c));
        s.mintTo(address(1), 1_000_000);
        vm.prank(address(c));
        j.mintTo(address(1), 1_000_000);
        u.mint(USER, amount);
        vm.startPrank(USER);
        u.approve(address(c), type(uint256).max);
        if (shouldFail) {
            vm.expectRevert(PerpController.ValueCapExceeded.selector);
        }
        c.flashMint2(srPayer ? amount : 0, srPayer ? 0 : amount, 0, 0);
        vm.stopPrank();
    }

    function _assertControllerActionMatrix(
        address target,
        address[4] memory callers,
        bytes[] memory actions,
        address expectedController
    ) private {
        for (uint256 i; i < actions.length; ++i) {
            for (uint256 j; j < callers.length; ++j) {
                vm.prank(callers[j]);
                (bool success, bytes memory returndata) = target.call(actions[i]);
                if (callers[j] == expectedController) {
                    assertTrue(success);
                } else {
                    assertFalse(success);
                    assertEq(_selector(returndata), PerpToken.UnauthorizedCall.selector);
                }
            }
        }
    }

    function _assertRebalanceLogOrder(Vm.Log[] memory logs, RebalanceFees memory fees) private {
        RebalanceLogState memory state;
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 rebalanceTopic = keccak256("Rebalance(uint256,bool)");
        bytes32 aumTopic = keccak256("AumFees(address,uint256)");
        bytes32 reserveSyncedTopic = keccak256("ReserveSynced(address,uint256)");

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0) continue;
            if (entry.topics[0] == transferTopic && entry.topics.length == 3) {
                _assertRebalanceTransfer(entry, fees, state);
            } else if (entry.emitter == address(controller) && entry.topics[0] == rebalanceTopic) {
                assertEq(state.stage, 3);
                (uint256 rebalanceValue, bool srPays) = abi.decode(entry.data, (uint256, bool));
                assertEq(rebalanceValue, 100);
                assertFalse(srPays);
                state.stage = 4;
            } else if (entry.emitter == address(controller) && entry.topics[0] == aumTopic) {
                _assertAumLog(entry, state);
            } else if (
                (entry.emitter == address(sr) || entry.emitter == address(jr))
                    && entry.topics[0] == reserveSyncedTopic
            ) {
                (address token, uint256 balance) = abi.decode(entry.data, (address, uint256));
                assertEq(token, address(underlying));
                assertGt(balance, 0);
                ++state.reserveSyncedCount;
            }
        }

        assertEq(state.stage, 6);
        assertEq(state.aumCount, 2);
        assertEq(state.reserveSyncedCount, 3);
    }

    function _assertRebalanceTransfer(
        Vm.Log memory entry,
        RebalanceFees memory fees,
        RebalanceLogState memory state
    ) private {
        address from = address(uint160(uint256(entry.topics[1])));
        address to = address(uint160(uint256(entry.topics[2])));
        uint256 amount = abi.decode(entry.data, (uint256));

        if (entry.emitter == address(sr) && from == address(controller) && to == address(0)) {
            assertEq(state.stage, 0);
            assertEq(amount, fees.sr);
            state.stage = 1;
        } else if (entry.emitter == address(jr) && from == address(controller) && to == address(0)) {
            assertEq(state.stage, 1);
            assertEq(amount, fees.jr);
            state.stage = 2;
        } else if (
            entry.emitter == address(underlying) && from == address(controller) && to == address(jr)
                && amount == fees.underlying
        ) {
            assertEq(state.stage, 2);
            state.stage = 3;
        } else if (
            entry.emitter == address(underlying) && from == address(jr) && to == address(sr) && amount == 100
        ) {
            assertEq(state.stage, 4);
            state.stage = 5;
        }
    }

    function _assertAumLog(Vm.Log memory entry, RebalanceLogState memory state) private {
        assertEq(state.stage, 5);
        address token = address(uint160(uint256(entry.topics[1])));
        uint256 amount = abi.decode(entry.data, (uint256));
        assertGt(amount, 0);
        if (state.aumCount == 0) assertEq(token, address(sr));
        else {
            assertEq(state.aumCount, 1);
            assertEq(token, address(jr));
        }
        ++state.aumCount;
        if (state.aumCount == 2) state.stage = 6;
    }

    function _assertAdminCall(
        address target,
        address caller,
        bytes memory callData,
        bool expectedSuccess,
        bytes4 expectedSelector
    ) private {
        vm.prank(caller);
        (bool success, bytes memory returndata) = target.call(callData);
        assertEq(success, expectedSuccess);
        if (!expectedSuccess) assertEq(_selector(returndata), expectedSelector);
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }

    function _seed(uint256 srSupply, uint256 srReserve, uint256 jrSupply, uint256 jrReserve) private {
        underlying.mint(address(sr), srReserve);
        underlying.mint(address(jr), jrReserve);
        vm.prank(address(controller));
        sr.mintTo(address(1), srSupply);
        vm.prank(address(controller));
        jr.mintTo(address(1), jrSupply);
    }

    function _assertZeroInputSideFeeIgnored(bool srInput, uint8 operation) private {
        (underlying, sr, jr, controller, feePolicy) = _deployFixture();
        _seed(9_581_311_974_479, 129_298_890, 33_850_817_003_440, 386_465_740);
        feePolicy.setFees(srInput ? 0 : WAD, srInput ? WAD : 0, 0);

        if (operation == 0) {
            underlying.mint(USER, 1_000_000);
            vm.startPrank(USER);
            underlying.approve(address(controller), type(uint256).max);
            (uint256 srOut, uint256 jrOut, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
                controller.flashMint2(srInput ? 1_000_000 : 0, srInput ? 0 : 1_000_000, 0, 0);
            vm.stopPrank();
            if (srInput) {
                assertGt(srOut, 0);
                assertEq(jrOut, 0);
            } else {
                assertEq(srOut, 0);
                assertGt(jrOut, 0);
            }
            assertEq(srFee.totalFeePerc, srInput ? 0 : WAD);
            assertEq(jrFee.totalFeePerc, srInput ? WAD : 0);
            return;
        }

        vm.prank(address(controller));
        if (srInput) sr.mintTo(USER, 1_000_000);
        else jr.mintTo(USER, 1_000_000);

        vm.startPrank(USER);
        sr.approve(address(controller), type(uint256).max);
        jr.approve(address(controller), type(uint256).max);
        if (operation == 1) {
            (uint256 underlyingOut, PerpController.FeePerc memory srFee, PerpController.FeePerc memory jrFee) =
                controller.flashRedeem2(srInput ? 1_000_000 : 0, srInput ? 0 : 1_000_000, 0);
            assertGt(underlyingOut, 0);
            assertEq(srFee.totalFeePerc, srInput ? 0 : WAD);
            assertEq(jrFee.totalFeePerc, srInput ? WAD : 0);
        } else {
            (
                PerpBalancer.ReserveAmounts memory srOut,
                PerpBalancer.ReserveAmounts memory jrOut,
                PerpController.FeePerc memory srFee,
                PerpController.FeePerc memory jrFee
            ) = controller.redeem2(srInput ? 1_000_000 : 0, srInput ? 0 : 1_000_000, 0);
            assertGt(srInput ? srOut.underlyingAmt : jrOut.underlyingAmt, 0);
            assertEq(srFee.totalFeePerc, srInput ? 0 : WAD);
            assertEq(jrFee.totalFeePerc, srInput ? WAD : 0);
        }
        vm.stopPrank();
    }

    function _configureMockIssuer() private returns (MockPhase1BIssuer issuer) {
        MockReserveTranche srLatest = _addMint2Tranche(sr, 1, 0, 1, 0, true);
        MockReserveTranche jrLatest = _addMint2Tranche(jr, 1, 0, 1, 0, false);
        issuer = new MockPhase1BIssuer(address(srLatest), address(jrLatest));
        controller.updateIssuer(address(issuer));
    }

    function _decodeAumAmount(bytes memory data) private pure returns (uint256 amount) {
        (, amount) = abi.decode(data, (address, uint256));
    }

    function _assertPermissionlessRebalance(address caller) private {
        address configuredKeeper = address(0xCAFE);
        controller.updateKeeper(configuredKeeper);
        uint256 timestamp = 64_800 + 86_400 * 10;
        vm.warp(timestamp);
        (uint64 windowStart,) = controller.rebalanceWindow(timestamp);
        vm.prank(caller);
        controller.rebalance();
        assertEq(controller.lastRebalanceTimestampSec(), windowStart);
    }

    function _assertRebalanceCooldownBoundary(uint8 probeCase) private {
        (underlying, sr, jr, controller, feePolicy) = _deployFixture();
        uint256 frequency = controller.rebalanceFreqSec();
        uint256 start = 64_800 + frequency * (20 + probeCase);
        uint256 end = start + controller.rebalanceWindowLengthSec();
        vm.warp(end - 1);
        controller.rebalance();
        assertEq(controller.lastRebalanceTimestampSec(), start);

        uint256 timestamp =
            probeCase == 0 ? start + frequency : probeCase == 1 ? start + frequency + 1 : start + frequency - 1;
        vm.warp(timestamp);
        if (probeCase == 2) vm.expectRevert(PerpController.LastRebalanceTooRecent.selector);
        controller.rebalance();
        if (probeCase != 2) {
            (uint64 windowStart,) = controller.rebalanceWindow(timestamp);
            assertEq(controller.lastRebalanceTimestampSec(), windowStart);
        }
    }

    function _addMint2Tranche(
        PerpToken perp,
        uint256 trancheSupply,
        uint256 perpBalance,
        uint256 trancheClaim,
        uint256 volatilityMultiplier,
        bool isSenior
    ) private returns (MockReserveTranche tranche) {
        tranche = new MockReserveTranche();
        tranche.setData(
            IBondsManager.TrancheData({
                trancheSupply: trancheSupply,
                trancheClaim: trancheClaim,
                totalClaim: 0,
                volatilityMultiplier: volatilityMultiplier,
                underlyingOpenPrice: 0,
                isMature: false,
                secondsToMaturity: 0,
                trancheRatio: 0,
                valueRatio: 0,
                bondID: bytes32(0),
                isSenior: isSenior,
                tranche: address(tranche),
                counterpart: address(0),
                manager: address(0)
            })
        );
        vm.prank(address(controller));
        perp.registerTranche(address(tranche));
        tranche.mint(address(perp), perpBalance);
        if (trancheSupply > perpBalance) tranche.mint(USER, trancheSupply - perpBalance);
    }

    function _assertFlashRedeem2Gross(uint256 totalSupply, uint256 reserve, uint256 shares, bool srSide) private {
        (underlying, sr, jr, controller, feePolicy) = _deployFixture();
        feePolicy.setFees(0, 0, 0);
        underlying.mint(address(sr), srSide ? reserve : 130_298_890);
        underlying.mint(address(jr), srSide ? 386_465_740 : reserve);
        vm.prank(address(controller));
        sr.mintTo(address(1), srSide ? totalSupply - shares : 9_655_414_018_003);
        vm.prank(address(controller));
        sr.mintTo(USER, srSide ? shares : 0);
        vm.prank(address(controller));
        jr.mintTo(address(1), srSide ? 33_850_817_003_440 : totalSupply - shares);
        vm.prank(address(controller));
        jr.mintTo(USER, srSide ? 0 : shares);
        vm.startPrank(USER);
        sr.approve(address(controller), type(uint256).max);
        jr.approve(address(controller), type(uint256).max);
        (uint256 underlyingOut,,) = controller.flashRedeem2(srSide ? shares : 0, srSide ? 0 : shares, 0);
        vm.stopPrank();
        assertEq(underlyingOut, 999_999);
        assertEq(underlying.balanceOf(USER), 999_999);
    }

    function _deployFixture()
        private
        returns (MockERC20 u, PerpToken s, PerpToken j, PerpController c, MockPhase1BFeePolicy f)
    {
        u = new MockERC20("Underlying", "UND", 8);
        s = new PerpToken("Senior Perp", "pSR", address(u), address(0xD00D), address(0), false, address(this));
        j = new PerpToken("Junior Perp", "pJR", address(u), address(0xD00D), address(0), true, address(this));
        PerpController implementation = new PerpController();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            abi.encodeCall(PerpController.init, (address(u), address(s), address(j)))
        );
        c = PerpController(address(proxy));
        s.updateController(address(c));
        j.updateController(address(c));
        f = new MockPhase1BFeePolicy();
        c.updateFeePolicy(address(f));
        c.updatePerpBalancer(address(new PerpBalancer()));
    }

    function _mulDiv(uint256 x, uint256 y, uint256 denominator) private pure returns (uint256) {
        return x * y / denominator;
    }
}
