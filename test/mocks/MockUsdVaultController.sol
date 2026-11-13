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
    uint256 public targetSystemRatio = 2_847_475_019_000_000_000;
    SystemState private _state;
    uint256 private _subDR;
    uint256 private _vmDR;

    constructor(address underlyingOracle_) {
        underlyingOracle = underlyingOracle_;
    }

    function setUnderlyingOracle(address underlyingOracle_) external {
        underlyingOracle = underlyingOracle_;
    }

    function setTargetSystemRatio(uint256 targetSystemRatio_) external {
        targetSystemRatio = targetSystemRatio_;
    }

    function setPerpSrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpSr = PerpState({totalSupply: totalSupply, reserveValue: reserveValue, vm: vm});
    }

    function setPerpJrState(uint256 totalSupply, uint256 reserveValue, uint256 vm) external {
        _state.perpJr = PerpState({totalSupply: totalSupply, reserveValue: reserveValue, vm: vm});
    }

    function setSystemDeviations(uint256 subDR, uint256 vmDR) external {
        _subDR = subDR;
        _vmDR = vmDR;
    }

    function systemReserveState() external view returns (SystemState memory state) {
        return _state;
    }

    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR) {
        return (_subDR, _vmDR);
    }
}
