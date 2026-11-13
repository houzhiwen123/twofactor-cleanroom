// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";
import {MockPriceOracle} from "../../test/mocks/MockPriceOracle.sol";

contract Phase4MarkerDex {
    error ExecutionReached(address sellToken, address buyToken, uint256 sellAmt);

    address public immutable usd;
    address public immutable underlying;
    uint256 public immutable price;

    constructor(address usd_, address underlying_, uint256 price_) {
        usd = usd_;
        underlying = underlying_;
        price = price_;
    }

    function isHealthy() external pure returns (bool) {
        return true;
    }

    function referencePrice(address, address) external view returns (uint256) {
        return price;
    }

    function quote(address sellToken, address, uint256 sellAmt) public view returns (uint256) {
        if (sellToken == usd) return sellAmt * 1e20 / price;
        return sellAmt * price / 1e20;
    }

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt)
    {
        return (maxSellAmt, quote(sellToken, buyToken, maxSellAmt));
    }

    function trade(address sellToken, address buyToken, uint256 sellAmt) external pure returns (uint256) {
        revert ExecutionReached(sellToken, buyToken, sellAmt);
    }
}

interface ITargetControllerPhase4 {
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

interface ITargetUsdVaultPhase4 {
    struct Range {
        uint96 lower;
        uint96 upper;
    }

    struct ReserveState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        ReserveState perpSr;
        ReserveState perpJr;
    }

    function getTVL() external view returns (uint256);
    function maxDeploymentVelocityPerc() external view returns (uint64);
    function minOpUsdVal() external view returns (uint128);
    function sessionBudgetUsdVal() external view returns (uint128);
    function sessionIsMintingPerp() external view returns (bool);
    function sessionOpenedAtSec() external view returns (uint64);
    function rebalance() external;
    function initDeposit(uint256 usdAmt) external returns (uint256 notesMinted);
    function updateHealthCheckParams(address usdOracle, uint64 maxUsdDeviation, uint64 maxUnderlyingDeviation) external;
    function updateOpLimits(uint128 minOpUsdVal, uint64 maxFlashMintFeePerc, uint64 maxFlashRedeemFeePerc) external;
    function updateSessionParams(uint32 freqSec, uint32 offsetSec, uint32 activeDelaySec, uint64 velocity) external;
    function updateTargetDR(uint96 targetDR, Range calldata range) external;
    function sessionCapacity()
        external
        view
        returns (bool active, bool isMintingPerp, uint256 budgetUsdVal, uint256 openedAtSec);
    function rebalanceCapacity()
        external
        view
        returns (
            uint256 maxRebalanceUnderlying,
            uint256 underlyingPrice,
            bool isMintingPerp,
            uint256 currentDR,
            SystemState memory state
        );
}

/// @notice Evidence-only public Base fork probes. No target storage or balances
///         are changed with deal/store, no transaction is signed, and nothing
///         is broadcast.
contract UsdVaultPhase4RebalanceCapacityProbe is Test {
    address private constant VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;
    address private constant VAULT_IMPLEMENTATION = 0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant DEX_STRATEGY = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    uint256 private constant TARGET_PRICE = 80_248_101_897_110_000_000_000;

    bytes4 private constant OP_UNAVAILABLE = bytes4(keccak256("OpUnavailable(string)"));
    bytes4 private constant NO_OP = bytes4(keccak256("NoOp()"));

    function testTargetCapacityGoldenVectorsBothDirectionsAndDeadband() public {
        _select(53_526_143);
        (uint256 assetLimited, uint256 price, bool minting, uint256 currentDR,) =
            ITargetUsdVaultPhase4(VAULT).rebalanceCapacity();
        assertEq(assetLimited, 4_651);
        assertEq(price, 80_248_101_897_110_000_000_000);
        assertTrue(minting);
        assertEq(currentDR, 1_052_430_305_854_682_822);

        _select(53_490_000);
        uint256 systemLimited;
        (systemLimited,, minting, currentDR,) = ITargetUsdVaultPhase4(VAULT).rebalanceCapacity();
        assertEq(systemLimited, 3_422_518);
        assertTrue(minting);
        assertEq(currentDR, 1_055_663_647_561_289_239);

        _select(53_480_533);
        uint256 redeeming;
        (redeeming,, minting, currentDR,) = ITargetUsdVaultPhase4(VAULT).rebalanceCapacity();
        assertEq(redeeming, 960_289);
        assertFalse(minting);
        assertEq(currentDR, 1_019_867_585_526_484_997);

        _select(53_492_000);
        uint256 deadband;
        (deadband,, minting, currentDR,) = ITargetUsdVaultPhase4(VAULT).rebalanceCapacity();
        assertEq(deadband, 0);
        assertFalse(minting);
        assertEq(currentDR, 1_026_428_101_402_202_294);
    }

    function testTargetExactEqualityRangeIsInclusive() public {
        _select(53_526_143);
        (uint256 subDR,) = ITargetControllerPhase4(CONTROLLER).systemDeviations();
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)", "Capacity Probe", "CAP-PROBE", USDC, CONTROLLER, DEX_STRATEGY
        );
        ITargetUsdVaultPhase4 fresh = ITargetUsdVaultPhase4(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        fresh.updateTargetDR(uint96(subDR), ITargetUsdVaultPhase4.Range({lower: uint96(subDR), upper: uint96(subDR)}));
        (uint256 maxUnderlying,,, uint256 currentDR,) = fresh.rebalanceCapacity();
        assertEq(currentDR, subDR);
        assertEq(maxUnderlying, 0, "exact equality must be in the no-rebalance deadband");
    }

    function testTargetObservedGuardSelectors() public {
        _select(53_526_143);
        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "min size"));
        ITargetUsdVaultPhase4(VAULT).rebalance();

        _select(53_490_000);
        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "direction"));
        ITargetUsdVaultPhase4(VAULT).rebalance();

        _select(53_492_000);
        vm.expectRevert(NO_OP);
        ITargetUsdVaultPhase4(VAULT).rebalance();
    }

    function testTargetSessionBudgetEqualityAndOneWeiClipping() public {
        _select(53_526_143);
        uint64 exactVelocity = 962_880_934_671_852_815;
        uint64 oneWeiShortVelocity = 962_880_934_671_852_715;
        uint256 requiredUsdVal = 9_629_772_227_653_200;

        (ITargetUsdVaultPhase4 exact, Phase4MarkerDex exactDex) = _freshBoundaryVault(exactVelocity);
        (bool active, bool direction, uint256 exactBudget,) = exact.sessionCapacity();
        assertFalse(active);
        assertFalse(direction, "fresh inactive session direction is not persisted yet");
        assertEq(exactBudget, requiredUsdVal);
        (uint256 exactCapacity,, bool minting,,) = exact.rebalanceCapacity();
        assertEq(exactCapacity, 12);
        assertTrue(minting);
        uint256 exactSellAmt = _expectExecutionMarker(exact);
        assertEq(address(exactDex).code.length > 0, true);

        (ITargetUsdVaultPhase4 shortVault,) = _freshBoundaryVault(oneWeiShortVelocity);
        (,, uint256 shortBudget,) = shortVault.sessionCapacity();
        assertEq(shortBudget, requiredUsdVal - 1);
        uint256 shortSellAmt = _expectExecutionMarker(shortVault);
        assertEq(exactSellAmt, 9_629);
        assertEq(shortSellAmt, 8_827);
        assertLt(shortSellAmt, exactSellAmt, "one WAD wei below the 12-sat edge must clip to 11 sats");

        (ITargetUsdVaultPhase4 zeroBudget,) = _freshBoundaryVault(1);
        (,, uint256 zero,) = zeroBudget.sessionCapacity();
        assertEq(zero, 0);
        vm.expectRevert(abi.encodeWithSelector(OP_UNAVAILABLE, "no capacity"));
        zeroBudget.rebalance();
    }

    function testTargetNewSessionSubtractsActualMintAndRedeemValues() public {
        _select(53_480_533);
        (bool active, bool direction, uint256 previewBudget, uint256 openedAt) =
            ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertFalse(active);
        assertTrue(direction);
        assertEq(previewBudget, 33_016_915_546_003_499_111_958);
        assertEq(openedAt, 1_793_743_200);

        _select(53_480_534);
        uint256 postRedeemBudget;
        (active, direction, postRedeemBudget, openedAt) = ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertTrue(active);
        assertFalse(direction);
        assertEq(postRedeemBudget, 32_273_956_312_748_941_964_558);
        assertEq(previewBudget - postRedeemBudget, 742_959_233_254_557_147_400);

        _select(53_491_334);
        (active, direction, previewBudget, openedAt) = ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertFalse(active);
        assertFalse(direction);
        assertEq(previewBudget, 33_016_963_790_403_425_541_687);
        assertEq(openedAt, 1_793_772_000);

        _select(53_491_335);
        uint256 postMintBudget;
        (active, direction, postMintBudget, openedAt) = ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertTrue(active);
        assertTrue(direction);
        assertEq(postMintBudget, 29_626_852_605_403_425_541_687);
        assertEq(previewBudget - postMintBudget, 3_390_111_185_000_000_000_000);
    }

    function testTargetActiveSessionOnlyDecrementsBudget() public {
        _select(53_481_733);
        (bool active, bool direction, uint256 beforeBudget, uint256 openedAt) =
            ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertTrue(active);
        assertFalse(direction);
        assertEq(beforeBudget, 32_273_956_312_748_941_964_558);
        assertEq(openedAt, 1_793_743_200);

        _select(53_481_734);
        uint256 afterBudget;
        uint256 afterOpenedAt;
        (active, direction, afterBudget, afterOpenedAt) = ITargetUsdVaultPhase4(VAULT).sessionCapacity();
        assertTrue(active);
        assertFalse(direction);
        assertEq(afterOpenedAt, openedAt);
        assertEq(afterBudget, 31_430_342_063_690_475_841_358);
        assertEq(beforeBudget - afterBudget, 843_614_249_058_466_123_200);
    }

    function _select(uint256 blockNumber) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), blockNumber);
    }

    function _freshBoundaryVault(uint64 velocity) private returns (ITargetUsdVaultPhase4 vault, Phase4MarkerDex dex) {
        MockERC20 usd = new MockERC20("Boundary USD", "BUSD", 6);
        MockPriceOracle usdOracle = new MockPriceOracle(1e18);
        dex = new Phase4MarkerDex(address(usd), CBBTC, TARGET_PRICE);
        bytes memory initData = abi.encodeWithSignature(
            "init(string,string,address,address,address)",
            "Capacity Boundary",
            "CAP-B",
            address(usd),
            CONTROLLER,
            address(dex)
        );
        vault = ITargetUsdVaultPhase4(address(new ERC1967Proxy(VAULT_IMPLEMENTATION, initData)));
        vault.updateHealthCheckParams(address(usdOracle), uint64(1e18), uint64(1e18));
        vault.updateOpLimits(0, uint64(1e18 - 1), uint64(1e18 - 1));
        vault.updateSessionParams(28_800, 21_600, 0, velocity);
        vault.updateTargetDR(
            1_027_500_000_000_000_000,
            ITargetUsdVaultPhase4.Range({lower: 1_022_000_000_000_000_000, upper: 1_033_000_000_000_000_000})
        );
        usd.mint(address(this), 10_001);
        usd.approve(address(vault), 10_001);
        vault.initDeposit(10_001);
    }

    function _expectExecutionMarker(ITargetUsdVaultPhase4 vault) private returns (uint256 sellAmt) {
        (bool ok, bytes memory reason) = address(vault).call(abi.encodeCall(ITargetUsdVaultPhase4.rebalance, ()));
        assertFalse(ok);
        assertGe(reason.length, 100);
        bytes4 selector;
        address sellToken;
        address buyToken;
        assembly {
            selector := mload(add(reason, 0x20))
            sellToken := mload(add(reason, 0x24))
            buyToken := mload(add(reason, 0x44))
            sellAmt := mload(add(reason, 0x64))
        }
        assertEq(selector, Phase4MarkerDex.ExecutionReached.selector);
        assertNotEq(sellToken, address(0));
        assertNotEq(buyToken, address(0));
    }
}
