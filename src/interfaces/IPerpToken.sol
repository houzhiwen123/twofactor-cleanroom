// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {PerpBalancer} from "../policy/PerpBalancer.sol";

interface IPerpToken {
    struct ReserveTokens {
        uint256 underlyingBal;
        PerpBalancer.TokenAmount[] trancheTokens;
    }

    function underlying() external view returns (address);
    function bondsManager() external view returns (address);
    function controller() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mintTo(address to, uint256 amount) external;
    function burnFrom(address from, uint256 amount) external;
    function registerTranche(address tranche) external;
    function transferReservesTo(address to, PerpBalancer.ReserveAmounts calldata amounts) external;
    function handleTransferReservesIn(PerpBalancer.ReserveAmounts calldata amounts) external;
    function logBalance(address token) external;
    function reserveData() external view returns (PerpBalancer.ReserveData memory);
    function reserves() external view returns (ReserveTokens memory);
}
