// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IBondsManager} from "../interfaces/IBondsManager.sol";

contract Tranche is Initializable, ERC20Upgradeable, OwnableUpgradeable {
    error StringsInsufficientHexLength(uint256 value, uint256 length);

    bytes32 private _bondID;
    address private _manager;
    bool private _isSenior;
    uint8 private _tokenDecimals;

    constructor() {
        _disableInitializers();
    }

    function init(address manager_, bytes32 bondID_, address underlying, uint64, bool isSenior_)
        external
        initializer
    {
        string memory baseName = IERC20Metadata(underlying).name();
        string memory baseSymbol = IERC20Metadata(underlying).symbol();
        _manager = manager_;
        _bondID = bondID_;
        _isSenior = isSenior_;
        _tokenDecimals = IERC20Metadata(underlying).decimals();
        __ERC20_init(
            string.concat(baseName, isSenior_ ? " Senior" : " Junior"),
            string.concat(baseSymbol, isSenior_ ? "-SR" : "-JR")
        );
        __Ownable_init(manager_);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function bondID() external view returns (bytes32) {
        return _bondID;
    }

    function manager() external view returns (address) {
        return _manager;
    }

    function isSenior() external view returns (bool) {
        return _isSenior;
    }

    function data() external view returns (IBondsManager.TrancheData memory) {
        return IBondsManager(_manager).trancheData(_bondID, _isSenior);
    }
}
