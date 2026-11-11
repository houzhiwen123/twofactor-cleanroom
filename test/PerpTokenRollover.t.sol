// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockRolloverBondsManager {
    using SafeERC20 for IERC20;

    error ForcedFailure();

    MockERC20 public immutable underlying;
    MockERC20 public immutable senior;
    MockERC20 public immutable junior;
    uint256 public callCount;
    uint256 public revertOnCall;

    constructor(MockERC20 underlying_) {
        underlying = underlying_;
        senior = new MockERC20("Senior tranche", "SR-T", 8);
        junior = new MockERC20("Junior tranche", "JR-T", 8);
    }

    function setRevertOnCall(uint256 callNumber) external {
        revertOnCall = callNumber;
    }

    function deposit(bytes32, uint256 underlyingAmt)
        external
        returns (IBondsManager.TokenAmount memory srTrAmt, IBondsManager.TokenAmount memory jrTrAmt)
    {
        ++callCount;
        if (callCount == revertOnCall) revert ForcedFailure();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmt);
        uint256 srAmount = underlyingAmt * 2;
        uint256 jrAmount = underlyingAmt * 3;
        senior.mint(msg.sender, srAmount);
        junior.mint(msg.sender, jrAmount);
        return
            (IBondsManager.TokenAmount(address(senior), srAmount), IBondsManager.TokenAmount(address(junior), jrAmount));
    }
}

contract PerpTokenRolloverTest is Test {
    bytes32 private constant RESERVE_SYNCED = keccak256("ReserveSynced(address,uint256)");
    address private constant RANDOM = address(0xBEEF);

    MockERC20 private underlying;
    MockRolloverBondsManager private manager;
    PerpToken private juniorPerp;
    PerpToken private seniorPerp;

    function setUp() public {
        underlying = new MockERC20("Wrapped BTC", "WBTC", 8);
        manager = new MockRolloverBondsManager(underlying);
        juniorPerp = new PerpToken(
            "Junior Perp", "JR-P", address(underlying), address(manager), address(this), true, address(this)
        );
        seniorPerp = new PerpToken(
            "Senior Perp", "SR-P", address(underlying), address(manager), address(this), false, address(this)
        );
    }

    function testBondDepositsForRolloverPermissionAndSeniorRejection() public {
        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](0);

        vm.prank(RANDOM);
        vm.expectRevert(PerpToken.UnauthorizedCall.selector);
        juniorPerp.bondDepositsForRollover(address(manager), deposits);

        (bool success, bytes memory returndata) =
            address(seniorPerp).call(abi.encodeCall(IPerpToken.bondDepositsForRollover, (address(manager), deposits)));
        assertFalse(success);
        assertEq(returndata.length, 0);
    }

    function testEmptyAndZeroDepositsMatchRound11EventBehavior() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);

        IPerpToken.BondDeposit[] memory empty = new IPerpToken.BondDeposit[](0);
        vm.recordLogs();
        juniorPerp.bondDepositsForRollover(address(manager), empty);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_reserveSyncCount(logs), 1);
        _assertNthReserveSync(logs, 0, address(underlying), 1_000);

        IPerpToken.BondDeposit[] memory zero = new IPerpToken.BondDeposit[](1);
        zero[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 0);
        vm.recordLogs();
        juniorPerp.bondDepositsForRollover(address(manager), zero);
        logs = vm.getRecordedLogs();
        assertEq(_reserveSyncCount(logs), 3);
        _assertNthReserveSync(logs, 0, address(manager.senior()), 0);
        _assertNthReserveSync(logs, 1, address(manager.junior()), 0);
        _assertNthReserveSync(logs, 2, address(underlying), 1_000);
        assertEq(juniorPerp.trancheTokens().length, 0);
    }

    function testPositiveAndRepeatedDepositsRegisterAndSyncReserves() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);

        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](2);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 400);
        deposits[1] = IPerpToken.BondDeposit(bytes32(uint256(2)), 600);

        vm.recordLogs();
        juniorPerp.bondDepositsForRollover(address(manager), deposits);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(underlying.balanceOf(address(juniorPerp)), 0);
        assertEq(underlying.balanceOf(address(manager)), 1_000);
        assertEq(manager.senior().balanceOf(address(juniorPerp)), 2_000);
        assertEq(manager.junior().balanceOf(address(juniorPerp)), 3_000);
        assertEq(underlying.allowance(address(juniorPerp), address(manager)), type(uint256).max);

        address[] memory tranches = juniorPerp.trancheTokens();
        assertEq(tranches.length, 2);
        assertEq(tranches[0], address(manager.senior()));
        assertEq(tranches[1], address(manager.junior()));
        assertEq(_reserveSyncCount(logs), 5);
        _assertNthReserveSync(logs, 4, address(underlying), 0);
    }

    function testSecondDepositRevertRollsBackFirstDeposit() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);
        manager.setRevertOnCall(2);

        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](2);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 400);
        deposits[1] = IPerpToken.BondDeposit(bytes32(uint256(2)), 600);

        vm.expectRevert(MockRolloverBondsManager.ForcedFailure.selector);
        juniorPerp.bondDepositsForRollover(address(manager), deposits);

        assertEq(manager.callCount(), 0);
        assertEq(underlying.balanceOf(address(juniorPerp)), 1_000);
        assertEq(underlying.balanceOf(address(manager)), 0);
        assertEq(manager.senior().balanceOf(address(juniorPerp)), 0);
        assertEq(manager.junior().balanceOf(address(juniorPerp)), 0);
        assertEq(juniorPerp.trancheTokens().length, 0);
    }

    function testCapacityFailureIsAtomic() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);
        for (uint160 i = 1; i <= 49; ++i) {
            juniorPerp.registerTranche(address(i));
        }

        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](1);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 1_000);

        vm.expectRevert(PerpToken.ReserveOverflow.selector);
        juniorPerp.bondDepositsForRollover(address(manager), deposits);

        assertEq(juniorPerp.trancheTokens().length, 49);
        assertEq(underlying.balanceOf(address(juniorPerp)), 1_000);
        assertEq(underlying.balanceOf(address(manager)), 0);
        assertEq(manager.senior().balanceOf(address(juniorPerp)), 0);
        assertEq(manager.junior().balanceOf(address(juniorPerp)), 0);
    }

    function _reserveSyncCount(Vm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length != 0 && logs[i].topics[0] == RESERVE_SYNCED) ++count;
        }
    }

    function _primeManagerApproval() private {
        (bool success,) = address(juniorPerp).call(abi.encodeWithSignature("primeApproval(address)", address(manager)));
        assertTrue(success);
    }

    function _assertNthReserveSync(Vm.Log[] memory logs, uint256 wanted, address token, uint256 balance) private {
        uint256 index;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != RESERVE_SYNCED) continue;
            if (index++ != wanted) continue;
            (address loggedToken, uint256 loggedBalance) = abi.decode(logs[i].data, (address, uint256));
            assertEq(loggedToken, token);
            assertEq(loggedBalance, balance);
            return;
        }
        fail();
    }
}
