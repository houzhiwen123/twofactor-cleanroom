// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";
import {ITranche} from "../interfaces/ITranche.sol";

interface IPriceOracle {
    function getValidPrice() external view returns (uint256);
}

contract BondsManager is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, IBondsManager {
    using SafeERC20 for IERC20;

    error DuplicateAsset();
    error DuplicateBond();
    error DuplicateIssuer();
    error FailedDeployment();
    error ImmaturableBond();
    error ImmatureBond();
    error InsufficientBalance(uint256 balance, uint256 needed);
    error InvalidBond();
    error InvalidParamDefn();
    error MatureBond();
    error SafeCastOverflowedUintDowncast(uint8 bits, uint256 value);
    error UnauthorizedCall();
    error UndefinedOracle();
    error UnexpectedAsset();
    error UnknownIssuer();

    uint256 private constant WAD = 1e18;

    address public trancheImpl;
    mapping(bytes32 => BondData) private _bonds;
    mapping(address => address) public oracles;
    mapping(address => bool) private _allowedIssuers;
    mapping(address => bool) public isValidTranche;
    address[] private _assets;
    mapping(address => bool) private _assetExists;

    event BondCreated(
        bytes32 indexed bondID,
        address indexed underlying_,
        uint64 srTrancheRatio_,
        uint64 maturityDate_,
        address senior,
        address junior,
        uint256 openPrice
    );
    event BondDeposit(bytes32 indexed bondID, uint256 underlyingAmtIn, uint256 srAmtMint, uint256 jrAmtMint);
    event BondMature(bytes32 indexed bondID, uint256 srClaim, uint256 jrClaim, uint256 closePrice);
    event TranchesRedeemed(
        bytes32 indexed bondID, uint256 srAmtRedeemed, uint256 jrAmtRedeemed, uint256 underlyingAmtReturned
    );

    constructor() {
        _disableInitializers();
    }

    function init(address trancheImpl_) external initializer {
        if (trancheImpl_ == address(0)) revert InvalidParamDefn();
        trancheImpl = trancheImpl_;
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
    }

    function addIssuer(address issuer_) external onlyOwner {
        if (issuer_ == address(0)) revert InvalidParamDefn();
        if (_allowedIssuers[issuer_]) revert DuplicateIssuer();
        _allowedIssuers[issuer_] = true;
    }

    function removeIssuer(address issuer_) external onlyOwner {
        if (!_allowedIssuers[issuer_]) revert UnknownIssuer();
        _allowedIssuers[issuer_] = false;
    }

    function addAsset(address asset) external onlyOwner {
        if (asset == address(0)) revert InvalidParamDefn();
        if (_assetExists[asset]) revert DuplicateAsset();
        _assetExists[asset] = true;
        _assets.push(asset);
    }

    function removeAsset(address asset) external onlyOwner {
        if (!_assetExists[asset]) revert UnexpectedAsset();
        _assetExists[asset] = false;
        delete oracles[asset];
        for (uint256 i; i < _assets.length; ++i) {
            if (_assets[i] == asset) {
                _assets[i] = _assets[_assets.length - 1];
                _assets.pop();
                break;
            }
        }
    }

    function updateOracle(address asset, address newOracle) external onlyOwner {
        if (!_assetExists[asset]) revert UnexpectedAsset();
        oracles[asset] = newOracle;
    }

    function oracleOf(address asset) external view returns (address) {
        return oracles[asset];
    }

    function assetAt(uint256 i) external view returns (address) {
        return _assets[i];
    }

    function assetCount() external view returns (uint256) {
        return _assets.length;
    }

    function assetPrice(address asset) public view returns (uint256) {
        address oracle = oracles[asset];
        if (oracle == address(0)) revert UndefinedOracle();
        return IPriceOracle(oracle).getValidPrice();
    }

    function computeBondID(
        address self_,
        address underlying_,
        uint64 srTrancheRatio_,
        uint64 maturityDate_,
        uint256 openPrice_
    ) public pure returns (bytes32) {
        return keccak256(abi.encode(self_, underlying_, srTrancheRatio_, maturityDate_, openPrice_));
    }

    function computeSettlement(uint64 srTrancheRatio_, uint256 underlyingBal_, uint256 openPrice_, uint256 closePrice_)
        public
        pure
        returns (uint256 srClaim, uint256 jrClaim)
    {
        uint256 baseSenior = Math.mulDiv(underlyingBal_, srTrancheRatio_, WAD, Math.Rounding.Ceil);
        uint256 rawSenior = Math.mulDiv(baseSenior, openPrice_, closePrice_, Math.Rounding.Ceil);
        srClaim = rawSenior < underlyingBal_ ? rawSenior : underlyingBal_;
        jrClaim = underlyingBal_ - srClaim;
    }

    function createBond(address underlying_, uint64 srTrancheRatio_, uint64 maturityDate_)
        external
        returns (bytes32 bondID, BondData memory bondData)
    {
        if (!_allowedIssuers[msg.sender]) revert UnauthorizedCall();
        if (srTrancheRatio_ > WAD) revert InvalidParamDefn();
        uint256 openPrice = assetPrice(underlying_);
        bondID = computeBondID(address(this), underlying_, srTrancheRatio_, maturityDate_, openPrice);
        if (_bonds[bondID].underlying != address(0)) revert DuplicateBond();

        address senior = Clones.clone(trancheImpl);
        address junior = Clones.clone(trancheImpl);
        if (senior == address(0) || junior == address(0)) revert FailedDeployment();
        ITranche(senior).init(address(this), bondID, underlying_, maturityDate_, true);
        ITranche(junior).init(address(this), bondID, underlying_, maturityDate_, false);
        isValidTranche[senior] = true;
        isValidTranche[junior] = true;

        bondData = BondData({
            underlying: underlying_,
            srTrancheRatio: srTrancheRatio_,
            isMature: false,
            maturityDate: maturityDate_,
            senior: senior,
            junior: junior,
            openPrice: openPrice,
            underlyingBal: 0,
            srClaim: 0,
            jrClaim: 0
        });
        _bonds[bondID] = bondData;
        emit BondCreated(bondID, underlying_, srTrancheRatio_, maturityDate_, senior, junior, openPrice);
    }

    function deposit(bytes32 bondID, uint256 underlyingAmt)
        external
        nonReentrant
        returns (TokenAmount memory srTrAmt, TokenAmount memory jrTrAmt)
    {
        BondData storage b = _getBond(bondID);
        if (b.isMature || block.timestamp >= b.maturityDate) revert MatureBond();
        IERC20(b.underlying).safeTransferFrom(msg.sender, address(this), underlyingAmt);
        uint256 totalTranche = Math.mulDiv(underlyingAmt, b.openPrice, WAD);
        uint256 srMint = Math.mulDiv(totalTranche, b.srTrancheRatio, WAD);
        uint256 jrMint = totalTranche - srMint;
        b.underlyingBal += underlyingAmt;
        ITranche(b.senior).mint(msg.sender, srMint);
        ITranche(b.junior).mint(msg.sender, jrMint);
        srTrAmt = TokenAmount(b.senior, srMint);
        jrTrAmt = TokenAmount(b.junior, jrMint);
        emit BondDeposit(bondID, underlyingAmt, srMint, jrMint);
    }

    function redeemImmature(bytes32 bondID, uint256 srAmtAvail, uint256 jrAmtAvail)
        public
        nonReentrant
        returns (uint256 underlyingAmtReturned, TokenAmount memory srTrAmt, TokenAmount memory jrTrAmt)
    {
        BondData storage b = _getBond(bondID);
        if (b.isMature || block.timestamp >= b.maturityDate) revert MatureBond();
        (underlyingAmtReturned, srTrAmt, jrTrAmt) =
            _redeemImmature(bondID, b, srAmtAvail, jrAmtAvail, msg.sender);
    }

    function redeem(bytes32 bondID, uint256 srAmtAvail, uint256 jrAmtAvail)
        external
        nonReentrant
        returns (uint256 underlyingAmtReturned, TokenAmount memory srTrAmt, TokenAmount memory jrTrAmt)
    {
        BondData storage b = _getBond(bondID);
        if (block.timestamp < b.maturityDate && !b.isMature) {
            return _redeemImmature(bondID, b, srAmtAvail, jrAmtAvail, msg.sender);
        }
        if (!b.isMature) _mature(bondID, b);
        uint256 srOut = _redeemMature(bondID, b, true, srAmtAvail, msg.sender);
        uint256 jrOut = _redeemMature(bondID, b, false, jrAmtAvail, msg.sender);
        underlyingAmtReturned = srOut + jrOut;
        srTrAmt = TokenAmount(b.senior, srAmtAvail);
        jrTrAmt = TokenAmount(b.junior, jrAmtAvail);
    }

    function redeemMature(bytes32 bondID, bool isSenior_, uint256 trancheAmtRedeemed)
        external
        nonReentrant
        returns (uint256 underlyingAmtReturned)
    {
        BondData storage b = _getBond(bondID);
        if (!b.isMature) {
            if (block.timestamp < b.maturityDate) revert ImmatureBond();
            _mature(bondID, b);
        }
        return _redeemMature(bondID, b, isSenior_, trancheAmtRedeemed, msg.sender);
    }

    function redeemAll(BondRedeemParams[] calldata redeemOps)
        external
        nonReentrant
        returns (TokenAmount[] memory underlyingAmtsReturned, TokenAmount[2][] memory allTranchesRedeemed)
    {
        underlyingAmtsReturned = new TokenAmount[](redeemOps.length);
        allTranchesRedeemed = new TokenAmount[2][](redeemOps.length);
        for (uint256 i; i < redeemOps.length; ++i) {
            BondRedeemParams calldata op = redeemOps[i];
            BondData storage b = _getBond(op.bondID);
            TokenAmount memory sr;
            TokenAmount memory jr;
            uint256 returned;
            if (!b.isMature && block.timestamp < b.maturityDate) {
                (returned, sr, jr) = _redeemImmature(op.bondID, b, op.srAmtAvail, op.jrAmtAvail, msg.sender);
            } else {
                if (!b.isMature) _mature(op.bondID, b);
                uint256 srOut = _redeemMature(op.bondID, b, true, op.srAmtAvail, msg.sender);
                uint256 jrOut = _redeemMature(op.bondID, b, false, op.jrAmtAvail, msg.sender);
                returned = srOut + jrOut;
                sr = TokenAmount(b.senior, op.srAmtAvail);
                jr = TokenAmount(b.junior, op.jrAmtAvail);
            }
            underlyingAmtsReturned[i] = TokenAmount(b.underlying, returned);
            allTranchesRedeemed[i] = [sr, jr];
        }
    }

    function mature(bytes32 bondID) external {
        BondData storage b = _getBond(bondID);
        if (b.isMature || block.timestamp < b.maturityDate) revert ImmaturableBond();
        _mature(bondID, b);
    }

    function tryMature(bytes32 bondID) external returns (bool) {
        BondData storage b = _getBond(bondID);
        if (b.isMature || block.timestamp < b.maturityDate) return false;
        _mature(bondID, b);
        return true;
    }

    function _mature(bytes32 bondID, BondData storage b) private {
        uint256 closePrice = assetPrice(b.underlying);
        (b.srClaim, b.jrClaim) =
            computeSettlement(b.srTrancheRatio, b.underlyingBal, b.openPrice, closePrice);
        b.isMature = true;
        b.underlyingBal = 0;
        emit BondMature(bondID, b.srClaim, b.jrClaim, closePrice);
    }

    function _redeemImmature(
        bytes32 bondID,
        BondData storage b,
        uint256 srAmtAvail,
        uint256 jrAmtAvail,
        address account
    ) private returns (uint256 underlyingOut, TokenAmount memory srTrAmt, TokenAmount memory jrTrAmt) {
        uint256 srSupply = ITranche(b.senior).totalSupply();
        uint256 jrSupply = ITranche(b.junior).totalSupply();
        if (srAmtAvail > ITranche(b.senior).balanceOf(account)) {
            revert InsufficientBalance(ITranche(b.senior).balanceOf(account), srAmtAvail);
        }
        if (jrAmtAvail > ITranche(b.junior).balanceOf(account)) {
            revert InsufficientBalance(ITranche(b.junior).balanceOf(account), jrAmtAvail);
        }

        uint256 srBurn;
        uint256 jrBurn;
        if (srSupply != 0 && (jrSupply == 0 || _productLessThanOrEqual(srAmtAvail, jrSupply, jrAmtAvail, srSupply))) {
            srBurn = srAmtAvail;
            jrBurn = srSupply == 0 ? 0 : Math.mulDiv(jrSupply, srAmtAvail, srSupply);
            underlyingOut = srSupply == 0 ? 0 : Math.mulDiv(b.underlyingBal, srAmtAvail, srSupply);
        } else if (jrSupply != 0) {
            jrBurn = jrAmtAvail;
            srBurn = Math.mulDiv(srSupply, jrAmtAvail, jrSupply);
            underlyingOut = Math.mulDiv(b.underlyingBal, jrAmtAvail, jrSupply);
        }

        ITranche(b.senior).burn(account, srBurn);
        ITranche(b.junior).burn(account, jrBurn);
        b.underlyingBal -= underlyingOut;
        if (underlyingOut != 0) IERC20(b.underlying).safeTransfer(account, underlyingOut);
        srTrAmt = TokenAmount(b.senior, srBurn);
        jrTrAmt = TokenAmount(b.junior, jrBurn);
        emit TranchesRedeemed(bondID, srBurn, jrBurn, underlyingOut);
    }

    function _redeemMature(bytes32 bondID, BondData storage b, bool isSenior_, uint256 amount, address account)
        private
        returns (uint256 underlyingOut)
    {
        address tranche = isSenior_ ? b.senior : b.junior;
        uint256 supplyBefore = ITranche(tranche).totalSupply();
        uint256 balance = ITranche(tranche).balanceOf(account);
        if (amount > balance) revert InsufficientBalance(balance, amount);
        uint256 claimBefore = isSenior_ ? b.srClaim : b.jrClaim;
        // Unobserved zero-supply claims remain unallocated rather than redeemable.
        underlyingOut = supplyBefore == 0
            ? 0
            : amount == supplyBefore
            ? claimBefore
            : Math.mulDiv(claimBefore, amount, supplyBefore);
        ITranche(tranche).burn(account, amount);
        if (isSenior_) b.srClaim -= underlyingOut;
        else b.jrClaim -= underlyingOut;
        if (underlyingOut != 0) IERC20(b.underlying).safeTransfer(account, underlyingOut);
        emit TranchesRedeemed(bondID, isSenior_ ? amount : 0, isSenior_ ? 0 : amount, underlyingOut);
    }

    function trancheData(bytes32 bondID, bool isSenior_) external view returns (TrancheData memory td) {
        BondData storage b = _getBond(bondID);
        uint256 srClaim = b.srClaim;
        uint256 jrClaim = b.jrClaim;
        uint256 totalClaim;
        if (b.isMature) {
            totalClaim = srClaim + jrClaim;
        } else {
            totalClaim = b.underlyingBal;
            (srClaim, jrClaim) = computeSettlement(
                b.srTrancheRatio, b.underlyingBal, b.openPrice, assetPrice(b.underlying)
            );
        }

        uint256 sideClaim = isSenior_ ? srClaim : jrClaim;
        // These zero-claim and capped-claim branches were not observed on chain.
        uint256 valueRatio = totalClaim == 0
            ? isSenior_ ? b.srTrancheRatio : WAD - b.srTrancheRatio
            : Math.mulDiv(sideClaim, WAD, totalClaim);
        bool srCapped = totalClaim != 0 && srClaim >= totalClaim;
        uint256 vm;
        if (isSenior_) vm = srCapped ? WAD : 0;
        else if (!srCapped && valueRatio != 0) vm = 1e36 / valueRatio;

        uint64 remaining = b.maturityDate > block.timestamp ? uint64(b.maturityDate - block.timestamp) : 0;
        td = TrancheData({
            trancheSupply: ITranche(isSenior_ ? b.senior : b.junior).totalSupply(),
            trancheClaim: sideClaim,
            totalClaim: totalClaim,
            volatilityMultiplier: vm,
            underlyingOpenPrice: b.openPrice,
            isMature: b.isMature,
            secondsToMaturity: remaining,
            trancheRatio: b.srTrancheRatio,
            valueRatio: uint64(valueRatio),
            bondID: bondID,
            isSenior: isSenior_,
            tranche: isSenior_ ? b.senior : b.junior,
            counterpart: isSenior_ ? b.junior : b.senior,
            manager: address(this)
        });
    }

    function bondsData(bytes32 bondID) external view returns (BondData memory) {
        return _getBond(bondID);
    }

    function data(bytes32 bondID) external view returns (BondData memory) {
        return _getBond(bondID);
    }

    function isMature(bytes32 bondID) external view returns (bool) {
        return _getBond(bondID).isMature;
    }

    function isValidBond(bytes32 bondID) external view returns (bool) {
        return _bonds[bondID].underlying != address(0);
    }

    function maturityDate(bytes32 bondID) external view returns (uint64) {
        return _getBond(bondID).maturityDate;
    }

    function secondsToMaturity(bytes32 bondID) external view returns (uint64) {
        uint64 maturity = _getBond(bondID).maturityDate;
        return maturity > block.timestamp ? uint64(maturity - block.timestamp) : 0;
    }

    function srTranche(bytes32 bondID) external view returns (address) {
        return _getBond(bondID).senior;
    }

    function jrTranche(bytes32 bondID) external view returns (address) {
        return _getBond(bondID).junior;
    }

    function tranches(bytes32 bondID) external view returns (address senior, address junior) {
        BondData storage b = _getBond(bondID);
        return (b.senior, b.junior);
    }

    function underlying(bytes32 bondID) external view returns (address) {
        return _getBond(bondID).underlying;
    }

    function bondClaim(bytes32 bondID) external view returns (uint256) {
        BondData storage b = _getBond(bondID);
        return b.isMature ? b.srClaim + b.jrClaim : b.underlyingBal;
    }

    function _getBond(bytes32 bondID) private view returns (BondData storage b) {
        b = _bonds[bondID];
        if (b.underlying == address(0)) revert InvalidBond();
    }

    function _productLessThanOrEqual(uint256 a, uint256 b, uint256 c, uint256 d) private pure returns (bool) {
        (uint256 leftHigh, uint256 leftLow) = _product512(a, b);
        (uint256 rightHigh, uint256 rightLow) = _product512(c, d);
        return leftHigh < rightHigh || (leftHigh == rightHigh && leftLow <= rightLow);
    }

    function _product512(uint256 a, uint256 b) private pure returns (uint256 high, uint256 low) {
        assembly {
            let mm := mulmod(a, b, not(0))
            low := mul(a, b)
            high := sub(sub(mm, low), lt(mm, low))
        }
    }

    struct BondRedeemParams {
        bytes32 bondID;
        uint256 srAmtAvail;
        uint256 jrAmtAvail;
    }
}
