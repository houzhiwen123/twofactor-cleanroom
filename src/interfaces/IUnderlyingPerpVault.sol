// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Evidence-backed phase-1 surface shared by the cbBTC/Perp SR and cbBTC/Perp JR vaults.
interface IUnderlyingPerpVault is IERC20 {
    struct DRRange {
        uint96 lower;
        uint96 upper;
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

    event Deposit(uint256 underlyingAmtIn, uint256 perpAmtIn, uint256 notesMinted);
    event Redeem(uint256 notesBurnt, uint256 underlyingAmtOut, uint256 perpAmtOut);
    event Rebalance(uint256 drBefore, uint256 underlyingAmt, bool isMintingPerp);

    function MINIMUM_LIQUIDITY() external view returns (uint256);
    function ONE() external view returns (uint256);
    function underlying() external view returns (address);
    function perp() external view returns (address);
    function perpController() external view returns (address);
    function underlyingUnitAmt() external view returns (uint96);
    function isPerpSrVault() external view returns (bool);
    function mintsAboveTarget() external view returns (bool);
    function keeper() external view returns (address);
    function targetDR() external view returns (uint96);
    function eqDRRange() external view returns (uint96 lower, uint96 upper);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceOffsetSec() external view returns (uint32);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function minRebalanceVal() external view returns (uint128);
    function maxFlashFeePerc() external view returns (uint64);

    function init(
        string calldata name_,
        string calldata symbol_,
        address underlying_,
        address perpController_,
        bool isPerpSrVault_,
        bool mintsAboveTarget_
    ) external;

    function initDeposit(uint256 underlyingAmt) external returns (uint256 notesMinted);
    function underlyingBalance() external view returns (uint256);
    function perpBalance() external view returns (uint256);
    function getTVL() external view returns (uint256);

    function computeMintAmt(uint256 underlyingMax, uint256 perpMax)
        external
        view
        returns (uint256 notesMinted, uint256 underlyingAmtIn, uint256 perpAmtIn);

    function deposit(uint256 underlyingMax, uint256 perpMax) external returns (uint256 notesMinted);

    function computeRedemptionAmts(uint256 notesAmt)
        external
        view
        returns (uint256 underlyingAmtOut, uint256 perpAmtOut);

    function redeem(uint256 notesAmt) external returns (uint256 underlyingAmtOut, uint256 perpAmtOut);

    function computeRebalanceAmount() external view returns (uint256 underlyingAmt, bool isMintingPerp);
    function rebalance() external;
    function updateKeeper(address keeper_) external;
    function updateTargetDR(uint96 targetDR_, DRRange calldata eqDRRange_) external;
    function updateRebalanceTimingParams(uint32 freqSec_, uint32 offsetSec_) external;
    function updateMinRebalanceAmt(uint128 minRebalanceVal_) external;
    function updateMaxFlashFeePerc(uint64 maxFlashFeePerc_) external;
    function pause() external;
    function unpause() external;
}
