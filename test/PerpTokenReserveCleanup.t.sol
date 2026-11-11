// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IPerpToken} from "../src/interfaces/IPerpToken.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MockCleanupTranche is ERC20 {
    address public immutable manager;
    bytes32 public immutable bondID;
    bool public immutable isSenior;

    constructor(address manager_, bytes32 bondID_, bool isSenior_)
        ERC20(isSenior_ ? "Senior tranche" : "Junior tranche", isSenior_ ? "SR-T" : "JR-T")
    {
        manager = manager_;
        bondID = bondID_;
        isSenior = isSenior_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function data() external view returns (IBondsManager.TrancheData memory) {
        uint256 supply = totalSupply();
        return IBondsManager.TrancheData({
            trancheSupply: supply,
            trancheClaim: supply,
            totalClaim: supply * 2,
            volatilityMultiplier: isSenior ? 0 : 2e18,
            underlyingOpenPrice: 1e18,
            isMature: MockCleanupManager(manager).mature(bondID),
            secondsToMaturity: 1,
            trancheRatio: 5e17,
            valueRatio: 5e17,
            bondID: bondID,
            isSenior: isSenior,
            tranche: address(this),
            counterpart: isSenior
                ? address(MockCleanupManager(manager).junior(bondID))
                : address(MockCleanupManager(manager).senior(bondID)),
            manager: manager
        });
    }
}

contract MockCleanupManager {
    struct Pair {
        MockCleanupTranche senior;
        MockCleanupTranche junior;
        bool mature;
    }

    MockERC20 public immutable underlying;
    mapping(bytes32 => Pair) private _pairs;

    constructor(MockERC20 underlying_) {
        underlying = underlying_;
    }

    function createPair(bytes32 bondID) external returns (MockCleanupTranche senior_, MockCleanupTranche junior_) {
        senior_ = new MockCleanupTranche(address(this), bondID, true);
        junior_ = new MockCleanupTranche(address(this), bondID, false);
        _pairs[bondID] = Pair(senior_, junior_, false);
    }

    function setMature(bytes32 bondID, bool mature_) external {
        _pairs[bondID].mature = mature_;
    }

    function mature(bytes32 bondID) external view returns (bool) {
        return _pairs[bondID].mature;
    }

    function senior(bytes32 bondID) external view returns (MockCleanupTranche) {
        return _pairs[bondID].senior;
    }

    function junior(bytes32 bondID) external view returns (MockCleanupTranche) {
        return _pairs[bondID].junior;
    }

    function tranches(bytes32 bondID) external view returns (address senior_, address junior_) {
        Pair storage pair = _pairs[bondID];
        return (address(pair.senior), address(pair.junior));
    }

    function redeem(bytes32 bondID, uint256 srAmtAvail, uint256 jrAmtAvail)
        external
        returns (
            uint256 underlyingAmtReturned,
            IBondsManager.TokenAmount memory srTrAmt,
            IBondsManager.TokenAmount memory jrTrAmt
        )
    {
        Pair storage pair = _pairs[bondID];
        uint256 srRedeemed;
        uint256 jrRedeemed;
        if (pair.mature) {
            srRedeemed = srAmtAvail;
            jrRedeemed = jrAmtAvail;
        } else {
            uint256 paired = Math.min(srAmtAvail, jrAmtAvail);
            srRedeemed = paired;
            jrRedeemed = paired;
        }
        if (srRedeemed != 0) pair.senior.burn(msg.sender, srRedeemed);
        if (jrRedeemed != 0) pair.junior.burn(msg.sender, jrRedeemed);
        underlyingAmtReturned = srRedeemed + jrRedeemed;
        if (underlyingAmtReturned != 0) underlying.mint(msg.sender, underlyingAmtReturned);
        srTrAmt = IBondsManager.TokenAmount(address(pair.senior), srRedeemed);
        jrTrAmt = IBondsManager.TokenAmount(address(pair.junior), jrRedeemed);
    }
}

contract PerpTokenReserveCleanupTest is Test {
    bytes32 private constant RESERVE_SYNCED = keccak256("ReserveSynced(address,uint256)");
    address private constant RECIPIENT = address(0xCAFE);

    MockERC20 private underlying;
    MockCleanupManager private manager;
    PerpToken private perp;

    function setUp() public {
        underlying = new MockERC20("Wrapped BTC", "WBTC", 8);
        manager = new MockCleanupManager(underlying);
        perp = new PerpToken(
            "Senior Perp", "SR-P", address(underlying), address(manager), address(this), false, address(this)
        );
    }

    function testTransferFullBalanceAndZeroBalanceUseSwapPop() public {
        (MockCleanupTranche a,) = manager.createPair(bytes32(uint256(1)));
        (MockCleanupTranche b,) = manager.createPair(bytes32(uint256(2)));
        (MockCleanupTranche c,) = manager.createPair(bytes32(uint256(3)));
        (MockCleanupTranche zero,) = manager.createPair(bytes32(uint256(4)));
        perp.registerTranche(address(a));
        perp.registerTranche(address(b));
        perp.registerTranche(address(c));
        a.mint(address(perp), 100);
        b.mint(address(perp), 200);
        c.mint(address(perp), 300);

        _transferOne(address(b), 200);
        address[] memory tokens = perp.trancheTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], address(a));
        assertEq(tokens[1], address(c));
        assertEq(b.balanceOf(RECIPIENT), 200);

        perp.registerTranche(address(zero));
        vm.recordLogs();
        _transferOne(address(zero), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        tokens = perp.trancheTokens();
        assertEq(tokens.length, 2);
        assertEq(_reserveSyncCount(logs), 1);
    }

    function testHandleOneSidedRegistersIncomingAndRemovesZeroCounterpart() public {
        (MockCleanupTranche senior, MockCleanupTranche junior) = manager.createPair(bytes32(uint256(1)));
        perp.registerTranche(address(junior));
        senior.mint(address(perp), 100);

        _handleOne(address(senior), 100);

        address[] memory tokens = perp.trancheTokens();
        assertEq(tokens.length, 1);
        assertEq(tokens[0], address(senior));
        assertEq(senior.balanceOf(address(perp)), 100);
        assertEq(junior.balanceOf(address(perp)), 0);
    }

    function testHandlePairedTranchesRedeemsAndRemovesBoth() public {
        (MockCleanupTranche senior, MockCleanupTranche junior) = manager.createPair(bytes32(uint256(1)));
        perp.registerTranche(address(junior));
        senior.mint(address(perp), 100);
        junior.mint(address(perp), 100);

        _handleOne(address(senior), 100);

        assertEq(underlying.balanceOf(address(perp)), 200);
        assertEq(senior.balanceOf(address(perp)), 0);
        assertEq(junior.balanceOf(address(perp)), 0);
        assertEq(perp.trancheTokens().length, 0);
    }

    function testR2_RebalanceMustCountTransferredTrancheInReceiver() public {
        (MockCleanupTranche senior,) = manager.createPair(bytes32(uint256(1)));
        PerpToken receiver = new PerpToken(
            "Junior Perp", "JR-P", address(underlying), address(manager), address(this), true, address(this)
        );
        perp.registerTranche(address(senior));
        senior.mint(address(perp), 200_000_000);
        underlying.mint(address(receiver), 100_000_000);

        uint256 totalBefore = _reserveValue(perp.reserveData()) + _reserveValue(receiver.reserveData());
        assertEq(totalBefore, 300_000_000);

        PerpBalancer.TokenAmount[] memory trancheAmts = new PerpBalancer.TokenAmount[](1);
        trancheAmts[0] = PerpBalancer.TokenAmount(address(senior), 328_542);
        PerpBalancer.ReserveAmounts memory plan = PerpBalancer.ReserveAmounts(0, trancheAmts);
        perp.transferReservesTo(address(receiver), plan);
        receiver.handleTransferReservesIn(plan);

        PerpBalancer.ReserveData memory receiverData = receiver.reserveData();
        assertEq(receiverData.trancheData.length, 1);
        assertEq(receiverData.trancheData[0].value, 328_542);
        assertEq(_reserveValue(perp.reserveData()) + _reserveValue(receiverData), totalBefore);
    }

    function testRecoverReturnsFalseThenTrueAndRemovesMatureTranche() public {
        bytes32 bondID = bytes32(uint256(1));
        (MockCleanupTranche senior,) = manager.createPair(bondID);
        perp.registerTranche(address(senior));
        senior.mint(address(perp), 100);

        assertFalse(perp.recover());
        assertEq(senior.balanceOf(address(perp)), 100);
        assertEq(perp.trancheTokens().length, 1);

        manager.setMature(bondID, true);
        assertTrue(perp.recover());
        assertEq(underlying.balanceOf(address(perp)), 100);
        assertEq(senior.balanceOf(address(perp)), 0);
        assertEq(perp.trancheTokens().length, 0);
    }

    function testRecoverPermissionAndZeroSupplyReserveValue() public {
        (MockCleanupTranche zero,) = manager.createPair(bytes32(uint256(1)));
        perp.registerTranche(address(zero));
        PerpBalancer.ReserveData memory data = perp.reserveData();
        assertEq(data.trancheData.length, 1);
        assertEq(data.trancheData[0].balance, 0);
        assertEq(data.trancheData[0].value, 0);

        vm.expectRevert(PerpToken.UnauthorizedCall.selector);
        vm.prank(address(0xBEEF));
        perp.recover();
    }

    function _transferOne(address token, uint256 amount) private {
        PerpBalancer.TokenAmount[] memory trancheAmts = new PerpBalancer.TokenAmount[](1);
        trancheAmts[0] = PerpBalancer.TokenAmount(token, amount);
        perp.transferReservesTo(RECIPIENT, PerpBalancer.ReserveAmounts(0, trancheAmts));
    }

    function _handleOne(address token, uint256 amount) private {
        PerpBalancer.TokenAmount[] memory trancheAmts = new PerpBalancer.TokenAmount[](1);
        trancheAmts[0] = PerpBalancer.TokenAmount(token, amount);
        perp.handleTransferReservesIn(PerpBalancer.ReserveAmounts(0, trancheAmts));
    }

    function _reserveSyncCount(Vm.Log[] memory logs) private pure returns (uint256 count) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(0)) continue;
            if (logs[i].topics.length != 0 && logs[i].topics[0] == RESERVE_SYNCED) ++count;
        }
    }

    function _reserveValue(PerpBalancer.ReserveData memory data) private pure returns (uint256 value) {
        value = data.underlyingBal;
        for (uint256 i; i < data.trancheData.length; ++i) {
            value += data.trancheData[i].value;
        }
    }
}
