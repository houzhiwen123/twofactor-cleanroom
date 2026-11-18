// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

interface ITargetHighVmSurveyController {
    function systemDeviations() external view returns (uint256 subDR, uint256 vmDR);
}

/// @notice Bounded public-history state survey for the remaining high-VM compatibility question.
/// @dev This intentionally samples a fixed, documented list rather than scanning an unbounded
///      block range. It reads only target public state through local forks.
contract TargetHighVmStateSurveyTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    bytes32 private constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event HighVmStateSample(
        uint256 indexed blockNumber,
        bool readable,
        address implementation,
        bytes32 proxyCodehash,
        bytes32 implementationCodehash,
        uint256 subDR,
        uint256 vmDR
    );

    function testBoundedHistoricalVmSurvey() public {
        uint256[11] memory blocks = [
            uint256(51_000_000),
            51_500_000,
            51_777_385,
            52_250_000,
            52_750_000,
            53_243_583,
            53_750_000,
            54_250_000,
            54_750_000,
            54_990_962,
            57_015_384
        ];

        for (uint256 i; i < blocks.length; ++i) {
            vm.createSelectFork(vm.envString("BASE_RPC_URL"), blocks[i]);
            assertEq(block.chainid, 8453, "Base chain ID");
            assertEq(block.number, blocks[i], "survey block");

            if (CONTROLLER.code.length == 0) {
                emit HighVmStateSample(blocks[i], false, address(0), bytes32(0), bytes32(0), 0, 0);
                emit log_named_uint("survey block", blocks[i]);
                emit log_named_uint("survey readable", 0);
                continue;
            }

            address implementation = address(uint160(uint256(vm.load(CONTROLLER, EIP1967_IMPLEMENTATION_SLOT))));
            try ITargetHighVmSurveyController(CONTROLLER).systemDeviations() returns (uint256 subDR, uint256 vmDR) {
                emit HighVmStateSample(
                    blocks[i],
                    true,
                    implementation,
                    CONTROLLER.codehash,
                    implementation.codehash,
                    subDR,
                    vmDR
                );
                emit log_named_uint("survey block", blocks[i]);
                emit log_named_uint("survey readable", 1);
                emit log_named_address("survey implementation", implementation);
                emit log_named_bytes32("survey proxy codehash", CONTROLLER.codehash);
                emit log_named_bytes32("survey implementation codehash", implementation.codehash);
                emit log_named_uint("survey subDR", subDR);
                emit log_named_uint("survey vmDR", vmDR);
            } catch {
                emit HighVmStateSample(
                    blocks[i], false, implementation, CONTROLLER.codehash, implementation.codehash, 0, 0
                );
                emit log_named_uint("survey block", blocks[i]);
                emit log_named_uint("survey readable", 0);
            }
        }
    }
}
