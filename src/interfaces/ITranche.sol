// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IBondsManager} from "./IBondsManager.sol";

interface ITranche {
    function init(address manager, bytes32 bondID, address underlying, uint64 maturityDate, bool isSenior) external;

    function mint(address to, uint256 amount) external;

    function burn(address from, uint256 amount) external;

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function decimals() external view returns (uint8);

    function bondID() external view returns (bytes32);

    function manager() external view returns (address);

    function isSenior() external view returns (bool);

    function data() external view returns (IBondsManager.TrancheData memory);
}
