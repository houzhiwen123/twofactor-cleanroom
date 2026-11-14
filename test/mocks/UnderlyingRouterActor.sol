// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {UnderlyingSingleAssetRouter} from "../../src/router/UnderlyingSingleAssetRouter.sol";

contract UnderlyingRouterActor {
    UnderlyingSingleAssetRouter public immutable router;

    constructor() {
        router = new UnderlyingSingleAssetRouter();
    }

    function depositBoth(address underlying, address seniorVault, address juniorVault, uint256 amount)
        external
        returns (uint256 seniorNotes, uint256 juniorNotes)
    {
        IERC20(underlying).approve(address(router), type(uint256).max);
        seniorNotes = router.depositUnderlying(seniorVault, amount, 0, 2);
        juniorNotes = router.depositUnderlying(juniorVault, amount, 0, 2);
    }

    function depositOne(address underlying, address vault, uint256 amount) external returns (uint256 notes) {
        IERC20(underlying).approve(address(router), type(uint256).max);
        notes = router.depositUnderlying(vault, amount, 0, 2);
    }

    function redeemBoth(address seniorVault, address juniorVault, uint256 seniorNotes, uint256 juniorNotes)
        external
        returns (uint256 seniorUnderlying, uint256 juniorUnderlying)
    {
        IERC20(seniorVault).approve(address(router), type(uint256).max);
        IERC20(juniorVault).approve(address(router), type(uint256).max);
        seniorUnderlying = router.redeemUnderlying(seniorVault, seniorNotes, 0);
        juniorUnderlying = router.redeemUnderlying(juniorVault, juniorNotes, 0);
    }

    function redeemOne(address vault, uint256 notes, uint256 minUnderlyingOut)
        external
        returns (uint256 underlyingOut)
    {
        IERC20(vault).approve(address(router), type(uint256).max);
        underlyingOut = router.redeemUnderlying(vault, notes, minUnderlyingOut);
    }
}
