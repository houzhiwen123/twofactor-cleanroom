// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockUnderlyingPerpVaultRebalanceToken is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function controllerBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}

contract MockUnderlyingPerpVaultRebalanceController {
    using SafeERC20 for IERC20;

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

    address public immutable underlying;
    address public immutable perpSr;
    address public immutable perpJr;

    uint256 public targetSystemRatio = 1e18;
    uint256 public subDR = 1e18;
    uint256 public vmDR = 1e18;
    SystemState private _state;

    uint256 public srMintOut;
    uint256 public jrMintOut;
    uint256 public redeemUnderlyingOut;
    FeePerc public srFee;
    FeePerc public jrFee;

    uint256 public flashMintCalls;
    address public lastMintCaller;
    uint256 public lastSrUnderlyingIn;
    uint256 public lastJrUnderlyingIn;
    uint256 public lastMinSrOut;
    uint256 public lastMinJrOut;

    uint256 public flashRedeemCalls;
    address public lastRedeemCaller;
    uint256 public lastSrPerpIn;
    uint256 public lastJrPerpIn;
    uint256 public lastMinUnderlyingOut;

    bytes private _mintRevertData;
    bytes private _redeemRevertData;
    bool private _mintRevertsAfterTransfer;
    bool private _redeemRevertsAfterTransfer;

    constructor(address underlying_, address perpSr_, address perpJr_) {
        underlying = underlying_;
        perpSr = perpSr_;
        perpJr = perpJr_;
    }

    function setSystemState(PerpState calldata sr, PerpState calldata jr) external {
        _state = SystemState({perpSr: sr, perpJr: jr});
    }

    function setTargetSystemRatio(uint256 ratio) external {
        targetSystemRatio = ratio;
    }

    function setDeviations(uint256 subDR_, uint256 vmDR_) external {
        subDR = subDR_;
        vmDR = vmDR_;
    }

    function setMintResult(uint256 srOut, uint256 jrOut, FeePerc calldata srFee_, FeePerc calldata jrFee_) external {
        srMintOut = srOut;
        jrMintOut = jrOut;
        srFee = srFee_;
        jrFee = jrFee_;
    }

    function setRedeemResult(uint256 underlyingOut, FeePerc calldata srFee_, FeePerc calldata jrFee_) external {
        redeemUnderlyingOut = underlyingOut;
        srFee = srFee_;
        jrFee = jrFee_;
    }

    function setMintRevert(bytes calldata data, bool afterTransfer) external {
        _mintRevertData = data;
        _mintRevertsAfterTransfer = afterTransfer;
    }

    function setRedeemRevert(bytes calldata data, bool afterTransfer) external {
        _redeemRevertData = data;
        _redeemRevertsAfterTransfer = afterTransfer;
    }

    function systemReserveState() external view returns (SystemState memory state) {
        return _state;
    }

    function systemDeviations() external view returns (uint256 subDR_, uint256 vmDR_) {
        return (subDR, vmDR);
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSrOut, uint256 minJrOut)
        external
        returns (uint256 srOut, uint256 jrOut, FeePerc memory srFeeOut, FeePerc memory jrFeeOut)
    {
        flashMintCalls += 1;
        lastMintCaller = msg.sender;
        lastSrUnderlyingIn = srUnderlying;
        lastJrUnderlyingIn = jrUnderlying;
        lastMinSrOut = minSrOut;
        lastMinJrOut = minJrOut;

        if (_mintRevertData.length != 0 && !_mintRevertsAfterTransfer) _revert(_mintRevertData);

        uint256 underlyingIn = srUnderlying + jrUnderlying;
        if (underlyingIn != 0) IERC20(underlying).safeTransferFrom(msg.sender, address(this), underlyingIn);
        if (srMintOut != 0) MockUnderlyingPerpVaultRebalanceToken(perpSr).mint(msg.sender, srMintOut);
        if (jrMintOut != 0) MockUnderlyingPerpVaultRebalanceToken(perpJr).mint(msg.sender, jrMintOut);

        if (_mintRevertData.length != 0) _revert(_mintRevertData);
        return (srMintOut, jrMintOut, srFee, jrFee);
    }

    function flashRedeem2(uint256 srPerpIn, uint256 jrPerpIn, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingOut, FeePerc memory srFeeOut, FeePerc memory jrFeeOut)
    {
        flashRedeemCalls += 1;
        lastRedeemCaller = msg.sender;
        lastSrPerpIn = srPerpIn;
        lastJrPerpIn = jrPerpIn;
        lastMinUnderlyingOut = minUnderlyingOut;

        if (_redeemRevertData.length != 0 && !_redeemRevertsAfterTransfer) _revert(_redeemRevertData);

        if (srPerpIn != 0) MockUnderlyingPerpVaultRebalanceToken(perpSr).controllerBurn(msg.sender, srPerpIn);
        if (jrPerpIn != 0) MockUnderlyingPerpVaultRebalanceToken(perpJr).controllerBurn(msg.sender, jrPerpIn);
        if (redeemUnderlyingOut != 0) IERC20(underlying).safeTransfer(msg.sender, redeemUnderlyingOut);

        if (_redeemRevertData.length != 0) _revert(_redeemRevertData);
        return (redeemUnderlyingOut, srFee, jrFee);
    }

    function _revert(bytes memory data) private pure {
        assembly ("memory-safe") {
            revert(add(data, 0x20), mload(data))
        }
    }
}
