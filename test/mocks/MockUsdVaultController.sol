// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

contract MockUsdVaultController {
    struct PerpState {
        uint256 totalSupply;
        uint256 reserveValue;
        uint256 vm;
    }

    struct SystemState {
        PerpState perpSr;
        PerpState perpJr;
    }

    address public underlyingOracle;
    SystemState private _state;

    constructor(address underlyingOracle_) {
        underlyingOracle = underlyingOracle_;
    }

    function setUnderlyingOracle(address underlyingOracle_) external {
        underlyingOracle = underlyingOracle_;
    }

    function setPerpSrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpSr = PerpState({totalSupply: totalSupply, reserveValue: reserveValue, vm: vm});
    }

    function setPerpJrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpJr = PerpState({totalSupply: totalSupply, reserveValue: reserveValue, vm: vm});
    }

    function systemReserveState() external view returns (SystemState memory state) {
        return _state;
    }
}
