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

    error InvalidParamDefn();
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
    }

    /// @notice Establishes the target-observed initial share price and locks the minimum notes in the vault itself.
    function initDeposit(uint256 underlyingAmt)
        external
        override
        onlyOwner
        whenNotPaused
        nonReentrant
        returns (uint256 notesMinted)
    {
        if (_vaultInitialized) revert VaultInitialized();

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
        whenNotPaused
        nonReentrant
        returns (uint256 notesMinted)
    {
        if (!_vaultInitialized) revert VaultNotInitialized();

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

    function updateKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
    }

    function pause() external {
        if (msg.sender != keeper) revert UnauthorizedCall();
        _pause();
    }

    function unpause() external {
        if (msg.sender != keeper) revert UnauthorizedCall();
        _unpause();
    }
}
