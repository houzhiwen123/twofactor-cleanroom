// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPairRouter} from "../../src/interfaces/IPairRouter.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

interface IPairPhase4Types {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }
}

contract PairPhase4Recorder {
    uint256[] private _calls;

    function record(uint256 code) external {
        _calls.push(code);
    }

    function length() external view returns (uint256) {
        return _calls.length;
    }

    function at(uint256 index) external view returns (uint256) {
        return _calls[index];
    }
}

contract PairPhase4Controller {
    MockERC20 public immutable underlying;
    MockERC20 public immutable perpSr;
    MockERC20 public immutable perpJr;
    PairPhase4Recorder public immutable recorder;

    constructor(MockERC20 underlying_, MockERC20 sr_, MockERC20 jr_, PairPhase4Recorder recorder_) {
        underlying = underlying_;
        perpSr = sr_;
        perpJr = jr_;
        recorder = recorder_;
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256, uint256)
        external
        returns (
            uint256 srOut,
            uint256 jrOut,
            IPairPhase4Types.FeePerc memory srFee,
            IPairPhase4Types.FeePerc memory jrFee
        )
    {
        recorder.record(60);
        uint256 total = srUnderlying + jrUnderlying;
        if (total != 0) underlying.transferFrom(msg.sender, address(this), total);
        if (srUnderlying != 0) {
            srOut = srUnderlying;
            perpSr.mint(msg.sender, srOut);
        }
        if (jrUnderlying != 0) {
            jrOut = jrUnderlying;
            perpJr.mint(msg.sender, jrOut);
        }
        srFee = IPairPhase4Types.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = IPairPhase4Types.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
    }

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256)
        external
        returns (
            uint256 underlyingOut,
            IPairPhase4Types.FeePerc memory srFee,
            IPairPhase4Types.FeePerc memory jrFee
        )
    {
        recorder.record(70);
        if (srIn != 0) perpSr.transferFrom(msg.sender, address(this), srIn);
        if (jrIn != 0) perpJr.transferFrom(msg.sender, address(this), jrIn);
        underlyingOut = srIn + jrIn;
        if (underlyingOut != 0) underlying.mint(msg.sender, underlyingOut);
        srFee = IPairPhase4Types.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
        jrFee = IPairPhase4Types.FeePerc({totalFeePerc: 0, protocolFeePerc: 0});
    }

    function systemDeviations() external pure returns (uint256 subDR, uint256 vmDR) {
        return (1e18, 1e18);
    }
}

contract PairPhase4UsdVault is ERC20 {
    address public usd;
    address public underlying;
    address public perpSr;
    address public perpController;
    PairPhase4Recorder public immutable recorder;

    constructor(
        address usd_,
        address underlying_,
        address sr_,
        address controller_,
        PairPhase4Recorder recorder_
    ) ERC20("Phase 4 USD notes", "p4USD") {
        usd = usd_;
        underlying = underlying_;
        perpSr = sr_;
        perpController = controller_;
        recorder = recorder_;
    }

    function configure(address usd_, address underlying_, address sr_, address controller_) external {
        usd = usd_;
        underlying = underlying_;
        perpSr = sr_;
        perpController = controller_;
    }

    function mintNotes(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function upkeep() external {
        recorder.record(10);
    }

    function deposit(uint256 usdMax, uint256 srMax) external returns (uint256 notesMinted) {
        recorder.record(20);
        if (usdMax != 0) MockERC20(usd).transferFrom(msg.sender, address(this), usdMax);
        if (srMax != 0) MockERC20(perpSr).transferFrom(msg.sender, address(this), srMax);
        notesMinted = usdMax + srMax;
        if (notesMinted != 0) _mint(msg.sender, notesMinted);
    }

    function redeem(uint256 notes) external returns (uint256 usdOut, uint256 srOut) {
        recorder.record(40);
        _burn(msg.sender, notes);
        usdOut = notes;
        srOut = notes;
        if (usdOut != 0) MockERC20(usd).mint(msg.sender, usdOut);
        if (srOut != 0) MockERC20(perpSr).mint(msg.sender, srOut);
    }
}

contract PairPhase4UnderlyingVault is ERC20 {
    address public underlying;
    address public perp;
    address public perpController;
    bool public isPerpSrVault;
    PairPhase4Recorder public immutable recorder;

    constructor(
        address underlying_,
        address perp_,
        address controller_,
        bool senior_,
        PairPhase4Recorder recorder_
    ) ERC20("Phase 4 underlying notes", "p4U") {
        underlying = underlying_;
        perp = perp_;
        perpController = controller_;
        isPerpSrVault = senior_;
        recorder = recorder_;
    }

    function configure(address underlying_, address perp_, address controller_, bool senior_) external {
        underlying = underlying_;
        perp = perp_;
        perpController = controller_;
        isPerpSrVault = senior_;
    }

    function mintNotes(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted) {
        recorder.record(30);
        if (underlyingMax != 0) MockERC20(underlying).transferFrom(msg.sender, address(this), underlyingMax);
        if (perpMax != 0) MockERC20(perp).transferFrom(msg.sender, address(this), perpMax);
        notesMinted = underlyingMax + perpMax;
        if (notesMinted != 0) _mint(msg.sender, notesMinted);
    }

    function redeem(uint256 notes) external returns (uint256 underlyingOut, uint256 perpOut) {
        recorder.record(50);
        _burn(msg.sender, notes);
        underlyingOut = notes;
        perpOut = notes;
        if (underlyingOut != 0) MockERC20(underlying).mint(msg.sender, underlyingOut);
        if (perpOut != 0) MockERC20(perp).mint(msg.sender, perpOut);
    }
}

contract PairPhase4Strategy {
    address public usd;
    address public underlying;
    PairPhase4Recorder public immutable recorder;

    constructor(address usd_, address underlying_, PairPhase4Recorder recorder_) {
        usd = usd_;
        underlying = underlying_;
        recorder = recorder_;
    }

    function configure(address usd_, address underlying_) external {
        usd = usd_;
        underlying = underlying_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt) {
        recorder.record(80);
        if (sellToken == underlying && buyToken == usd) {
            MockERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
            buyAmt = sellAmt;
            MockERC20(buyToken).mint(msg.sender, buyAmt);
        } else if (sellToken == usd && buyToken == underlying) {
            MockERC20(sellToken).transferFrom(msg.sender, address(this), sellAmt);
            buyAmt = sellAmt;
            MockERC20(buyToken).mint(msg.sender, buyAmt);
        } else {
            revert("pair");
        }
    }
}

contract PairRouterPhase4ValidationGenesisProbe is Test {
    address private constant TARGET_ROUTER = 0x97c521D21468022E205d8A57b2fcaeE33d6714d6;
    bytes4 private constant TARGET_DEPOSIT_SELECTOR = 0x0176cb45;
    bytes4 private constant TARGET_REDEEM_SELECTOR = 0xb2a72016;
    address private constant USER = address(0xBEEF);

    MockERC20 private underlying;
    MockERC20 private usd;
    MockERC20 private sr;
    MockERC20 private jr;
    MockERC20 private other;
    PairPhase4Recorder private recorder;
    PairPhase4Controller private controller;
    PairPhase4Controller private otherController;
    PairPhase4UsdVault private usdVault;
    PairPhase4UnderlyingVault private jrVault;
    PairPhase4Strategy private strategy;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 57_015_384);
        assertEq(block.chainid, 8453);
        assertEq(TARGET_ROUTER.codehash, 0x487610478a620be27092ff42bf2dea6bfc08275af635abdc27245329f9801218);

        underlying = new MockERC20("cbBTC", "cbBTC", 8);
        usd = new MockERC20("USDC", "USDC", 6);
        sr = new MockERC20("SR", "SR", 8);
        jr = new MockERC20("JR", "JR", 8);
        other = new MockERC20("OTHER", "OTHER", 18);
        recorder = new PairPhase4Recorder();
        controller = new PairPhase4Controller(underlying, sr, jr, recorder);
        otherController = new PairPhase4Controller(underlying, sr, jr, recorder);
        usdVault = new PairPhase4UsdVault(address(usd), address(underlying), address(sr), address(controller), recorder);
        jrVault = new PairPhase4UnderlyingVault(address(underlying), address(jr), address(controller), false, recorder);
        strategy = new PairPhase4Strategy(address(usd), address(underlying), recorder);

        underlying.mint(USER, 1_000);
        usdVault.mintNotes(USER, 100);
        jrVault.mintNotes(USER, 100);
        vm.startPrank(USER);
        underlying.approve(TARGET_ROUTER, type(uint256).max);
        usdVault.approve(TARGET_ROUTER, type(uint256).max);
        jrVault.approve(TARGET_ROUTER, type(uint256).max);
        vm.stopPrank();
    }

    function testObserveCanonicalZeroDeposit() public {
        (bool success, bytes memory result) = _callDeposit(_zeroDeposit());
        assertTrue(success);
        assertEq(result.length, 6 * 32);
        (uint256 a, uint256 b, uint256 c, uint256 d, uint256 e, uint256 f) =
            abi.decode(result, (uint256, uint256, uint256, uint256, uint256, uint256));
        assertEq(a | b | c | d | e | f, 0);
        assertEq(recorder.length(), 0);
        emit log_named_uint("zero deposit success", success ? 1 : 0);
        emit log_named_bytes32("zero deposit selector", bytes32(_selector(result)));
        emit log_named_uint("zero deposit return length", result.length);
        emit log_named_uint("zero deposit call count", recorder.length());
    }

    function testObserveCanonicalZeroRedeem() public {
        (bool success, bytes memory result) = _callRedeem(_zeroRedeem());
        assertTrue(success);
        assertEq(result.length, 2 * 32);
        (uint256 usdOut, uint256 underlyingOut) = abi.decode(result, (uint256, uint256));
        assertEq(usdOut | underlyingOut, 0);
        assertEq(recorder.length(), 0);
        emit log_named_uint("zero redeem success", success ? 1 : 0);
        emit log_named_bytes32("zero redeem selector", bytes32(_selector(result)));
        emit log_named_uint("zero redeem return length", result.length);
        emit log_named_uint("zero redeem call count", recorder.length());
    }

    function testObserveDependencyValidationMatrix() public {
        jrVault.configure(address(underlying), address(jr), address(otherController), false);
        _logBoth("controller mismatch", false);
        _restoreCanonical();

        jrVault.configure(address(underlying), address(jr), address(controller), true);
        _logBoth("underlying vault is senior", false);
        _restoreCanonical();

        jrVault.configure(address(underlying), address(other), address(controller), false);
        _logBoth("underlying vault perp mismatch", false);
        _restoreCanonical();

        usdVault.configure(address(usd), address(underlying), address(other), address(controller));
        _logBoth("USD vault SR mismatch", false);
        _restoreCanonical();

        jrVault.configure(address(other), address(jr), address(controller), false);
        _logBoth("underlying vault underlying mismatch", true);
        _restoreCanonical();

        usdVault.configure(address(usd), address(other), address(sr), address(controller));
        _logBoth("USD vault underlying mismatch", true);
        _restoreCanonical();

        usdVault.configure(address(other), address(underlying), address(sr), address(controller));
        _logBoth("USD token changed", true);
        _restoreCanonical();

        strategy.configure(address(other), address(other));
        _logBoth("Strategy token getters changed", true);
    }

    function testObserveZeroStrategyWithHealthDisabled() public {
        IPairRouter.DepositParams memory depositParams = _zeroDeposit();
        depositParams.strategy = address(0);
        depositParams.healthCheck = false;
        (bool depositSuccess, bytes memory depositResult) = _callDeposit(depositParams);

        IPairRouter.RedeemParams memory redeemParams = _zeroRedeem();
        redeemParams.strategy = address(0);
        redeemParams.healthCheck = false;
        (bool redeemSuccess, bytes memory redeemResult) = _callRedeem(redeemParams);

        assertTrue(depositSuccess);
        assertTrue(redeemSuccess);
        assertEq(depositResult.length, 6 * 32);
        assertEq(redeemResult.length, 2 * 32);

        emit log_named_uint("zero Strategy deposit success", depositSuccess ? 1 : 0);
        emit log_named_bytes32("zero Strategy deposit selector", bytes32(_selector(depositResult)));
        emit log_named_uint("zero Strategy redeem success", redeemSuccess ? 1 : 0);
        emit log_named_bytes32("zero Strategy redeem selector", bytes32(_selector(redeemResult)));
    }

    function _zeroDeposit() private view returns (IPairRouter.DepositParams memory params) {
        params = IPairRouter.DepositParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(strategy),
            recipient: address(0),
            underlyingIn: 0,
            minUsdFromTrade: 0,
            underlyingToTrade: 0,
            srUnderlyingIn: 0,
            jrUnderlyingIn: 0,
            minUsdNotes: 0,
            minUnderlyingNotes: 0,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: true
        });
    }

    function _zeroRedeem() private view returns (IPairRouter.RedeemParams memory params) {
        params = IPairRouter.RedeemParams({
            usdVault: address(usdVault),
            underlyingVault: address(jrVault),
            strategy: address(strategy),
            usdNotes: 0,
            underlyingNotes: 0,
            maxUsdRetained: type(uint256).max,
            underlyingToTrade: 0,
            runUpkeep: false,
            minUsdOut: 0,
            minUnderlyingOut: 0,
            minSubDr: 0,
            maxSubDr: type(uint256).max,
            minVmDr: 0,
            maxVmDr: type(uint256).max,
            healthCheck: true
        });
    }

    function _callDeposit(IPairRouter.DepositParams memory params)
        private
        returns (bool success, bytes memory result)
    {
        vm.prank(USER);
        return TARGET_ROUTER.call(abi.encodePacked(TARGET_DEPOSIT_SELECTOR, abi.encode(params)));
    }

    function _callRedeem(IPairRouter.RedeemParams memory params)
        private
        returns (bool success, bytes memory result)
    {
        vm.prank(USER);
        return TARGET_ROUTER.call(abi.encodePacked(TARGET_REDEEM_SELECTOR, abi.encode(params)));
    }

    function _restoreCanonical() private {
        usdVault.configure(address(usd), address(underlying), address(sr), address(controller));
        jrVault.configure(address(underlying), address(jr), address(controller), false);
        strategy.configure(address(usd), address(underlying));
    }

    function _logBoth(string memory label, bool expectedSuccess) private {
        (bool depositSuccess, bytes memory depositResult) = _callDeposit(_zeroDeposit());
        (bool redeemSuccess, bytes memory redeemResult) = _callRedeem(_zeroRedeem());
        assertEq(depositSuccess, expectedSuccess);
        assertEq(redeemSuccess, expectedSuccess);
        if (expectedSuccess) {
            assertEq(depositResult.length, 6 * 32);
            assertEq(redeemResult.length, 2 * 32);
        } else {
            assertEq(_selector(depositResult), bytes4(0xd126d255));
            assertEq(_selector(redeemResult), bytes4(0xd126d255));
        }
        emit log_named_string("case", label);
        emit log_named_uint("deposit success", depositSuccess ? 1 : 0);
        emit log_named_bytes32("deposit selector", bytes32(_selector(depositResult)));
        emit log_named_uint("redeem success", redeemSuccess ? 1 : 0);
        emit log_named_bytes32("redeem selector", bytes32(_selector(redeemResult)));
    }

    function _selector(bytes memory data) private pure returns (bytes4 value) {
        if (data.length < 4) return bytes4(0);
        assembly ("memory-safe") {
            value := mload(add(data, 32))
        }
    }
}
