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

    function underlyingOracle() external view returns (address);
}

/// @notice Clean-room implementation of the evidence-backed USD Vault mint/deposit and exit paths.
/// @dev Session, capacity, rebalance and the target initializer remain outside this phase.
contract UsdVault is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IUsdVault {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();

    uint256 private constant WAD = 1e18;
    uint256 private constant USD_UNIT = 1e6;
    uint256 private constant UNDERLYING_UNIT = 1e8;

    IERC20 private _usdToken;
    IERC20 private _perpSrToken;
    IERC20 private _underlyingToken;
    address private _perpController;

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
}
