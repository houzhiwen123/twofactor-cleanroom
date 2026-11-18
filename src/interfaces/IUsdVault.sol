// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Evidence-backed mint/deposit and exit surface for the clean-room USD Senior Vault.
/// @dev Includes the target-observed session-capacity and phase-5B rebalance execution surfaces.
interface IUsdVault is IERC20 {
    struct ReserveState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        ReserveState perpSr;
        ReserveState perpJr;
    }

    struct Range {
        uint96 lower;
        uint96 upper;
    }

    event Deposit(uint256 usdAmtIn, uint256 perpSrAmtIn, uint256 notesMinted);
    event Redeem(uint256 notesAmt, uint256 usdAmtOut, uint256 perpSrAmtOut);
    event Rebalance(uint256 drBefore, uint256 underlyingPrice, uint256 rebalanceUsdVal, bool isMintingPerp);

    function MINIMUM_LIQUIDITY() external view returns (uint256);

    function initDeposit(uint256 usdAmt) external returns (uint256 notesMinted);

    function getTVL() external view returns (uint256);

    function computeMintAmt(uint256 usdMax, uint256 perpSrMax)
        external
        view
        returns (uint256 notesMinted, uint256 usdAmtIn, uint256 perpSrAmtIn);

    function deposit(uint256 usdMax, uint256 perpSrMax) external returns (uint256 notesMinted);

    function computeRedemptionAmts(uint256 notesAmt) external view returns (uint256 usdAmtOut, uint256 perpSrAmtOut);

    function redeem(uint256 notesAmt) external returns (uint256 usdAmtOut, uint256 perpSrAmtOut);

    function usdBalance() external view returns (uint256);

    function perpSrBalance() external view returns (uint256);

    function underlyingBalance() external view returns (uint256);

    function usd() external view returns (address);

    function underlying() external view returns (address);

    function perpSr() external view returns (address);

    function usdUnitAmt() external pure returns (uint256);

    function underlyingUnitAmt() external pure returns (uint256);

    function perpController() external view returns (address);

    function sessionCapacity()
        external
        view
        returns (bool active, bool sessionIsMintingPerp_, uint256 sessionBudgetUsdVal_, uint256 sessionOpenedAtSec_);

    function sessionBudgetUsdVal() external view returns (uint128);

    function sessionOpenedAtSec() external view returns (uint64);

    function sessionIsMintingPerp() external view returns (bool);

    function rebalanceFreqSec() external view returns (uint32);

    function rebalanceOffsetSec() external view returns (uint32);

    function maxDeploymentVelocityPerc() external view returns (uint64);

    function targetDR() external view returns (uint96);

    function eqDRRange() external view returns (Range memory);

    function minOpUsdVal() external view returns (uint128);

    function activeRebalanceDelaySec() external view returns (uint32);

    function dexStrategy() external view returns (address);

    function usdOracle() external view returns (address);

    function isSwapper(address account) external view returns (bool);

    /// @dev BNB-DESIGN safety surface: lets governance revoke or rotate Inventory authorization.
    function updateSwapper(address account, bool authorized) external;

    function maxUsdDeviationPerc() external view returns (uint64);

    function maxUnderlyingDeviationPerc() external view returns (uint64);

    function maxFlashMintFeePerc() external view returns (uint64);

    function maxFlashRedeemFeePerc() external view returns (uint64);

    function rebalance() external;

    function upkeep() external;

    function swap(address tokenIn, address tokenOut, uint256 tokenInAmt, uint256 tokenOutAmt) external;

    function rebalanceCapacity()
        external
        view
        returns (
            uint256 maxRebalanceUnderlying,
            uint256 underlyingPrice,
            bool isMintingPerp,
            uint256 currentDR,
            SystemState memory state
        );
}
