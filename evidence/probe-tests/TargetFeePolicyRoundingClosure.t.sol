// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {FeePolicy} from "../../src/policy/FeePolicy.sol";

/// @notice Clean-room black-box rounding matrix using a fresh local proxy backed by the
/// fixed target implementation. The deployed target proxy is never mutated.
contract TargetFeePolicyRoundingClosureTest is Test {
    uint256 private constant WAD = 1e18;
    uint256 private constant FIXED_BLOCK = 54_990_962;
    uint256 private constant TARGET_X = 1_078_564_994_000_000_000;
    address private constant TARGET_FEE_POLICY_IMPL = 0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900;
    bytes32 private constant TARGET_FEE_POLICY_IMPL_CODEHASH =
        0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755;

    FeePolicy private target;
    uint256 private observationCount;

    event RoundingObservation(
        uint8 indexed group,
        uint16 indexed originShift,
        uint16 indexed intervalOffset,
        uint256 origin,
        uint256 start,
        uint256 end,
        bool success,
        bytes4 errorSelector,
        uint256 targetTotalFee,
        uint256 targetProtocolFee
    );

    event RoundingClosureSummary(uint256 observations);

    function setUp() public {
        require(block.chainid == 8453, "TARGET_FORK_CHAIN_ID");
        require(block.number == FIXED_BLOCK, "TARGET_FORK_BLOCK");
        assertEq(TARGET_FEE_POLICY_IMPL.codehash, TARGET_FEE_POLICY_IMPL_CODEHASH, "target impl codehash");
        target = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    TARGET_FEE_POLICY_IMPL, address(this), abi.encodeWithSignature("init()")
                )
            )
        );
        assertEq(target.owner(), address(this), "fresh target proxy owner");
    }

    function testTargetFeePolicyRoundingClosure() public {
        _increasingResidueGrid();
        _decreasingResidueGrid();
        _decreasingFourOverFiveGrid();
        _surroundingPointControls();
        assertEq(observationCount, 4_158, "rounding closure observation count");
        emit RoundingClosureSummary(observationCount);
    }

    function _increasingResidueGrid() private {
        for (uint16 shift; shift < 43; ++shift) {
            uint256 origin = WAD + shift;
            _setCurves(_increasing32Over43(origin, 0, 2 * WAD), _zeroCurve());
            for (uint16 offset; offset < 43; ++offset) {
                _observe(0, shift, offset, origin, origin + offset, origin + offset + 1, true);
            }
            _observe(2, shift, 0, origin, origin - 1, origin + 1, true);
            _observe(3, shift, 42, origin, origin + 42, origin + 44, true);
        }

        for (uint16 shift; shift < 43; ++shift) {
            uint256 origin = TARGET_X + shift;
            _setCurves(_increasing32Over43(origin, 0, 2 * WAD), _zeroCurve());
            _observe(1, shift, 0, origin, origin, origin + 1, true);
        }
    }

    function _decreasingResidueGrid() private {
        for (uint16 shift; shift < 43; ++shift) {
            uint256 origin = WAD + shift;
            _setCurves(_zeroCurve(), _decreasing32Over43(origin, 0, 2 * WAD));
            for (uint16 offset; offset < 43; ++offset) {
                _observe(4, shift, offset, origin, origin + offset, origin + offset + 1, false);
            }
            _observe(6, shift, 0, origin, origin - 1, origin + 1, false);
            _observe(7, shift, 42, origin, origin + 42, origin + 44, false);
        }

        for (uint16 shift; shift < 43; ++shift) {
            uint256 origin = TARGET_X + shift;
            _setCurves(_zeroCurve(), _decreasing32Over43(origin, 0, 2 * WAD));
            _observe(5, shift, 0, origin, origin, origin + 1, false);
        }
    }

    function _decreasingFourOverFiveGrid() private {
        for (uint16 shift; shift < 5; ++shift) {
            uint256 origin = WAD + shift;
            _setCurves(_zeroCurve(), _decreasing4Over5(origin, 0, 2 * WAD));
            for (uint16 offset; offset < 5; ++offset) {
                _observe(8, shift, offset, origin, origin + offset, origin + offset + 1, false);
            }
        }

        for (uint16 shift; shift < 5; ++shift) {
            uint256 origin = TARGET_X + shift;
            _setCurves(_zeroCurve(), _decreasing4Over5(origin, 0, 2 * WAD));
            _observe(9, shift, 0, origin, origin, origin + 1, false);
        }
    }

    function _surroundingPointControls() private {
        uint256 origin = WAD + 10;
        uint256 nearP1 = origin - 101;
        uint256 nearP4 = origin + 144;

        _setCurves(_increasing32Over43(origin, nearP1, 2 * WAD), _zeroCurve());
        for (uint16 offset; offset < 43; ++offset) {
            _observe(10, 10, offset, origin, origin + offset, origin + offset + 1, true);
        }
        _setCurves(_increasing32Over43(origin, 0, nearP4), _zeroCurve());
        for (uint16 offset; offset < 43; ++offset) {
            _observe(11, 10, offset, origin, origin + offset, origin + offset + 1, true);
        }

        _setCurves(_zeroCurve(), _decreasing32Over43(origin, nearP1, 2 * WAD));
        for (uint16 offset; offset < 43; ++offset) {
            _observe(12, 10, offset, origin, origin + offset, origin + offset + 1, false);
        }
        _setCurves(_zeroCurve(), _decreasing32Over43(origin, 0, nearP4));
        for (uint16 offset; offset < 43; ++offset) {
            _observe(13, 10, offset, origin, origin + offset, origin + offset + 1, false);
        }
    }

    function _observe(
        uint8 group,
        uint16 originShift,
        uint16 intervalOffset,
        uint256 origin,
        uint256 start,
        uint256 end,
        bool increasing
    ) private {
        FeePolicy.OpSystemChange memory change = FeePolicy.OpSystemChange({
            subDRPre: increasing ? start : end, subDRPost: increasing ? end : start, vmDRPre: WAD, vmDRPost: WAD
        });
        bytes memory result;
        (bool success, bytes memory callResult) = address(target)
            .staticcall(abi.encodeCall(FeePolicy.computeOpFees, (FeePolicy.OpFeeInput(true, false, change))));
        result = callResult;
        bytes4 selector;
        FeePolicy.OpFees memory fees;
        if (success) {
            fees = abi.decode(result, (FeePolicy.OpFees));
        } else if (result.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(result, 0x20))
            }
        }
        assertTrue(success, "target rounding vector reverted");
        observationCount++;
        emit RoundingObservation(
            group,
            originShift,
            intervalOffset,
            origin,
            start,
            end,
            success,
            selector,
            fees.totalFeePerc,
            fees.protocolFeePerc
        );
    }

    function _setCurves(FeePolicy.Curve memory subUp, FeePolicy.Curve memory subDown) private {
        FeePolicy.Curve memory zero = _zeroCurve();
        FeePolicy.Fees memory fees = FeePolicy.Fees({
            subDRUp: subUp, subDRDown: subDown, vmDRUp: zero, vmDRDown: zero, basePerc: 0, flashBasePerc: 0
        });
        target.updateFeeParams(fees, fees);
    }

    function _increasing32Over43(uint256 origin, uint256 p1x, uint256 p4x)
        private
        pure
        returns (FeePolicy.Curve memory curve)
    {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(p1x, 0),
            p2: FeePolicy.Point(origin, 0),
            p3: FeePolicy.Point(origin + 43, 32),
            p4: FeePolicy.Point(p4x, 1_000)
        });
    }

    function _decreasing32Over43(uint256 origin, uint256 p1x, uint256 p4x)
        private
        pure
        returns (FeePolicy.Curve memory curve)
    {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(p1x, 1_000),
            p2: FeePolicy.Point(origin, 32),
            p3: FeePolicy.Point(origin + 43, 0),
            p4: FeePolicy.Point(p4x, 0)
        });
    }

    function _decreasing4Over5(uint256 origin, uint256 p1x, uint256 p4x)
        private
        pure
        returns (FeePolicy.Curve memory curve)
    {
        curve = FeePolicy.Curve({
            p1: FeePolicy.Point(p1x, 1_000),
            p2: FeePolicy.Point(origin, 4),
            p3: FeePolicy.Point(origin + 5, 0),
            p4: FeePolicy.Point(p4x, 0)
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
}
