// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";
import {IPerpToken} from "../interfaces/IPerpToken.sol";
import {ITranche} from "../interfaces/ITranche.sol";
import {PerpBalancer} from "../policy/PerpBalancer.sol";

contract PerpToken is ERC20, Ownable2Step {
    using SafeERC20 for IERC20;

    error UnauthorizedCall();
    error ReserveOverflow();

    event ReserveSynced(address token, uint256 balance);

    uint256 private constant MAX_TRANCHES = 50;

    address public immutable underlying;
    address public immutable bondsManager;
    address public controller;
    bool public immutable isJunior;

    address[] private _trancheTokens;
    mapping(address => bool) private _registered;

    modifier onlyController() {
        if (msg.sender != controller) revert UnauthorizedCall();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        address underlying_,
        address bondsManager_,
        address controller_,
        bool isJunior_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        underlying = underlying_;
        bondsManager = bondsManager_;
        controller = controller_;
        isJunior = isJunior_;
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    function updateController(address controller_) external onlyOwner {
        controller = controller_;
    }

    function maxTrancheCount() external pure returns (uint256) {
        return MAX_TRANCHES;
    }

    function trancheTokens() external view returns (address[] memory) {
        return _trancheTokens;
    }

    function registerTranche(address tranche) external onlyController {
        if (_registered[tranche]) return;
        if (_trancheTokens.length >= MAX_TRANCHES) revert ReserveOverflow();
        _registered[tranche] = true;
        _trancheTokens.push(tranche);
    }

    function mintTo(address to, uint256 amount) external onlyController {
        _mint(to, amount);
    }

    function burnFrom(address from, uint256 amount) external onlyController {
        _burn(from, amount);
    }

    function transferReservesTo(address to, PerpBalancer.ReserveAmounts calldata amounts) external onlyController {
        if (amounts.underlyingAmt != 0) {
            IERC20(underlying).safeTransfer(to, amounts.underlyingAmt);
            emit ReserveSynced(underlying, IERC20(underlying).balanceOf(address(this)));
        }
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            PerpBalancer.TokenAmount calldata item = amounts.trancheAmts[i];
            if (item.amount == 0) continue;
            IERC20(item.token).safeTransfer(to, item.amount);
            emit ReserveSynced(item.token, IERC20(item.token).balanceOf(address(this)));
        }
    }

    function handleTransferReservesIn(PerpBalancer.ReserveAmounts calldata amounts) external onlyController {
        if (amounts.underlyingAmt != 0) {
            emit ReserveSynced(underlying, IERC20(underlying).balanceOf(address(this)));
        }
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            PerpBalancer.TokenAmount calldata item = amounts.trancheAmts[i];
            if (item.amount != 0) emit ReserveSynced(item.token, IERC20(item.token).balanceOf(address(this)));
        }
    }

    function logBalance(address token) external onlyController {
        emit ReserveSynced(token, IERC20(token).balanceOf(address(this)));
    }

    function reserveData() external view returns (PerpBalancer.ReserveData memory) {
        return _reserveData();
    }

    function reserves() external view returns (IPerpToken.ReserveTokens memory result) {
        result.underlyingBal = IERC20(underlying).balanceOf(address(this));
        result.trancheTokens = new PerpBalancer.TokenAmount[](_trancheTokens.length);
        for (uint256 i; i < _trancheTokens.length; ++i) {
            address token = _trancheTokens[i];
            result.trancheTokens[i] =
                PerpBalancer.TokenAmount(token, IERC20(token).balanceOf(address(this)));
        }
    }

    fallback() external {
        if (!isJunior) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        bytes4 selector = msg.sig;
        if (
            selector != bytes4(keccak256("primeApproval(address)"))
                && selector != bytes4(keccak256("revokeApproval(address)"))
        ) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        if (msg.sender != controller) revert UnauthorizedCall();
        if (msg.data.length != 36) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }
        uint256 rawSpender;
        assembly ("memory-safe") {
            rawSpender := calldataload(4)
        }
        address spender = address(uint160(rawSpender));
        if (selector == bytes4(keccak256("primeApproval(address)"))) {
            IERC20(underlying).forceApprove(spender, type(uint256).max);
        } else {
            IERC20(underlying).forceApprove(spender, 0);
        }
    }

    function _reserveData() private view returns (PerpBalancer.ReserveData memory result) {
        result.underlyingBal = IERC20(underlying).balanceOf(address(this));
        result.trancheData = new PerpBalancer.ReserveTrancheData[](_trancheTokens.length);
        for (uint256 i; i < _trancheTokens.length; ++i) {
            address token = _trancheTokens[i];
            IBondsManager.TrancheData memory data = ITranche(token).data();
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 value = Math.mulDiv(balance, data.trancheClaim, data.trancheSupply);
            result.trancheData[i] = PerpBalancer.ReserveTrancheData({data: data, balance: balance, value: value});
        }
    }
}
