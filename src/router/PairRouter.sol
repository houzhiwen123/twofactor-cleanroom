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
}

interface IPairUnderlyingVault is IERC20 {
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted);
}

interface IPairController {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFee, FeePerc memory jrFee);

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

/// @notice Two-sided clean-room entry point for the USD/SR and underlying/JR vault pair.
/// @dev The proven target path is intentionally limited to deposit. Redeem, zero-genesis and
///      unsupported-pair behavior remain separate evidence work. The fallback accepts the locked
///      target selector `0x0176cb45` because its public selector database has no signature entry.
contract PairRouter is IPairRouter {
    using SafeERC20 for IERC20;

    bytes4 private constant TARGET_DEPOSIT_SELECTOR = 0x0176cb45;
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

    fallback() external {
        if (msg.sig != TARGET_DEPOSIT_SELECTOR) revert InvalidSelector();
        DepositParams memory params = abi.decode(msg.data[4:], (DepositParams));
        (
            uint256 usdNotes,
            uint256 underlyingNotes,
            uint256 underlyingRefund,
            uint256 usdRefund,
            uint256 srRefund,
            uint256 jrRefund
        ) = _deposit(params);
        bytes memory result = abi.encode(usdNotes, underlyingNotes, underlyingRefund, usdRefund, srRefund, jrRefund);
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
        if (params.usdVault == address(0) || params.underlyingVault == address(0) || params.strategy == address(0)) {
            revert InvalidInput();
        }
        if (params.underlyingToTrade + params.srUnderlyingIn + params.jrUnderlyingIn > params.underlyingIn) {
            revert InvalidInput();
        }

        address recipient = params.recipient == address(0) ? msg.sender : params.recipient;
        IPairUsdVault usdVault = IPairUsdVault(params.usdVault);
        IPairUnderlyingVault underlyingVault = IPairUnderlyingVault(params.underlyingVault);
        IDexStrategy strategy = IDexStrategy(params.strategy);
        IERC20 underlyingToken = IERC20(underlyingVault.underlying());
        IERC20 usdToken = IERC20(usdVault.usd());
        IERC20 srToken = IERC20(usdVault.perpSr());
        IERC20 jrToken = IERC20(underlyingVault.perp());
        address controller = usdVault.perpController();

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
