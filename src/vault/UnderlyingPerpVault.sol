// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {
    ERC20BurnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUnderlyingPerpVault} from "../interfaces/IUnderlyingPerpVault.sol";

interface IUnderlyingPerpVaultController {
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

    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
    function systemReserveState() external view returns (SystemState memory state);
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
    function targetSystemRatio() external view returns (uint256);

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee);

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee);
}

/// @notice Clean-room phase-1 implementation shared by the cbBTC/Perp SR and cbBTC/Perp JR vaults.
/// @dev Only target-confirmed initialization, valuation, deposit and redemption behavior is included.
contract UnderlyingPerpVault is
    Initializable,
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IUnderlyingPerpVault
{
    using SafeERC20 for IERC20;

    struct Phase2Storage {
        uint96 targetDR;
        uint32 rebalanceFreqSec;
        uint32 rebalanceOffsetSec;
        uint64 lastRebalanceTimestampSec;
        uint96 eqDRLower;
        uint96 eqDRUpper;
        uint64 maxFlashFeePerc;
        uint128 minRebalanceVal;
    }

    error InvalidParamDefn();
    error InvalidPerc();
    error InvalidRange();
    error LastRebalanceTooRecent();
    error NoOp();
    error OpUnavailable(string reason);
    error SlippageTooHigh();
    error UnauthorizedCall();
    error VaultInitialized();
    error VaultNotInitialized();

    uint256 public constant override MINIMUM_LIQUIDITY = 1e10;
    uint256 public constant override ONE = 1e18;

    address public override underlying;
    address public override perp;
    address public override perpController;
    address public override keeper;
    uint96 public override underlyingUnitAmt;
    bool public override isPerpSrVault;
    bool public override mintsAboveTarget;
    bool internal _vaultInitialized;

    // A struct begins at a fresh slot, preserving the complete Phase 1 slot 0–4 prefix.
    Phase2Storage private _phase2;

    constructor() {
        _disableInitializers();
    }

    function init(
        string calldata name_,
        string calldata symbol_,
        address underlying_,
        address perpController_,
        bool isPerpSrVault_,
        bool mintsAboveTarget_
    ) external override initializer {
        if (underlying_ == address(0) || perpController_ == address(0)) {
            revert InvalidParamDefn();
        }

        __ERC20_init(name_, symbol_);
        __ERC20Burnable_init();
        __Ownable_init(msg.sender);
        __Pausable_init();
        __ReentrancyGuard_init();

        IUnderlyingPerpVaultController controller = IUnderlyingPerpVaultController(perpController_);
        address selectedPerp = isPerpSrVault_ ? controller.perpSr() : controller.perpJr();
        if (selectedPerp == address(0)) revert InvalidParamDefn();

        uint8 underlyingDecimals = IERC20Metadata(underlying_).decimals();
        if (underlyingDecimals > 28) revert InvalidParamDefn();

        underlying = underlying_;
        perp = selectedPerp;
        perpController = perpController_;
        keeper = msg.sender;
        underlyingUnitAmt = uint96(10 ** underlyingDecimals);
        isPerpSrVault = isPerpSrVault_;
        mintsAboveTarget = mintsAboveTarget_;

        _phase2.targetDR = uint96(ONE);
        _phase2.eqDRLower = uint96(ONE);
        _phase2.eqDRUpper = uint96(ONE);
        _phase2.rebalanceFreqSec = 86_400;
        _phase2.maxFlashFeePerc = 1e16;
    }

    /// @notice Establishes the target-observed initial share price and locks the minimum notes in the vault itself.
    function initDeposit(uint256 underlyingAmt) external override onlyOwner nonReentrant returns (uint256 notesMinted) {
        if (_vaultInitialized) revert VaultInitialized();
        _requireNotPaused();

        notesMinted = Math.mulDiv(underlyingAmt, ONE, underlyingUnitAmt);
        if (notesMinted <= MINIMUM_LIQUIDITY) return 0;

        IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmt);
        _mint(address(this), MINIMUM_LIQUIDITY);
        _mint(msg.sender, notesMinted - MINIMUM_LIQUIDITY);

        emit Deposit(0, 0, MINIMUM_LIQUIDITY);
        emit Deposit(underlyingAmt, 0, notesMinted - MINIMUM_LIQUIDITY);
        _vaultInitialized = true;
    }

    function underlyingBalance() public view override returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function perpBalance() public view override returns (uint256) {
        return IERC20(perp).balanceOf(address(this));
    }

    function getTVL() public view override returns (uint256) {
        uint256 perpBal = perpBalance();
        if (perpBal == 0) return underlyingBalance();

        IUnderlyingPerpVaultController.SystemState memory state =
            IUnderlyingPerpVaultController(perpController).systemReserveState();
        IUnderlyingPerpVaultController.PerpState memory selected = isPerpSrVault ? state.perpSr : state.perpJr;
        return underlyingBalance() + Math.mulDiv(perpBal, selected.reserveValue, selected.totalSupply);
    }

    function computeMintAmt(uint256 underlyingMax, uint256 perpMax)
        public
        view
        override
        returns (uint256 notesMinted, uint256 underlyingAmtIn, uint256 perpAmtIn)
    {
        uint256 notesSupply = totalSupply();
        if (notesSupply == 0) return (0, 0, 0);

        uint256 underlyingBal = underlyingBalance();
        uint256 perpBal = perpBalance();
        if (underlyingBal == 0) {
            if (perpBal == 0) return (0, 0, 0);
            perpAmtIn = perpMax;
            notesMinted = Math.mulDiv(perpAmtIn, notesSupply, perpBal);
            return (notesMinted, 0, perpAmtIn);
        }
        if (perpBal == 0) {
            underlyingAmtIn = underlyingMax;
            notesMinted = Math.mulDiv(underlyingAmtIn, notesSupply, underlyingBal);
            return (notesMinted, underlyingAmtIn, 0);
        }

        uint256 underlyingFromPerp = Math.mulDiv(perpMax, underlyingBal, perpBal);
        if (underlyingFromPerp < underlyingMax) {
            underlyingAmtIn = underlyingFromPerp;
            perpAmtIn = perpMax;
        } else {
            underlyingAmtIn = underlyingMax;
            perpAmtIn = Math.mulDiv(underlyingMax, perpBal, underlyingBal);
        }
        notesMinted = Math.mulDiv(underlyingAmtIn, notesSupply, underlyingBal);
    }

    function deposit(uint256 underlyingMax, uint256 perpMax)
        external
        override
        nonReentrant
        returns (uint256 notesMinted)
    {
        if (!_vaultInitialized) revert VaultNotInitialized();
        _requireNotPaused();

        uint256 underlyingAmtIn;
        uint256 perpAmtIn;
        (notesMinted, underlyingAmtIn, perpAmtIn) = computeMintAmt(underlyingMax, perpMax);
        if (notesMinted == 0) return 0;

        if (underlyingAmtIn != 0) IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingAmtIn);
        if (perpAmtIn != 0) IERC20(perp).safeTransferFrom(msg.sender, address(this), perpAmtIn);
        _mint(msg.sender, notesMinted);

        emit Deposit(underlyingAmtIn, perpAmtIn, notesMinted);
    }

    function computeRedemptionAmts(uint256 notesAmt)
        public
        view
        override
        returns (uint256 underlyingAmtOut, uint256 perpAmtOut)
    {
        uint256 notesSupply = totalSupply();
        if (notesSupply == 0 || notesAmt == 0) return (0, 0);
        underlyingAmtOut = Math.mulDiv(notesAmt, underlyingBalance(), notesSupply);
        perpAmtOut = Math.mulDiv(notesAmt, perpBalance(), notesSupply);
    }

    function redeem(uint256 notesAmt)
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 underlyingAmtOut, uint256 perpAmtOut)
    {
        if (notesAmt == 0) return (0, 0);
        (underlyingAmtOut, perpAmtOut) = computeRedemptionAmts(notesAmt);
        _burn(msg.sender, notesAmt);

        if (underlyingAmtOut != 0) IERC20(underlying).safeTransfer(msg.sender, underlyingAmtOut);
        if (perpAmtOut != 0) IERC20(perp).safeTransfer(msg.sender, perpAmtOut);
        emit Redeem(notesAmt, underlyingAmtOut, perpAmtOut);
    }

    function eqDRRange() external view override returns (uint96 lower, uint96 upper) {
        return (_phase2.eqDRLower, _phase2.eqDRUpper);
    }

    function targetDR() external view override returns (uint96) {
        return _phase2.targetDR;
    }

    function rebalanceFreqSec() external view override returns (uint32) {
        return _phase2.rebalanceFreqSec;
    }

    function rebalanceOffsetSec() external view override returns (uint32) {
        return _phase2.rebalanceOffsetSec;
    }

    function lastRebalanceTimestampSec() external view override returns (uint64) {
        return _phase2.lastRebalanceTimestampSec;
    }

    function minRebalanceVal() external view override returns (uint128) {
        return _phase2.minRebalanceVal;
    }

    function maxFlashFeePerc() external view override returns (uint64) {
        return _phase2.maxFlashFeePerc;
    }

    function computeRebalanceAmount() public view override returns (uint256 underlyingAmt, bool isMintingPerp) {
        (underlyingAmt, isMintingPerp,,) = _rebalanceCapacity();
    }

    function rebalance() external override whenNotPaused nonReentrant {
        uint64 previous = _phase2.lastRebalanceTimestampSec;
        if (previous != 0 && block.timestamp < uint256(previous) + _phase2.rebalanceFreqSec) {
            revert LastRebalanceTooRecent();
        }

        (
            uint256 underlyingAmt,
            bool isMintingPerp,
            uint256 drBefore,
            IUnderlyingPerpVaultController.SystemState memory state
        ) = _rebalanceCapacity();
        if (underlyingAmt == 0) revert NoOp();
        if (underlyingAmt < _phase2.minRebalanceVal) revert OpUnavailable("no capacity");

        IUnderlyingPerpVaultController controller = IUnderlyingPerpVaultController(perpController);
        IUnderlyingPerpVaultController.FeePerc memory selectedFee;
        if (isMintingPerp) {
            IERC20(underlying).forceApprove(perpController, underlyingAmt);
            if (isPerpSrVault) {
                (,, selectedFee,) = controller.flashMint2(underlyingAmt, 0, 0, 0);
            } else {
                (,,, selectedFee) = controller.flashMint2(0, underlyingAmt, 0, 0);
            }
        } else {
            IUnderlyingPerpVaultController.PerpState memory selected = isPerpSrVault ? state.perpSr : state.perpJr;
            uint256 perpIn = Math.mulDiv(underlyingAmt, selected.totalSupply, selected.reserveValue);
            if (isPerpSrVault) {
                (, selectedFee,) = controller.flashRedeem2(perpIn, 0, 0);
            } else {
                (,, selectedFee) = controller.flashRedeem2(0, perpIn, 0);
            }
        }

        if (selectedFee.totalFeePerc > _phase2.maxFlashFeePerc) revert SlippageTooHigh();
        _phase2.lastRebalanceTimestampSec = uint64(
            ((block.timestamp - _phase2.rebalanceOffsetSec) / _phase2.rebalanceFreqSec) * _phase2.rebalanceFreqSec
                + _phase2.rebalanceOffsetSec
        );
        emit Rebalance(drBefore, underlyingAmt, isMintingPerp);
    }

    function updateTargetDR(uint96 targetDR_, IUnderlyingPerpVault.DRRange calldata eqDRRange_)
        external
        override
        onlyOwner
    {
        if (targetDR_ == 0) revert InvalidParamDefn();
        if (eqDRRange_.lower > targetDR_ || targetDR_ > eqDRRange_.upper) revert InvalidRange();
        _phase2.targetDR = targetDR_;
        _phase2.eqDRLower = eqDRRange_.lower;
        _phase2.eqDRUpper = eqDRRange_.upper;
    }

    function updateRebalanceTimingParams(uint32 freqSec_, uint32 offsetSec_) external override onlyOwner {
        if (freqSec_ == 0 || offsetSec_ >= freqSec_) revert InvalidParamDefn();
        _phase2.rebalanceFreqSec = freqSec_;
        _phase2.rebalanceOffsetSec = offsetSec_;
    }

    function updateMinRebalanceAmt(uint128 minRebalanceVal_) external override onlyOwner {
        _phase2.minRebalanceVal = minRebalanceVal_;
    }

    function updateMaxFlashFeePerc(uint64 maxFlashFeePerc_) external override onlyOwner {
        if (maxFlashFeePerc_ > ONE) revert InvalidPerc();
        _phase2.maxFlashFeePerc = maxFlashFeePerc_;
    }

    function _rebalanceCapacity()
        private
        view
        returns (
            uint256 underlyingAmt,
            bool isMintingPerp,
            uint256 currentDR,
            IUnderlyingPerpVaultController.SystemState memory state
        )
    {
        IUnderlyingPerpVaultController controller = IUnderlyingPerpVaultController(perpController);
        (currentDR,) = controller.systemDeviations();
        isMintingPerp = mintsAboveTarget ? currentDR > _phase2.targetDR : currentDR < _phase2.targetDR;
        state = controller.systemReserveState();

        if (currentDR >= _phase2.eqDRLower && currentDR <= _phase2.eqDRUpper) {
            return (0, isMintingPerp, currentDR, state);
        }

        uint256 ratio = controller.targetSystemRatio();
        if (ratio == 0 || _phase2.targetDR == 0) return (0, isMintingPerp, currentDR, state);
        uint256 ratioTimesTarget = ratio * uint256(_phase2.targetDR);
        IUnderlyingPerpVaultController.PerpState memory selected = isPerpSrVault ? state.perpSr : state.perpJr;
        uint256 targetReserve;
        uint256 systemCapacity;

        if (isPerpSrVault) {
            if (isMintingPerp) {
                targetReserve = Math.mulDiv(state.perpJr.reserveValue, ONE * ONE, ratioTimesTarget);
                systemCapacity =
                    targetReserve > state.perpSr.reserveValue ? targetReserve - state.perpSr.reserveValue : 0;
            } else {
                targetReserve = Math.mulDiv(state.perpJr.reserveValue, ONE * ONE, ratioTimesTarget, Math.Rounding.Ceil);
                systemCapacity =
                    state.perpSr.reserveValue > targetReserve ? state.perpSr.reserveValue - targetReserve : 0;
            }
        } else if (isMintingPerp) {
            targetReserve = Math.mulDiv(state.perpSr.reserveValue, ratioTimesTarget, ONE * ONE);
            systemCapacity = targetReserve > state.perpJr.reserveValue ? targetReserve - state.perpJr.reserveValue : 0;
        } else {
            targetReserve = Math.mulDiv(state.perpSr.reserveValue, ratioTimesTarget, ONE * ONE, Math.Rounding.Ceil);
            systemCapacity = state.perpJr.reserveValue > targetReserve ? state.perpJr.reserveValue - targetReserve : 0;
        }

        uint256 assetCapacity;
        if (isMintingPerp) {
            assetCapacity = underlyingBalance();
        } else if (selected.totalSupply != 0) {
            assetCapacity = Math.mulDiv(perpBalance(), selected.reserveValue, selected.totalSupply);
        }
        underlyingAmt = Math.min(systemCapacity, assetCapacity);
    }

    function updateKeeper(address keeper_) external override onlyOwner {
        keeper = keeper_;
    }

    function pause() external override {
        if (msg.sender != keeper) revert UnauthorizedCall();
        _pause();
    }

    function unpause() external override {
        if (msg.sender != keeper) revert UnauthorizedCall();
        _unpause();
    }
}
