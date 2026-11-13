// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUsdVault} from "../interfaces/IUsdVault.sol";

interface IUsdVaultPriceOracle {
    function getValidPrice() external view returns (uint256);

    function cachePrice() external;

    function resetCache() external;
}

interface IUsdVaultController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    function systemReserveState() external view returns (SystemState memory state);

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);

    function underlyingOracle() external view returns (address);

    function targetSystemRatio() external view returns (uint256);

    function flashMint2(
        uint256 underlyingAmtIntoPerpSr,
        uint256 underlyingAmtIntoPerpJr,
        uint256 minPerpSrAmtOut,
        uint256 minPerpJrAmtOut
    )
        external
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);

    function flashRedeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minUnderlyingAmtOut)
        external
        returns (uint256 underlyingAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc);
}

interface IUsdVaultDexStrategy {
    function isHealthy() external view returns (bool);

    function referencePrice(address sellToken, address buyToken) external view returns (uint256);

    function maxFillable(address sellToken, address buyToken, uint256 maxSellAmt, uint256 minBuyAmt)
        external
        view
        returns (uint256 sellAmt, uint256 buyAmt);

    function trade(address sellToken, address buyToken, uint256 sellAmt) external returns (uint256 buyAmt);
}

/// @notice Clean-room implementation of the evidence-backed USD Vault core paths.
/// @dev Phase 5B preserves the target-observed split between authorized inventory swaps and the direct DEX fallback.
contract UsdVault is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IUsdVault {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();
    error NoOp();
    error OpUnavailable(string reason);
    error SlippageTooHigh();
    error UnauthorizedCall();

    uint256 private constant WAD = 1e18;
    uint256 private constant USD_UNIT = 1e6;
    uint256 private constant UNDERLYING_UNIT = 1e8;
    uint32 private constant DEFAULT_REBALANCE_FREQ_SEC = 28_800;
    uint32 private constant DEFAULT_REBALANCE_OFFSET_SEC = 21_600;
    uint64 private constant DEFAULT_MAX_DEPLOYMENT_VELOCITY_PERC = 330_000_000_000_000_000;
    uint96 private constant DEFAULT_TARGET_DR = 1_027_500_000_000_000_000;
    uint96 private constant DEFAULT_EQ_DR_LOWER = 1_022_000_000_000_000_000;
    uint96 private constant DEFAULT_EQ_DR_UPPER = 1_033_000_000_000_000_000;
    uint128 private constant DEFAULT_MIN_OP_USD_VAL = 50e18;
    uint32 private constant DEFAULT_ACTIVE_REBALANCE_DELAY_SEC = 3_600;
    uint64 private constant DEFAULT_MAX_USD_DEVIATION_PERC = 5_000_000_000_000_000;
    uint64 private constant DEFAULT_MAX_UNDERLYING_DEVIATION_PERC = 50_000_000_000_000_000;
    uint64 private constant DEFAULT_MAX_FLASH_MINT_FEE_PERC = 5_000_000_000_000_000;
    uint64 private constant DEFAULT_MAX_FLASH_REDEEM_FEE_PERC = 5_000_000_000_000_000;

    IERC20 private _usdToken;
    IERC20 private _perpSrToken;
    IERC20 private _underlyingToken;
    address private _perpController;
    uint128 internal _sessionBudgetUsdVal;
    uint64 internal _sessionOpenedAtSec;
    bool internal _sessionIsMintingPerp;
    uint32 internal _rebalanceFreqSec;
    uint32 internal _rebalanceOffsetSec;
    uint64 internal _maxDeploymentVelocityPerc;
    uint96 internal _targetDR;
    uint128 internal _minOpUsdVal;
    uint96 internal _eqDRLower;
    uint32 internal _activeRebalanceDelaySec;
    uint96 internal _eqDRUpper;
    address private _dexStrategy;
    address private _usdOracle;
    mapping(address => bool) private _isSwapper;
    uint64 private _maxUsdDeviationPerc;
    uint64 private _maxUnderlyingDeviationPerc;
    uint64 private _maxFlashMintFeePerc;
    uint64 private _maxFlashRedeemFeePerc;

    struct RebalancePlan {
        uint256 maxRebalanceUnderlying;
        uint256 underlyingPrice;
        uint256 rebalanceUsdVal;
        bool isMintingPerp;
        uint256 currentDR;
        bool sessionActive;
        uint256 sessionBudgetUsdVal;
        uint256 sessionOpenedAtSec;
        uint256 perpSrTotalSupply;
        uint256 perpSrReserveValue;
    }

    struct ExecutionContext {
        RebalancePlan plan;
        uint256 referencePrice;
        address underlyingOracle;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the local proxy-compatible vault module.
    /// @dev LOCAL-CLEANROOM scaffolding, not a target-confirmed initializer ABI.
    function init(
        string calldata name_,
        string calldata symbol_,
        address usdToken_,
        address perpSrToken_,
        address underlyingToken_,
        address perpController_
    ) external initializer {
        _initializeCore(name_, symbol_, usdToken_, perpSrToken_, underlyingToken_, perpController_);
    }

    /// @notice Initializes a fresh local deployment with the phase-5B execution dependencies.
    /// @dev LOCAL-CLEANROOM deployment scaffolding. The target initializer ABI has not been copied.
    function initExecution(
        string calldata name_,
        string calldata symbol_,
        address usdToken_,
        address perpSrToken_,
        address underlyingToken_,
        address perpController_,
        address dexStrategy_,
        address usdOracle_,
        address swapper_
    ) external initializer {
        if (dexStrategy_ == address(0) || usdOracle_ == address(0) || swapper_ == address(0)) {
            revert InvalidParamDefn();
        }
        _initializeCore(name_, symbol_, usdToken_, perpSrToken_, underlyingToken_, perpController_);
        _dexStrategy = dexStrategy_;
        _usdOracle = usdOracle_;
        _isSwapper[swapper_] = true;
    }

    function _initializeCore(
        string calldata name_,
        string calldata symbol_,
        address usdToken_,
        address perpSrToken_,
        address underlyingToken_,
        address perpController_
    ) private {
        if (
            usdToken_ == address(0) || perpSrToken_ == address(0) || underlyingToken_ == address(0)
                || perpController_ == address(0)
        ) revert InvalidParamDefn();
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        _usdToken = IERC20(usdToken_);
        _perpSrToken = IERC20(perpSrToken_);
        _underlyingToken = IERC20(underlyingToken_);
        _perpController = perpController_;
        _rebalanceFreqSec = DEFAULT_REBALANCE_FREQ_SEC;
        _rebalanceOffsetSec = DEFAULT_REBALANCE_OFFSET_SEC;
        _maxDeploymentVelocityPerc = DEFAULT_MAX_DEPLOYMENT_VELOCITY_PERC;
        _targetDR = DEFAULT_TARGET_DR;
        _minOpUsdVal = DEFAULT_MIN_OP_USD_VAL;
        _eqDRLower = DEFAULT_EQ_DR_LOWER;
        _eqDRUpper = DEFAULT_EQ_DR_UPPER;
        _activeRebalanceDelaySec = DEFAULT_ACTIVE_REBALANCE_DELAY_SEC;
        _maxUsdDeviationPerc = DEFAULT_MAX_USD_DEVIATION_PERC;
        _maxUnderlyingDeviationPerc = DEFAULT_MAX_UNDERLYING_DEVIATION_PERC;
        _maxFlashMintFeePerc = DEFAULT_MAX_FLASH_MINT_FEE_PERC;
        _maxFlashRedeemFeePerc = DEFAULT_MAX_FLASH_REDEEM_FEE_PERC;
    }

    function usdBalance() public view returns (uint256) {
        return _usdToken.balanceOf(address(this));
    }

    function perpSrBalance() public view returns (uint256) {
        return _perpSrToken.balanceOf(address(this));
    }

    function underlyingBalance() public view returns (uint256) {
        return _underlyingToken.balanceOf(address(this));
    }

    function perpController() external view returns (address) {
        return _perpController;
    }

    function sessionBudgetUsdVal() external view returns (uint128) {
        return _sessionBudgetUsdVal;
    }

    function sessionOpenedAtSec() external view returns (uint64) {
        return _sessionOpenedAtSec;
    }

    function sessionIsMintingPerp() external view returns (bool) {
        return _sessionIsMintingPerp;
    }

    function rebalanceFreqSec() external view returns (uint32) {
        return _rebalanceFreqSec;
    }

    function rebalanceOffsetSec() external view returns (uint32) {
        return _rebalanceOffsetSec;
    }

    function maxDeploymentVelocityPerc() external view returns (uint64) {
        return _maxDeploymentVelocityPerc;
    }

    function targetDR() external view returns (uint96) {
        return _targetDR;
    }

    function eqDRRange() external view returns (IUsdVault.Range memory) {
        return IUsdVault.Range({lower: _eqDRLower, upper: _eqDRUpper});
    }

    function minOpUsdVal() external view returns (uint128) {
        return _minOpUsdVal;
    }

    function activeRebalanceDelaySec() external view returns (uint32) {
        return _activeRebalanceDelaySec;
    }

    function dexStrategy() external view returns (address) {
        return _dexStrategy;
    }

    function usdOracle() external view returns (address) {
        return _usdOracle;
    }

    function isSwapper(address account) external view returns (bool) {
        return _isSwapper[account];
    }

    function maxUsdDeviationPerc() external view returns (uint64) {
        return _maxUsdDeviationPerc;
    }

    function maxUnderlyingDeviationPerc() external view returns (uint64) {
        return _maxUnderlyingDeviationPerc;
    }

    function maxFlashMintFeePerc() external view returns (uint64) {
        return _maxFlashMintFeePerc;
    }

    function maxFlashRedeemFeePerc() external view returns (uint64) {
        return _maxFlashRedeemFeePerc;
    }

    function sessionCapacity()
        external
        view
        returns (bool active, bool sessionIsMintingPerp_, uint256 sessionBudgetUsdVal_, uint256 sessionOpenedAtSec_)
    {
        return _sessionCapacity();
    }

    function _sessionCapacity()
        internal
        view
        returns (bool active, bool sessionIsMintingPerp_, uint256 sessionBudgetUsdVal_, uint256 sessionOpenedAtSec_)
    {
        sessionOpenedAtSec_ = ((block.timestamp - _rebalanceOffsetSec) / _rebalanceFreqSec) * _rebalanceFreqSec
            + _rebalanceOffsetSec;
        active = sessionOpenedAtSec_ == _sessionOpenedAtSec;
        if (active) {
            return (true, _sessionIsMintingPerp, _sessionBudgetUsdVal, _sessionOpenedAtSec);
        }

        // An inactive preview keeps the last persisted direction. The current
        // required direction belongs to rebalanceCapacity(); it is committed
        // here only after a successful rebalance execution.
        sessionIsMintingPerp_ = _sessionIsMintingPerp;
        sessionBudgetUsdVal_ = Math.mulDiv(getTVL(), _maxDeploymentVelocityPerc, WAD);
    }

    function rebalanceCapacity()
        public
        view
        returns (
            uint256 maxRebalanceUnderlying,
            uint256 underlyingPrice,
            bool isMintingPerp,
            uint256 currentDR,
            IUsdVault.SystemState memory state
        )
    {
        IUsdVaultController.SystemState memory controllerState =
            IUsdVaultController(_perpController).systemReserveState();
        state.perpSr = IUsdVault.ReserveState({
            totalSupply: controllerState.perpSr.totalSupply,
            reserveValue: controllerState.perpSr.reserveValue,
            vm: controllerState.perpSr.vm
        });
        state.perpJr = IUsdVault.ReserveState({
            totalSupply: controllerState.perpJr.totalSupply,
            reserveValue: controllerState.perpJr.reserveValue,
            vm: controllerState.perpJr.vm
        });
        underlyingPrice = IUsdVaultPriceOracle(IUsdVaultController(_perpController).underlyingOracle()).getValidPrice();
        (currentDR,) = IUsdVaultController(_perpController).systemDeviations();
        isMintingPerp = currentDR > _targetDR;

        if (currentDR >= _eqDRLower && currentDR <= _eqDRUpper) {
            return (0, underlyingPrice, isMintingPerp, currentDR, state);
        }

        uint256 targetSystemRatio_ = IUsdVaultController(_perpController).targetSystemRatio();
        if (targetSystemRatio_ == 0 || _targetDR == 0) return (0, underlyingPrice, isMintingPerp, currentDR, state);
        uint256 denominator = targetSystemRatio_ * uint256(_targetDR);
        uint256 targetSrReserve;

        if (isMintingPerp) {
            targetSrReserve = Math.mulDiv(state.perpJr.reserveValue, WAD * WAD, denominator);
            uint256 systemCapacity =
                targetSrReserve > state.perpSr.reserveValue ? targetSrReserve - state.perpSr.reserveValue : 0;
            uint256 usdValue = Math.mulDiv(usdBalance(), WAD, USD_UNIT);
            uint256 assetCapacity = underlyingPrice == 0 ? 0 : Math.mulDiv(usdValue, UNDERLYING_UNIT, underlyingPrice);
            maxRebalanceUnderlying = Math.min(systemCapacity, assetCapacity);
        } else {
            targetSrReserve = Math.mulDiv(state.perpJr.reserveValue, WAD * WAD, denominator, Math.Rounding.Ceil);
            uint256 systemCapacity =
                state.perpSr.reserveValue > targetSrReserve ? state.perpSr.reserveValue - targetSrReserve : 0;
            uint256 assetCapacity = state.perpSr.totalSupply == 0
                ? 0
                : Math.mulDiv(perpSrBalance(), state.perpSr.reserveValue, state.perpSr.totalSupply);
            maxRebalanceUnderlying = Math.min(systemCapacity, assetCapacity);
        }
    }

    /// @dev Builds and validates the bounded plan used by both inventory and direct execution.
    ///      The returned plan is committed only after all asset movement succeeds.
    function _validatedRebalancePlan() internal view returns (RebalancePlan memory plan) {
        IUsdVault.SystemState memory state;
        (plan.maxRebalanceUnderlying, plan.underlyingPrice, plan.isMintingPerp, plan.currentDR, state) =
            rebalanceCapacity();
        plan.perpSrTotalSupply = state.perpSr.totalSupply;
        plan.perpSrReserveValue = state.perpSr.reserveValue;
        if (plan.maxRebalanceUnderlying == 0) revert NoOp();

        bool sessionDirection;
        (plan.sessionActive, sessionDirection, plan.sessionBudgetUsdVal, plan.sessionOpenedAtSec) = _sessionCapacity();
        if (plan.sessionActive && sessionDirection != plan.isMintingPerp) revert OpUnavailable("direction");

        uint256 sessionCapacityUnderlying = plan.underlyingPrice == 0
            ? 0
            : Math.mulDiv(plan.sessionBudgetUsdVal, UNDERLYING_UNIT, plan.underlyingPrice);
        plan.maxRebalanceUnderlying = Math.min(plan.maxRebalanceUnderlying, sessionCapacityUnderlying);
        if (plan.maxRebalanceUnderlying == 0) revert OpUnavailable("no capacity");
        plan.rebalanceUsdVal = Math.mulDiv(plan.maxRebalanceUnderlying, plan.underlyingPrice, UNDERLYING_UNIT);
        if (plan.rebalanceUsdVal < _minOpUsdVal) revert OpUnavailable("min size");
    }

    /// @dev Called only after rebalance asset execution has succeeded atomically.
    function _commitRebalanceSession(RebalancePlan memory plan, uint256 consumedUsdVal) internal {
        if (consumedUsdVal > plan.sessionBudgetUsdVal) revert OpUnavailable("capacity");
        _setSessionState(
            plan.isMintingPerp, uint128(plan.sessionBudgetUsdVal - consumedUsdVal), uint64(plan.sessionOpenedAtSec)
        );
    }

    /// @notice Permissionless direct-DEX fallback after the active-session delay.
    function rebalance() external nonReentrant {
        _executeDirectRebalance(true);
    }

    /// @notice Permissionless maintenance entry used by external automation.
    /// @dev Target evidence proves health/state revalidation and NoOp, but not an internal DEX settlement path.
    function upkeep() external nonReentrant {
        _loadExecutionContext(true);
        revert NoOp();
    }

    /// @notice Authorized inventory callback; external market settlement remains outside this Vault.
    function swap(address tokenIn, address tokenOut, uint256 tokenInAmt, uint256 tokenOutAmt) external nonReentrant {
        if (!_isSwapper[msg.sender]) revert UnauthorizedCall();

        bool isMintingPerp = tokenIn == address(_underlyingToken) && tokenOut == address(_usdToken);
        bool isRedeemingPerp = tokenIn == address(_usdToken) && tokenOut == address(_underlyingToken);
        if (!isMintingPerp && !isRedeemingPerp) revert InvalidParamDefn();

        ExecutionContext memory context = _loadExecutionContext(false);
        if (context.plan.isMintingPerp != isMintingPerp) revert OpUnavailable("direction");
        if (isMintingPerp) {
            _executeInventoryMint(context, tokenInAmt, tokenOutAmt);
        } else {
            _executeInventoryRedeem(context, tokenInAmt, tokenOutAmt);
        }
    }

    function _executeInventoryMint(ExecutionContext memory context, uint256 underlyingIn, uint256 usdOut) private {
        if (underlyingIn == 0 || underlyingIn > context.plan.maxRebalanceUnderlying) {
            revert OpUnavailable("capacity");
        }
        uint256 consumedUsdVal = usdOut * (WAD / USD_UNIT);
        _validateActualRebalance(context.plan, consumedUsdVal);

        _underlyingToken.safeTransferFrom(msg.sender, address(this), underlyingIn);
        _underlyingToken.forceApprove(_perpController, underlyingIn);
        (,, IUsdVaultController.FeePerc memory fee,) =
            IUsdVaultController(_perpController).flashMint2(underlyingIn, 0, 0, 0);
        _validateFlashFee(fee, _maxFlashMintFeePerc);
        _usdToken.safeTransfer(msg.sender, usdOut);

        _finalizeRebalance(context, consumedUsdVal);
    }

    function _executeInventoryRedeem(ExecutionContext memory context, uint256 usdIn, uint256 underlyingOut) private {
        if (underlyingOut == 0 || underlyingOut > context.plan.maxRebalanceUnderlying) {
            revert OpUnavailable("capacity");
        }
        uint256 perpToRedeem = _perpForUnderlying(context.plan, context.plan.maxRebalanceUnderlying);

        _usdToken.safeTransferFrom(msg.sender, address(this), usdIn);
        _perpSrToken.forceApprove(_perpController, perpToRedeem);
        (uint256 underlyingReceived, IUsdVaultController.FeePerc memory fee,) =
            IUsdVaultController(_perpController).flashRedeem2(perpToRedeem, 0, 0);
        _validateFlashFee(fee, _maxFlashRedeemFeePerc);
        if (underlyingReceived < underlyingOut) revert SlippageTooHigh();
        _underlyingToken.safeTransfer(msg.sender, underlyingOut);

        uint256 consumedUsdVal = Math.mulDiv(underlyingReceived, context.plan.underlyingPrice, UNDERLYING_UNIT);
        _validateActualRebalance(context.plan, consumedUsdVal);
        _finalizeRebalance(context, consumedUsdVal);
    }

    function _executeDirectRebalance(bool enforceDelay) private {
        ExecutionContext memory context = _loadExecutionContext(true);
        if (enforceDelay && block.timestamp < context.plan.sessionOpenedAtSec + uint256(_activeRebalanceDelaySec)) {
            revert OpUnavailable("active delayed");
        }

        uint256 consumedUsdVal;
        if (context.plan.isMintingPerp) {
            consumedUsdVal = _directMint(context);
        } else {
            consumedUsdVal = _directRedeem(context);
        }
        _validateActualRebalance(context.plan, consumedUsdVal);
        _finalizeRebalance(context, consumedUsdVal);
    }

    function _directMint(ExecutionContext memory context) private returns (uint256 consumedUsdVal) {
        uint256 maxUsdSell = Math.mulDiv(context.plan.maxRebalanceUnderlying, context.referencePrice, 1e20);
        uint256 minUnderlyingBuy = Math.mulDiv(maxUsdSell, 1e20, context.referencePrice);
        (uint256 usdSell,) = IUsdVaultDexStrategy(_dexStrategy)
            .maxFillable(address(_usdToken), address(_underlyingToken), maxUsdSell, minUnderlyingBuy);
        if (usdSell == 0) revert NoOp();

        _usdToken.forceApprove(_dexStrategy, usdSell);
        uint256 underlyingBought =
            IUsdVaultDexStrategy(_dexStrategy).trade(address(_usdToken), address(_underlyingToken), usdSell);
        if (underlyingBought < minUnderlyingBuy) revert SlippageTooHigh();

        _underlyingToken.forceApprove(_perpController, underlyingBought);
        (,, IUsdVaultController.FeePerc memory fee,) =
            IUsdVaultController(_perpController).flashMint2(underlyingBought, 0, 0, 0);
        _validateFlashFee(fee, _maxFlashMintFeePerc);
        consumedUsdVal = usdSell * (WAD / USD_UNIT);
    }

    function _directRedeem(ExecutionContext memory context) private returns (uint256 consumedUsdVal) {
        uint256 perpToRedeem = _perpForUnderlying(context.plan, context.plan.maxRebalanceUnderlying);
        _perpSrToken.forceApprove(_perpController, perpToRedeem);
        (uint256 underlyingReceived, IUsdVaultController.FeePerc memory fee,) =
            IUsdVaultController(_perpController).flashRedeem2(perpToRedeem, 0, 0);
        _validateFlashFee(fee, _maxFlashRedeemFeePerc);

        uint256 minUsdBuy = Math.mulDiv(underlyingReceived, context.referencePrice, 1e20);
        (uint256 underlyingSell,) = IUsdVaultDexStrategy(_dexStrategy)
            .maxFillable(address(_underlyingToken), address(_usdToken), underlyingReceived, minUsdBuy);
        if (underlyingSell == 0) revert NoOp();

        _underlyingToken.forceApprove(_dexStrategy, underlyingSell);
        uint256 usdBought =
            IUsdVaultDexStrategy(_dexStrategy).trade(address(_underlyingToken), address(_usdToken), underlyingSell);
        if (usdBought < minUsdBuy) revert SlippageTooHigh();
        consumedUsdVal = Math.mulDiv(underlyingReceived, context.plan.underlyingPrice, UNDERLYING_UNIT);
    }

    function _loadExecutionContext(bool requireHealthy) private returns (ExecutionContext memory context) {
        if (_dexStrategy == address(0) || _usdOracle == address(0)) revert OpUnavailable("execution unavailable");
        if (requireHealthy && !IUsdVaultDexStrategy(_dexStrategy).isHealthy()) {
            revert OpUnavailable("dex unhealthy");
        }

        uint256 usdPrice = IUsdVaultPriceOracle(_usdOracle).getValidPrice();
        if (usdPrice == 0) revert OpUnavailable("usd oracle");
        if (usdPrice < WAD - _maxUsdDeviationPerc || usdPrice > WAD + _maxUsdDeviationPerc) {
            revert OpUnavailable("usd peg");
        }
        context.underlyingOracle = IUsdVaultController(_perpController).underlyingOracle();
        IUsdVaultPriceOracle(context.underlyingOracle).cachePrice();
        uint256 underlyingPrice = IUsdVaultPriceOracle(context.underlyingOracle).getValidPrice();
        if (underlyingPrice == 0) {
            revert OpUnavailable("underlying oracle");
        }
        context.referencePrice =
            IUsdVaultDexStrategy(_dexStrategy).referencePrice(address(_underlyingToken), address(_usdToken));
        if (context.referencePrice == 0) revert OpUnavailable("reference price");
        uint256 lowerReferencePrice = Math.mulDiv(underlyingPrice, WAD - _maxUnderlyingDeviationPerc, WAD);
        uint256 upperReferencePrice = Math.mulDiv(underlyingPrice, WAD + _maxUnderlyingDeviationPerc, WAD);
        if (context.referencePrice < lowerReferencePrice || context.referencePrice > upperReferencePrice) {
            revert OpUnavailable("oracle divergence");
        }
        context.plan = _validatedRebalancePlan();
    }

    function _validateFlashFee(IUsdVaultController.FeePerc memory fee, uint64 maxFeePerc) private pure {
        if (fee.totalFeePerc > maxFeePerc) revert OpUnavailable("flash fee");
    }

    function _validateActualRebalance(RebalancePlan memory plan, uint256 consumedUsdVal) private view {
        if (consumedUsdVal > plan.sessionBudgetUsdVal) revert OpUnavailable("capacity");
        if (consumedUsdVal < _minOpUsdVal) revert OpUnavailable("min size");
    }

    function _perpForUnderlying(RebalancePlan memory plan, uint256 underlyingAmt) private pure returns (uint256) {
        if (plan.perpSrTotalSupply == 0 || plan.perpSrReserveValue == 0) revert NoOp();
        return Math.mulDiv(underlyingAmt, plan.perpSrTotalSupply, plan.perpSrReserveValue, Math.Rounding.Ceil);
    }

    function _finalizeRebalance(ExecutionContext memory context, uint256 consumedUsdVal) private {
        _commitRebalanceSession(context.plan, consumedUsdVal);
        emit Rebalance(context.plan.currentDR, context.plan.underlyingPrice, consumedUsdVal, context.plan.isMintingPerp);
        IUsdVaultPriceOracle(context.underlyingOracle).resetCache();
    }

    function getTVL() public view returns (uint256) {
        IUsdVaultController.SystemState memory state = IUsdVaultController(_perpController).systemReserveState();
        uint256 underlyingPrice =
            IUsdVaultPriceOracle(IUsdVaultController(_perpController).underlyingOracle()).getValidPrice();

        uint256 perpUnderlying = Math.mulDiv(perpSrBalance(), state.perpSr.reserveValue, state.perpSr.totalSupply);
        uint256 usdValue = Math.mulDiv(usdBalance(), WAD, USD_UNIT);
        uint256 idleUnderlyingValue = Math.mulDiv(underlyingBalance(), underlyingPrice, UNDERLYING_UNIT);
        uint256 perpValue = Math.mulDiv(perpUnderlying, underlyingPrice, UNDERLYING_UNIT);
        return usdValue + idleUnderlyingValue + perpValue;
    }

    function computeMintAmt(uint256 usdMax, uint256 perpSrMax)
        public
        view
        returns (uint256 notesMinted, uint256 usdAmtIn, uint256 perpSrAmtIn)
    {
        uint256 usdBal = usdBalance();
        uint256 perpBal = perpSrBalance();

        if (usdMax * perpBal <= perpSrMax * usdBal) {
            usdAmtIn = usdMax;
            perpSrAmtIn = usdMax * perpBal / usdBal;
        } else {
            perpSrAmtIn = perpSrMax;
            usdAmtIn = perpSrMax * usdBal / perpBal;
        }

        IUsdVaultController.SystemState memory state = IUsdVaultController(_perpController).systemReserveState();
        uint256 underlyingPrice =
            IUsdVaultPriceOracle(IUsdVaultController(_perpController).underlyingOracle()).getValidPrice();
        uint256 perpUnderlying = Math.mulDiv(perpSrAmtIn, state.perpSr.reserveValue, state.perpSr.totalSupply);
        uint256 depositValue =
            Math.mulDiv(usdAmtIn, WAD, USD_UNIT) + Math.mulDiv(perpUnderlying, underlyingPrice, UNDERLYING_UNIT);

        notesMinted = Math.mulDiv(depositValue, totalSupply(), getTVL());
    }

    function deposit(uint256 usdMax, uint256 perpSrMax) external nonReentrant returns (uint256 notesMinted) {
        uint256 usdAmtIn;
        uint256 perpSrAmtIn;
        (notesMinted, usdAmtIn, perpSrAmtIn) = computeMintAmt(usdMax, perpSrMax);
        if (notesMinted == 0 && usdAmtIn == 0 && perpSrAmtIn == 0) return 0;

        if (usdAmtIn != 0) _usdToken.safeTransferFrom(msg.sender, address(this), usdAmtIn);
        if (perpSrAmtIn != 0) _perpSrToken.safeTransferFrom(msg.sender, address(this), perpSrAmtIn);
        _mint(msg.sender, notesMinted);

        emit Deposit(usdAmtIn, perpSrAmtIn, notesMinted);
    }

    function computeRedemptionAmts(uint256 notesAmt) public view returns (uint256 usdAmtOut, uint256 perpSrAmtOut) {
        uint256 notesSupply = totalSupply();
        usdAmtOut = Math.mulDiv(notesAmt, usdBalance(), notesSupply);
        perpSrAmtOut = Math.mulDiv(notesAmt, perpSrBalance(), notesSupply);
    }

    function redeem(uint256 notesAmt) external nonReentrant returns (uint256 usdAmtOut, uint256 perpSrAmtOut) {
        (usdAmtOut, perpSrAmtOut) = computeRedemptionAmts(notesAmt);
        _burn(msg.sender, notesAmt);

        if (usdAmtOut != 0) _usdToken.safeTransfer(msg.sender, usdAmtOut);
        if (perpSrAmtOut != 0) _perpSrToken.safeTransfer(msg.sender, perpSrAmtOut);

        emit Redeem(notesAmt, usdAmtOut, perpSrAmtOut);
    }

    /// @dev Reserved for a future evidence-backed note issuance path. This is
    ///      reachable only from derived contracts, such as the local test harness.
    function _mintNotes(address to, uint256 amount) internal {
        _mint(to, amount);
    }

    /// @dev Reserved for the separately evidenced rebalance phase. The production
    ///      contract has no external session mutator in this phase.
    function _setSessionState(bool isMintingPerp, uint128 budgetUsdVal, uint64 openedAtSec) internal {
        _sessionIsMintingPerp = isMintingPerp;
        _sessionBudgetUsdVal = budgetUsdVal;
        _sessionOpenedAtSec = openedAtSec;
    }
}
