// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockRolloverTranche is MockERC20 {
    address public immutable manager;
    bytes32 public immutable bondID;
    bool public immutable isSenior;

    constructor(address manager_, bytes32 bondID_, bool isSenior_)
        MockERC20(isSenior_ ? "Senior tranche" : "Junior tranche", isSenior_ ? "SR-T" : "JR-T", 8)
    {
        manager = manager_;
        bondID = bondID_;
        isSenior = isSenior_;
    }

    function data() external view returns (IBondsManager.TrancheData memory result) {
        (address senior, address junior) = MockRolloverBondsManager(manager).tranches(bondID);
        uint256 supply = totalSupply();
        result = IBondsManager.TrancheData({
            trancheSupply: supply,
            trancheClaim: supply,
            totalClaim: supply * 2,
            volatilityMultiplier: isSenior ? 0 : 2e18,
            underlyingOpenPrice: 1e18,
            isMature: false,
            secondsToMaturity: 30 days,
            trancheRatio: 5e17,
            valueRatio: 5e17,
            bondID: bondID,
            isSenior: isSenior,
            tranche: address(this),
            counterpart: isSenior ? junior : senior,
            manager: manager
        });
    }
}

contract MockRolloverBondsManager {
    using SafeERC20 for IERC20;

    error ForcedFailure();

    struct Pair {
        MockRolloverTranche senior;
        MockRolloverTranche junior;
    }

    MockERC20 public immutable underlying;
    mapping(bytes32 => Pair) private _pairs;
    uint256 public callCount;
    uint256 public revertOnCall;
    bool public misreportSeniorAmount;

    constructor(MockERC20 underlying_) {
        underlying = underlying_;
    }

    function createPair(bytes32 bondID)
        external
        returns (MockRolloverTranche seniorTranche, MockRolloverTranche juniorTranche)
    {
        seniorTranche = new MockRolloverTranche(address(this), bondID, true);
        juniorTranche = new MockRolloverTranche(address(this), bondID, false);
        _pairs[bondID] = Pair(seniorTranche, juniorTranche);
    }

    function tranches(bytes32 bondID) external view returns (address seniorTranche, address juniorTranche) {
        Pair storage pair = _pairs[bondID];
        return (address(pair.senior), address(pair.junior));
    }

    function senior(bytes32 bondID) external view returns (MockRolloverTranche) {
        return _pairs[bondID].senior;
    }

    function junior(bytes32 bondID) external view returns (MockRolloverTranche) {
        return _pairs[bondID].junior;
    }

    function setRevertOnCall(uint256 callNumber) external {
        revertOnCall = callNumber;
    }

    function setMisreportSeniorAmount(bool enabled) external {
        misreportSeniorAmount = enabled;
    }

    function deposit(bytes32 bondID, uint256 underlyingAmt)
        external
        returns (IBondsManager.TokenAmount memory srTrAmt, IBondsManager.TokenAmount memory jrTrAmt)
    {
        ++callCount;
        if (callCount == revertOnCall) revert ForcedFailure();
        IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmt);
        uint256 srAmount = underlyingAmt * 2;
        uint256 jrAmount = underlyingAmt * 3;
        Pair storage pair = _pairs[bondID];
        pair.senior.mint(msg.sender, srAmount);
        pair.junior.mint(msg.sender, jrAmount);
        return (
            IBondsManager.TokenAmount(address(pair.senior), srAmount + (misreportSeniorAmount ? 1 : 0)),
            IBondsManager.TokenAmount(address(pair.junior), jrAmount)
        );
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
        manager.createPair(bytes32(uint256(1)));
        manager.createPair(bytes32(uint256(2)));
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
        _assertNthReserveSync(logs, 0, address(manager.senior(bytes32(uint256(1)))), 0);
        _assertNthReserveSync(logs, 1, address(manager.junior(bytes32(uint256(1)))), 0);
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
        assertEq(manager.senior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 800);
        assertEq(manager.junior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 1_200);
        assertEq(manager.senior(bytes32(uint256(2))).balanceOf(address(juniorPerp)), 1_200);
        assertEq(manager.junior(bytes32(uint256(2))).balanceOf(address(juniorPerp)), 1_800);
        assertEq(underlying.allowance(address(juniorPerp), address(manager)), type(uint256).max);

        address[] memory tranches = juniorPerp.trancheTokens();
        assertEq(tranches.length, 4);
        assertEq(tranches[0], address(manager.senior(bytes32(uint256(1)))));
        assertEq(tranches[1], address(manager.junior(bytes32(uint256(1)))));
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
        assertEq(manager.senior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 0);
        assertEq(manager.junior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 0);
        assertEq(juniorPerp.trancheTokens().length, 0);
    }

    function testCapacityFailureIsAtomic() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);
        for (uint256 i = 10; i < 34; ++i) {
            (MockRolloverTranche senior, MockRolloverTranche junior) = manager.createPair(bytes32(i));
            juniorPerp.registerTranche(address(senior));
            juniorPerp.registerTranche(address(junior));
        }
        (MockRolloverTranche lastSenior,) = manager.createPair(bytes32(uint256(34)));
        juniorPerp.registerTranche(address(lastSenior));
        manager.createPair(bytes32(uint256(99)));

        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](1);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(99)), 1_000);

        vm.expectRevert(PerpToken.ReserveOverflow.selector);
        juniorPerp.bondDepositsForRollover(address(manager), deposits);

        assertEq(juniorPerp.trancheTokens().length, 49);
        assertEq(underlying.balanceOf(address(juniorPerp)), 1_000);
        assertEq(underlying.balanceOf(address(manager)), 0);
        assertEq(manager.senior(bytes32(uint256(99))).balanceOf(address(juniorPerp)), 0);
        assertEq(manager.junior(bytes32(uint256(99))).balanceOf(address(juniorPerp)), 0);
    }

    function testRejectsNonCanonicalManagerBeforeAssetMovement() public {
        underlying.mint(address(juniorPerp), 1_000);
        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](1);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 1_000);

        vm.expectRevert(PerpToken.InvalidBondsManager.selector);
        juniorPerp.bondDepositsForRollover(address(0xBEEF), deposits);

        assertEq(underlying.balanceOf(address(juniorPerp)), 1_000);
        assertEq(juniorPerp.trancheTokens().length, 0);
    }

    function testMisreportedDepositAmountRollsBackAllBalances() public {
        _primeManagerApproval();
        underlying.mint(address(juniorPerp), 1_000);
        manager.setMisreportSeniorAmount(true);
        IPerpToken.BondDeposit[] memory deposits = new IPerpToken.BondDeposit[](1);
        deposits[0] = IPerpToken.BondDeposit(bytes32(uint256(1)), 1_000);

        vm.expectRevert(PerpToken.InvalidDepositResult.selector);
        juniorPerp.bondDepositsForRollover(address(manager), deposits);

        assertEq(underlying.balanceOf(address(juniorPerp)), 1_000);
        assertEq(underlying.balanceOf(address(manager)), 0);
        assertEq(manager.senior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 0);
        assertEq(manager.junior(bytes32(uint256(1))).balanceOf(address(juniorPerp)), 0);
        assertEq(juniorPerp.trancheTokens().length, 0);
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
