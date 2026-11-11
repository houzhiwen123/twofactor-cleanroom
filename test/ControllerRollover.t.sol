// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PerpController, IBondIssuerController} from "../src/controller/PerpController.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";

contract RolloverCallRecorder {
    uint8[] private _ops;

    function record(uint8 operation) external {
        _ops.push(operation);
    }

    function count() external view returns (uint256) {
        return _ops.length;
    }

    function op(uint256 index) external view returns (uint8) {
        return _ops[index];
    }
}

contract MockControllerRolloverPlanner {
    error PlannerFailure();

    address internal immutable managerExpected;
    address internal constant STALE_TOKEN = 0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B;
    address internal constant FRESH_ZERO_TOKEN = 0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68;
    address internal constant FRESH_A_TOKEN = 0x2b97045571Ec78aE1010Df47b3e275eCdAE53300;
    address internal constant FRESH_LATEST_TOKEN = 0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1;
    bytes32 internal constant BOND_C = 0x342b85e9d38918a8718c6ea642ea0df75e75c938bc45a6efde8c1dbaa3ef108d;
    bytes32 internal constant BOND_A = 0x93dcba573477147233c33c344a994ff99eedbe3ac9c31c2c5198f72add177ca8;
    bytes32 internal constant BOND_LATEST = 0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b;

    uint256 public underlyingValRolled = 41_875_890;
    bool public failPlanning;

    constructor(address manager_) {
        managerExpected = manager_;
    }

    function setUnderlyingValRolled(uint256 value) external {
        underlyingValRolled = value;
    }

    function setFailPlanning(bool fail) external {
        failPlanning = fail;
    }

    function computePerpSrRolloverPlan(
        PerpBalancer.ReserveData memory,
        PerpBalancer.ReserveData memory,
        address manager,
        uint32 minMaturitySec,
        uint256 reservedPerpJrLiquidity
    ) external view returns (PerpBalancer.RolloverExecution memory execution) {
        if (failPlanning) revert PlannerFailure();
        require(manager == managerExpected, "manager");
        require(minMaturitySec == 604_800, "maturity");
        require(reservedPerpJrLiquidity == 3_864_657, "reserved");

        execution.stale.underlyingAmt = 0;
        execution.stale.trancheAmts = new PerpBalancer.TokenAmount[](1);
        execution.stale.trancheAmts[0] = PerpBalancer.TokenAmount(STALE_TOKEN, 3_133_547_705_520);

        execution.freshBondDepositAmts = new PerpBalancer.BondDepositParams[](3);
        execution.freshBondDepositAmts[0] = PerpBalancer.BondDepositParams(BOND_C, 0);
        execution.freshBondDepositAmts[1] = PerpBalancer.BondDepositParams(BOND_A, 6_411_258);
        execution.freshBondDepositAmts[2] = PerpBalancer.BondDepositParams(BOND_LATEST, 77_245_228);

        execution.freshSrTrAmts = new PerpBalancer.TokenAmount[](3);
        execution.freshSrTrAmts[0] = PerpBalancer.TokenAmount(FRESH_ZERO_TOKEN, 0);
        execution.freshSrTrAmts[1] = PerpBalancer.TokenAmount(FRESH_A_TOKEN, 243_440_724_687);
        execution.freshSrTrAmts[2] = PerpBalancer.TokenAmount(FRESH_LATEST_TOKEN, 2_890_107_281_474);
        execution.underlyingValRolled = underlyingValRolled;
    }
}

contract MockControllerRolloverPerp {
    uint8 internal constant OP_SR_RECOVER = 1;
    uint8 internal constant OP_JR_RECOVER = 2;
    uint8 internal constant OP_SR_REGISTER = 4;
    uint8 internal constant OP_JR_REGISTER = 5;
    uint8 internal constant OP_SR_TRANSFER = 6;
    uint8 internal constant OP_JR_HANDLE = 7;
    uint8 internal constant OP_JR_DEPOSITS = 8;
    uint8 internal constant OP_JR_TRANSFER = 9;
    uint8 internal constant OP_SR_LOG = 10;

    RolloverCallRecorder public immutable recorder;
    address public immutable bondsManager;
    bool public immutable isSr;
    uint256 public totalSupply = 1;
    uint256 public underlyingBalance;
    bool public failDeposits;
    bool public recoverResult;

    uint256 public transferredUnderlying;
    address public transferRecipient;
    address[] private _transferredTokens;
    uint256[] private _transferredAmounts;
    uint256 public handledUnderlying;
    address[] private _handledTokens;
    uint256[] private _handledAmounts;
    address public depositManager;
    bytes32[] private _depositBondIds;
    uint256[] private _depositAmounts;
    address[] private _loggedTokens;

    constructor(RolloverCallRecorder recorder_, address manager_, bool isSr_, uint256 underlyingBalance_) {
        recorder = recorder_;
        bondsManager = manager_;
        isSr = isSr_;
        underlyingBalance = underlyingBalance_;
    }

    function setFailDeposits(bool fail) external {
        failDeposits = fail;
    }

    function setRecoverResult(bool recovered) external {
        recoverResult = recovered;
    }

    function reserveData() external view returns (PerpBalancer.ReserveData memory result) {
        result.underlyingBal = underlyingBalance;
        result.trancheData = new PerpBalancer.ReserveTrancheData[](0);
    }

    function recover() external returns (bool) {
        recorder.record(isSr ? OP_SR_RECOVER : OP_JR_RECOVER);
        return recoverResult;
    }

    function registerTranche(address) external {
        recorder.record(isSr ? OP_SR_REGISTER : OP_JR_REGISTER);
    }

    function transferReservesTo(address to, PerpBalancer.ReserveAmounts calldata amounts) external {
        recorder.record(isSr ? OP_SR_TRANSFER : OP_JR_TRANSFER);
        transferRecipient = to;
        transferredUnderlying = amounts.underlyingAmt;
        delete _transferredTokens;
        delete _transferredAmounts;
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            _transferredTokens.push(amounts.trancheAmts[i].token);
            _transferredAmounts.push(amounts.trancheAmts[i].amount);
        }
    }

    function handleTransferReservesIn(PerpBalancer.ReserveAmounts calldata amounts) external {
        recorder.record(OP_JR_HANDLE);
        handledUnderlying = amounts.underlyingAmt;
        delete _handledTokens;
        delete _handledAmounts;
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            _handledTokens.push(amounts.trancheAmts[i].token);
            _handledAmounts.push(amounts.trancheAmts[i].amount);
        }
    }

    function bondDepositsForRollover(address manager, IPerpToken.BondDeposit[] calldata deposits) external {
        recorder.record(OP_JR_DEPOSITS);
        if (failDeposits) revert("deposit failure");
        depositManager = manager;
        delete _depositBondIds;
        delete _depositAmounts;
        for (uint256 i; i < deposits.length; ++i) {
            _depositBondIds.push(deposits[i].bondID);
            _depositAmounts.push(deposits[i].underlyingAmt);
        }
    }

    function logBalance(address token) external {
        recorder.record(OP_SR_LOG);
        _loggedTokens.push(token);
    }

    function primeApproval(address) external {}

    function revokeApproval(address) external {}

    function transferred(uint256 index) external view returns (address token, uint256 amount) {
        return (_transferredTokens[index], _transferredAmounts[index]);
    }

    function handled(uint256 index) external view returns (address token, uint256 amount) {
        return (_handledTokens[index], _handledAmounts[index]);
    }

    function depositAt(uint256 index) external view returns (bytes32 bondID, uint256 amount) {
        return (_depositBondIds[index], _depositAmounts[index]);
    }

    function transferCount() external view returns (uint256) {
        return _transferredTokens.length;
    }

    function handledCount() external view returns (uint256) {
        return _handledTokens.length;
    }

    function depositCount() external view returns (uint256) {
        return _depositBondIds.length;
    }

    function loggedCount() external view returns (uint256) {
        return _loggedTokens.length;
    }

    function loggedToken(uint256 index) external view returns (address) {
        return _loggedTokens[index];
    }
}

contract MockControllerRolloverIssuer is IBondIssuerController {
    RolloverCallRecorder public immutable recorder;
    BondInfo private _info;
    address public immutable override bondsManager;
    bool public issued;

    constructor(RolloverCallRecorder recorder_, address manager, address srTranche, address jrTranche) {
        recorder = recorder_;
        bondsManager = manager;
        _info =
            BondInfo(manager, 0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b, srTranche, jrTranche);
    }

    function issue() external returns (bool wasIssued, BondInfo memory info) {
        recorder.record(3);
        return (issued, _info);
    }

    function latestBondInfo() external view returns (BondInfo memory) {
        return _info;
    }

    function setIssued(bool value) external {
        issued = value;
    }
}

    contract MockControllerOracleRegistry {
        address public oracle;

        function setOracle(address oracle_) external {
            oracle = oracle_;
        }

        function oracleOf(address) external view returns (address) {
            return oracle;
        }
    }

    contract MockControllerOracle {
        RolloverCallRecorder public immutable recorder;

        constructor(RolloverCallRecorder recorder_) {
            recorder = recorder_;
        }

        function cachePrice() external {
            recorder.record(0);
        }

        function resetCache() external {
            recorder.record(11);
        }
    }

    contract ControllerRolloverTest is Test {
        address internal constant RANDOM_CALLER = address(0xBEEF);

        address internal manager;
        PerpController internal controller;
        RolloverCallRecorder internal recorder;
        MockControllerRolloverPlanner internal planner;
        MockControllerRolloverPerp internal sr;
        MockControllerRolloverPerp internal jr;
        MockControllerRolloverIssuer internal issuer;
        MockControllerOracleRegistry internal registry;
        MockControllerOracle internal oracle;

        function setUp() public {
            recorder = new RolloverCallRecorder();
            registry = new MockControllerOracleRegistry();
            oracle = new MockControllerOracle(recorder);
            registry.setOracle(address(oracle));
            manager = address(registry);
            planner = new MockControllerRolloverPlanner(manager);
            sr = new MockControllerRolloverPerp(recorder, manager, true, 100_000_000);
            jr = new MockControllerRolloverPerp(recorder, manager, false, 386_465_700);
            issuer = new MockControllerRolloverIssuer(
                recorder, manager, address(0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1), address(0xe027)
            );

            PerpController implementation = new PerpController();
            ERC1967Proxy proxy = new ERC1967Proxy(
                address(implementation), abi.encodeCall(PerpController.init, (address(0xCB), address(sr), address(jr)))
            );
            controller = PerpController(address(proxy));
            controller.pauseUserOps(false);
            controller.updatePerpBalancer(address(planner));
            controller.updateIssuer(address(issuer));
        }

        function testPermissionlessStandardRolloverPreservesTargetCallOrderAndZeroEntries() public {
            vm.prank(RANDOM_CALLER);
            controller.rollover();

            assertEq(recorder.count(), 12);
            assertEq(recorder.op(0), 1);
            assertEq(recorder.op(1), 2);
            assertEq(recorder.op(2), 3);
            assertEq(recorder.op(3), 4);
            assertEq(recorder.op(4), 5);
            assertEq(recorder.op(5), 6);
            assertEq(recorder.op(6), 7);
            assertEq(recorder.op(7), 8);
            assertEq(recorder.op(8), 9);
            assertEq(recorder.op(9), 10);
            assertEq(recorder.op(10), 10);
            assertEq(recorder.op(11), 10);

            assertEq(sr.transferRecipient(), address(jr));
            assertEq(sr.transferredUnderlying(), 0);
            assertEq(sr.transferCount(), 1);
            (address token, uint256 amount) = sr.transferred(0);
            _assertTokenAmount(token, amount, 0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B, 3_133_547_705_520);

            assertEq(jr.handledUnderlying(), 0);
            assertEq(jr.handledCount(), 1);
            (token, amount) = jr.handled(0);
            _assertTokenAmount(token, amount, 0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B, 3_133_547_705_520);

            assertEq(jr.depositManager(), manager);
            assertEq(jr.depositCount(), 3);
            (bytes32 bondID, uint256 depositAmount) = jr.depositAt(0);
            _assertBondDeposit(
                bondID, depositAmount, 0x342b85e9d38918a8718c6ea642ea0df75e75c938bc45a6efde8c1dbaa3ef108d, 0
            );
            (bondID, depositAmount) = jr.depositAt(1);
            _assertBondDeposit(
                bondID, depositAmount, 0x93dcba573477147233c33c344a994ff99eedbe3ac9c31c2c5198f72add177ca8, 6_411_258
            );
            (bondID, depositAmount) = jr.depositAt(2);
            _assertBondDeposit(
                bondID, depositAmount, 0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b, 77_245_228
            );

            assertEq(jr.transferRecipient(), address(sr));
            assertEq(jr.transferredUnderlying(), 0);
            assertEq(jr.transferCount(), 3);
            (token, amount) = jr.transferred(0);
            _assertTokenAmount(token, amount, 0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68, 0);
            (token, amount) = jr.transferred(1);
            _assertTokenAmount(token, amount, 0x2b97045571Ec78aE1010Df47b3e275eCdAE53300, 243_440_724_687);
            (token, amount) = jr.transferred(2);
            _assertTokenAmount(token, amount, 0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1, 2_890_107_281_474);
            assertEq(sr.loggedCount(), 3);
            assertEq(sr.loggedToken(0), 0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68);
            assertEq(sr.loggedToken(1), 0x2b97045571Ec78aE1010Df47b3e275eCdAE53300);
            assertEq(sr.loggedToken(2), 0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1);
            assertEq(controller.lastRebalanceTimestampSec(), 0);
        }

        function testNoWorkAndBelowCleanupRevertBeforeAssetCalls() public {
            planner.setUnderlyingValRolled(0);
            vm.expectRevert(PerpController.InsufficientRollover.selector);
            controller.rollover();
            assertEq(recorder.count(), 0);

            planner.setUnderlyingValRolled(controller.minCleanupVal() - 1);
            vm.expectRevert(PerpController.InsufficientRollover.selector);
            controller.rollover();
            assertEq(recorder.count(), 0);
        }

        function testPlannerFailureIsAtomic() public {
            planner.setFailPlanning(true);
            vm.expectRevert(MockControllerRolloverPlanner.PlannerFailure.selector);
            controller.rollover();
            assertEq(recorder.count(), 0);
        }

        function testCleanupBoundaryIsInclusive() public {
            planner.setUnderlyingValRolled(controller.minCleanupVal());
            controller.rollover();
            assertEq(recorder.count(), 12);
        }

        function testPauseAndDownstreamFailureAreAtomic() public {
            controller.pauseSystemOps(true);
            vm.expectRevert(PerpController.SystemOpsPaused.selector);
            controller.rollover();
            assertEq(recorder.count(), 0);

            controller.pauseSystemOps(false);
            jr.setFailDeposits(true);
            vm.expectRevert(bytes("deposit failure"));
            controller.rollover();
            assertEq(recorder.count(), 0);
        }

        function testUpkeepNoWorkRevertsAtomically() public {
            controller.setUnderlyingOracle();
            vm.expectRevert(PerpController.NoOp.selector);
            vm.prank(RANDOM_CALLER);
            controller.upkeep();
            assertEq(recorder.count(), 0);
        }

        function testUpkeepIssueOnlyPreservesObservedCallOrder() public {
            controller.setUnderlyingOracle();
            issuer.setIssued(true);
            vm.prank(RANDOM_CALLER);
            controller.upkeep();
            _assertUpkeepCallOrder();
        }

        function testUpkeepMaturityOnlyPreservesObservedCallOrder() public {
            controller.setUnderlyingOracle();
            sr.setRecoverResult(true);
            vm.prank(RANDOM_CALLER);
            controller.upkeep();
            _assertUpkeepCallOrder();
        }

        function testUpkeepMaturityAndIssuePreservesObservedCallOrder() public {
            controller.setUnderlyingOracle();
            jr.setRecoverResult(true);
            issuer.setIssued(true);
            vm.prank(RANDOM_CALLER);
            controller.upkeep();
            _assertUpkeepCallOrder();
        }

        function testUpkeepSystemPauseRevertsBeforeSubcalls() public {
            controller.setUnderlyingOracle();
            controller.pauseSystemOps(true);
            vm.expectRevert(PerpController.SystemOpsPaused.selector);
            controller.upkeep();
            assertEq(recorder.count(), 0);
        }

        function _assertUpkeepCallOrder() private view {
            assertEq(recorder.count(), 7);
            assertEq(recorder.op(0), 0);
            assertEq(recorder.op(1), 1);
            assertEq(recorder.op(2), 2);
            assertEq(recorder.op(3), 3);
            assertEq(recorder.op(4), 4);
            assertEq(recorder.op(5), 5);
            assertEq(recorder.op(6), 11);
            assertEq(controller.lastRebalanceTimestampSec(), 0);
        }

        function _assertTokenAmount(address token, uint256 amount, address expectedToken, uint256 expectedAmount)
            private
            pure
        {
            assertEq(token, expectedToken);
            assertEq(amount, expectedAmount);
        }

        function _assertBondDeposit(bytes32 bondID, uint256 amount, bytes32 expectedBondID, uint256 expectedAmount)
            private
            pure
        {
            assertEq(bondID, expectedBondID);
            assertEq(amount, expectedAmount);
        }
    }
