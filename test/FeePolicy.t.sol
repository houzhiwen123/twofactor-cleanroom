// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {RebalanceReference} from "./ref/RebalanceReference.sol";

contract FeePolicyTest is Test {
    FeePolicy private policy;

    function setUp() public {
        FeePolicy implementation = new FeePolicy();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), address(this), abi.encodeCall(FeePolicy.init, ())
        );
        policy = FeePolicy(address(proxy));
    }

    function testComputeOpFeesGoldenVectors() public view {
        _assertFee(1e18, 1_200_000_000_000_000_000, 1e18, 1e18, 11_549_414_793_129_602);
        _assertFee(1_200_000_000_000_000_000, 1e18, 1e18, 1e18, 1_607_449_202_625_840);
        _assertFee(1e18, 800_000_000_000_000_000, 1e18, 1e18, 23_095_912_909_054_698);
        _assertFee(800_000_000_000_000_000, 1e18, 1e18, 1e18, 0);
        _assertFee(1e18, 1_500_000_000_000_000_000, 1e18, 1e18, 21_540_710_379_864_000);
        _assertFee(1e18, 2e18, 1e18, 1e18, 31_578_350_210_000_000);
        _assertFee(1e18, 500_000_000_000_000_000, 1e18, 1e18, 27_579_927_424_212_248);
        _assertFee(900_000_000_000_000_000, 1_100_000_000_000_000_000, 1e18, 1e18, 854_808_339_014_020);
        _assertFee(1e18, 1e18, 1e18, 1_200_000_000_000_000_000, 1e18);
        _assertFee(1e18, 1e18, 1e18, 800_000_000_000_000_000, 1e18);
        _assertFee(1e18, 1e18, 1e18, 1_050_000_000_000_000_000, 153_353_658_536_585_365);
        _assertFee(1e18, 1e18, 1e18, 950_000_000_000_000_000, 165_384_616_565_088_768);
        _assertFee(1e18, 1e18, 1e18, 1e18, 0);
    }

    function testComputeRebalanceValGoldenVectors() public view {
        _assertRebalance(1e10, 5e9, 1e18, 14_880_952, true);
        _assertRebalance(1e10, 2e10, 1e18, 10_951_404, false);
        _assertRebalance(1e11, 5e10, 1e18, 148_809_523, true);
        _assertRebalance(1e10, 3e10, 3e18, 0, false);
        _assertRebalance(1e10, 2e10, 3e18, 14_880_952, true);
        _assertRebalance(1e10, 4e10, 3e18, 14_880_952, false);
        _assertRebalance(1e10, 0, 1e18, 16_427_105, true);
        _assertRebalance(0, 1e10, 1e18, 5_475_702, false);
        _assertRebalance(128_490_118, 387_274_512, 2_847_475_019_000_000_000, 33_110, false);
        _assertRebalance(1e10, 29_900_000_000, 3e18, 148_809, true);
        _assertRebalance(1e10, 29_990_000_000, 3e18, 136_893, true);
        _assertRebalance(1e10, 29_999_900_000, 3e18, 25_000, true);
        _assertRebalance(1e10, 30_000_100_000, 3e18, 25_000, false);
        _assertRebalance(1e10, 30_100_000_000, 3e18, 148_809, false);
        _assertRebalance(100e8, 100e8, 1e18, 0, false);
        _assertRebalance(100e8, 50e8, 1e18, 14_880_952, true);
        _assertRebalance(100e8, 200e8, 1e18, 10_951_404, false);
        _assertRebalance(1_000e8, 500e8, 1e18, 148_809_523, true);
        _assertRebalance(50e8, 100e8, 1e18, 5_475_702, false);
    }

    function testFuzzRebalanceValMatchesIndependentModel(uint128 sr, uint128 jr, uint64 ratio) public view {
        vm.assume(ratio <= 20e18);
        (uint256 value, bool srPayer) = policy.computeRebalanceVal(sr, jr, ratio);
        (uint256 expected, bool expectedPayer) = RebalanceReference.quote(
            sr,
            jr,
            ratio,
            168,
            13_689_300_000_000,
            1_642_710_500_000_000,
            168,
            4_544_800_000_000,
            547_570_200_000_000
        );
        assertEq(value, expected);
        assertEq(srPayer, expectedPayer);
        uint256 targetSr = (uint256(sr) + jr) * 1e18 / (uint256(ratio) + 1e18);
        uint256 imbalance = sr > targetSr ? sr - targetSr : targetSr - sr;
        uint256 payerTVL = srPayer ? sr : jr;
        assertLe(value, imbalance);
        assertLe(value, payerTVL);
    }

    function _assertFee(uint256 subPre, uint256 subPost, uint256 vmPre, uint256 vmPost, uint256 expected)
        private
        view
    {
        FeePolicy.OpFeeInput memory input = FeePolicy.OpFeeInput({
            isPerpSrOp: true,
            isFlashOp: false,
            systemDeviation: FeePolicy.OpSystemChange({
                subDRPre: subPre, subDRPost: subPost, vmDRPre: vmPre, vmDRPost: vmPost
            })
        });
        FeePolicy.OpFees memory result = policy.computeOpFees(input);
        assertEq(result.totalFeePerc, expected);
        assertEq(result.protocolFeePerc, 0);
    }

    function _assertRebalance(uint256 sr, uint256 jr, uint256 ratio, uint256 expected, bool expectedPayer)
        private
        view
    {
        (uint256 actual, bool payer) = policy.computeRebalanceVal(sr, jr, ratio);
        assertEq(actual, expected);
        assertEq(payer, expectedPayer);
    }
}
