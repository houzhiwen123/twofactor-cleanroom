// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Evidence-backed mint/deposit and exit surface for the clean-room USD Senior Vault.
/// @dev Includes the target-observed session-capacity view; rebalance execution remains deferred.
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
