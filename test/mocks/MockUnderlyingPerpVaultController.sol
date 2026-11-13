// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract MockUnderlyingPerpVaultController {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    address public perpSr;
    address public perpJr;
    SystemState private _state;

    constructor(address perpSr_, address perpJr_) {
        perpSr = perpSr_;
        perpJr = perpJr_;
    }

    function setPerpSrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpSr = PerpState(totalSupply, reserveValue, vm);
    }

    function setPerpJrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpJr = PerpState(totalSupply, reserveValue, vm);
    }

    function systemReserveState() external view returns (SystemState memory state) {
        return _state;
    }
}
