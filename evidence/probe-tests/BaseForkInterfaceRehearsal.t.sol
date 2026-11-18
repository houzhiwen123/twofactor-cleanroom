// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IPairRouter} from "../../src/interfaces/IPairRouter.sol";
import {CachedOracle} from "../../src/oracle/CachedOracle.sol";
import {PairRouter} from "../../src/router/PairRouter.sol";
import {UniswapV3DexStrategy} from "../../src/strategy/UniswapV3DexStrategy.sol";
import {UnderlyingPerpVault} from "../../src/vault/UnderlyingPerpVault.sol";
import {UsdVault} from "../../src/vault/UsdVault.sol";

/// @dev Minimal public, read-only target surfaces used by this rehearsal.
interface ITargetControllerRehearsal {
    function underlying() external view returns (address);
    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
    function underlyingOracle() external view returns (address);
}

interface ITargetUsdVaultRehearsal {
    function usd() external view returns (address);
    function underlying() external view returns (address);
    function perpSr() external view returns (address);
    function perpController() external view returns (address);
    function dexStrategy() external view returns (address);
    function usdOracle() external view returns (address);
}

interface ITargetOracleRehearsal {
    function FEED() external view returns (address);
    function STALE_AFTER() external view returns (uint32);
    function SEQUENCER_FEED() external view returns (address);
    function GRACE_PERIOD() external view returns (uint32);
    function getValidPrice() external view returns (uint256);
}

interface ITargetDexRehearsal {
    function isHealthy() external view returns (bool);
    function referencePrice(address sellToken, address buyToken) external view returns (uint256);
    function quote(address sellToken, address buyToken, uint256 sellAmt) external view returns (uint256);
    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);
}

interface IERC20Rehearsal {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice A version-locked, no-asset-movement compatibility rehearsal.
/// @dev Every deployment is ephemeral inside Foundry's local fork. No target function that changes
///      state is called; no target impersonation, deal/store, wallet, signing, or broadcasting is used.
contract BaseForkInterfaceRehearsalTest is Test {
    uint256 private constant INTERFACE_BLOCK = 53_526_143;
    uint256 private constant DEX_BLOCK = 53_243_583;

    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant JR_VAULT = 0xebEe489B84C1b3408838A87A691A4370aED139DB;
    address private constant USD_VAULT = 0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3;

    address private constant TARGET_DEX = 0xE0fC0566ADCD6b83149874619A1FAFdF3345144f;
    address private constant DEX_POOL = 0xfBB6Eed8e7aa03B138556eeDaF5D271A5E1e43ef;
    uint128 private constant DEX_MIN_LIQUIDITY = 200_000_000_000;

    struct TargetSnapshot {
        uint256 usdVaultSupply;
        uint256 jrVaultSupply;
        uint256 usdAtUsdVault;
        uint256 srAtUsdVault;
        uint256 underlyingAtJrVault;
        uint256 jrAtJrVault;
    }

    function setUp() public {
        _selectFork(INTERFACE_BLOCK);
    }

    function testLocalPairRouterReadsPinnedTargetDependenciesWithoutTargetStateChanges() public {
        _assertPinnedTopology();
        TargetSnapshot memory before_ = _snapshotTargetState();

        PairRouter localRouter = new PairRouter();
        IPairRouter.DepositParams memory depositParams = IPairRouter.DepositParams({
            usdVault: USD_VAULT,
            underlyingVault: JR_VAULT,
            strategy: address(0),
            recipient: address(this),
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
            healthCheck: false
        });
        (
            uint256 usdNotes,
            uint256 underlyingNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        ) = localRouter.deposit(depositParams);
        assertEq(usdNotes | underlyingNotes | underlyingRefund | usdRefund | srRefund | jrRefund, 0);

        IPairRouter.RedeemParams memory redeemParams = IPairRouter.RedeemParams({
            usdVault: USD_VAULT,
            underlyingVault: JR_VAULT,
            strategy: address(0),
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
            healthCheck: false
        });
        (uint256 usdOut, uint256 underlyingOut) = localRouter.redeem(redeemParams);
        assertEq(usdOut | underlyingOut, 0);

        _assertSameTargetState(before_);
        assertEq(IERC20Rehearsal(USDC).balanceOf(address(localRouter)), 0);
        assertEq(IERC20Rehearsal(CBBTC).balanceOf(address(localRouter)), 0);
        assertEq(IERC20Rehearsal(PERP_SR).balanceOf(address(localRouter)), 0);
        assertEq(IERC20Rehearsal(PERP_JR).balanceOf(address(localRouter)), 0);
    }

    function testLocalProxiesInitializeAgainstPinnedPublicDependencies() public {
        _assertPinnedTopology();

        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        UnderlyingPerpVault localJunior = _deployUnderlyingVault(implementation, false, false);
        UnderlyingPerpVault localSenior = _deployUnderlyingVault(implementation, true, true);
        assertEq(localJunior.underlying(), CBBTC);
        assertEq(localJunior.perpController(), CONTROLLER);
        assertEq(localJunior.perp(), PERP_JR);
        assertFalse(localJunior.isPerpSrVault());
        assertEq(localSenior.underlying(), CBBTC);
        assertEq(localSenior.perpController(), CONTROLLER);
        assertEq(localSenior.perp(), PERP_SR);
        assertTrue(localSenior.isPerpSrVault());

        ITargetUsdVaultRehearsal targetUsdVault = ITargetUsdVaultRehearsal(USD_VAULT);
        UsdVault usdImplementation = new UsdVault();
        UsdVault localUsdVault = UsdVault(
            address(
                new TransparentUpgradeableProxy(
                    address(usdImplementation),
                    address(this),
                    abi.encodeCall(
                        UsdVault.initExecution,
                        (
                            "Local Interface Rehearsal USD Vault",
                            "lirUSD",
                            USDC,
                            PERP_SR,
                            CBBTC,
                            CONTROLLER,
                            targetUsdVault.dexStrategy(),
                            targetUsdVault.usdOracle(),
                            address(this)
                        )
                    )
                )
            )
        );
        assertEq(localUsdVault.usd(), USDC);
        assertEq(localUsdVault.perpSr(), PERP_SR);
        assertEq(localUsdVault.underlying(), CBBTC);
        assertEq(localUsdVault.perpController(), CONTROLLER);
        assertEq(localUsdVault.dexStrategy(), targetUsdVault.dexStrategy());
        assertEq(localUsdVault.usdOracle(), targetUsdVault.usdOracle());
        assertTrue(localUsdVault.isSwapper(address(this)));
    }

    function testLocalOracleMatchesPinnedTargetConfigurationAndPrice() public {
        _selectFork(INTERFACE_BLOCK);
        address oracleAddress = ITargetControllerRehearsal(CONTROLLER).underlyingOracle();
        ITargetOracleRehearsal targetOracle = ITargetOracleRehearsal(oracleAddress);
        CachedOracle localOracle = new CachedOracle(
            targetOracle.FEED(), targetOracle.STALE_AFTER(), targetOracle.SEQUENCER_FEED(), targetOracle.GRACE_PERIOD()
        );

        assertEq(localOracle.FEED(), targetOracle.FEED());
        assertEq(localOracle.STALE_AFTER(), targetOracle.STALE_AFTER());
        assertEq(localOracle.SEQUENCER_FEED(), targetOracle.SEQUENCER_FEED());
        assertEq(localOracle.GRACE_PERIOD(), targetOracle.GRACE_PERIOD());
        assertEq(localOracle.getValidPrice(), targetOracle.getValidPrice());

        // Transient cache writes are local to this EVM call and never touch the target oracle.
        localOracle.cachePrice();
        assertEq(localOracle.getValidPrice(), targetOracle.getValidPrice());
        localOracle.resetCache();
        assertEq(localOracle.getValidPrice(), targetOracle.getValidPrice());
    }

    function testLocalDexAdapterMatchesPinnedTargetQuotes() public {
        _selectFork(DEX_BLOCK);
        ITargetDexRehearsal targetDex = ITargetDexRehearsal(TARGET_DEX);
        UniswapV3DexStrategy localDex = new UniswapV3DexStrategy(USDC, CBBTC, DEX_POOL, DEX_MIN_LIQUIDITY);

        assertEq(localDex.isHealthy(), targetDex.isHealthy());
        assertEq(localDex.referencePrice(USDC, CBBTC), targetDex.referencePrice(USDC, CBBTC));
        assertEq(localDex.referencePrice(CBBTC, USDC), targetDex.referencePrice(CBBTC, USDC));

        uint256[3] memory usdInputs = [uint256(1_000_000), 1_000_000_000, 1_000_000_000_000];
        for (uint256 i; i < usdInputs.length; ++i) {
            _assertDexVector(localDex, targetDex, USDC, CBBTC, usdInputs[i]);
        }
        uint256[3] memory btcInputs = [uint256(1_000), 1_000_000, 100_000_000];
        for (uint256 i; i < btcInputs.length; ++i) {
            _assertDexVector(localDex, targetDex, CBBTC, USDC, btcInputs[i]);
        }
    }

    function _deployUnderlyingVault(UnderlyingPerpVault implementation, bool senior, bool mintsAboveTarget)
        private
        returns (UnderlyingPerpVault vault)
    {
        vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            senior ? "Local Interface Rehearsal Senior" : "Local Interface Rehearsal Junior",
                            senior ? "lirSR" : "lirJR",
                            CBBTC,
                            CONTROLLER,
                            senior,
                            mintsAboveTarget
                        )
                    )
                )
            )
        );
    }

    function _assertDexVector(
        UniswapV3DexStrategy localDex,
        ITargetDexRehearsal targetDex,
        address sellToken,
        address buyToken,
        uint256 input
    ) private view {
        uint256 targetQuote = targetDex.quote(sellToken, buyToken, input);
        assertEq(localDex.quote(sellToken, buyToken, input), targetQuote);
        (uint256 targetSell, uint256 targetBuy) = targetDex.maxFillable(sellToken, buyToken, input, targetQuote);
        (uint256 localSell, uint256 localBuy) = localDex.maxFillable(sellToken, buyToken, input, targetQuote);
        assertEq(localSell, targetSell);
        assertEq(localBuy, targetBuy);
    }

    function _selectFork(uint256 blockNumber) private {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), blockNumber);
        assertEq(block.chainid, 8453);
        assertEq(block.number, blockNumber);
    }

    function _assertPinnedTopology() private view {
        assertGt(CONTROLLER.code.length, 0);
        assertGt(USD_VAULT.code.length, 0);
        assertGt(JR_VAULT.code.length, 0);
        ITargetControllerRehearsal controller = ITargetControllerRehearsal(CONTROLLER);
        assertEq(controller.underlying(), CBBTC);
        assertEq(controller.perpJr(), PERP_JR);
        assertEq(controller.perpSr(), PERP_SR);
        ITargetUsdVaultRehearsal usdVault = ITargetUsdVaultRehearsal(USD_VAULT);
        assertEq(usdVault.usd(), USDC);
        assertEq(usdVault.underlying(), CBBTC);
        assertEq(usdVault.perpSr(), PERP_SR);
        assertEq(usdVault.perpController(), CONTROLLER);
    }

    function _snapshotTargetState() private view returns (TargetSnapshot memory snapshot) {
        snapshot.usdVaultSupply = IERC20Rehearsal(USD_VAULT).totalSupply();
        snapshot.jrVaultSupply = IERC20Rehearsal(JR_VAULT).totalSupply();
        snapshot.usdAtUsdVault = IERC20Rehearsal(USDC).balanceOf(USD_VAULT);
        snapshot.srAtUsdVault = IERC20Rehearsal(PERP_SR).balanceOf(USD_VAULT);
        snapshot.underlyingAtJrVault = IERC20Rehearsal(CBBTC).balanceOf(JR_VAULT);
        snapshot.jrAtJrVault = IERC20Rehearsal(PERP_JR).balanceOf(JR_VAULT);
    }

    function _assertSameTargetState(TargetSnapshot memory before_) private view {
        TargetSnapshot memory after_ = _snapshotTargetState();
        assertEq(after_.usdVaultSupply, before_.usdVaultSupply);
        assertEq(after_.jrVaultSupply, before_.jrVaultSupply);
        assertEq(after_.usdAtUsdVault, before_.usdAtUsdVault);
        assertEq(after_.srAtUsdVault, before_.srAtUsdVault);
        assertEq(after_.underlyingAtJrVault, before_.underlyingAtJrVault);
        assertEq(after_.jrAtJrVault, before_.jrAtJrVault);
    }
}
