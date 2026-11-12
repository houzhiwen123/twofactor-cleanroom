// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {FeePolicy} from "../../src/policy/FeePolicy.sol";

/// @notice Black-box FeePolicy matrix at one fixed public Base block.
/// @dev Evidence class 0 calls the fixed target proxy. Evidence class 1 calls a
///      fresh local proxy backed by the fixed target implementation. Class 1 is
///      used only for synthetic configuration rows and never mutates the target.
contract TargetFeePolicySemanticsMatrixTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant FIXED_BLOCK = 54_990_962;
    address private constant TARGET_FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant TARGET_FEE_POLICY_IMPL = 0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900;
    bytes32 private constant TARGET_FEE_POLICY_IMPL_CODEHASH =
        0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755;

    FeePolicy private cleanroom;
    FeePolicy private syntheticTarget;
    FeePolicy private syntheticCleanroom;
    uint256 private caseCount;
    uint256 private comparisonCount;
    uint256 private mismatchCount;

    event MatrixInput(
        uint16 indexed caseId,
        uint8 indexed evidenceClass,
        bool isFlash,
        uint256 subDRPre,
        uint256 subDRPost,
        uint256 vmDRPre,
        uint256 vmDRPost
    );
    event MatrixFeeResult(
        uint16 indexed caseId,
        uint8 indexed side,
        bool targetSuccess,
        bytes4 targetSelector,
        uint256 targetTotalFee,
        uint256 targetProtocolFee,
        bool cleanroomSuccess,
        bytes4 cleanroomSelector,
        uint256 cleanroomTotalFee,
        uint256 cleanroomProtocolFee,
        int256 totalFeeDelta,
        int256 protocolFeeDelta,
        bool matches
    );
    event MatrixSummary(uint256 cases, uint256 sideComparisons, uint256 matches, uint256 mismatches);

    function setUp() public {
        require(block.chainid == 8453, "TARGET_FORK_CHAIN_ID");
        require(block.number == FIXED_BLOCK, "TARGET_FORK_BLOCK");
        assertEq(TARGET_FEE_POLICY_IMPL.codehash, TARGET_FEE_POLICY_IMPL_CODEHASH, "target impl codehash");

        cleanroom = _newCleanroomPolicy();
        syntheticCleanroom = _newCleanroomPolicy();
        syntheticTarget = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    TARGET_FEE_POLICY_IMPL, address(this), abi.encodeWithSignature("init()")
                )
            )
        );
        assertEq(syntheticTarget.owner(), address(this), "fresh target proxy owner");
        syntheticTarget.updateFeeParams(
            _fees(FeePolicy(TARGET_FEE_POLICY), true), _fees(FeePolicy(TARGET_FEE_POLICY), false)
        );
        assertEq(
            keccak256(abi.encode(_fees(FeePolicy(TARGET_FEE_POLICY), true))),
            keccak256(abi.encode(_fees(syntheticTarget, true))),
            "fresh target defaults"
        );
    }

    function testTargetFeePolicySemanticsMatrix() public {
        _equalityCases();
        _movementCases();
        _knotCases();
        _jointAndClippingCases();
        this.runRoundingDiscriminatorCasesA();
        this.runRoundingDiscriminatorCasesB();
        _syntheticConfigCases();
        this.runSyntheticIncreasingCurveCases();
        this.runSyntheticDecreasingCurveCases();
        this.runSyntheticVmIncreasingCurveCases();
        this.runSyntheticVmDecreasingCurveCases();
        this.runSyntheticRationalSlopeCases();
        this.runSyntheticTranslatedRationalSlopeCases();

        emit MatrixSummary(caseCount, comparisonCount, comparisonCount - mismatchCount, mismatchCount);
        assertEq(caseCount, 136, "matrix case count");
        assertEq(comparisonCount, 272, "matrix side comparison count");
        assertEq(mismatchCount, 0, "target FeePolicy semantic compatibility");
    }

    function _equalityCases() private {
        _fixed(1, false, 8e17, 8e17, WAD, WAD);
        _fixed(2, false, WAD, WAD, WAD, WAD);
        _fixed(3, false, 12e17, 12e17, WAD, WAD);
        _fixed(4, false, WAD, WAD, 95e16, 95e16);
        _fixed(5, false, WAD, WAD, WAD, WAD);
        _fixed(6, false, WAD, WAD, 105e16, 105e16);
    }

    function _movementCases() private {
        _fixed(10, false, 8e17, 9e17, WAD, WAD);
        _fixed(11, false, 9e17, 8e17, WAD, WAD);
        _fixed(12, false, WAD, 12e17, WAD, WAD);
        _fixed(13, false, 12e17, WAD, WAD, WAD);
        _fixed(14, false, 9e17, 11e17, WAD, WAD);
        _fixed(15, false, 11e17, 9e17, WAD, WAD);
        _fixed(16, false, WAD, WAD, 9e17, 95e16);
        _fixed(17, false, WAD, WAD, 95e16, 9e17);
        _fixed(18, false, WAD, WAD, WAD, 105e16);
        _fixed(19, false, WAD, WAD, 105e16, WAD);
        _fixed(20, false, WAD, WAD, 95e16, 105e16);
        _fixed(21, false, WAD, WAD, 105e16, 95e16);
    }

    function _knotCases() private {
        uint256[4] memory subUp = [uint256(0), 1_078_564_994_000_000_000, 1_105_439_994_000_000_000, 2e18];
        uint256[4] memory subDown = [uint256(0), 1_003_564_994_000_000_000, 1_028_564_994_000_000_000, 2e18];
        uint256[4] memory vmUp = [uint256(0), 1e18, 1_025_000_000_000_000_000, 1_076_250_000_000_000_000];
        uint256[4] memory vmDown = [uint256(928_571_429_000_000_000), 975_000_000_000_000_000, 1e18, 2e18];

        _upKnotCases(100, subUp, true);
        _downKnotCases(120, subDown, true);
        _upKnotCases(140, vmUp, false);
        _downKnotCases(160, vmDown, false);
    }

    function _upKnotCases(uint16 baseId, uint256[4] memory knots, bool isSub) private {
        for (uint16 i; i < 4; ++i) {
            uint256 knot = knots[i];
            if (knot != 0) {
                if (isSub) _fixed(baseId + i * 2, false, knot - 1, knot, WAD, WAD);
                else _fixed(baseId + i * 2, false, WAD, WAD, knot - 1, knot);
            }
            if (isSub) _fixed(baseId + i * 2 + 1, false, knot, knot + 1, WAD, WAD);
            else _fixed(baseId + i * 2 + 1, false, WAD, WAD, knot, knot + 1);
        }
    }

    function _downKnotCases(uint16 baseId, uint256[4] memory knots, bool isSub) private {
        for (uint16 i; i < 4; ++i) {
            uint256 knot = knots[i];
            if (isSub) _fixed(baseId + i * 2, false, knot + 1, knot, WAD, WAD);
            else _fixed(baseId + i * 2, false, WAD, WAD, knot + 1, knot);
            if (knot != 0) {
                if (isSub) _fixed(baseId + i * 2 + 1, false, knot, knot - 1, WAD, WAD);
                else _fixed(baseId + i * 2 + 1, false, WAD, WAD, knot, knot - 1);
            }
        }
    }

    function _jointAndClippingCases() private {
        _fixed(200, false, 8e17, 9e17, WAD, 105e16);
        _fixed(201, false, 9e17, 8e17, WAD, 105e16);
        _fixed(202, false, 8e17, 9e17, 105e16, 95e16);
        _fixed(203, false, 9e17, 8e17, 105e16, 95e16);
        _fixed(
            204,
            false,
            847_534_510_909_630_408,
            1_329_227_995_784_915_872_903_807_060_280_344_575,
            1_060_773_479_096_730_879,
            0
        );
        _fixed(205, false, WAD, WAD, 12e17, 13e17);
        _fixed(206, false, 2e18, 3e18, 2e18, 3e18);
        _fixed(207, false, 1_078_564_994_000_000_001, 1_078_564_994_000_000_004, WAD, WAD);
        _fixed(208, false, 1_003_564_994_000_000_004, 1_003_564_994_000_000_001, WAD, WAD);
        _fixed(209, false, WAD, WAD, 1_000_000_000_000_000_001, 1_000_000_000_000_000_004);
        _fixed(210, false, WAD, WAD, 975_000_000_000_000_004, 975_000_000_000_000_001);
    }

    function runRoundingDiscriminatorCasesA() external {
        assertEq(msg.sender, address(this), "self only");
        _fixed(211, false, 1_078_564_994_000_000_002, 1_078_564_994_000_000_007, WAD, WAD);
        _fixed(212, false, 1_105_439_993_999_999_993, 1_105_439_993_999_999_998, WAD, WAD);
        _fixed(213, false, 1_003_564_993_999_999_998, 1_003_564_993_999_999_993, WAD, WAD);
        _fixed(214, false, 1_003_564_994_000_000_007, 1_003_564_994_000_000_002, WAD, WAD);
        _fixed(215, false, WAD, WAD, 1_025_000_000_000_000_002, 1_025_000_000_000_000_007);
        _fixed(216, false, WAD, WAD, 1_076_249_999_999_999_993, 1_076_249_999_999_999_998);
    }

    function runRoundingDiscriminatorCasesB() external {
        assertEq(msg.sender, address(this), "self only");
        _fixed(217, false, WAD, WAD, 928_571_429_000_000_007, 928_571_429_000_000_002);
        _fixed(218, false, WAD, WAD, 974_999_999_999_999_998, 974_999_999_999_999_993);
        _fixed(219, false, 1_078_564_993_999_999_997, 1_078_564_994_000_000_005, WAD, WAD);
        _fixed(220, false, 1_003_564_994_000_000_005, 1_003_564_993_999_999_997, WAD, WAD);
        _fixed(221, false, WAD, WAD, 1_024_999_999_999_999_997, 1_025_000_000_000_000_005);
        _fixed(222, false, WAD, WAD, 975_000_000_000_000_005, 974_999_999_999_999_997);
    }

    function _syntheticConfigCases() private {
        FeePolicy.Fees memory srFees = _fees(syntheticTarget, true);
        FeePolicy.Fees memory jrFees = _fees(syntheticTarget, false);
        srFees.basePerc = 12_345_678_901_234_567;
        srFees.flashBasePerc = 34_567_890_123_456_789;
        jrFees.basePerc = 23_456_789_012_345_678;
        jrFees.flashBasePerc = 45_678_901_234_567_890;

        syntheticTarget.updateFeeParams(srFees, jrFees);
        syntheticCleanroom.updateFeeParams(srFees, jrFees);
        syntheticTarget.updateProtocolFeeConfig(70_000_000_000_000_000, address(0xFEE));
        syntheticCleanroom.updateProtocolFeeConfig(70_000_000_000_000_000, address(0xFEE));

        _synthetic(300, false, 8e17, 8e17, WAD, WAD);
        _synthetic(301, true, 8e17, 8e17, WAD, WAD);
        _synthetic(302, false, 8e17, 9e17, WAD, WAD);
        _synthetic(303, false, 2e18, 3e18, 2e18, 3e18);
        _synthetic(304, true, 2e18, 3e18, 2e18, 3e18);
        _synthetic(305, false, 9e17, 8e17, 105e16, 95e16);
    }

    function runSyntheticIncreasingCurveCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticCurves(_increasingCurve(), _decreasingCurve(), _zeroCurve());
        _synthetic(400, false, WAD, WAD + 1, WAD, WAD);
        _synthetic(401, false, WAD + 1, WAD + 4, WAD, WAD);
        _synthetic(402, false, WAD + 2, WAD + 7, WAD, WAD);
        _synthetic(403, false, WAD - 1, WAD + 5, WAD, WAD);
        _synthetic(404, false, WAD + 50, WAD + 60, WAD, WAD);
        _synthetic(405, false, WAD + 99, WAD + 100, WAD, WAD);
        _synthetic(406, false, WAD + 100, WAD + 101, WAD, WAD);
        _synthetic(407, false, 2 * WAD - 1, 2 * WAD, WAD, WAD);
        _synthetic(408, false, 2 * WAD, 2 * WAD + 1, WAD, WAD);
    }

    function runSyntheticDecreasingCurveCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticCurves(_increasingCurve(), _decreasingCurve(), _zeroCurve());
        _synthetic(409, false, WAD + 1, WAD, WAD, WAD);
        _synthetic(410, false, WAD + 4, WAD + 1, WAD, WAD);
        _synthetic(411, false, WAD + 7, WAD + 2, WAD, WAD);
        _synthetic(412, false, WAD + 5, WAD - 1, WAD, WAD);
        _synthetic(413, false, WAD + 60, WAD + 50, WAD, WAD);
        _synthetic(414, false, WAD + 100, WAD + 99, WAD, WAD);
        _synthetic(415, false, WAD + 101, WAD + 100, WAD, WAD);
        _synthetic(416, false, 2 * WAD, 2 * WAD - 1, WAD, WAD);
        _synthetic(417, false, 2 * WAD + 1, 2 * WAD, WAD, WAD);
    }

    function runSyntheticVmIncreasingCurveCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticVmCurves(_increasingCurve(), _decreasingCurve(), _zeroCurve());
        _synthetic(430, false, WAD, WAD, WAD, WAD + 1);
        _synthetic(431, false, WAD, WAD, WAD + 1, WAD + 4);
        _synthetic(432, false, WAD, WAD, WAD + 2, WAD + 7);
        _synthetic(433, false, WAD, WAD, WAD - 1, WAD + 5);
        _synthetic(434, false, WAD, WAD, WAD + 50, WAD + 60);
        _synthetic(435, false, WAD, WAD, WAD + 99, WAD + 100);
        _synthetic(436, false, WAD, WAD, WAD + 100, WAD + 101);
        _synthetic(437, false, WAD, WAD, 2 * WAD - 1, 2 * WAD);
        _synthetic(438, false, WAD, WAD, 2 * WAD, 2 * WAD + 1);
    }

    function runSyntheticVmDecreasingCurveCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticVmCurves(_increasingCurve(), _decreasingCurve(), _zeroCurve());
        _synthetic(439, false, WAD, WAD, WAD + 1, WAD);
        _synthetic(440, false, WAD, WAD, WAD + 4, WAD + 1);
        _synthetic(441, false, WAD, WAD, WAD + 7, WAD + 2);
        _synthetic(442, false, WAD, WAD, WAD + 5, WAD - 1);
        _synthetic(443, false, WAD, WAD, WAD + 60, WAD + 50);
        _synthetic(444, false, WAD, WAD, WAD + 100, WAD + 99);
        _synthetic(445, false, WAD, WAD, WAD + 101, WAD + 100);
        _synthetic(446, false, WAD, WAD, 2 * WAD, 2 * WAD - 1);
        _synthetic(447, false, WAD, WAD, 2 * WAD + 1, 2 * WAD);
    }

    function runSyntheticRationalSlopeCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticCurves(_rationalIncreasingCurve(), _rationalDecreasingCurve(), _zeroCurve());
        _synthetic(450, false, WAD, WAD + 1, WAD, WAD);
        _synthetic(451, false, WAD + 1, WAD + 4, WAD, WAD);
        _synthetic(452, false, WAD + 2, WAD + 7, WAD, WAD);
        _synthetic(453, false, WAD - 3, WAD + 5, WAD, WAD);
        _synthetic(454, false, WAD + 42, WAD + 43, WAD, WAD);
        _synthetic(455, false, WAD + 43, WAD + 44, WAD, WAD);
        _synthetic(456, false, WAD + 1, WAD, WAD, WAD);
        _synthetic(457, false, WAD + 4, WAD + 1, WAD, WAD);
        _synthetic(458, false, WAD + 5, WAD + 2, WAD, WAD);
        _synthetic(459, false, WAD + 5, WAD - 3, WAD, WAD);
        _synthetic(460, false, WAD + 5, WAD + 4, WAD, WAD);
        _synthetic(461, false, WAD + 6, WAD + 5, WAD, WAD);
    }

    function runSyntheticTranslatedRationalSlopeCases() external {
        assertEq(msg.sender, address(this), "self only");
        uint256 targetP2 = 1_078_564_994_000_000_000;
        _setSyntheticCurves(_translatedRationalIncreasingCurve(targetP2), _rationalDecreasingCurve(), _zeroCurve());
        _synthetic(470, false, targetP2, targetP2 + 1, WAD, WAD);
        _synthetic(471, false, targetP2 + 1, targetP2 + 4, WAD, WAD);
        _synthetic(472, false, targetP2 + 2, targetP2 + 7, WAD, WAD);
        _synthetic(473, false, targetP2 - 3, targetP2 + 5, WAD, WAD);
        _synthetic(474, false, targetP2 + 42, targetP2 + 43, WAD, WAD);
        _synthetic(475, false, targetP2 + 43, targetP2 + 44, WAD, WAD);

        uint256 shiftedP2 = WAD + 1;
        _setSyntheticCurves(_translatedRationalIncreasingCurve(shiftedP2), _rationalDecreasingCurve(), _zeroCurve());
        _synthetic(476, false, shiftedP2, shiftedP2 + 1, WAD, WAD);
        _synthetic(477, false, shiftedP2 + 1, shiftedP2 + 4, WAD, WAD);
        _synthetic(478, false, shiftedP2 + 2, shiftedP2 + 7, WAD, WAD);
        _synthetic(479, false, shiftedP2 - 3, shiftedP2 + 5, WAD, WAD);
        _synthetic(480, false, shiftedP2 + 42, shiftedP2 + 43, WAD, WAD);
        _synthetic(481, false, shiftedP2 + 43, shiftedP2 + 44, WAD, WAD);
    }

    function runSyntheticSwappedCurveCases() external {
        assertEq(msg.sender, address(this), "self only");
        _setSyntheticCurves(_decreasingCurve(), _increasingCurve(), _zeroCurve());
        _synthetic(420, false, 101, 104, WAD, WAD);
        _synthetic(421, false, 99, 105, WAD, WAD);
        _synthetic(422, false, 199, 201, WAD, WAD);
        _synthetic(423, false, 104, 101, WAD, WAD);
        _synthetic(424, false, 105, 99, WAD, WAD);
        _synthetic(425, false, 201, 199, WAD, WAD);
    }

    function _increasingCurve() private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 0),
            p2: FeePolicy.Point(WAD, 0),
            p3: FeePolicy.Point(WAD + 100, 100),
            p4: FeePolicy.Point(2 * WAD, 1_000)
        });
    }

    function _decreasingCurve() private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 1_000),
            p2: FeePolicy.Point(WAD, 100),
            p3: FeePolicy.Point(WAD + 100, 0),
            p4: FeePolicy.Point(2 * WAD, 0)
        });
    }

    function _zeroCurve() private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 0),
            p2: FeePolicy.Point(WAD, 0),
            p3: FeePolicy.Point(WAD + 100, 0),
            p4: FeePolicy.Point(2 * WAD, 0)
        });
    }

    function _rationalIncreasingCurve() private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 0),
            p2: FeePolicy.Point(WAD, 0),
            p3: FeePolicy.Point(WAD + 43, 32),
            p4: FeePolicy.Point(2 * WAD, 1_000)
        });
    }

    function _rationalDecreasingCurve() private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 1_000),
            p2: FeePolicy.Point(WAD, 4),
            p3: FeePolicy.Point(WAD + 5, 0),
            p4: FeePolicy.Point(2 * WAD, 0)
        });
    }

    function _translatedRationalIncreasingCurve(uint256 p2x) private pure returns (FeePolicy.Curve memory curve) {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, 0),
            p2: FeePolicy.Point(p2x, 0),
            p3: FeePolicy.Point(p2x + 43, 32),
            p4: FeePolicy.Point(2 * WAD, 1_000)
        });
    }

    function _setSyntheticCurves(
        FeePolicy.Curve memory subUp,
        FeePolicy.Curve memory subDown,
        FeePolicy.Curve memory zero
    ) private {
        FeePolicy.Fees memory fees = FeePolicy.Fees({
            subDRUp: subUp, subDRDown: subDown, vmDRUp: zero, vmDRDown: zero, basePerc: 0, flashBasePerc: 0
        });
        syntheticTarget.updateFeeParams(fees, fees);
        syntheticCleanroom.updateFeeParams(fees, fees);
    }

    function _setSyntheticVmCurves(
        FeePolicy.Curve memory vmUp,
        FeePolicy.Curve memory vmDown,
        FeePolicy.Curve memory zero
    ) private {
        FeePolicy.Fees memory fees = FeePolicy.Fees({
            subDRUp: zero, subDRDown: zero, vmDRUp: vmUp, vmDRDown: vmDown, basePerc: 0, flashBasePerc: 0
        });
        syntheticTarget.updateFeeParams(fees, fees);
        syntheticCleanroom.updateFeeParams(fees, fees);
    }

    function _fixed(uint16 caseId, bool isFlash, uint256 subDRPre, uint256 subDRPost, uint256 vmDRPre, uint256 vmDRPost)
        private
    {
        _check(caseId, 0, FeePolicy(TARGET_FEE_POLICY), cleanroom, isFlash, subDRPre, subDRPost, vmDRPre, vmDRPost);
    }

    function _synthetic(
        uint16 caseId,
        bool isFlash,
        uint256 subDRPre,
        uint256 subDRPost,
        uint256 vmDRPre,
        uint256 vmDRPost
    ) private {
        _check(caseId, 1, syntheticTarget, syntheticCleanroom, isFlash, subDRPre, subDRPost, vmDRPre, vmDRPost);
    }

    function _check(
        uint16 caseId,
        uint8 evidenceClass,
        FeePolicy target,
        FeePolicy local,
        bool isFlash,
        uint256 subDRPre,
        uint256 subDRPost,
        uint256 vmDRPre,
        uint256 vmDRPost
    ) private {
        caseCount++;
        emit MatrixInput(caseId, evidenceClass, isFlash, subDRPre, subDRPost, vmDRPre, vmDRPost);

        FeePolicy.OpSystemChange memory change = FeePolicy.OpSystemChange(subDRPre, subDRPost, vmDRPre, vmDRPost);
        _compareSide(caseId, 0, target, local, FeePolicy.OpFeeInput(true, isFlash, change));
        _compareSide(caseId, 1, target, local, FeePolicy.OpFeeInput(false, isFlash, change));
    }

    function _compareSide(
        uint16 caseId,
        uint8 side,
        FeePolicy target,
        FeePolicy local,
        FeePolicy.OpFeeInput memory input
    ) private {
        (bool targetSuccess, FeePolicy.OpFees memory targetFees, bytes4 targetSelector) = _call(target, input);
        (bool localSuccess, FeePolicy.OpFees memory localFees, bytes4 localSelector) = _call(local, input);
        int256 totalDelta = targetSuccess && localSuccess
            ? int256(targetFees.totalFeePerc) - int256(localFees.totalFeePerc)
            : int256(0);
        int256 protocolDelta = targetSuccess && localSuccess
            ? int256(targetFees.protocolFeePerc) - int256(localFees.protocolFeePerc)
            : int256(0);
        bool matches = targetSuccess == localSuccess && targetSelector == localSelector;
        if (targetSuccess && localSuccess) {
            matches = matches && totalDelta == 0 && protocolDelta == 0;
        }
        comparisonCount++;
        if (!matches) mismatchCount++;
        emit MatrixFeeResult(
            caseId,
            side,
            targetSuccess,
            targetSelector,
            targetFees.totalFeePerc,
            targetFees.protocolFeePerc,
            localSuccess,
            localSelector,
            localFees.totalFeePerc,
            localFees.protocolFeePerc,
            totalDelta,
            protocolDelta,
            matches
        );
    }

    function _call(FeePolicy policy, FeePolicy.OpFeeInput memory input)
        private
        view
        returns (bool success, FeePolicy.OpFees memory fees, bytes4 selector)
    {
        bytes memory result;
        (success, result) = address(policy).staticcall(abi.encodeCall(FeePolicy.computeOpFees, (input)));
        if (success) {
            fees = abi.decode(result, (FeePolicy.OpFees));
        } else if (result.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
        }
    }

    function _newCleanroomPolicy() private returns (FeePolicy policy) {
        FeePolicy implementation = new FeePolicy();
        policy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
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
}
