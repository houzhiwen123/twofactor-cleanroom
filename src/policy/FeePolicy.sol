// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract FeePolicy is Initializable, Ownable2StepUpgradeable {
    error InvalidParamDefn();
    error InvalidPerc();
    error InvalidRange();
    error SafeCastOverflowedIntToUint(int256 value);
    error SafeCastOverflowedUintToInt(uint256 value);
    error Unreachable();

    uint256 private constant WAD = 1e18;

    struct Point {
        uint256 x;
        uint256 y;
    }

    struct Curve {
        Point p1;
        Point p2;
        Point p3;
        Point p4;
    }

    struct Fees {
        Curve subDRUp;
        Curve subDRDown;
        Curve vmDRUp;
        Curve vmDRDown;
        uint64 basePerc;
        uint64 flashBasePerc;
    }

    struct Range {
        uint256 lower;
        uint256 upper;
    }

    struct Debasement {
        uint64 lag;
        Range tvlPercLimits;
    }

    struct OpSystemChange {
        uint256 subDRPre;
        uint256 subDRPost;
        uint256 vmDRPre;
        uint256 vmDRPost;
    }

    struct OpFeeInput {
        bool isPerpSrOp;
        bool isFlashOp;
        OpSystemChange systemDeviation;
    }

    struct OpFees {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    Fees public perpSrFees;
    Fees public perpJrFees;
    Debasement public perpSrDebasement;
    Debasement public perpJrDebasement;
    uint64 public perpSrAUMFeePerc;
    uint64 public perpJrAUMFeePerc;
    uint64 public protocolMaxOpFeePerc;
    address public protocolFeeCollector;

    constructor() {
        _disableInitializers();
    }

    function init() external initializer {
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        perpSrFees = _defaultFees();
        perpJrFees = _defaultFees();
        perpSrDebasement = Debasement(168, Range(13_689_300_000_000, 1_642_710_500_000_000));
        perpJrDebasement = Debasement(168, Range(4_544_800_000_000, 547_570_200_000_000));
    }

    function updateFeeParams(Fees calldata perpSrFees_, Fees calldata perpJrFees_) external onlyOwner {
        _validateFees(perpSrFees_);
        _validateFees(perpJrFees_);
        perpSrFees = perpSrFees_;
        perpJrFees = perpJrFees_;
    }

    function updateAumFeePerc(uint64 perpSrAUMFeePerc_, uint64 perpJrAUMFeePerc_) external onlyOwner {
        if (perpSrAUMFeePerc_ >= WAD || perpJrAUMFeePerc_ >= WAD) revert InvalidPerc();
        perpSrAUMFeePerc = perpSrAUMFeePerc_;
        perpJrAUMFeePerc = perpJrAUMFeePerc_;
    }

    function updateProtocolFeeConfig(uint64 protocolMaxOpFeePerc_, address protocolFeeCollector_) external onlyOwner {
        if (protocolMaxOpFeePerc_ > WAD) revert InvalidPerc();
        protocolMaxOpFeePerc = protocolMaxOpFeePerc_;
        protocolFeeCollector = protocolFeeCollector_;
    }

    function updateRebalanceParams(Debasement calldata perpSrDebasement_, Debasement calldata perpJrDebasement_)
        external
        onlyOwner
    {
        _validateDebasement(perpSrDebasement_);
        _validateDebasement(perpJrDebasement_);
        perpSrDebasement = perpSrDebasement_;
        perpJrDebasement = perpJrDebasement_;
    }

    function computeOpFees(OpFeeInput calldata ip) external view returns (OpFees memory f) {
        Fees storage fees = ip.isPerpSrOp ? perpSrFees : perpJrFees;
        uint256 total = ip.isFlashOp ? fees.flashBasePerc : fees.basePerc;
        Curve storage subCurve =
            ip.systemDeviation.subDRPost >= ip.systemDeviation.subDRPre ? fees.subDRUp : fees.subDRDown;
        Curve storage vmCurve = ip.systemDeviation.vmDRPost >= ip.systemDeviation.vmDRPre ? fees.vmDRUp : fees.vmDRDown;
        total += _average(subCurve, ip.systemDeviation.subDRPre, ip.systemDeviation.subDRPost);
        total += _average(vmCurve, ip.systemDeviation.vmDRPre, ip.systemDeviation.vmDRPost);
        f.totalFeePerc = total;
        f.protocolFeePerc = total < protocolMaxOpFeePerc ? total : protocolMaxOpFeePerc;
    }

    function computeRebalanceVal(uint256 perpSrTVL, uint256 perpJrTVL, uint256 targetSystemRatio)
        external
        view
        returns (uint256 rebalVal, bool isPerpSrPayer)
    {
        uint256 totalTVL = perpSrTVL + perpJrTVL;
        uint256 targetSrTVL = Math.mulDiv(totalTVL, WAD, targetSystemRatio + WAD);
        uint256 imbalance = perpSrTVL > targetSrTVL ? perpSrTVL - targetSrTVL : targetSrTVL - perpSrTVL;
        if (imbalance == 0) return (0, false);

        isPerpSrPayer = perpSrTVL > targetSrTVL;
        uint256 payerTVL = isPerpSrPayer ? perpSrTVL : perpJrTVL;
        Debasement storage debasement = isPerpSrPayer ? perpSrDebasement : perpJrDebasement;
        uint256 linear = imbalance / debasement.lag;
        uint256 lower = Math.mulDiv(payerTVL, debasement.tvlPercLimits.lower, WAD);
        uint256 upper = Math.mulDiv(payerTVL, debasement.tvlPercLimits.upper, WAD);
        if (linear < lower) linear = lower;
        if (linear > upper) linear = upper;
        rebalVal = linear < imbalance ? linear : imbalance;
    }

    function _average(Curve storage curve, uint256 from, uint256 to) private view returns (uint256) {
        if (from == to) return 0;
        uint256 lo = from < to ? from : to;
        uint256 hi = from < to ? to : from;

        uint256 area;
        if (lo < curve.p1.x) area += _segmentArea(curve.p1, curve.p2, lo, _min(hi, curve.p1.x));
        area += _boundedSegmentArea(curve.p1, curve.p2, lo, hi);
        area += _boundedSegmentArea(curve.p2, curve.p3, lo, hi);
        area += _boundedSegmentArea(curve.p3, curve.p4, lo, hi);
        if (hi > curve.p4.x) area += _segmentArea(curve.p3, curve.p4, _max(lo, curve.p4.x), hi);
        uint256 average = area / (hi - lo);
        return average < WAD ? average : WAD;
    }

    function _boundedSegmentArea(Point storage leftPoint, Point storage rightPoint, uint256 lo, uint256 hi)
        private
        view
        returns (uint256)
    {
        uint256 left = _max(lo, leftPoint.x);
        uint256 right = _min(hi, rightPoint.x);
        if (right <= left) return 0;
        return _segmentArea(leftPoint, rightPoint, left, right);
    }

    function _segmentArea(Point storage leftPoint, Point storage rightPoint, uint256 left, uint256 right)
        private
        view
        returns (uint256)
    {
        if (right <= left) return 0;
        return Math.mulDiv(right - left, _segmentAverage(leftPoint, rightPoint, left, right), 1);
    }

    function _segmentAverage(Point storage leftPoint, Point storage rightPoint, uint256 left, uint256 right)
        private
        view
        returns (uint256)
    {
        uint256 dx = rightPoint.x - leftPoint.x;
        if (dx == 0) return rightPoint.y;
        if (rightPoint.y >= leftPoint.y) {
            uint256 risingDelta = rightPoint.y - leftPoint.y;
            return leftPoint.y + _midpointTerm(left, right, risingDelta, dx) - Math.mulDiv(leftPoint.x, risingDelta, dx);
        }
        uint256 fallingDelta = leftPoint.y - rightPoint.y;
        return leftPoint.y + Math.mulDiv(leftPoint.x, fallingDelta, dx) - _midpointTerm(left, right, fallingDelta, dx);
    }

    function _midpointTerm(uint256 left, uint256 right, uint256 dy, uint256 dx) private pure returns (uint256) {
        uint256 leftQuotient = Math.mulDiv(left, dy, dx);
        uint256 rightQuotient = Math.mulDiv(right, dy, dx);
        uint256 leftRemainder = mulmod(left, dy, dx);
        uint256 rightRemainder = mulmod(right, dy, dx);
        uint256 carry = leftRemainder >= dx - rightRemainder ? 1 : 0;
        return leftQuotient / 2 + rightQuotient / 2 + ((leftQuotient & 1) + (rightQuotient & 1) + carry) / 2;
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _validateFees(Fees calldata fees) private pure {
        if (fees.basePerc > WAD || fees.flashBasePerc > WAD) revert InvalidPerc();
        _validateCurve(fees.subDRUp);
        _validateCurve(fees.subDRDown);
        _validateCurve(fees.vmDRUp);
        _validateCurve(fees.vmDRDown);
    }

    function _validateCurve(Curve calldata curve) private pure {
        if (curve.p1.x > curve.p2.x || curve.p2.x > curve.p3.x || curve.p3.x > curve.p4.x) {
            revert InvalidParamDefn();
        }
        // BNB-DESIGN / CLEANROOM SAFETY: p1-p2 is extrapolated to the left and p3-p4 to the right. A rising
        // left edge or falling right edge can cross below zero and make fee computation revert system-wide.
        if (curve.p1.y < curve.p2.y || curve.p3.y > curve.p4.y) revert InvalidParamDefn();
        if (curve.p1.y > WAD || curve.p2.y > WAD || curve.p3.y > WAD || curve.p4.y > WAD) {
            revert InvalidPerc();
        }
    }

    function _validateDebasement(Debasement calldata d) private pure {
        if (d.lag == 0) revert InvalidParamDefn();
        if (d.tvlPercLimits.lower > d.tvlPercLimits.upper) revert InvalidRange();
        if (d.tvlPercLimits.upper > WAD) revert InvalidPerc();
    }

    function _defaultFees() private pure returns (Fees memory fees) {
        fees = Fees({
            subDRUp: Curve(
                Point(0, 0),
                Point(1_078_564_994_000_000_000, 0),
                Point(1_105_439_994_000_000_000, 20_000_000_000_000_000),
                Point(2 * WAD, 50_000_000_000_000_000)
            ),
            subDRDown: Curve(
                Point(0, 50_000_000_000_000_000),
                Point(1_003_564_994_000_000_000, 20_000_000_000_000_000),
                Point(1_028_564_994_000_000_000, 0),
                Point(2 * WAD, 0)
            ),
            vmDRUp: Curve(
                Point(0, 0),
                Point(WAD, 0),
                Point(1_025_000_000_000_000_000, 50_000_000_000_000_000),
                Point(1_076_250_000_000_000_000, WAD)
            ),
            vmDRDown: Curve(
                Point(928_571_429_000_000_000, WAD),
                Point(975_000_000_000_000_000, 50_000_000_000_000_000),
                Point(WAD, 0),
                Point(2 * WAD, 0)
            ),
            basePerc: 0,
            flashBasePerc: 0
        });
    }
}
