// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PerpController} from "../controller/PerpController.sol";
import {IPerpToken} from "../interfaces/IPerpToken.sol";

/// @notice One-use deployment helper for the clean-room protocol.
/// @dev The Controller must be paused and must temporarily name this contract as keeper. The
/// deployer retains Controller ownership, so it can restore the final keeper after this call.
contract GenesisSeeder {
    using SafeERC20 for IERC20;

    error AlreadyBootstrapped();
    error InsufficientSeed();
    error InvalidParamDefn();
    error NonEmptyReserve();
    error UnexpectedKeeper();
    error UserOpsNotPaused();
    error UnauthorizedCall();

    address public constant LOCKED_LIQUIDITY = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MIN_LOCKED_SHARES = 1e8;
    uint256 public constant MIN_INITIAL_SHARES = 1_000e8;

    address public immutable deployer;
    bool public used;

    event GenesisSeeded(
        address indexed controller,
        address indexed receiver,
        uint256 srShares,
        uint256 jrShares,
        uint256 lockedSharesPerSide,
        uint256 jrUnderlyingTopUp
    );

    constructor(address deployer_) {
        if (deployer_ == address(0)) revert InvalidParamDefn();
        deployer = deployer_;
    }

    function bootstrap(
        PerpController controller,
        address srTranche,
        uint256 srAmount,
        address jrTranche,
        uint256 jrAmount,
        uint256 maxJrUnderlyingTopUp,
        address receiver
    ) external returns (uint256 srShares, uint256 jrShares) {
        if (msg.sender != deployer) revert UnauthorizedCall();
        if (used) revert AlreadyBootstrapped();
        if (
            address(controller) == address(0) || srTranche == address(0) || jrTranche == address(0)
                || receiver == address(0)
        ) {
            revert InvalidParamDefn();
        }
        if (!controller.userOpsPaused()) revert UserOpsNotPaused();
        if (controller.keeper() != address(this)) revert UnexpectedKeeper();

        address perpSr = controller.perpSr();
        address perpJr = controller.perpJr();
        if (IPerpToken(perpSr).totalSupply() != 0 || IPerpToken(perpJr).totalSupply() != 0) {
            revert AlreadyBootstrapped();
        }
        _requireEmptyReserve(perpSr, srTranche);
        _requireEmptyReserve(perpJr, jrTranche);
        if (srAmount < MIN_INITIAL_SHARES || jrAmount < MIN_INITIAL_SHARES) revert InsufficientSeed();
        if (
            IERC20(srTranche).balanceOf(address(this)) < srAmount
                || IERC20(jrTranche).balanceOf(address(this)) < jrAmount
        ) revert InsufficientSeed();

        used = true;
        IERC20(srTranche).forceApprove(address(controller), srAmount);
        IERC20(jrTranche).forceApprove(address(controller), jrAmount);

        controller.pauseUserOps(false);
        (srShares, jrShares,,) = controller.mint2(
            PerpController.TokenAmount(srTranche, srAmount),
            PerpController.TokenAmount(jrTranche, jrAmount),
            MIN_LOCKED_SHARES + 1,
            MIN_LOCKED_SHARES + 1
        );

        (PerpController.SystemState memory state,,) = controller.systemReserveState();
        uint256 targetJrVm = controller.targetPerpJrVM();
        uint256 jrUnderlyingTopUp = computeJrUnderlyingTopUp(state.perpJr.reserveValue, state.perpJr.vm, targetJrVm);
        address underlying = controller.underlying();
        if (jrUnderlyingTopUp != 0) {
            if (
                jrUnderlyingTopUp > maxJrUnderlyingTopUp
                    || IERC20(underlying).balanceOf(address(this)) < jrUnderlyingTopUp
            ) revert InsufficientSeed();
            IERC20(underlying).forceApprove(address(controller), jrUnderlyingTopUp);
            (, uint256 jrTopUpShares,,) = controller.flashMint2(0, jrUnderlyingTopUp, 0, 1);
            jrShares += jrTopUpShares;
        }
        uint256 refund = IERC20(underlying).balanceOf(address(this));
        if (refund != 0) IERC20(underlying).safeTransfer(deployer, refund);
        controller.pauseUserOps(true);

        if (srShares <= MIN_LOCKED_SHARES || jrShares <= MIN_LOCKED_SHARES) revert InsufficientSeed();
        IERC20(perpSr).safeTransfer(LOCKED_LIQUIDITY, MIN_LOCKED_SHARES);
        IERC20(perpJr).safeTransfer(LOCKED_LIQUIDITY, MIN_LOCKED_SHARES);
        IERC20(perpSr).safeTransfer(receiver, srShares - MIN_LOCKED_SHARES);
        IERC20(perpJr).safeTransfer(receiver, jrShares - MIN_LOCKED_SHARES);

        emit GenesisSeeded(address(controller), receiver, srShares, jrShares, MIN_LOCKED_SHARES, jrUnderlyingTopUp);
    }

    /// @notice Returns the smallest idle-underlying top-up that reduces JR VM to the target.
    /// @dev If dilution is needed, a target at or below the underlying VM (1e18) is unreachable.
    function computeJrUnderlyingTopUp(uint256 reserveValue, uint256 jrVm, uint256 targetJrVm)
        public
        pure
        returns (uint256)
    {
        if (jrVm <= targetJrVm) return 0;
        if (targetJrVm <= 1e18) revert InvalidParamDefn();
        return Math.mulDiv(reserveValue, jrVm - targetJrVm, targetJrVm - 1e18, Math.Rounding.Ceil);
    }

    function _requireEmptyReserve(address perp, address genesisTranche) private view {
        IPerpToken.ReserveTokens memory reserve = IPerpToken(perp).reserves();
        if (reserve.underlyingBal != 0 || IERC20(genesisTranche).balanceOf(perp) != 0) revert NonEmptyReserve();
        for (uint256 i; i < reserve.trancheTokens.length; ++i) {
            if (reserve.trancheTokens[i].amount != 0) revert NonEmptyReserve();
        }
    }
}
