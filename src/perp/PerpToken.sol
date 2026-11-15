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
    error InvalidBondsManager();
    error InvalidTranche();
    error InvalidDepositResult();
    error UnregisteredTranche();

    event ReserveSynced(address token, uint256 balance);

    uint256 private constant MAX_TRANCHES = 50;

    address public immutable underlying;
    address public immutable bondsManager;
    address public controller;
    bool public immutable isJunior;

    address[] private _trancheTokens;
    mapping(address => uint256) private _trancheIndexPlusOne;

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
        _registerTranche(tranche);
    }

    function _registerTranche(address tranche) private {
        _assertCanonicalTranche(tranche);
        if (_trancheIndexPlusOne[tranche] != 0) return;
        if (_trancheTokens.length >= MAX_TRANCHES) revert ReserveOverflow();
        _trancheTokens.push(tranche);
        _trancheIndexPlusOne[tranche] = _trancheTokens.length;
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
            // Target traces include canonical zero-value transfers. They cannot move reserves, so
            // preserve them while requiring registration for every positive outflow.
            if (item.amount != 0 && _trancheIndexPlusOne[item.token] == 0) revert UnregisteredTranche();
            _assertCanonicalTranche(item.token);
            IERC20(item.token).safeTransfer(to, item.amount);
            uint256 balance = IERC20(item.token).balanceOf(address(this));
            emit ReserveSynced(item.token, balance);
            if (balance == 0) _removeTranche(item.token);
        }
    }

    function handleTransferReservesIn(PerpBalancer.ReserveAmounts calldata amounts) external onlyController {
        if (amounts.underlyingAmt != 0) {
            emit ReserveSynced(underlying, IERC20(underlying).balanceOf(address(this)));
        }
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            PerpBalancer.TokenAmount calldata item = amounts.trancheAmts[i];
            _registerTranche(item.token);
            _recoverTranche(item.token);
        }
    }

    function recover() external onlyController returns (bool recovered) {
        address[] memory tokens = _trancheTokens;
        for (uint256 i; i < tokens.length; ++i) {
            if (_recoverTranche(tokens[i])) recovered = true;
        }
    }

    function logBalance(address token) external onlyController {
        emit ReserveSynced(token, IERC20(token).balanceOf(address(this)));
    }

    function bondDepositsForRollover(address manager, IPerpToken.BondDeposit[] calldata deposits)
        external
        onlyController
    {
        if (!isJunior) {
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        // Empty calls are target-observed no-ops apart from the final balance sync. A manager is
        // only trusted once an asset-moving deposit is requested.
        if (deposits.length != 0 && manager != bondsManager) revert InvalidBondsManager();

        for (uint256 i; i < deposits.length; ++i) {
            IPerpToken.BondDeposit calldata item = deposits[i];
            (address expectedSenior, address expectedJunior) = IBondsManager(bondsManager).tranches(item.bondID);
            _assertCanonicalPair(item.bondID, expectedSenior, expectedJunior);
            _assertCanonicalTranche(expectedSenior);
            _assertCanonicalTranche(expectedJunior);

            uint256 underlyingBefore = IERC20(underlying).balanceOf(address(this));
            uint256 seniorBefore = IERC20(expectedSenior).balanceOf(address(this));
            uint256 juniorBefore = IERC20(expectedJunior).balanceOf(address(this));
            (IBondsManager.TokenAmount memory srTranche, IBondsManager.TokenAmount memory jrTranche) =
                IBondsManager(manager).deposit(item.bondID, item.underlyingAmt);

            uint256 underlyingAfter = IERC20(underlying).balanceOf(address(this));
            uint256 seniorAfter = IERC20(expectedSenior).balanceOf(address(this));
            uint256 juniorAfter = IERC20(expectedJunior).balanceOf(address(this));
            if (
                srTranche.token != expectedSenior || jrTranche.token != expectedJunior || seniorAfter < seniorBefore
                    || juniorAfter < juniorBefore || underlyingAfter > underlyingBefore
                    || seniorAfter - seniorBefore != srTranche.amount || juniorAfter - juniorBefore != jrTranche.amount
                    || underlyingBefore - underlyingAfter != item.underlyingAmt
            ) revert InvalidDepositResult();

            if (srTranche.amount != 0) _registerTranche(srTranche.token);
            if (jrTranche.amount != 0) _registerTranche(jrTranche.token);

            emit ReserveSynced(srTranche.token, IERC20(srTranche.token).balanceOf(address(this)));
            emit ReserveSynced(jrTranche.token, IERC20(jrTranche.token).balanceOf(address(this)));
        }

        emit ReserveSynced(underlying, IERC20(underlying).balanceOf(address(this)));
    }

    function reserveData() external view returns (PerpBalancer.ReserveData memory) {
        return _reserveData();
    }

    function reserves() external view returns (IPerpToken.ReserveTokens memory result) {
        result.underlyingBal = IERC20(underlying).balanceOf(address(this));
        result.trancheTokens = new PerpBalancer.TokenAmount[](_trancheTokens.length);
        for (uint256 i; i < _trancheTokens.length; ++i) {
            address token = _trancheTokens[i];
            result.trancheTokens[i] = PerpBalancer.TokenAmount(token, IERC20(token).balanceOf(address(this)));
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
            uint256 value = data.trancheSupply == 0 ? 0 : Math.mulDiv(balance, data.trancheClaim, data.trancheSupply);
            result.trancheData[i] = PerpBalancer.ReserveTrancheData({data: data, balance: balance, value: value});
        }
    }

    function _recoverTranche(address tranche) private returns (bool recovered) {
        (bytes32 bondID, address senior, address junior) = _assertCanonicalTranche(tranche);
        uint256 seniorBalance = IERC20(senior).balanceOf(address(this));
        uint256 juniorBalance = IERC20(junior).balanceOf(address(this));
        (uint256 underlyingReturned,,) = IBondsManager(bondsManager).redeem(bondID, seniorBalance, juniorBalance);

        seniorBalance = IERC20(senior).balanceOf(address(this));
        juniorBalance = IERC20(junior).balanceOf(address(this));
        emit ReserveSynced(senior, seniorBalance);
        emit ReserveSynced(junior, juniorBalance);
        if (underlyingReturned != 0) {
            emit ReserveSynced(underlying, IERC20(underlying).balanceOf(address(this)));
            recovered = true;
        }
        if (seniorBalance == 0) _removeTranche(senior);
        if (juniorBalance == 0) _removeTranche(junior);
    }

    /// @dev Clean-room safety boundary. These checks are defense-in-depth and are not claimed as
    /// target-observed reverts. They prevent an invalid planner output from turning a reserve token
    /// into an arbitrary external manager call.
    function _assertCanonicalTranche(address tranche)
        private
        view
        returns (bytes32 bondID, address senior, address junior)
    {
        if (tranche.code.length == 0 || ITranche(tranche).manager() != bondsManager) revert InvalidTranche();
        bondID = ITranche(tranche).bondID();
        (senior, junior) = IBondsManager(bondsManager).tranches(bondID);
        _assertCanonicalPair(bondID, senior, junior);

        bool seniorSide;
        if (tranche == senior) seniorSide = true;
        else if (tranche != junior) revert InvalidTranche();
        if (ITranche(tranche).isSenior() != seniorSide) revert InvalidTranche();

        IBondsManager.TrancheData memory data = ITranche(tranche).data();
        address counterpart = seniorSide ? junior : senior;
        if (
            data.manager != bondsManager || data.bondID != bondID || data.tranche != tranche
                || data.counterpart != counterpart || data.isSenior != seniorSide
        ) revert InvalidTranche();
    }

    function _assertCanonicalPair(bytes32 bondID, address senior, address junior) private view {
        if (bondID == bytes32(0) || senior == address(0) || junior == address(0) || senior == junior) {
            revert InvalidTranche();
        }
        if (senior.code.length == 0 || junior.code.length == 0) revert InvalidTranche();
    }

    function _removeTranche(address tranche) private {
        uint256 indexPlusOne = _trancheIndexPlusOne[tranche];
        if (indexPlusOne == 0) return;

        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _trancheTokens.length - 1;
        if (index != lastIndex) {
            address last = _trancheTokens[lastIndex];
            _trancheTokens[index] = last;
            _trancheIndexPlusOne[last] = indexPlusOne;
        }
        _trancheTokens.pop();
        delete _trancheIndexPlusOne[tranche];
    }
}
