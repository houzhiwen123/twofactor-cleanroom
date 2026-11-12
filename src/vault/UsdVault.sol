// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUsdVault} from "../interfaces/IUsdVault.sol";

/// @notice Clean-room implementation of the target-confirmed USD Vault exit path.
/// @dev This phase implements redemption only. The initializer is local proxy
///      scaffolding; the target initializer and all note-minting semantics remain
///      unverified and are deliberately not exposed here.
contract UsdVault is Initializable, ERC20Upgradeable, ReentrancyGuardUpgradeable, IUsdVault {
    using SafeERC20 for IERC20;

    error InvalidParamDefn();

    IERC20 private _usdToken;
    IERC20 private _perpSrToken;

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the local proxy-compatible redemption module.
    /// @dev LOCAL-CLEANROOM scaffolding, not a target-confirmed initializer ABI.
    function init(string calldata name_, string calldata symbol_, address usdToken_, address perpSrToken_)
        external
        initializer
    {
        if (usdToken_ == address(0) || perpSrToken_ == address(0)) revert InvalidParamDefn();
        __ERC20_init(name_, symbol_);
        __ReentrancyGuard_init();
        _usdToken = IERC20(usdToken_);
        _perpSrToken = IERC20(perpSrToken_);
    }

    function usdBalance() public view returns (uint256) {
        return _usdToken.balanceOf(address(this));
    }

    function perpSrBalance() public view returns (uint256) {
        return _perpSrToken.balanceOf(address(this));
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
