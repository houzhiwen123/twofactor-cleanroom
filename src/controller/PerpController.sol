// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PerpBalancer} from "../policy/PerpBalancer.sol";
import {IPerpToken} from "../interfaces/IPerpToken.sol";

interface IFeePolicyController {
    struct OpSystemChange {
        uint256 subDRPre;
        uint256 subDRPost;
        uint256 vmDRPre;
        uint256 vmDRPost;
    }

    struct OpFeeInput {
        bool isPerpSrOp;
        bool isFlashOp;
        OpSystemChange systemDeviation;
    }

    struct OpFees {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    function computeOpFees(OpFeeInput calldata input) external view returns (OpFees memory);
    function computeRebalanceVal(uint256 srTVL, uint256 jrTVL, uint256 targetSystemRatio)
        external
        view
        returns (uint256, bool);
    function protocolFeeCollector() external view returns (address);
    function perpSrAUMFeePerc() external view returns (uint64);
    function perpJrAUMFeePerc() external view returns (uint64);
}

interface IBondIssuerController {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function issue() external returns (bool issued, BondInfo memory info);
    function latestBondInfo() external view returns (BondInfo memory);
}

contract PerpController is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    error InsufficientLiquidity();
    error InsufficientRollover();
    error InvalidParamDefn();
    error InvalidPerc();
    error LastRebalanceTooRecent();
    error NoOp();
    error OpDisabled();
    error OutOfRebalanceWindow();
    error SlippageExceededLimit();
    error SystemOpsPaused();
    error UnauthorizedCall();
    error UnexpectedAsset();
    error UnexpectedAmount();
    error UserOpsPaused();
    error ValueCapExceeded();
    error ZeroSupply();

    event AumFees(address indexed token, uint256 amount);
    event OpFees(address indexed token, uint256 totalFeeAmt, uint256 protocolFeeAmt);
    event Rebalance(uint256 rebalanceValue, bool isPerpSrPayer);

    uint256 private constant WAD = 1e18;
    uint256 private constant WAD_SQUARED = 1e36;

    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
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

    struct MintQuote {
        SystemState preState;
        SystemState postState;
        uint256 srGrossShares;
        uint256 jrGrossShares;
        uint256 srValue;
        uint256 jrValue;
        FeePerc srFeePerc;
        FeePerc jrFeePerc;
    }

    struct RedeemQuote {
        PerpBalancer.ReserveData srRd;
        PerpBalancer.ReserveData jrRd;
        PerpBalancer.ReserveAmounts srAmounts;
        PerpBalancer.ReserveAmounts jrAmounts;
        uint256 srNet;
        uint256 jrNet;
        uint256 srFeePerp;
        uint256 jrFeePerp;
        FeePerc srFeePerc;
        FeePerc jrFeePerc;
    }

    struct FlashRedeemQuote {
        PerpBalancer.ReserveData srRd;
        PerpBalancer.ReserveData jrRd;
        uint256 srGross;
        uint256 jrGross;
        FeePerc srFeePerc;
        FeePerc jrFeePerc;
    }

    address public underlying;
    address public perpSr;
    address public perpJr;
    address public feePolicy;
    address public balancer;
    address public issuer;
    address public keeper;
    address public underlyingOracle;

    uint256 public targetSystemRatio;
    uint256 public targetPerpJrVM;
    uint256 public valueCap;
    uint256 public minCleanupVal;
    uint256 public perpJrReservedUnderlyingAmt;
    uint64 public perpJrReservedUnderlyingPerc;
    uint32 public minMaturitySec;
    uint32 public rebalanceFreqSec;
    uint32 public rebalanceWindowOffsetSec;
    uint32 public rebalanceWindowLengthSec;
    uint64 public lastRebalanceTimestampSec;
    bool public userOpsPaused;
    bool public systemOpsPaused;

    mapping(address => uint256) public collectedFeeBal;
    mapping(address => uint256) public protocolFeeBals;
    BondInfo private _latestBondInfo;

    constructor() {
        _disableInitializers();
    }

    function init(address underlying_, address perpSr_, address perpJr_) external initializer {
        if (underlying_ == address(0) || perpSr_ == address(0) || perpJr_ == address(0)) {
            revert InvalidParamDefn();
        }
        underlying = underlying_;
        perpSr = perpSr_;
        perpJr = perpJr_;
        keeper = msg.sender;
        targetSystemRatio = 2_847_475_019e9;
        targetPerpJrVM = 1_333_333_333_000_000_000;
        valueCap = 1_000_000_000;
        minCleanupVal = 1_000_000;
        minMaturitySec = 604_800;
        perpJrReservedUnderlyingAmt = 1_000_000;
        perpJrReservedUnderlyingPerc = 1e16;
        rebalanceFreqSec = 86_400;
        rebalanceWindowOffsetSec = 64_800;
        rebalanceWindowLengthSec = 86_400;
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
    }

    function latestBondInfo() external view returns (BondInfo memory) {
        return _latestBondInfo;
    }

    function systemReserveState()
        public
        view
        returns (
            SystemState memory state,
            PerpBalancer.ReserveData memory perpSrRd,
            PerpBalancer.ReserveData memory perpJrRd
        )
    {
        perpSrRd = IPerpToken(perpSr).reserveData();
        perpJrRd = IPerpToken(perpJr).reserveData();
        state.perpSr = _perpState(perpSr, perpSrRd);
        state.perpJr = _perpState(perpJr, perpJrRd);
    }

    function systemDeviations() public view returns (uint256 subDR_, uint256 vmDR_) {
        (SystemState memory state,,) = systemReserveState();
        return _computeDRs(state, targetSystemRatio, targetPerpJrVM);
    }

    function computeDRs(SystemState memory state, uint256 targetSystemRatio_, uint256 targetPerpJrVM_)
        public
        pure
        returns (uint256 subDR_, uint256 vmDR_)
    {
        return _computeDRs(state, targetSystemRatio_, targetPerpJrVM_);
    }

    function reservedPerpJrLiquidity() public view returns (uint256) {
        PerpState memory jr = _perpState(perpJr, IPerpToken(perpJr).reserveData());
        uint256 percentage = Math.mulDiv(jr.reserveValue, perpJrReservedUnderlyingPerc, WAD);
        return percentage > perpJrReservedUnderlyingAmt ? percentage : perpJrReservedUnderlyingAmt;
    }

    function availPerpJrLiquidity() public view returns (uint256) {
        uint256 idle = IERC20(underlying).balanceOf(perpJr);
        uint256 reserved = reservedPerpJrLiquidity();
        return idle > reserved ? idle - reserved : 0;
    }

    function rebalanceWindow(uint256 blockTs) public view returns (uint64 windowStart, uint64 windowEnd) {
        uint256 start =
            ((blockTs - rebalanceWindowOffsetSec) / rebalanceFreqSec) * rebalanceFreqSec + rebalanceWindowOffsetSec;
        windowStart = SafeCast.toUint64(start);
        windowEnd = SafeCast.toUint64(start + rebalanceWindowLengthSec);
    }

    function pauseUserOps(bool paused) external onlyOwner {
        userOpsPaused = paused;
    }

    function pauseSystemOps(bool paused) external onlyOwner {
        systemOpsPaused = paused;
    }

    function updateDRTargets(uint256 targetSystemRatio_, uint256 targetPerpJrVM_) external onlyOwner {
        targetSystemRatio = targetSystemRatio_;
        targetPerpJrVM = targetPerpJrVM_;
    }

    function updateFeePolicy(address feePolicy_) external onlyOwner {
        feePolicy = feePolicy_;
    }

    function updateIssuer(address issuer_) external onlyOwner {
        issuer = issuer_;
    }

    function updateKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
    }

    function updateLiquidityThresholds(uint256 amount_, uint64 percentage_) external onlyOwner {
        perpJrReservedUnderlyingAmt = amount_;
        perpJrReservedUnderlyingPerc = percentage_;
    }

    function updateMinCleanupVal(uint256 minCleanupVal_) external onlyOwner {
        minCleanupVal = minCleanupVal_;
    }

    function updatePerpBalancer(address balancer_) external onlyOwner {
        balancer = balancer_;
    }

    function updateRebalanceWindow(uint32 freqSec, uint32 windowOffsetSec, uint32 windowLengthSec) external onlyOwner {
        if (freqSec == 0 || windowOffsetSec >= freqSec || windowLengthSec == 0) revert InvalidParamDefn();
        rebalanceFreqSec = freqSec;
        rebalanceWindowOffsetSec = windowOffsetSec;
        rebalanceWindowLengthSec = windowLengthSec;
    }

    function updateRolloverEligibility(uint32 minMaturitySec_) external onlyOwner {
        minMaturitySec = minMaturitySec_;
    }

    function updateValueCap(uint256 valueCap_) external onlyOwner {
        valueCap = valueCap_;
    }

    function flashMint2(
        uint256 underlyingAmtIntoPerpSr,
        uint256 underlyingAmtIntoPerpJr,
        uint256 minPerpSrAmtOut,
        uint256 minPerpJrAmtOut
    )
        external
        nonReentrant
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc)
    {
        if (userOpsPaused) revert UserOpsPaused();
        if (underlyingAmtIntoPerpSr != 0 && issuer != address(0)) _issueAndRegister();

        MintQuote memory quote = _quoteUnderlyingMint(underlyingAmtIntoPerpSr, underlyingAmtIntoPerpJr);
        perpSrFeePerc = quote.srFeePerc;
        perpJrFeePerc = quote.jrFeePerc;
        if (perpSrFeePerc.totalFeePerc >= WAD || perpJrFeePerc.totalFeePerc >= WAD) revert OpDisabled();
        _checkValueCap(quote.preState, quote.postState, underlyingAmtIntoPerpSr, underlyingAmtIntoPerpJr);
        (perpSrAmt, perpJrAmt) = _recordMintFees(quote, minPerpSrAmtOut, minPerpJrAmtOut);

        _receiveUnderlying(perpSr, underlyingAmtIntoPerpSr);
        _receiveUnderlying(perpJr, underlyingAmtIntoPerpJr);
        _deliverMint(perpSr, quote.srGrossShares, perpSrAmt);
        _deliverMint(perpJr, quote.jrGrossShares, perpJrAmt);
    }

    function flashRedeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minUnderlyingAmtOut)
        external
        nonReentrant
        returns (uint256 underlyingAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc)
    {
        if (userOpsPaused) revert UserOpsPaused();
        FlashRedeemQuote memory quote = _quoteFlashRedeem(perpSrAmtRedeemed, perpJrAmtRedeemed);
        perpSrFeePerc = quote.srFeePerc;
        perpJrFeePerc = quote.jrFeePerc;
        if (perpSrFeePerc.totalFeePerc >= WAD || perpJrFeePerc.totalFeePerc >= WAD) revert OpDisabled();
        if (quote.jrGross > availPerpJrLiquidity()) revert InsufficientLiquidity();

        uint256 srFeeAmt = Math.mulDiv(quote.srGross, perpSrFeePerc.totalFeePerc, WAD);
        uint256 jrFeeAmt = Math.mulDiv(quote.jrGross, perpJrFeePerc.totalFeePerc, WAD);
        uint256 srNet = quote.srGross - srFeeAmt;
        uint256 jrNet = quote.jrGross - jrFeeAmt;
        underlyingAmt = srNet + jrNet;
        if (underlyingAmt < minUnderlyingAmtOut) revert SlippageExceededLimit();

        _moveUnderlyingToPerpJr(quote.srGross);
        IPerpToken(perpSr).burnFrom(msg.sender, perpSrAmtRedeemed);
        IPerpToken(perpJr).burnFrom(msg.sender, perpJrAmtRedeemed);
        _withdrawUnderlying(perpJr, quote.srGross + quote.jrGross);
        _sendFlashRedeemOutput(quote.srGross, perpSrFeePerc, msg.sender);
        _sendFlashRedeemOutput(quote.jrGross, perpJrFeePerc, msg.sender);
    }

    function mint2(
        TokenAmount calldata srTrAmtIn,
        TokenAmount calldata jrTrAmtIn,
        uint256 minPerpSrAmtOut,
        uint256 minPerpJrAmtOut
    )
        external
        nonReentrant
        returns (uint256 perpSrAmt, uint256 perpJrAmt, FeePerc memory perpSrFeePerc, FeePerc memory perpJrFeePerc)
    {
        if (userOpsPaused) revert UserOpsPaused();
        if (issuer != address(0)) _issueAndRegister();
        BondInfo memory latest = _latestBondInfo;
        if (srTrAmtIn.amount != 0 && srTrAmtIn.token != latest.srTranche) revert UnexpectedAsset();
        if (jrTrAmtIn.amount != 0 && jrTrAmtIn.token != latest.jrTranche) revert UnexpectedAsset();

        MintQuote memory quote = _quoteTrancheMint(srTrAmtIn, jrTrAmtIn);
        perpSrFeePerc = quote.srFeePerc;
        perpJrFeePerc = quote.jrFeePerc;
        if (perpSrFeePerc.totalFeePerc >= WAD || perpJrFeePerc.totalFeePerc >= WAD) revert OpDisabled();
        _checkValueCap(quote.preState, quote.postState, quote.srValue, quote.jrValue);
        (perpSrAmt, perpJrAmt) = _recordMintFees(quote, minPerpSrAmtOut, minPerpJrAmtOut);
        _receiveTranche(perpSr, srTrAmtIn);
        _receiveTranche(perpJr, jrTrAmtIn);
        _deliverMint(perpSr, quote.srGrossShares, perpSrAmt);
        _deliverMint(perpJr, quote.jrGrossShares, perpJrAmt);
    }

    function redeem2(uint256 perpSrAmtRedeemed, uint256 perpJrAmtRedeemed, uint256 minValOut)
        external
        nonReentrant
        returns (
            PerpBalancer.ReserveAmounts memory returnedPerpSrReserveAmounts,
            PerpBalancer.ReserveAmounts memory returnedPerpJrReserveAmounts,
            FeePerc memory perpSrFeePerc,
            FeePerc memory perpJrFeePerc
        )
    {
        if (userOpsPaused) revert UserOpsPaused();
        RedeemQuote memory quote = _quoteRedeem2(perpSrAmtRedeemed, perpJrAmtRedeemed);
        perpSrFeePerc = quote.srFeePerc;
        perpJrFeePerc = quote.jrFeePerc;
        returnedPerpSrReserveAmounts = quote.srAmounts;
        returnedPerpJrReserveAmounts = quote.jrAmounts;
        if (_basketValue(quote.srRd, quote.srAmounts) + _basketValue(quote.jrRd, quote.jrAmounts) < minValOut) {
            revert SlippageExceededLimit();
        }
        _retainPerpFee(perpSr, msg.sender, perpSrAmtRedeemed, quote.srNet, quote.srFeePerp, quote.srFeePerc);
        _retainPerpFee(perpJr, msg.sender, perpJrAmtRedeemed, quote.jrNet, quote.jrFeePerp, quote.jrFeePerc);
        IPerpToken(perpSr).transferReservesTo(msg.sender, quote.srAmounts);
        IPerpToken(perpJr).transferReservesTo(msg.sender, quote.jrAmounts);
    }

    function rebalance() external nonReentrant {
        if (systemOpsPaused) revert SystemOpsPaused();
        if (msg.sender != keeper) revert UnauthorizedCall();
        (uint64 windowStart, uint64 windowEnd) = rebalanceWindow(block.timestamp);
        if (block.timestamp < windowStart || block.timestamp > windowEnd) revert OutOfRebalanceWindow();
        if (lastRebalanceTimestampSec != 0 && block.timestamp < uint256(lastRebalanceTimestampSec) + rebalanceFreqSec) {
            revert LastRebalanceTooRecent();
        }

        // Trace order: protocol-split fee balances settle before computeRebalanceVal; the plan transfers,
        // then AUM mints. See CONTROLLER_PROBES_2.md R2 and CODEX_REVIEW_PROBES.md Round 2 R2/AUM trace.
        _settleCollectedFees();
        (SystemState memory state, PerpBalancer.ReserveData memory srRd, PerpBalancer.ReserveData memory jrRd) =
            systemReserveState();
        (uint256 rebalanceValue, bool isPerpSrPayer) = IFeePolicyController(feePolicy)
            .computeRebalanceVal(state.perpSr.reserveValue, state.perpJr.reserveValue, targetSystemRatio);
        emit Rebalance(rebalanceValue, isPerpSrPayer);

        PerpBalancer.ReserveAmounts memory plan =
            PerpBalancer(balancer).computeSystemRebalancePlan(isPerpSrPayer ? srRd : jrRd, rebalanceValue);
        address payer = isPerpSrPayer ? perpSr : perpJr;
        address receiver = isPerpSrPayer ? perpJr : perpSr;
        IPerpToken(payer).transferReservesTo(receiver, plan);
        IPerpToken(receiver).handleTransferReservesIn(plan);

        _mintAumFee(perpSr, IFeePolicyController(feePolicy).perpSrAUMFeePerc());
        _mintAumFee(perpJr, IFeePolicyController(feePolicy).perpJrAUMFeePerc());
        lastRebalanceTimestampSec = SafeCast.toUint64(block.timestamp);
    }

    function pullProtocolFees(address token, address to, uint256 amount) external {
        address collector = IFeePolicyController(feePolicy).protocolFeeCollector();
        if (msg.sender != collector) revert UnauthorizedCall();
        protocolFeeBals[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
    }

    function _issueAndRegister() private {
        (bool issued, IBondIssuerController.BondInfo memory info) = IBondIssuerController(issuer).issue();
        if (!issued) info = IBondIssuerController(issuer).latestBondInfo();
        _latestBondInfo = BondInfo(info.manager, info.bondID, info.srTranche, info.jrTranche);
        if (info.srTranche != address(0)) IPerpToken(perpSr).registerTranche(info.srTranche);
        if (info.jrTranche != address(0)) IPerpToken(perpJr).registerTranche(info.jrTranche);
    }

    function _receiveUnderlying(address perp, uint256 amount) private {
        if (amount == 0) return;
        IERC20(underlying).safeTransferFrom(msg.sender, perp, amount);
        PerpBalancer.TokenAmount[] memory none = new PerpBalancer.TokenAmount[](0);
        IPerpToken(perp).handleTransferReservesIn(PerpBalancer.ReserveAmounts(amount, none));
    }

    function _receiveTranche(address perp, TokenAmount calldata input) private {
        if (input.amount == 0) return;
        IERC20(input.token).safeTransferFrom(msg.sender, perp, input.amount);
        PerpBalancer.TokenAmount[] memory amounts = new PerpBalancer.TokenAmount[](1);
        amounts[0] = PerpBalancer.TokenAmount(input.token, input.amount);
        IPerpToken(perp).handleTransferReservesIn(PerpBalancer.ReserveAmounts(0, amounts));
    }

    function _withdrawUnderlying(address perp, uint256 amount) private {
        if (amount == 0) return;
        PerpBalancer.TokenAmount[] memory none = new PerpBalancer.TokenAmount[](0);
        IPerpToken(perp).transferReservesTo(address(this), PerpBalancer.ReserveAmounts(amount, none));
    }

    function _moveUnderlyingToPerpJr(uint256 amount) private {
        if (amount == 0) return;
        PerpBalancer.TokenAmount[] memory none = new PerpBalancer.TokenAmount[](0);
        PerpBalancer.ReserveAmounts memory amounts = PerpBalancer.ReserveAmounts(amount, none);
        IPerpToken(perpSr).transferReservesTo(perpJr, amounts);
        IPerpToken(perpJr).handleTransferReservesIn(amounts);
    }

    function _sendFlashRedeemOutput(uint256 gross, FeePerc memory fee, address to) private {
        if (gross == 0) return;
        uint256 feeAmt = Math.mulDiv(gross, fee.totalFeePerc, WAD);
        IERC20(underlying).safeTransfer(to, gross - feeAmt);
        _recordFee(underlying, gross, fee);
    }

    function _recordFee(address token, uint256 gross, FeePerc memory fee) private returns (uint256 totalFeeAmt) {
        totalFeeAmt = Math.mulDiv(gross, fee.totalFeePerc, WAD);
        // Round-1 split vectors match protocolFeeAmt = floor(gross * protocolFeePerc / 1e18);
        // collected fees are the remainder: totalFeeAmt - protocolFeeAmt.
        uint256 protocolFeeAmt = Math.mulDiv(gross, fee.protocolFeePerc, WAD);
        protocolFeeBals[token] += protocolFeeAmt;
        collectedFeeBal[token] += totalFeeAmt - protocolFeeAmt;
        emit OpFees(token, totalFeeAmt, protocolFeeAmt);
    }

    function _retainPerpFee(
        address token,
        address user,
        uint256 input,
        uint256 net,
        uint256 feePerp,
        FeePerc memory fee
    ) private {
        IERC20(token).safeTransferFrom(user, address(this), input);
        if (net != 0) IPerpToken(token).burnFrom(address(this), net);
        uint256 protocolFeeAmt = Math.mulDiv(input, fee.protocolFeePerc, WAD);
        protocolFeeBals[token] += protocolFeeAmt;
        collectedFeeBal[token] += feePerp - protocolFeeAmt;
        emit OpFees(token, feePerp, protocolFeeAmt);
    }

    function _settleCollectedFees() private {
        uint256 srCollected = collectedFeeBal[perpSr];
        if (srCollected != 0) {
            collectedFeeBal[perpSr] = 0;
            IPerpToken(perpSr).burnFrom(address(this), srCollected);
        }
        uint256 jrCollected = collectedFeeBal[perpJr];
        if (jrCollected != 0) {
            collectedFeeBal[perpJr] = 0;
            IPerpToken(perpJr).burnFrom(address(this), jrCollected);
        }
        uint256 underlyingCollected = collectedFeeBal[underlying];
        if (underlyingCollected != 0) {
            collectedFeeBal[underlying] = 0;
            IERC20(underlying).safeTransfer(perpJr, underlyingCollected);
            PerpBalancer.TokenAmount[] memory none = new PerpBalancer.TokenAmount[](0);
            IPerpToken(perpJr).handleTransferReservesIn(PerpBalancer.ReserveAmounts(underlyingCollected, none));
        }
    }

    function _mintAumFee(address perp, uint64 feePerc) private {
        if (feePerc == 0) return;
        uint256 supply = IPerpToken(perp).totalSupply();
        uint256 amount = Math.mulDiv(supply, feePerc, WAD - feePerc);
        if (amount == 0) return;
        IPerpToken(perp).mintTo(IFeePolicyController(feePolicy).protocolFeeCollector(), amount);
        emit AumFees(perp, amount);
    }

    function _computeFeePercs(SystemState memory preState, SystemState memory postState, bool isFlashOp)
        private
        view
        returns (FeePerc memory srFee, FeePerc memory jrFee)
    {
        (uint256 subPre, uint256 vmPre) = _computeDRs(preState, targetSystemRatio, targetPerpJrVM);
        (uint256 subPost, uint256 vmPost) = _computeDRs(postState, targetSystemRatio, targetPerpJrVM);
        IFeePolicyController.OpSystemChange memory change =
            IFeePolicyController.OpSystemChange(subPre, subPost, vmPre, vmPost);
        IFeePolicyController.OpFees memory sr =
            IFeePolicyController(feePolicy).computeOpFees(IFeePolicyController.OpFeeInput(true, isFlashOp, change));
        IFeePolicyController.OpFees memory jr =
            IFeePolicyController(feePolicy).computeOpFees(IFeePolicyController.OpFeeInput(false, isFlashOp, change));
        srFee = FeePerc(sr.totalFeePerc, sr.protocolFeePerc);
        jrFee = FeePerc(jr.totalFeePerc, jr.protocolFeePerc);
    }

    function _quoteUnderlyingMint(uint256 srInput, uint256 jrInput) private view returns (MintQuote memory quote) {
        PerpBalancer.ReserveData memory srRd;
        PerpBalancer.ReserveData memory jrRd;
        SystemState memory preState;
        (preState, srRd, jrRd) = systemReserveState();
        quote.preState = preState;
        quote.srValue = srInput;
        quote.jrValue = jrInput;
        quote.srGrossShares = Math.mulDiv(srInput, preState.perpSr.totalSupply, preState.perpSr.reserveValue);
        quote.jrGrossShares = Math.mulDiv(jrInput, preState.perpJr.totalSupply, preState.perpJr.reserveValue);
        quote.postState =
            _postUnderlyingMint(preState, srRd, jrRd, srInput, jrInput, quote.srGrossShares, quote.jrGrossShares);
        (quote.srFeePerc, quote.jrFeePerc) = _computeFeePercs(preState, quote.postState, true);
    }

    function _quoteTrancheMint(TokenAmount calldata srInput, TokenAmount calldata jrInput)
        private
        view
        returns (MintQuote memory quote)
    {
        PerpBalancer.ReserveData memory srRd;
        PerpBalancer.ReserveData memory jrRd;
        SystemState memory preState;
        (preState, srRd, jrRd) = systemReserveState();
        quote.preState = preState;
        quote.srValue = _trancheValue(srInput);
        quote.jrValue = _trancheValue(jrInput);
        quote.srGrossShares = Math.mulDiv(quote.srValue, preState.perpSr.totalSupply, preState.perpSr.reserveValue);
        quote.jrGrossShares = Math.mulDiv(quote.jrValue, preState.perpJr.totalSupply, preState.perpJr.reserveValue);
        uint256 srVm = srInput.amount == 0 ? WAD : IPerpTokenTrancheData(srInput.token).data().volatilityMultiplier;
        uint256 jrVm = jrInput.amount == 0 ? WAD : IPerpTokenTrancheData(jrInput.token).data().volatilityMultiplier;
        quote.postState = _postTrancheMint(
            preState, srRd, jrRd, quote.srValue, quote.jrValue, srVm, jrVm, quote.srGrossShares, quote.jrGrossShares
        );
        (quote.srFeePerc, quote.jrFeePerc) = _computeFeePercs(preState, quote.postState, false);
    }

    function _quoteRedeem2(uint256 srInput, uint256 jrInput) private view returns (RedeemQuote memory quote) {
        SystemState memory preState;
        (preState, quote.srRd, quote.jrRd) = systemReserveState();
        uint256 srGross = Math.mulDiv(srInput, preState.perpSr.reserveValue, preState.perpSr.totalSupply);
        uint256 jrGross = Math.mulDiv(jrInput, preState.perpJr.reserveValue, preState.perpJr.totalSupply);
        SystemState memory postState =
            _postFlashRedeem(preState, quote.srRd, quote.jrRd, srInput, jrInput, srGross, jrGross, true);
        (quote.srFeePerc, quote.jrFeePerc) = _computeFeePercs(preState, postState, false);
        if (quote.srFeePerc.totalFeePerc >= WAD || quote.jrFeePerc.totalFeePerc >= WAD) revert OpDisabled();
        quote.srFeePerp = Math.mulDiv(srInput, quote.srFeePerc.totalFeePerc, WAD);
        quote.jrFeePerp = Math.mulDiv(jrInput, quote.jrFeePerc.totalFeePerc, WAD);
        quote.srNet = srInput - quote.srFeePerp;
        quote.jrNet = jrInput - quote.jrFeePerp;
        quote.srAmounts = _redeemBasket(quote.srRd, quote.srNet, preState.perpSr.totalSupply);
        quote.jrAmounts = _redeemBasket(quote.jrRd, quote.jrNet, preState.perpJr.totalSupply);
    }

    function _quoteFlashRedeem(uint256 srInput, uint256 jrInput) private view returns (FlashRedeemQuote memory quote) {
        SystemState memory preState;
        (preState, quote.srRd, quote.jrRd) = systemReserveState();
        quote.srGross = Math.mulDiv(srInput, preState.perpSr.reserveValue, preState.perpSr.totalSupply);
        quote.jrGross = Math.mulDiv(jrInput, preState.perpJr.reserveValue, preState.perpJr.totalSupply);
        SystemState memory postState =
            _postFlashRedeem(preState, quote.srRd, quote.jrRd, srInput, jrInput, quote.srGross, quote.jrGross, false);
        (quote.srFeePerc, quote.jrFeePerc) = _computeFeePercs(preState, postState, true);
    }

    function _recordMintFees(MintQuote memory quote, uint256 minSr, uint256 minJr)
        private
        returns (uint256 srNet, uint256 jrNet)
    {
        srNet = quote.srGrossShares - _recordFee(perpSr, quote.srGrossShares, quote.srFeePerc);
        jrNet = quote.jrGrossShares - _recordFee(perpJr, quote.jrGrossShares, quote.jrFeePerc);
        if (srNet < minSr || jrNet < minJr) revert SlippageExceededLimit();
    }

    function _deliverMint(address perp, uint256 grossShares, uint256 netShares) private {
        if (grossShares == 0) return;
        IPerpToken(perp).mintTo(address(this), grossShares);
        IERC20(perp).safeTransfer(msg.sender, netShares);
    }

    function _perpState(address perp, PerpBalancer.ReserveData memory rd)
        private
        view
        returns (PerpState memory state)
    {
        state.totalSupply = IPerpToken(perp).totalSupply();
        state.reserveValue = rd.underlyingBal;
        uint256 vmValue = rd.underlyingBal * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData memory item = rd.trancheData[i];
            state.reserveValue += item.value;
            vmValue += item.value * item.data.volatilityMultiplier;
        }
        state.vm = state.reserveValue == 0 ? 0 : vmValue / state.reserveValue;
    }

    function _computeDRs(SystemState memory state, uint256 targetSystemRatio_, uint256 targetPerpJrVM_)
        private
        pure
        returns (uint256 subDR_, uint256 vmDR_)
    {
        if (state.perpSr.reserveValue == 0) return (type(uint120).max, 0);
        if (state.perpJr.reserveValue == 0) return (0, 0);
        subDR_ = Math.mulDiv(state.perpJr.reserveValue, WAD_SQUARED, state.perpSr.reserveValue * targetSystemRatio_);
        vmDR_ = Math.mulDiv(state.perpJr.vm, WAD, targetPerpJrVM_);
    }

    function _postUnderlyingMint(
        SystemState memory pre,
        PerpBalancer.ReserveData memory srRd,
        PerpBalancer.ReserveData memory jrRd,
        uint256 srAmount,
        uint256 jrAmount,
        uint256 srShares,
        uint256 jrShares
    ) private pure returns (SystemState memory post) {
        post.perpSr = _stateAfterDeposit(pre.perpSr, srRd, srAmount, WAD, srShares);
        post.perpJr = _stateAfterDeposit(pre.perpJr, jrRd, jrAmount, WAD, jrShares);
    }

    function _postTrancheMint(
        SystemState memory pre,
        PerpBalancer.ReserveData memory srRd,
        PerpBalancer.ReserveData memory jrRd,
        uint256 srValue,
        uint256 jrValue,
        uint256 srVm,
        uint256 jrVm,
        uint256 srShares,
        uint256 jrShares
    ) private pure returns (SystemState memory post) {
        post.perpSr = _stateAfterDeposit(pre.perpSr, srRd, srValue, srVm, srShares);
        post.perpJr = _stateAfterDeposit(pre.perpJr, jrRd, jrValue, jrVm, jrShares);
    }

    function _stateAfterDeposit(
        PerpState memory pre,
        PerpBalancer.ReserveData memory rd,
        uint256 value,
        uint256 vm,
        uint256 shares
    ) private pure returns (PerpState memory post) {
        post.totalSupply = pre.totalSupply + shares;
        post.reserveValue = pre.reserveValue + value;
        if (post.reserveValue == 0) {
            post.vm = 0;
            return post;
        }
        uint256 vmValue = rd.underlyingBal * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            vmValue += rd.trancheData[i].value * rd.trancheData[i].data.volatilityMultiplier;
        }
        vmValue += value * vm;
        post.vm = vmValue / post.reserveValue;
    }

    function _postFlashRedeem(
        SystemState memory pre,
        PerpBalancer.ReserveData memory srRd,
        PerpBalancer.ReserveData memory jrRd,
        uint256 srShares,
        uint256 jrShares,
        uint256 srValueOut,
        uint256 jrValueOut,
        bool proportionalBasket
    ) private pure returns (SystemState memory post) {
        post.perpSr.totalSupply = pre.perpSr.totalSupply - srShares;
        post.perpSr.reserveValue = pre.perpSr.reserveValue - srValueOut;
        post.perpJr.totalSupply = pre.perpJr.totalSupply - jrShares;
        post.perpJr.reserveValue = pre.perpJr.reserveValue - jrValueOut;
        if (proportionalBasket) {
            post.perpSr.vm = pre.perpSr.vm;
            post.perpJr.vm = pre.perpJr.vm;
        } else {
            post.perpSr.vm = _vmAfterUnderlyingWithdrawal(srRd, srValueOut, post.perpSr.reserveValue);
            post.perpJr.vm = _vmAfterUnderlyingWithdrawal(jrRd, jrValueOut, post.perpJr.reserveValue);
        }
    }

    function _vmAfterUnderlyingWithdrawal(
        PerpBalancer.ReserveData memory rd,
        uint256 underlyingOut,
        uint256 reserveAfter
    ) private pure returns (uint256) {
        if (reserveAfter == 0) return 0;
        uint256 underlyingAfter = rd.underlyingBal > underlyingOut ? rd.underlyingBal - underlyingOut : 0;
        uint256 vmValue = underlyingAfter * WAD;
        for (uint256 i; i < rd.trancheData.length; ++i) {
            vmValue += rd.trancheData[i].value * rd.trancheData[i].data.volatilityMultiplier;
        }
        return vmValue / reserveAfter;
    }

    function _checkValueCap(SystemState memory pre, SystemState memory post, uint256 srInput, uint256 jrInput)
        private
        view
    {
        if (
            pre.perpSr.reserveValue + pre.perpJr.reserveValue <= valueCap
                && post.perpSr.reserveValue + post.perpJr.reserveValue <= valueCap
        ) return;
        if (srInput != 0 && jrInput != 0) revert ValueCapExceeded();
        (uint256 preSub,) = _computeDRs(pre, targetSystemRatio, targetPerpJrVM);
        (uint256 postSub,) = _computeDRs(post, targetSystemRatio, targetPerpJrVM);
        if (preSub > WAD) {
            if (srInput == 0 || postSub > preSub || postSub < WAD) revert ValueCapExceeded();
        } else if (preSub < WAD) {
            if (jrInput == 0 || postSub < preSub || postSub > WAD) revert ValueCapExceeded();
        } else {
            revert ValueCapExceeded();
        }
    }

    function _trancheValue(TokenAmount calldata input) private view returns (uint256) {
        if (input.amount == 0) return 0;
        IPerpTokenTrancheData.Data memory data = IPerpTokenTrancheData(input.token).data();
        return Math.mulDiv(input.amount, data.trancheClaim, data.trancheSupply);
    }

    function _redeemBasket(PerpBalancer.ReserveData memory rd, uint256 netShares, uint256 supply)
        private
        pure
        returns (PerpBalancer.ReserveAmounts memory amounts)
    {
        amounts.underlyingAmt = Math.mulDiv(rd.underlyingBal, netShares, supply);
        amounts.trancheAmts = new PerpBalancer.TokenAmount[](rd.trancheData.length);
        for (uint256 i; i < rd.trancheData.length; ++i) {
            PerpBalancer.ReserveTrancheData memory tranche = rd.trancheData[i];
            amounts.trancheAmts[i] =
                PerpBalancer.TokenAmount(tranche.data.tranche, Math.mulDiv(tranche.balance, netShares, supply));
        }
    }

    function _basketValue(PerpBalancer.ReserveData memory rd, PerpBalancer.ReserveAmounts memory amounts)
        private
        pure
        returns (uint256 value)
    {
        value = amounts.underlyingAmt;
        for (uint256 i; i < amounts.trancheAmts.length; ++i) {
            for (uint256 j; j < rd.trancheData.length; ++j) {
                if (amounts.trancheAmts[i].token == rd.trancheData[j].data.tranche) {
                    value += Math.mulDiv(
                        amounts.trancheAmts[i].amount,
                        rd.trancheData[j].data.trancheClaim,
                        rd.trancheData[j].data.trancheSupply
                    );
                    break;
                }
            }
        }
    }
}

interface IPerpTokenTrancheData {
    struct Data {
        uint256 trancheSupply;
        uint256 trancheClaim;
        uint256 totalClaim;
        uint256 volatilityMultiplier;
        uint256 underlyingOpenPrice;
        bool isMature;
        uint64 secondsToMaturity;
        uint64 trancheRatio;
        uint64 valueRatio;
        bytes32 bondID;
        bool isSenior;
        address tranche;
        address counterpart;
        address manager;
    }

    function data() external view returns (Data memory);
}
