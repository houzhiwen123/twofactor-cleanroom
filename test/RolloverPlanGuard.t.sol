// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {RolloverPlanGuard} from "../src/policy/RolloverPlanGuard.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";

contract MockGuardManager {}

contract MockMaliciousPlanner {
    uint256 public mode;

    function setMode(uint256 mode_) external {
        mode = mode_;
    }

    function computeSystemRebalancePlan(PerpBalancer.ReserveData memory reserves, uint256)
        external
        view
        returns (PerpBalancer.ReserveAmounts memory plan)
    {
        plan.trancheAmts = new PerpBalancer.TokenAmount[](0);
        if (mode == 5) plan.underlyingAmt = reserves.underlyingBal + 1;
    }

    function computePerpSrRolloverPlan(
        PerpBalancer.ReserveData memory srReserves,
        PerpBalancer.ReserveData memory,
        address,
        uint32,
        uint256
    ) external view returns (PerpBalancer.RolloverExecution memory execution) {
        execution.underlyingValRolled = 1;
        if (mode == 1) {
            execution.stale.trancheAmts = new PerpBalancer.TokenAmount[](2);
            execution.stale.trancheAmts[0] = PerpBalancer.TokenAmount(srReserves.trancheData[0].data.tranche, 1);
            execution.stale.trancheAmts[1] = PerpBalancer.TokenAmount(srReserves.trancheData[0].data.tranche, 1);
        } else if (mode == 2) {
            execution.stale.trancheAmts = new PerpBalancer.TokenAmount[](1);
            execution.stale.trancheAmts[0] =
                PerpBalancer.TokenAmount(srReserves.trancheData[0].data.tranche, srReserves.trancheData[0].balance + 1);
        } else if (mode == 3 || mode == 4) {
            PerpBalancer.ReserveTrancheData memory fresh = srReserves.trancheData[1];
            uint256 deposit = mode == 3 ? 220 : 361;
            execution.freshBondDepositAmts = new PerpBalancer.BondDepositParams[](1);
            execution.freshBondDepositAmts[0] = PerpBalancer.BondDepositParams(fresh.data.bondID, deposit);
            execution.freshSrTrAmts = new PerpBalancer.TokenAmount[](1);
            uint256 expected = deposit / 2;
            execution.freshSrTrAmts[0] =
                PerpBalancer.TokenAmount(fresh.data.tranche, mode == 3 ? expected + 1 : expected);
        }
    }
}

contract RolloverPlanGuardTest is Test {
    address private constant STALE_SR = address(0x101);
    address private constant FRESH_SR = address(0x102);
    address private constant STALE_JR = address(0x201);
    address private constant FRESH_JR = address(0x202);
    bytes32 private constant STALE_BOND = bytes32(uint256(1));
    bytes32 private constant FRESH_BOND = bytes32(uint256(2));

    MockGuardManager private manager;
    PerpBalancer private canonicalPlanner;
    MockMaliciousPlanner private maliciousPlanner;

    function setUp() public {
        manager = new MockGuardManager();
        canonicalPlanner = new PerpBalancer();
        maliciousPlanner = new MockMaliciousPlanner();
    }

    function testCanonicalPlannerOutputPassesGuardExactly() public {
        RolloverPlanGuard guard = new RolloverPlanGuard(address(canonicalPlanner), address(manager));
        (PerpBalancer.ReserveData memory sr, PerpBalancer.ReserveData memory jr) = _reserves();

        PerpBalancer.RolloverExecution memory execution =
            guard.computePerpSrRolloverPlan(sr, jr, address(manager), 10, 50);

        assertEq(execution.underlyingValRolled, 110);
        assertEq(execution.stale.underlyingAmt, 10);
        assertEq(execution.stale.trancheAmts.length, 1);
        assertEq(execution.stale.trancheAmts[0].token, STALE_SR);
        assertEq(execution.stale.trancheAmts[0].amount, 100);
        assertEq(execution.freshBondDepositAmts[0].underlyingAmt, 220);
        assertEq(execution.freshSrTrAmts[0].token, FRESH_SR);
        assertEq(execution.freshSrTrAmts[0].amount, 110);
    }

    function testRejectsDuplicateStaleToken() public {
        maliciousPlanner.setMode(1);
        _expectInvalidRollover();
    }

    function testRejectsStaleReserveOverdraw() public {
        maliciousPlanner.setMode(2);
        _expectInvalidRollover();
    }

    function testRejectsFreshMintAmountMismatch() public {
        maliciousPlanner.setMode(3);
        _expectInvalidRollover();
    }

    function testRejectsDepositAboveJrFreeAndUnlockedLiquidity() public {
        maliciousPlanner.setMode(4);
        _expectInvalidRollover();
    }

    function testRejectsSystemRebalanceOverdraw() public {
        maliciousPlanner.setMode(5);
        RolloverPlanGuard guard = new RolloverPlanGuard(address(maliciousPlanner), address(manager));
        (PerpBalancer.ReserveData memory sr,) = _reserves();
        vm.expectRevert(RolloverPlanGuard.InvalidPlan.selector);
        guard.computeSystemRebalancePlan(sr, 1);
    }

    function testRejectsManagerDifferentFromImmutableCanonicalManager() public {
        RolloverPlanGuard guard = new RolloverPlanGuard(address(canonicalPlanner), address(manager));
        (PerpBalancer.ReserveData memory sr, PerpBalancer.ReserveData memory jr) = _reserves();
        vm.expectRevert(RolloverPlanGuard.InvalidBondsManager.selector);
        guard.computePerpSrRolloverPlan(sr, jr, address(0xBEEF), 10, 50);
    }

    function _expectInvalidRollover() private {
        RolloverPlanGuard guard = new RolloverPlanGuard(address(maliciousPlanner), address(manager));
        (PerpBalancer.ReserveData memory sr, PerpBalancer.ReserveData memory jr) = _reserves();
        vm.expectRevert(RolloverPlanGuard.InvalidPlan.selector);
        guard.computePerpSrRolloverPlan(sr, jr, address(manager), 10, 50);
    }

    function _reserves() private view returns (PerpBalancer.ReserveData memory sr, PerpBalancer.ReserveData memory jr) {
        sr.underlyingBal = 10;
        sr.trancheData = new PerpBalancer.ReserveTrancheData[](2);
        sr.trancheData[0] = _row(STALE_SR, STALE_JR, STALE_BOND, true, 1, 100, 100);
        sr.trancheData[1] = _row(FRESH_SR, FRESH_JR, FRESH_BOND, true, 1_000, 100, 100);

        jr.underlyingBal = 200;
        jr.trancheData = new PerpBalancer.ReserveTrancheData[](1);
        jr.trancheData[0] = _row(STALE_JR, STALE_SR, STALE_BOND, false, 1, 100, 100);
    }

    function _row(
        address token,
        address counterpart,
        bytes32 bondID,
        bool isSenior,
        uint64 secondsToMaturity,
        uint256 balance,
        uint256 value
    ) private view returns (PerpBalancer.ReserveTrancheData memory row) {
        row.data = IBondsManager.TrancheData({
            trancheSupply: 100,
            trancheClaim: 100,
            totalClaim: 200,
            volatilityMultiplier: isSenior ? 0 : 2e18,
            underlyingOpenPrice: 1e18,
            isMature: false,
            secondsToMaturity: secondsToMaturity,
            trancheRatio: 5e17,
            valueRatio: 5e17,
            bondID: bondID,
            isSenior: isSenior,
            tranche: token,
            counterpart: counterpart,
            manager: address(manager)
        });
        row.balance = balance;
        row.value = value;
    }
}
