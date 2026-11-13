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
}

interface IUsdVaultController {
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
}

/// @notice Clean-room implementation of the evidence-backed USD Vault mint/deposit and exit paths.
/// @dev Rebalance execution, keeper/admin controls, health checks and the target initializer remain outside this phase.
contract UsdVault is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IUsdVault {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();
    error NoOp();
    error OpUnavailable(string reason);

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

    struct RebalancePlan {
        uint256 maxRebalanceUnderlying;
        uint256 underlyingPrice;
        uint256 rebalanceUsdVal;
        bool isMintingPerp;
        uint256 currentDR;
        bool sessionActive;
        uint256 sessionBudgetUsdVal;
        uint256 sessionOpenedAtSec;
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

    /// @dev Planning-only guard surface. Asset movement remains deferred. The
    ///      returned plan is committed only after a future executor succeeds.
    function _validatedRebalancePlan() internal view returns (RebalancePlan memory plan) {
        (plan.maxRebalanceUnderlying, plan.underlyingPrice, plan.isMintingPerp, plan.currentDR,) = rebalanceCapacity();
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

    /// @dev Must be called only as the last state-changing step after future
    ///      rebalance asset execution has succeeded atomically.
    function _commitRebalanceSession(RebalancePlan memory plan, uint256 consumedUsdVal) internal {
        if (consumedUsdVal > plan.sessionBudgetUsdVal) revert OpUnavailable("capacity");
        _setSessionState(
            plan.isMintingPerp, uint128(plan.sessionBudgetUsdVal - consumedUsdVal), uint64(plan.sessionOpenedAtSec)
        );
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
