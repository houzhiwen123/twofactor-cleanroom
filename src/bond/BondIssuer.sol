// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";

contract BondIssuer is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    error InvalidParamDefn();
    error InvalidPerc();

    uint256 private constant WAD = 1e18;

    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    address public bondsManager;
    address public underlying;
    uint64 public srTrancheRatio;
    uint32 public maxMaturitySec;
    uint32 public minIssueTimeIntervalSec;
    uint32 public issueWindowOffsetSec;
    uint64 public lastIssueWindowTimestamp;
    bytes32 public latestBondID;

    bytes32[] private _activeBondIDs;
    BondInfo private _latestBondInfo;

    constructor() {
        _disableInitializers();
    }

    function init(address bondsManager_, address underlying_) external initializer {
        if (bondsManager_ == address(0) || underlying_ == address(0)) revert InvalidParamDefn();
        bondsManager = bondsManager_;
        underlying = underlying_;
        srTrancheRatio = uint64(WAD / 2);
        maxMaturitySec = 2_419_200;
        minIssueTimeIntervalSec = 604_800;
        issueWindowOffsetSec = 68_400;
        __Ownable_init(msg.sender);
        __Ownable2Step_init();
        __ReentrancyGuard_init();
    }

    function updateBondConfig(uint64 srTrancheRatio_, uint32 maxMaturitySec_) external onlyOwner {
        if (srTrancheRatio_ > WAD) revert InvalidPerc();
        if (maxMaturitySec_ == 0) revert InvalidParamDefn();
        srTrancheRatio = srTrancheRatio_;
        maxMaturitySec = maxMaturitySec_;
    }

    function updateIssuanceTimingConfig(uint32 minIssueTimeIntervalSec_, uint32 issueWindowOffsetSec_)
        external
        onlyOwner
    {
        if (minIssueTimeIntervalSec_ == 0 || issueWindowOffsetSec_ >= minIssueTimeIntervalSec_) {
            revert InvalidParamDefn();
        }
        minIssueTimeIntervalSec = minIssueTimeIntervalSec_;
        issueWindowOffsetSec = issueWindowOffsetSec_;
    }

    function issue() external nonReentrant returns (bool bondIssued, BondInfo memory info) {
        uint256 interval = minIssueTimeIntervalSec;
        uint256 offset = issueWindowOffsetSec;
        uint256 windowStart = ((block.timestamp - offset) / interval) * interval + offset;
        if (windowStart <= lastIssueWindowTimestamp) return (false, _latestBondInfo);

        uint64 maturity = uint64(windowStart + maxMaturitySec);
        (bytes32 bondID, IBondsManager.BondData memory bond) =
            IBondsManager(bondsManager).createBond(underlying, srTrancheRatio, maturity);
        lastIssueWindowTimestamp = uint64(windowStart);
        latestBondID = bondID;
        info = BondInfo(bondsManager, bondID, bond.senior, bond.junior);
        _latestBondInfo = info;
        _activeBondIDs.push(bondID);
        return (true, info);
    }

    function cleanupMature() external nonReentrant returns (bool bondMature) {
        uint256 i = _activeBondIDs.length;
        while (i != 0) {
            unchecked {
                --i;
            }
            bytes32 bondID = _activeBondIDs[i];
            bool matured = IBondsManager(bondsManager).isMature(bondID);
            if (!matured) matured = IBondsManager(bondsManager).tryMature(bondID);
            if (matured) {
                _activeBondIDs[i] = _activeBondIDs[_activeBondIDs.length - 1];
                _activeBondIDs.pop();
                bondMature = true;
            }
        }
    }

    function activeBondIDs() external view returns (bytes32[] memory) {
        return _activeBondIDs;
    }

    function latestBondInfo() external view returns (BondInfo memory) {
        return _latestBondInfo;
    }
}
