// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IDexStrategy} from "../interfaces/IDexStrategy.sol";
import {IPairRouter} from "../interfaces/IPairRouter.sol";

interface IPairUsdVault is IERC20 {
    function usd() external view returns (address);
    function underlying() external view returns (address);
    function perpSr() external view returns (address);
    function perpController() external view returns (address);
    function deposit(uint256 usdMax, uint256 perpSrMax) external returns (uint256 notesMinted);
    function redeem(uint256 notes) external returns (uint256 usdOut, uint256 perpSrOut);
    function upkeep() external;
}

interface IPairUnderlyingVault is IERC20 {
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function isPerpSrVault() external view returns (bool);
    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted);
    function redeem(uint256 notes) external returns (uint256 underlyingOut, uint256 perpOut);
}

interface IPairController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee);

    function flashRedeem2(uint256 srIn, uint256 jrIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingOut, FeePerc memory srFee, FeePerc memory jrFee);

    function underlying() external view returns (address);
    function perpSr() external view returns (address);
    function perpJr() external view returns (address);
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

/// @notice Two-sided clean-room entry point for the USD/SR and underlying/JR vault pair.
/// @dev Deposit and redeem preserve the locked target selectors through the compatibility
///      fallback. Redeem partial fills settle from actual Router balances. Pair dependencies
///      are validated against the shared Controller before assets move; the typed entry points
///      are clean-room convenience APIs.
contract PairRouter is IPairRouter {
    using SafeERC20 for IERC20;

    bytes4 private constant TARGET_DEPOSIT_SELECTOR = 0x0176cb45;
    bytes4 private constant TARGET_REDEEM_SELECTOR = 0xb2a72016;
    bytes4 private constant UNHEALTHY_SELECTOR = 0xc9f488c6;

    function deposit(DepositParams calldata params)
        external
        returns (
            uint256 usdNotes,
            uint256 underlyingNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        )
    {
        return _deposit(params);
    }

    function redeem(RedeemParams calldata params) external returns (uint256 usdOut, uint256 underlyingOut) {
        return _redeem(params);
    }

    fallback() external {
        bytes memory result;
        if (msg.sig == TARGET_DEPOSIT_SELECTOR) {
            DepositParams memory params = abi.decode(msg.data[4:], (DepositParams));
            (
                uint256 usdNotes,
                uint256 underlyingNotes,
                uint256 underlyingRefund,
                uint256 usdRefund,
                uint256 srRefund,
                uint256 jrRefund
            ) = _deposit(params);
            result = abi.encode(usdNotes, underlyingNotes, underlyingRefund, usdRefund, srRefund, jrRefund);
        } else if (msg.sig == TARGET_REDEEM_SELECTOR) {
            RedeemParams memory params = abi.decode(msg.data[4:], (RedeemParams));
            (uint256 usdOut, uint256 underlyingOut) = _redeem(params);
            result = abi.encode(usdOut, underlyingOut);
        } else {
            revert InvalidSelector();
        }
        assembly ("memory-safe") {
            return(add(result, 0x20), mload(result))
        }
    }

    function _deposit(DepositParams memory params)
        private
        returns (
            uint256 usdNotes,
            uint256 underlyingNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        )
    {
        if (params.underlyingToTrade + params.srUnderlyingIn + params.jrUnderlyingIn > params.underlyingIn) {
            revert InvalidInput();
        }

        address recipient = params.recipient == address(0) ? msg.sender : params.recipient;
        IPairUsdVault usdVault = IPairUsdVault(params.usdVault);
        IPairUnderlyingVault underlyingVault = IPairUnderlyingVault(params.underlyingVault);
        IDexStrategy strategy = IDexStrategy(params.strategy);
        address controller = usdVault.perpController();
        if (controller != underlyingVault.perpController() || underlyingVault.isPerpSrVault()) {
            revert InvalidParamDefn();
        }
        IERC20 jrToken = IERC20(underlyingVault.perp());
        if (address(jrToken) != IPairController(controller).perpJr()) revert InvalidParamDefn();
        IERC20 srToken = IERC20(usdVault.perpSr());
        if (address(srToken) != IPairController(controller).perpSr()) revert InvalidParamDefn();
        IERC20 underlyingToken = IERC20(IPairController(controller).underlying());
        IERC20 usdToken = IERC20(usdVault.usd());

        uint256 underlyingBefore = underlyingToken.balanceOf(address(this));
        uint256 usdBefore = usdToken.balanceOf(address(this));
        uint256 srBefore = srToken.balanceOf(address(this));
        uint256 jrBefore = jrToken.balanceOf(address(this));

        if (params.underlyingIn != 0) underlyingToken.safeTransferFrom(msg.sender, address(this), params.underlyingIn);

        if (params.healthCheck && !strategy.isHealthy()) _revertSelector(UNHEALTHY_SELECTOR);

        uint256 usdOut;
        if (params.underlyingToTrade != 0) {
            _approveIfNeeded(underlyingToken, params.strategy, params.underlyingToTrade);
            usdOut = strategy.trade(address(underlyingToken), address(usdToken), params.underlyingToTrade);
            if (usdOut < params.minUsdFromTrade) revert SlippageTooHigh();
        } else if (params.minUsdFromTrade != 0) {
            revert SlippageTooHigh();
        }

        uint256 srOut;
        uint256 jrOut;
        if (params.srUnderlyingIn != 0 || params.jrUnderlyingIn != 0) {
            uint256 controllerInput = params.srUnderlyingIn + params.jrUnderlyingIn;
            _approveIfNeeded(underlyingToken, controller, controllerInput);
            (srOut, jrOut,,) =
                IPairController(controller).flashMint2(params.srUnderlyingIn, params.jrUnderlyingIn, 0, 0);
        }

        if (usdOut != 0 || srOut != 0) {
            _approveIfNeeded(usdToken, address(usdVault), usdOut);
            _approveIfNeeded(srToken, address(usdVault), srOut);
            usdNotes = usdVault.deposit(usdOut, srOut);
        }
        if (jrOut != 0) {
            _approveIfNeeded(jrToken, address(underlyingVault), jrOut);
            underlyingNotes = underlyingVault.deposit(0, jrOut);
        }

        if (usdNotes < params.minUsdNotes || underlyingNotes < params.minUnderlyingNotes) {
            revert SlippageTooHigh();
        }
        (uint256 subDR, uint256 vmDR) = IPairController(controller).systemDeviations();
        if (subDR < params.minSubDr || subDR > params.maxSubDr || vmDR < params.minVmDr || vmDR > params.maxVmDr) {
            revert PostStateOutOfBounds();
        }

        if (usdNotes != 0) IERC20(address(usdVault)).safeTransfer(recipient, usdNotes);
        if (underlyingNotes != 0) IERC20(address(underlyingVault)).safeTransfer(recipient, underlyingNotes);

        underlyingRefund = _refundDelta(underlyingToken, underlyingBefore, recipient);
        usdRefund = _refundDelta(usdToken, usdBefore, recipient);
        srRefund = _refundDelta(srToken, srBefore, recipient);
        jrRefund = _refundDelta(jrToken, jrBefore, recipient);
    }

    function _redeem(RedeemParams memory params) private returns (uint256 usdOut, uint256 underlyingOut) {
        IPairUsdVault usdVault = IPairUsdVault(params.usdVault);
        IPairUnderlyingVault underlyingVault = IPairUnderlyingVault(params.underlyingVault);
        IDexStrategy strategy = IDexStrategy(params.strategy);
        address controller = usdVault.perpController();
        if (controller != underlyingVault.perpController() || underlyingVault.isPerpSrVault()) {
            revert InvalidParamDefn();
        }
        IERC20 jrToken = IERC20(underlyingVault.perp());
        if (address(jrToken) != IPairController(controller).perpJr()) revert InvalidParamDefn();
        IERC20 srToken = IERC20(usdVault.perpSr());
        if (address(srToken) != IPairController(controller).perpSr()) revert InvalidParamDefn();
        IERC20 underlyingToken = IERC20(IPairController(controller).underlying());
        IERC20 usdToken = IERC20(usdVault.usd());

        if (params.healthCheck && !strategy.isHealthy()) _revertSelector(UNHEALTHY_SELECTOR);
        if (params.runUpkeep) usdVault.upkeep();

        uint256 srOut;
        uint256 jrOut;
        if (params.usdNotes != 0) {
            IERC20(params.usdVault).safeTransferFrom(msg.sender, address(this), params.usdNotes);
            (usdOut, srOut) = usdVault.redeem(params.usdNotes);
        }
        if (params.underlyingNotes != 0) {
            IERC20(params.underlyingVault).safeTransferFrom(msg.sender, address(this), params.underlyingNotes);
            (underlyingOut, jrOut) = underlyingVault.redeem(params.underlyingNotes);
        }

        if (srOut != 0 || jrOut != 0) {
            _approveIfNeeded(srToken, controller, srOut);
            _approveIfNeeded(jrToken, controller, jrOut);
            (uint256 redeemedUnderlying,,) = IPairController(controller).flashRedeem2(srOut, jrOut, 0);
            underlyingOut += redeemedUnderlying;
        }

        if (params.underlyingToTrade != 0) {
            if (params.underlyingToTrade > underlyingOut) revert InvalidParamDefn();
            _approveIfNeeded(underlyingToken, params.strategy, params.underlyingToTrade);
            uint256 tradedUsd = strategy.trade(address(underlyingToken), address(usdToken), params.underlyingToTrade);
            underlyingOut -= params.underlyingToTrade;
            usdOut += tradedUsd;
        } else if (usdOut > params.maxUsdRetained) {
            uint256 usdToTrade = usdOut - params.maxUsdRetained;
            _approveIfNeeded(usdToken, params.strategy, usdToTrade);
            uint256 tradedUnderlying = strategy.trade(address(usdToken), address(underlyingToken), usdToTrade);
            usdOut = params.maxUsdRetained;
            underlyingOut += tradedUnderlying;
        }

        // The target settles the caller from the Router's actual post-trade balances. This is
        // material when a Strategy spends less than the requested amount and returns the unused
        // sell token: requested-amount bookkeeping would strand that refund on the Router.
        usdOut = usdToken.balanceOf(address(this));
        underlyingOut = underlyingToken.balanceOf(address(this));

        if (usdOut < params.minUsdOut || underlyingOut < params.minUnderlyingOut) revert SlippageTooHigh();
        (uint256 subDR, uint256 vmDR) = IPairController(controller).systemDeviations();
        if (subDR < params.minSubDr || subDR > params.maxSubDr || vmDR < params.minVmDr || vmDR > params.maxVmDr) {
            revert SlippageTooHigh();
        }

        if (usdOut != 0) usdToken.safeTransfer(msg.sender, usdOut);
        if (underlyingOut != 0) underlyingToken.safeTransfer(msg.sender, underlyingOut);
    }

    function _approveIfNeeded(IERC20 token, address spender, uint256 amount) private {
        if (amount != 0 && token.allowance(address(this), spender) < amount) {
            token.forceApprove(spender, type(uint256).max);
        }
    }

    function _refundDelta(IERC20 token, uint256 beforeBalance, address recipient) private returns (uint256 amount) {
        uint256 balance = token.balanceOf(address(this));
        if (balance > beforeBalance) {
            amount = balance - beforeBalance;
            token.safeTransfer(recipient, amount);
        }
    }

    function _revertSelector(bytes4 selector) private pure {
        assembly ("memory-safe") {
            mstore(0, selector)
            revert(0, 4)
        }
    }
}
