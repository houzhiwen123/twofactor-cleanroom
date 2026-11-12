// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {FeePolicy} from "../../src/policy/FeePolicy.sol";

interface ITargetControllerExitFeeProbe {
    struct TrancheData {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct ReserveData {
        uint256 underlyingBal;
        ReserveTrancheData[] trancheData;
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

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);

    function systemReserveState()
        external
        view
        returns (SystemState memory state, ReserveData memory perpSrRd, ReserveData memory perpJrRd);
}

interface IERC20SupplyProbe {
    function totalSupply() external view returns (uint256);
}

/// @notice Public-Base, read-only differential probe. Run only on the fixed fork block below.
/// @dev The 40 vectors are copied byte-for-byte from evidence/genesis-exit-fee-curve.json.
///      They are LOCAL CLEANROOM / BNB-DESIGN inputs, not target execution evidence.
contract TargetExitFeeDifferentialTest is Test {
    uint256 private constant FIXED_BLOCK = 54_990_962;

    address private constant TARGET_CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant TARGET_CONTROLLER_IMPL = 0x16e324BAe2098317477129a5E71f770bFf51f02a;
    address private constant TARGET_FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant TARGET_FEE_POLICY_IMPL = 0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900;
    address private constant TARGET_PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant TARGET_PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;

    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant TARGET_CONTROLLER_PROXY_CODEHASH =
        0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e;
    bytes32 private constant TARGET_CONTROLLER_IMPL_CODEHASH =
        0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31;
    bytes32 private constant TARGET_FEE_POLICY_PROXY_CODEHASH =
        0x2a16f92d0d60ffb240c4be576111b0e8a195a4c5b0f98856380c8943b9bbaa44;
    bytes32 private constant TARGET_FEE_POLICY_IMPL_CODEHASH =
        0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755;

    FeePolicy private cleanroom;
    uint256 private vectorCount;
    uint256 private mismatchCount;

    event TargetVersionLock(
        uint256 chainId,
        uint256 blockNumber,
        address controller,
        address controllerImplementation,
        bytes32 controllerProxyCodehash,
        bytes32 controllerImplementationCodehash,
        address feePolicy,
        address feePolicyImplementation,
        bytes32 feePolicyProxyCodehash,
        bytes32 feePolicyImplementationCodehash
    );
    event TargetSystemSnapshot(
        uint256 subDR,
        uint256 vmDR,
        uint256 srTotalSupply,
        uint256 srReserveValue,
        uint256 srVm,
        uint256 srUnderlyingBalance,
        uint256 srTrancheCount,
        uint256 jrTotalSupply,
        uint256 jrReserveValue,
        uint256 jrVm,
        uint256 jrUnderlyingBalance,
        uint256 jrTrancheCount
    );
    event TargetFeeConfigBase(uint8 indexed side, uint64 basePerc, uint64 flashBasePerc, bytes32 configHash);
    event TargetFeeConfigPoint(uint8 indexed side, uint8 indexed curve, uint8 indexed point, uint256 x, uint256 y);
    event TargetExitFeeDiff(
        uint8 indexed mode,
        uint16 indexed exitBps,
        bool trendEligible,
        uint256 preSubDR,
        uint256 postSubDR,
        uint256 preVmDR,
        uint256 postVmDR,
        uint256 targetSrFee,
        uint256 targetJrFee,
        uint256 cleanroomSrFee,
        uint256 cleanroomJrFee,
        int256 srWadDelta,
        int256 jrWadDelta,
        bool matches
    );
    event TargetExitFeeDiffSummary(uint256 vectors, uint256 matches, uint256 mismatches);

    function setUp() public {
        require(block.chainid == 8453, "TARGET_FORK_CHAIN_ID");
        require(block.number == FIXED_BLOCK, "TARGET_FORK_BLOCK");

        FeePolicy implementation = new FeePolicy();
        cleanroom = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
    }

    function testTargetVersionStateAndFeeConfig() public {
        _assertVersionLock();

        ITargetControllerExitFeeProbe controller = ITargetControllerExitFeeProbe(TARGET_CONTROLLER);
        (
            ITargetControllerExitFeeProbe.SystemState memory state,
            ITargetControllerExitFeeProbe.ReserveData memory srRd,
            ITargetControllerExitFeeProbe.ReserveData memory jrRd
        ) = controller.systemReserveState();
        (uint256 subDR, uint256 vmDR) = controller.systemDeviations();

        assertEq(state.perpSr.totalSupply, IERC20SupplyProbe(TARGET_PERP_SR).totalSupply(), "SR supply mismatch");
        assertEq(state.perpJr.totalSupply, IERC20SupplyProbe(TARGET_PERP_JR).totalSupply(), "JR supply mismatch");

        emit TargetSystemSnapshot(
            subDR,
            vmDR,
            state.perpSr.totalSupply,
            state.perpSr.reserveValue,
            state.perpSr.vm,
            srRd.underlyingBal,
            srRd.trancheData.length,
            state.perpJr.totalSupply,
            state.perpJr.reserveValue,
            state.perpJr.vm,
            jrRd.underlyingBal,
            jrRd.trancheData.length
        );

        FeePolicy target = FeePolicy(TARGET_FEE_POLICY);
        FeePolicy.Fees memory targetSr = _fees(target, true);
        FeePolicy.Fees memory targetJr = _fees(target, false);
        FeePolicy.Fees memory cleanroomSr = _fees(cleanroom, true);
        FeePolicy.Fees memory cleanroomJr = _fees(cleanroom, false);

        bytes32 targetSrHash = keccak256(abi.encode(targetSr));
        bytes32 targetJrHash = keccak256(abi.encode(targetJr));
        assertEq(targetSrHash, keccak256(abi.encode(cleanroomSr)), "SR fee config differs");
        assertEq(targetJrHash, keccak256(abi.encode(cleanroomJr)), "JR fee config differs");

        _emitConfig(0, targetSr, targetSrHash);
        _emitConfig(1, targetJr, targetJrHash);
    }

    function testTargetExitFeeDifferential() public {
        _check(
            0,
            100,
            847534510909630408,
            847234148514625054,
            1060773479096730879,
            1060773479096730879,
            737786924881158484,
            737786924881158484,
            true
        );
        _check(
            0,
            500,
            847534510909630408,
            845973479930060434,
            1060773479096730879,
            1060773479096730879,
            737805767735265120,
            737805767735265120,
            true
        );
        _check(
            0,
            1000,
            847534510909630408,
            844250449627468543,
            1060773479096730879,
            1060773479096730879,
            737831521378221382,
            737831521378221382,
            true
        );
        _check(
            0,
            2500,
            847534510909630408,
            837810743924280124,
            1060773479096730879,
            1060773479096730879,
            737927773824376181,
            737927773824376181,
            true
        );
        _check(
            0,
            5000,
            847534510909630408,
            819461064529227184,
            1060773479096730879,
            1060773479096730879,
            738202041253562530,
            738202041253562530,
            true
        );
        _check(
            0,
            7500,
            847534510909630408,
            771858215073362718,
            1060773479096730879,
            1060773479096730879,
            738913547479972383,
            738913547479972383,
            true
        );
        _check(
            0,
            9000,
            847534510909630408,
            673478974739308018,
            1060773479096730879,
            1060773479096730879,
            740383993952132631,
            740383993952132631,
            true
        );
        _check(
            0,
            9500,
            847534510909630408,
            582969936008808716,
            1060773479096730879,
            1060773479096730879,
            741736806763534351,
            741736806763534351,
            true
        );
        _check(
            0,
            9900,
            847534510909630408,
            422064759603894307,
            1060773479096730879,
            1060773479096730879,
            744141810585413092,
            744141810585413092,
            true
        );
        _check(
            0,
            10000,
            847534510909630408,
            350231952948552434,
            1060773479096730879,
            1060773479096730879,
            745215475077769955,
            745215475077769955,
            true
        );
        _check(
            1,
            100,
            847534510909630408,
            847534498784501926,
            1060773479096730879,
            1060773479096730879,
            737782435631259286,
            737782435631259286,
            true
        );
        _check(
            1,
            500,
            847534510909630408,
            847534498484272457,
            1060773479096730879,
            1060773479096730879,
            737782435635746731,
            737782435635746731,
            true
        );
        _check(
            1,
            1000,
            847534510909630408,
            847534498071456937,
            1060773479096730879,
            1060773479096730879,
            737782435641916967,
            737782435641916967,
            true
        );
        _check(
            1,
            2500,
            847534510909630408,
            847534496502757971,
            1060773479096730879,
            1060773479096730879,
            737782435665363863,
            737782435665363863,
            true
        );
        _check(
            1,
            5000,
            847534510909630408,
            847534491796661130,
            1060773479096730879,
            1060773479096730879,
            737782435735704551,
            737782435735704551,
            true
        );
        _check(
            1,
            7500,
            847534510909630408,
            847534477678371142,
            1060773479096730879,
            1060773479096730879,
            737782435946726609,
            737782435946726609,
            true
        );
        _check(
            1,
            9000,
            847534510909630408,
            847534435323505998,
            1060773479096730879,
            1060773479096730879,
            737782436579792709,
            737782436579792709,
            true
        );
        _check(
            1,
            9500,
            847534510909630408,
            847534364732080155,
            1060773479096730879,
            1060773479096730879,
            737782437634902636,
            737782437634902636,
            false
        );
        _check(
            1,
            9900,
            847534510909630408,
            847533800001396264,
            1060773479096730879,
            1060773479096730879,
            737782446075771249,
            737782446075771249,
            false
        );
        _check(
            1,
            10000,
            847534510909630408,
            1329227995784915872903807060280344575,
            1060773479096730879,
            0,
            1000000000000000000,
            1000000000000000000,
            true
        );
        _check(
            2,
            100,
            847534510909630408,
            855578401991375657,
            1060773479096730879,
            1060773479096730879,
            713118149110133366,
            713118149110133366,
            true
        );
        _check(
            2,
            500,
            847534510909630408,
            889341153123555435,
            1060773479096730879,
            1060773479096730879,
            713118149110133366,
            713118149110133366,
            true
        );
        _check(
            2,
            1000,
            847534510909630408,
            935486221253000625,
            1060773479096730879,
            1060773479096730879,
            713118149110133366,
            713118149110133366,
            true
        );
        _check(
            2,
            2500,
            847534510909630408,
            1107950198212778165,
            1060773479096730879,
            1060773479096730879,
            714343343125718335,
            714343343125718335,
            true
        );
        _check(
            2,
            5000,
            847534510909630408,
            1599379915616757763,
            1060773479096730879,
            1060773479096730879,
            732056289326278502,
            732056289326278502,
            true
        );
        _check(
            2,
            7500,
            847534510909630408,
            2874248730118248624,
            1060773479096730879,
            1060773479096730879,
            756590862384793777,
            756590862384793777,
            true
        );
        _check(
            2,
            9000,
            847534510909630408,
            5508980275508166561,
            1060773479096730879,
            1060773479096730879,
            801822609317605530,
            801822609317605530,
            true
        );
        _check(
            2,
            9500,
            847534510909630408,
            7932935938203117771,
            1060773479096730879,
            1060773479096730879,
            842744523990565337,
            842744523990565337,
            true
        );
        _check(
            2,
            9900,
            847534510909630408,
            12242196497606584222,
            1060773479096730879,
            1060773479096730879,
            915203729302374841,
            915203729302374841,
            true
        );
        _check(
            2,
            10000,
            847534510909630408,
            14165976967872195882,
            1060773479096730879,
            1060773479096730879,
            947509560190094392,
            947509560190094392,
            true
        );
        _check(
            3,
            100,
            847534510909630408,
            839268707597083615,
            1060773479096730879,
            1060773479096730879,
            737905982056804770,
            737905982056804770,
            true
        );
        _check(
            3,
            500,
            847534510909630408,
            806205489352217952,
            1060773479096730879,
            1060773479096730879,
            738400168558564102,
            738400168558564102,
            true
        );
        _check(
            3,
            1000,
            847534510909630408,
            764876462800127007,
            1060773479096730879,
            1060773479096730879,
            739017901741753794,
            739017901741753794,
            true
        );
        _check(
            3,
            2500,
            847534510909630408,
            640889383143854174,
            1060773479096730879,
            1060773479096730879,
            740871101291322870,
            740871101291322870,
            true
        );
        _check(
            3,
            5000,
            847534510909630408,
            434244250383399451,
            1060773479096730879,
            1060773479096730879,
            743959767207271330,
            743959767207271330,
            true
        );
        _check(
            3,
            7500,
            847534510909630408,
            227599117622944729,
            1060773479096730879,
            1060773479096730879,
            747048433123219790,
            747048433123219790,
            true
        );
        _check(
            3,
            9000,
            847534510909630408,
            103612037966671895,
            1060773479096730879,
            1060773479096730879,
            748901632672788866,
            748901632672788866,
            true
        );
        _check(
            3,
            9500,
            847534510909630408,
            62283011414580951,
            1060773479096730879,
            1060773479096730879,
            749519365855978558,
            749519365855978558,
            true
        );
        _check(
            3,
            9900,
            847534510909630408,
            29219793169715288,
            1060773479096730879,
            1060773479096730879,
            750013552357737890,
            750013552357737890,
            true
        );
        _check(
            3,
            10000,
            847534510909630408,
            20953984862490006,
            1060773479096730879,
            1060773479096730879,
            750137099039168250,
            750137099039168250,
            true
        );

        assertEq(vectorCount, 40, "vector count");
        assertEq(mismatchCount, 0, "target FeePolicy compatibility");
        emit TargetExitFeeDiffSummary(vectorCount, vectorCount - mismatchCount, mismatchCount);
    }

    function _assertVersionLock() private {
        address controllerImpl = address(uint160(uint256(vm.load(TARGET_CONTROLLER, EIP1967_IMPLEMENTATION_SLOT))));
        address feePolicyImpl = address(uint160(uint256(vm.load(TARGET_FEE_POLICY, EIP1967_IMPLEMENTATION_SLOT))));

        assertEq(controllerImpl, TARGET_CONTROLLER_IMPL, "controller implementation");
        assertEq(feePolicyImpl, TARGET_FEE_POLICY_IMPL, "fee policy implementation");
        assertEq(TARGET_CONTROLLER.codehash, TARGET_CONTROLLER_PROXY_CODEHASH, "controller proxy codehash");
        assertEq(TARGET_CONTROLLER_IMPL.codehash, TARGET_CONTROLLER_IMPL_CODEHASH, "controller impl codehash");
        assertEq(TARGET_FEE_POLICY.codehash, TARGET_FEE_POLICY_PROXY_CODEHASH, "fee proxy codehash");
        assertEq(TARGET_FEE_POLICY_IMPL.codehash, TARGET_FEE_POLICY_IMPL_CODEHASH, "fee impl codehash");

        emit TargetVersionLock(
            block.chainid,
            block.number,
            TARGET_CONTROLLER,
            controllerImpl,
            TARGET_CONTROLLER.codehash,
            TARGET_CONTROLLER_IMPL.codehash,
            TARGET_FEE_POLICY,
            feePolicyImpl,
            TARGET_FEE_POLICY.codehash,
            TARGET_FEE_POLICY_IMPL.codehash
        );
    }

    function _check(
        uint8 mode,
        uint16 exitBps,
        uint256 preSubDR,
        uint256 postSubDR,
        uint256 preVmDR,
        uint256 postVmDR,
        uint256,
        uint256,
        bool trendEligible
    ) private {
        FeePolicy.OpSystemChange memory deviation = FeePolicy.OpSystemChange({
            subDRPre: preSubDR, subDRPost: postSubDR, vmDRPre: preVmDR, vmDRPost: postVmDR
        });

        FeePolicy.OpFees memory targetSr = FeePolicy(TARGET_FEE_POLICY)
            .computeOpFees(FeePolicy.OpFeeInput({isPerpSrOp: true, isFlashOp: false, systemDeviation: deviation}));
        FeePolicy.OpFees memory targetJr = FeePolicy(TARGET_FEE_POLICY)
            .computeOpFees(FeePolicy.OpFeeInput({isPerpSrOp: false, isFlashOp: false, systemDeviation: deviation}));
        FeePolicy.OpFees memory cleanSr = cleanroom.computeOpFees(
            FeePolicy.OpFeeInput({isPerpSrOp: true, isFlashOp: false, systemDeviation: deviation})
        );
        FeePolicy.OpFees memory cleanJr = cleanroom.computeOpFees(
            FeePolicy.OpFeeInput({isPerpSrOp: false, isFlashOp: false, systemDeviation: deviation})
        );

        int256 srDelta = int256(targetSr.totalFeePerc) - int256(cleanSr.totalFeePerc);
        int256 jrDelta = int256(targetJr.totalFeePerc) - int256(cleanJr.totalFeePerc);
        bool matches = srDelta == 0 && jrDelta == 0;
        vectorCount++;
        if (!matches) mismatchCount++;

        emit TargetExitFeeDiff(
            mode,
            exitBps,
            trendEligible,
            preSubDR,
            postSubDR,
            preVmDR,
            postVmDR,
            targetSr.totalFeePerc,
            targetJr.totalFeePerc,
            cleanSr.totalFeePerc,
            cleanJr.totalFeePerc,
            srDelta,
            jrDelta,
            matches
        );
    }

    function _emitConfig(uint8 side, FeePolicy.Fees memory fees, bytes32 configHash) private {
        emit TargetFeeConfigBase(side, fees.basePerc, fees.flashBasePerc, configHash);
        _emitCurve(side, 0, fees.subDRUp);
        _emitCurve(side, 1, fees.subDRDown);
        _emitCurve(side, 2, fees.vmDRUp);
        _emitCurve(side, 3, fees.vmDRDown);
    }

    function _fees(FeePolicy policy, bool isSr) private view returns (FeePolicy.Fees memory fees) {
        if (isSr) {
            (fees.subDRUp, fees.subDRDown, fees.vmDRUp, fees.vmDRDown, fees.basePerc, fees.flashBasePerc) =
                policy.perpSrFees();
        } else {
            (fees.subDRUp, fees.subDRDown, fees.vmDRUp, fees.vmDRDown, fees.basePerc, fees.flashBasePerc) =
                policy.perpJrFees();
        }
    }

    function _emitCurve(uint8 side, uint8 curve, FeePolicy.Curve memory c) private {
        emit TargetFeeConfigPoint(side, curve, 0, c.p1.x, c.p1.y);
        emit TargetFeeConfigPoint(side, curve, 1, c.p2.x, c.p2.y);
        emit TargetFeeConfigPoint(side, curve, 2, c.p3.x, c.p3.y);
        emit TargetFeeConfigPoint(side, curve, 3, c.p4.x, c.p4.y);
    }
}
