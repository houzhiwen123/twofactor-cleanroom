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
        if (perpSrAUMFeePerc_ > WAD || perpJrAUMFeePerc_ > WAD) revert InvalidPerc();
        perpSrAUMFeePerc = perpSrAUMFeePerc_;
        perpJrAUMFeePerc = perpJrAUMFeePerc_;
    }

    function updateProtocolFeeConfig(uint64 protocolMaxOpFeePerc_, address protocolFeeCollector_)
        external
        onlyOwner
    {
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
        Curve storage subCurve = ip.systemDeviation.subDRPost >= ip.systemDeviation.subDRPre
            ? fees.subDRUp
            : fees.subDRDown;
        Curve storage vmCurve =
            ip.systemDeviation.vmDRPost >= ip.systemDeviation.vmDRPre ? fees.vmDRUp : fees.vmDRDown;
        total += _average(
            subCurve, ip.systemDeviation.subDRPre, ip.systemDeviation.subDRPost
        );
        total += _average(vmCurve, ip.systemDeviation.vmDRPre, ip.systemDeviation.vmDRPost);
        if (total > WAD) total = WAD;
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
        if (from == to) return _valueAt(curve, from);
        // Floors interpolation and trapezoid areas before dividing by the interval width.
        uint256 lo = from < to ? from : to;
        uint256 hi = from < to ? to : from;

        uint256 area;
        if (lo < curve.p1.x) area += _rangeArea(curve, lo, _min(hi, curve.p1.x));
        area += _segmentArea(curve, lo, hi, curve.p1.x, curve.p2.x);
        area += _segmentArea(curve, lo, hi, curve.p2.x, curve.p3.x);
        area += _segmentArea(curve, lo, hi, curve.p3.x, curve.p4.x);
        if (hi > curve.p4.x) area += _rangeArea(curve, _max(lo, curve.p4.x), hi);
        return area / (hi - lo);
    }

    function _rangeArea(Curve storage curve, uint256 left, uint256 right) private view returns (uint256) {
        return Math.mulDiv(right - left, _valueAt(curve, left) + _valueAt(curve, right), 2);
    }

    function _segmentArea(Curve storage curve, uint256 lo, uint256 hi, uint256 x0, uint256 x1)
        private
        view
        returns (uint256)
    {
        uint256 left = _max(lo, x0);
        uint256 right = _min(hi, x1);
        if (right <= left) return 0;
        return Math.mulDiv(right - left, _valueAt(curve, left) + _valueAt(curve, right), 2);
    }

    function _valueAt(Curve storage curve, uint256 x) private view returns (uint256) {
        Point storage p1 = curve.p1;
        Point storage p2 = curve.p2;
        Point storage p3 = curve.p3;
        Point storage p4 = curve.p4;
        // The 100% VM boundary vector implies extrapolating the endpoint segment.
        if (x < p1.x) return _interpolate(p1, p2, x);
        if (x > p4.x) return _interpolate(p3, p4, x);
        if (x <= p2.x) return _interpolate(p1, p2, x);
        if (x <= p3.x) return _interpolate(p2, p3, x);
        return _interpolate(p3, p4, x);
    }

    function _interpolate(Point storage left, Point storage right, uint256 x) private view returns (uint256) {
        if (right.x == left.x) return right.y;
        uint256 offset = x >= left.x ? x - left.x : left.x - x;
        uint256 delta = right.y >= left.y
            ? Math.mulDiv(offset, right.y - left.y, right.x - left.x)
            : Math.mulDiv(offset, left.y - right.y, right.x - left.x);
        bool addDelta = (right.y >= left.y) == (x >= left.x);
        if (addDelta) {
            return left.y + delta;
        }
        return left.y - delta;
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
