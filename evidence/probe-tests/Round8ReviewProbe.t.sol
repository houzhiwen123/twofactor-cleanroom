// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

struct R8TokenAmount {
    address token;
    uint256 amount;
}

struct R8ReserveTokens {
    uint256 underlyingBal;
    R8TokenAmount[] trancheTokens;
}

interface IR8ERC20 {
    function balanceOf(address account) external view returns (uint256);
}

interface IR8Controller {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function targetSystemRatio() external view returns (uint256);
    function targetPerpJrVM() external view returns (uint256);
    function feePolicy() external view returns (address);
    function issuer() external view returns (address);
    function perpJrReservedUnderlyingAmt() external view returns (uint256);
    function perpJrReservedUnderlyingPerc() external view returns (uint64);
    function minCleanupVal() external view returns (uint256);
    function balancer() external view returns (address);
    function minMaturitySec() external view returns (uint32);
    function rebalanceFreqSec() external view returns (uint32);
    function rebalanceWindowOffsetSec() external view returns (uint32);
    function rebalanceWindowLengthSec() external view returns (uint32);
    function valueCap() external view returns (uint256);
    function userOpsPaused() external view returns (bool);
    function systemOpsPaused() external view returns (bool);
}

contract Round8ReviewProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant TEST_ADDRESS = address(1);
    uint256 private constant WAD = 1e18;
    uint256 private constant FORK_BLOCK = 54_990_962;

    IR8Controller private controller;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        controller = IR8Controller(CONTROLLER);
    }

    function testR8LiveReserveTupleMatchesTokenBalances() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        for (uint256 i; i < perps.length; ++i) {
            address perp = perps[i];
            (bool success, bytes memory returndata) = perp.staticcall(abi.encodeWithSignature("reserves()"));
            require(success, "reserves staticcall failed");
            R8ReserveTokens memory reserves = abi.decode(returndata, (R8ReserveTokens));
            require(reserves.underlyingBal == IR8ERC20(CBBTC).balanceOf(perp), "underlying balance mismatch");
            for (uint256 j; j < reserves.trancheTokens.length; ++j) {
                R8TokenAmount memory item = reserves.trancheTokens[j];
                require(item.amount == IR8ERC20(item.token).balanceOf(perp), "tranche amount mismatch");
            }
            console2.log(
                string.concat(
                    "OBS:R8_RESERVES {\"perp\":\"",
                    vm.toString(perp),
                    "\",\"returndataLength\":",
                    vm.toString(returndata.length),
                    ",\"underlyingBal\":",
                    vm.toString(reserves.underlyingBal),
                    ",\"count\":",
                    vm.toString(reserves.trancheTokens.length),
                    ",\"allBalancesMatch\":true}"
                )
            );
            for (uint256 j; j < reserves.trancheTokens.length; ++j) {
                console2.log(
                    string.concat(
                        "OBS:R8_RESERVE_ITEM {\"perp\":\"",
                        vm.toString(perp),
                        "\",\"index\":",
                        vm.toString(j),
                        ",\"token\":\"",
                        vm.toString(reserves.trancheTokens[j].token),
                        "\",\"amount\":",
                        vm.toString(reserves.trancheTokens[j].amount),
                        ",\"directBalance\":",
                        vm.toString(IR8ERC20(reserves.trancheTokens[j].token).balanceOf(perp)),
                        "}"
                    )
                );
            }
        }
    }

    function testR8SeniorApprovalSelectorsHaveEmptyRevertData() public {
        bytes4[2] memory selectors = [bytes4(0x397e327f), bytes4(0x484685b0)];
        for (uint256 i; i < selectors.length; ++i) {
            bytes memory callData = abi.encodePacked(selectors[i], abi.encode(BONDS_MANAGER));
            vm.prank(CONTROLLER);
            (bool success, bytes memory returndata) = PERP_SR.call(callData);
            console2.log(
                string.concat(
                    "OBS:R8_SR_APPROVAL_SELECTOR {\"selector\":\"",
                    vm.toString(selectors[i]),
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"revertData\":\"",
                    vm.toString(returndata),
                    "\"}"
                )
            );
            require(!success && returndata.length == 0, "SR approval selector did not empty-revert");
        }
    }

    function testR8ControllerSetterInputMatrix() public {
        address owner = controller.owner();
        address keeper = controller.keeper();

        _probe2(
            "dr_zero_system",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", 0, WAD),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_system_wad_minus_one_jr_plus_one",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD - 1, WAD + 1),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_system_wad_jr_plus_one",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD, WAD + 1),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_system_plus_one_jr_wad_minus_one",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD + 1, WAD - 1),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_system_plus_one_jr_wad",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD + 1, WAD),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_zero_jr",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD, 0),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_one_wad",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", 1, WAD),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_wad_wad",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD, WAD),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_wad_minus_one",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD - 1, WAD - 1),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );
        _probe2(
            "dr_wad_plus_one",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", WAD + 1, WAD + 1),
            owner,
            "targetSystemRatio",
            "targetPerpJrVM"
        );

        _probe1(
            "fee_policy_zero",
            abi.encodeWithSignature("updateFeePolicy(address)", address(0)),
            owner,
            "feePolicy"
        );
        _probe1(
            "fee_policy_one",
            abi.encodeWithSignature("updateFeePolicy(address)", TEST_ADDRESS),
            owner,
            "feePolicy"
        );
        _probe1(
            "issuer_zero",
            abi.encodeWithSignature("updateIssuer(address)", address(0)),
            owner,
            "issuer"
        );
        _probe1("issuer_one", abi.encodeWithSignature("updateIssuer(address)", TEST_ADDRESS), owner, "issuer");
        _probe1(
            "issuer_current",
            abi.encodeWithSignature("updateIssuer(address)", controller.issuer()),
            owner,
            "issuer"
        );
        _probe1(
            "issuer_bonds_manager",
            abi.encodeWithSignature("updateIssuer(address)", BONDS_MANAGER),
            owner,
            "issuer"
        );
        _probe1(
            "issuer_perp_sr",
            abi.encodeWithSignature("updateIssuer(address)", PERP_SR),
            owner,
            "issuer"
        );
        _probe1(
            "keeper_zero",
            abi.encodeWithSignature("updateKeeper(address)", address(0)),
            owner,
            "keeper"
        );
        _probe1("keeper_one", abi.encodeWithSignature("updateKeeper(address)", TEST_ADDRESS), owner, "keeper");
        _probe1(
            "balancer_zero",
            abi.encodeWithSignature("updatePerpBalancer(address)", address(0)),
            owner,
            "balancer"
        );
        _probe1(
            "balancer_one",
            abi.encodeWithSignature("updatePerpBalancer(address)", TEST_ADDRESS),
            owner,
            "balancer"
        );

        _probe2(
            "liquidity_zero_zero",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 0, 0),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );
        _probe2(
            "liquidity_one_one",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 1, 1),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );
        _probe2(
            "liquidity_wad_minus_one_wad_minus_one",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", WAD - 1, uint64(WAD - 1)),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );
        _probe2(
            "liquidity_wad_wad",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", WAD, uint64(WAD)),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );
        _probe2(
            "liquidity_wad_plus_one",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", WAD + 1, uint64(WAD)),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );
        _probe2(
            "liquidity_perc_wad_plus_one",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 0, uint64(WAD + 1)),
            owner,
            "perpJrReservedUnderlyingAmt",
            "perpJrReservedUnderlyingPerc"
        );

        _probe1(
            "cleanup_zero",
            abi.encodeWithSignature("updateMinCleanupVal(uint256)", 0),
            owner,
            "minCleanupVal"
        );
        _probe1("cleanup_one", abi.encodeWithSignature("updateMinCleanupVal(uint256)", 1), owner, "minCleanupVal");
        _probe1(
            "cleanup_wad_minus_one",
            abi.encodeWithSignature("updateMinCleanupVal(uint256)", WAD - 1),
            owner,
            "minCleanupVal"
        );
        _probe1("cleanup_wad", abi.encodeWithSignature("updateMinCleanupVal(uint256)", WAD), owner, "minCleanupVal");
        _probe1(
            "cleanup_wad_plus_one",
            abi.encodeWithSignature("updateMinCleanupVal(uint256)", WAD + 1),
            owner,
            "minCleanupVal"
        );
        _probe1(
            "cleanup_max",
            abi.encodeWithSignature("updateMinCleanupVal(uint256)", type(uint256).max),
            owner,
            "minCleanupVal"
        );

        uint32 currentEligibility = controller.minMaturitySec();
        _probe1(
            "eligibility_zero",
            abi.encodeWithSignature("updateRolloverEligibility(uint32)", 0),
            owner,
            "minMaturitySec"
        );
        _probe1(
            "eligibility_one",
            abi.encodeWithSignature("updateRolloverEligibility(uint32)", 1),
            owner,
            "minMaturitySec"
        );
        if (currentEligibility > 0) {
            _probe1(
                "eligibility_current_minus_one",
                abi.encodeWithSignature("updateRolloverEligibility(uint32)", currentEligibility - 1),
                owner,
                "minMaturitySec"
            );
        }
        _probe1(
            "eligibility_current",
            abi.encodeWithSignature("updateRolloverEligibility(uint32)", currentEligibility),
            owner,
            "minMaturitySec"
        );
        if (currentEligibility < type(uint32).max) {
            _probe1(
                "eligibility_current_plus_one",
                abi.encodeWithSignature("updateRolloverEligibility(uint32)", currentEligibility + 1),
                owner,
                "minMaturitySec"
            );
        }
        _probe1(
            "eligibility_max",
            abi.encodeWithSignature("updateRolloverEligibility(uint32)", type(uint32).max),
            owner,
            "minMaturitySec"
        );

        _probe1(
            "value_cap_zero",
            abi.encodeWithSignature("updateValueCap(uint256)", 0),
            keeper,
            "valueCap"
        );
        _probe1("value_cap_one", abi.encodeWithSignature("updateValueCap(uint256)", 1), keeper, "valueCap");
        _probe1(
            "value_cap_wad_minus_one",
            abi.encodeWithSignature("updateValueCap(uint256)", WAD - 1),
            keeper,
            "valueCap"
        );
        _probe1("value_cap_wad", abi.encodeWithSignature("updateValueCap(uint256)", WAD), keeper, "valueCap");
        _probe1(
            "value_cap_wad_plus_one",
            abi.encodeWithSignature("updateValueCap(uint256)", WAD + 1),
            keeper,
            "valueCap"
        );
        _probe1(
            "value_cap_max",
            abi.encodeWithSignature("updateValueCap(uint256)", type(uint256).max),
            keeper,
            "valueCap"
        );

        _probe1("pause_user_false", abi.encodeWithSignature("pauseUserOps(bool)", false), keeper, "userOpsPaused");
        _probe1("pause_user_true", abi.encodeWithSignature("pauseUserOps(bool)", true), keeper, "userOpsPaused");
        _probe1(
            "pause_system_false",
            abi.encodeWithSignature("pauseSystemOps(bool)", false),
            keeper,
            "systemOpsPaused"
        );
        _probe1(
            "pause_system_true",
            abi.encodeWithSignature("pauseSystemOps(bool)", true),
            keeper,
            "systemOpsPaused"
        );

        _probe3(
            "window_freq_zero",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 0, 0, 1),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_offset_freq_minus_one",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_399, 3_600),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_offset_freq",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_400, 3_600),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_offset_freq_plus_one",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_401, 3_600),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_length_zero",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 0),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_length_one",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 1),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_length_freq_minus_one",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 86_399),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_length_freq",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 86_400),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
        _probe3(
            "window_length_freq_plus_one",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 86_401),
            owner,
            "rebalanceFreqSec",
            "rebalanceWindowOffsetSec",
            "rebalanceWindowLengthSec"
        );
    }

    function _probe1(string memory label, bytes memory data, address caller, string memory getter) private {
        string[] memory names = new string[](1);
        bytes[] memory calls = new bytes[](1);
        names[0] = getter;
        calls[0] = abi.encodeWithSignature(string.concat(getter, "()"));
        _probe(label, data, caller, names, calls);
    }

    function _probe2(
        string memory label,
        bytes memory data,
        address caller,
        string memory getter0,
        string memory getter1
    ) private {
        string[] memory names = new string[](2);
        bytes[] memory calls = new bytes[](2);
        names[0] = getter0;
        names[1] = getter1;
        calls[0] = abi.encodeWithSignature(string.concat(getter0, "()"));
        calls[1] = abi.encodeWithSignature(string.concat(getter1, "()"));
        _probe(label, data, caller, names, calls);
    }

    function _probe3(
        string memory label,
        bytes memory data,
        address caller,
        string memory getter0,
        string memory getter1,
        string memory getter2
    ) private {
        string[] memory names = new string[](3);
        bytes[] memory calls = new bytes[](3);
        names[0] = getter0;
        names[1] = getter1;
        names[2] = getter2;
        calls[0] = abi.encodeWithSignature(string.concat(getter0, "()"));
        calls[1] = abi.encodeWithSignature(string.concat(getter1, "()"));
        calls[2] = abi.encodeWithSignature(string.concat(getter2, "()"));
        _probe(label, data, caller, names, calls);
    }

    function _probe(
        string memory label,
        bytes memory data,
        address caller,
        string[] memory getterNames,
        bytes[] memory getterCalls
    ) private {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (bool success, bytes memory returndata) = CONTROLLER.call(data);
        string memory observation = string.concat(
            "OBS:R8_SETTER {\"case\":\"",
            label,
            "\",\"caller\":\"",
            vm.toString(caller),
            "\",\"success\":",
            vm.toString(success),
            ",\"selector\":\"",
            vm.toString(_selector(returndata)),
            "\",\"returnLength\":",
            vm.toString(returndata.length),
            ",\"getters\":{"
        );
        for (uint256 i; i < getterCalls.length; ++i) {
            (bool getterSuccess, bytes memory getterReturndata) = CONTROLLER.staticcall(getterCalls[i]);
            require(getterSuccess && getterReturndata.length >= 32, "getter call failed");
            uint256 value = abi.decode(getterReturndata, (uint256));
            if (i != 0) observation = string.concat(observation, ",");
            observation = string.concat(observation, "\"", getterNames[i], "\":", vm.toString(value));
        }
        console2.log(string.concat(observation, "}}"));
        require(vm.revertToState(snapshot), "setter snapshot restore failed");
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }
}
