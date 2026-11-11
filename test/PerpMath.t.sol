// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PerpMath} from "../src/policy/PerpMath.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";

contract PerpMathTest is Test {
    uint256 private constant WAD = 1e18;

    PerpMath private math;
    address private constant FIRST = address(0x1001);
    address private constant SECOND = address(0x1002);

    function setUp() public {
        math = new PerpMath();
    }

    function testReserveAndDepositStateMatchIndependentArithmetic() public view {
        PerpBalancer.ReserveData memory rd = _reserveData();
        (uint256 reserveValue, uint256 vm) = math.reserveState(rd);
        uint256 vmValue = 100 * WAD + 200 * 2e18 + 300 * 5e17;
        assertEq(reserveValue, 600);
        assertEq(vm, vmValue / reserveValue);

        (uint256 supplyAfter, uint256 reserveAfter, uint256 vmAfter) =
            math.stateAfterDeposit(1_000, 600, rd, 50, 15e17, 80);
        assertEq(supplyAfter, 1_080);
        assertEq(reserveAfter, 650);
        assertEq(vmAfter, (vmValue + 50 * 15e17) / reserveAfter);
    }

    function testWithdrawalStateMatchesBothIndependentBranches() public view {
        PerpBalancer.ReserveData memory rd = _reserveData();
        uint256 preVm = 11e17;
        (uint256 supplyAfter, uint256 reserveAfter, uint256 proportionalVm) =
            math.stateAfterWithdrawal(1_000, 600, preVm, rd, 50, 40, true);
        assertEq(supplyAfter, 950);
        assertEq(reserveAfter, 560);
        assertEq(proportionalVm, preVm);

        (supplyAfter, reserveAfter, proportionalVm) = math.stateAfterWithdrawal(1_000, 600, preVm, rd, 50, 40, false);
        uint256 expectedVmValue = 60 * WAD + 200 * 2e18 + 300 * 5e17;
        assertEq(supplyAfter, 950);
        assertEq(reserveAfter, 560);
        assertEq(proportionalVm, expectedVmValue / reserveAfter);
    }

    function testRedeemBasketAndValueMatchIndependentFloors() public view {
        PerpBalancer.ReserveData memory rd = _reserveData();
        PerpBalancer.ReserveAmounts memory amounts = math.redeemBasket(rd, 333, 1_000);
        assertEq(amounts.underlyingAmt, 33);
        assertEq(amounts.trancheAmts.length, 2);
        assertEq(amounts.trancheAmts[0].token, FIRST);
        assertEq(amounts.trancheAmts[0].amount, 333);
        assertEq(amounts.trancheAmts[1].token, SECOND);
        assertEq(amounts.trancheAmts[1].amount, 166);

        uint256 expectedValue = 33 + Math.mulDiv(333, 600, 1_000) + Math.mulDiv(166, 1_200, 2_000);
        assertEq(math.basketValue(rd, amounts), expectedValue);
    }

    function testValueCapDirectionAndNoCrossingMatrix() public {
        uint256 targetRatio = 2e18;
        math.checkValueCap(100, 300, 120, 300, 350, 20, 0, targetRatio);

        vm.expectRevert(PerpMath.ValueCapExceeded.selector);
        math.checkValueCap(100, 300, 200, 300, 350, 100, 0, targetRatio);

        vm.expectRevert(PerpMath.ValueCapExceeded.selector);
        math.checkValueCap(100, 200, 101, 200, 250, 1, 0, targetRatio);

        math.checkValueCap(100, 200, 100, 200, 300, 0, 0, targetRatio);
    }

    function _reserveData() private view returns (PerpBalancer.ReserveData memory rd) {
        rd.underlyingBal = 100;
        rd.trancheData = new PerpBalancer.ReserveTrancheData[](2);
        rd.trancheData[0] = PerpBalancer.ReserveTrancheData(_trancheData(FIRST, 1_000, 600, 2e18), 1_000, 200);
        rd.trancheData[1] = PerpBalancer.ReserveTrancheData(_trancheData(SECOND, 2_000, 1_200, 5e17), 500, 300);
    }

    function _trancheData(address tranche, uint256 supply, uint256 claim, uint256 vm)
        private
        view
        returns (IBondsManager.TrancheData memory data)
    {
        data.trancheSupply = supply;
        data.trancheClaim = claim;
        data.totalClaim = claim;
        data.volatilityMultiplier = vm;
        data.underlyingOpenPrice = WAD;
        data.trancheRatio = 5e17;
        data.valueRatio = 5e17;
        data.tranche = tranche;
        data.manager = address(this);
    }
}
