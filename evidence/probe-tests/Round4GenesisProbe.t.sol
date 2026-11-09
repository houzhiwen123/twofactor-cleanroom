// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

contract Round4ERC1967Proxy {
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address implementation) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            sstore(slot, implementation)
        }
    }

    fallback() external payable {
        _delegate();
    }

    receive() external payable {
        _delegate();
    }

    function _delegate() private {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly ("memory-safe") {
            let implementation := sload(slot)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch success
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

interface IRound4GenesisERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IRound4GenesisPerp {
    struct ReserveData {
        uint256 underlyingBal;
        address[] trancheTokens;
    }

    function reserves() external view returns (ReserveData memory);
    function mintTo(address, uint256) external;
}

contract Round4GenesisProbeTest is Test {
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant CONTROLLER_IMPL = 0x16e324BAe2098317477129a5E71f770bFf51f02a;
    address private constant FEE_POLICY_IMPL = 0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900;
    address private constant PERP_SR_IMPL = 0x96fC14b136300f9136C0d589Ed7a787B66571574;
    address private constant PERP_JR_IMPL = 0x8e9ED1138060434E56A5f7965017391C93631529;
    address private constant BOND_ISSUER_IMPL = 0xE024Bd4967185456df3dE7D2365919B5fb89763B;
    address private constant BONDS_MANAGER_IMPL = 0x427758ed7ba97d3602125f957CD9e6716fddAaC2;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function testRound4FreshProxiesAndGenesisEdges() public {
        Round4ERC1967Proxy feePolicy = new Round4ERC1967Proxy(FEE_POLICY_IMPL);
        Round4ERC1967Proxy controller = new Round4ERC1967Proxy(CONTROLLER_IMPL);
        Round4ERC1967Proxy perpSr = new Round4ERC1967Proxy(PERP_SR_IMPL);
        Round4ERC1967Proxy perpJr = new Round4ERC1967Proxy(PERP_JR_IMPL);
        Round4ERC1967Proxy bondIssuer = new Round4ERC1967Proxy(BOND_ISSUER_IMPL);
        Round4ERC1967Proxy bondsManager = new Round4ERC1967Proxy(BONDS_MANAGER_IMPL);

        (bool feeInitSuccess, bytes memory feeInitRet) = address(feePolicy).call(abi.encodeWithSignature("init()"));
        (bool srInitSuccess, bytes memory srInitRet) = address(perpSr)
            .call(
                abi.encodeWithSignature(
                    "init(string,string,address,address)", "cbBTC Senior", "cbBTC-SR", CBBTC, address(controller)
                )
            );
        (bool jrInitSuccess, bytes memory jrInitRet) = address(perpJr)
            .call(
                abi.encodeWithSignature(
                    "init(string,string,address,address)", "cbBTC Junior", "cbBTC-JR", CBBTC, address(controller)
                )
            );
        (bool controllerInitSuccess, bytes memory controllerInitRet) = address(controller)
            .call(abi.encodeWithSignature("init(address,address,address)", CBBTC, address(perpSr), address(perpJr)));

        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_genesis_proxy_init\",\"feePolicyImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(feePolicy), IMPLEMENTATION_SLOT))))),
                "\",\"controllerImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(controller), IMPLEMENTATION_SLOT))))),
                "\",\"perpSrImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(perpSr), IMPLEMENTATION_SLOT))))),
                "\",\"perpJrImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(perpJr), IMPLEMENTATION_SLOT))))),
                "\",\"bondIssuerImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(bondIssuer), IMPLEMENTATION_SLOT))))),
                "\",\"bondsManagerImpl\":\"",
                vm.toString(address(uint160(uint256(vm.load(address(bondsManager), IMPLEMENTATION_SLOT))))),
                "\",\"feeInitSuccess\":",
                vm.toString(feeInitSuccess),
                ",\"feeInitSelector\":\"",
                vm.toString(_selector(feeInitRet)),
                "\",\"srInitSuccess\":",
                vm.toString(srInitSuccess),
                ",\"srInitSelector\":\"",
                vm.toString(_selector(srInitRet)),
                "\",\"jrInitSuccess\":",
                vm.toString(jrInitSuccess),
                ",\"jrInitSelector\":\"",
                vm.toString(_selector(jrInitRet)),
                "\",\"controllerInitSuccess\":",
                vm.toString(controllerInitSuccess),
                ",\"controllerInitSelector\":\"",
                vm.toString(_selector(controllerInitRet)),
                "\",\"bondIssuerInitSelector\":\"0xf09a4016\",\"bondsManagerInitSelector\":\"none\"}"
            )
        );

        (bool aumBelowWadSuccess, bytes memory aumBelowWadRet) = address(feePolicy)
            .call(abi.encodeWithSignature("updateAumFeePerc(uint64,uint64)", uint64(1e18 - 1), uint64(1e18 - 1)));
        (bool aumAtWadSuccess, bytes memory aumAtWadRet) = address(feePolicy)
            .call(abi.encodeWithSignature("updateAumFeePerc(uint64,uint64)", uint64(1e18), uint64(1e18)));
        (bool aumAboveWadSuccess, bytes memory aumAboveWadRet) = address(feePolicy)
            .call(abi.encodeWithSignature("updateAumFeePerc(uint64,uint64)", uint64(1e18 + 1), uint64(1e18 + 1)));
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_genesis_aum_bounds\",\"belowWadSuccess\":",
                vm.toString(aumBelowWadSuccess),
                ",\"belowWadSelector\":\"",
                vm.toString(_selector(aumBelowWadRet)),
                "\",\"atWadSuccess\":",
                vm.toString(aumAtWadSuccess),
                ",\"atWadSelector\":\"",
                vm.toString(_selector(aumAtWadRet)),
                "\",\"aboveWadSuccess\":",
                vm.toString(aumAboveWadSuccess),
                ",\"aboveWadSelector\":\"",
                vm.toString(_selector(aumAboveWadRet)),
                "\"}"
            )
        );

        if (controllerInitSuccess && srInitSuccess && jrInitSuccess) {
            deal(CBBTC, address(this), 1_000_000);
            (bool approveSuccess, bytes memory approveRet) =
                CBBTC.call(abi.encodeWithSignature("approve(address,uint256)", address(controller), type(uint256).max));
            uint256 supplyBefore = IRound4GenesisERC20(address(perpSr)).totalSupply();
            (bool flashSuccess, bytes memory flashRet) = address(controller)
                .call(abi.encodeWithSignature("flashMint2(uint256,uint256,uint256,uint256)", 1_000_000, 0, 0, 0));
            uint256 supplyAfter = IRound4GenesisERC20(address(perpSr)).totalSupply();
            IRound4GenesisPerp.ReserveData memory srReserves = IRound4GenesisPerp(address(perpSr)).reserves();
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_genesis_first_flash_mint\",\"approveSuccess\":",
                    vm.toString(approveSuccess),
                    ",\"approveSelector\":\"",
                    vm.toString(_selector(approveRet)),
                    "\",\"supplyBefore\":",
                    vm.toString(supplyBefore),
                    ",\"flashSuccess\":",
                    vm.toString(flashSuccess),
                    ",\"flashSelector\":\"",
                    vm.toString(_selector(flashRet)),
                    "\",\"supplyAfter\":",
                    vm.toString(supplyAfter),
                    ",\"reserveIdleAfter\":",
                    vm.toString(srReserves.underlyingBal),
                    ",\"reserveTrancheCountAfter\":",
                    vm.toString(srReserves.trancheTokens.length),
                    "}"
                )
            );

            vm.prank(address(controller));
            IRound4GenesisPerp(address(perpSr)).mintTo(address(0xBEEF), 100);
            uint256 zeroReserveSupply = IRound4GenesisERC20(address(perpSr)).totalSupply();
            IRound4GenesisPerp.ReserveData memory zeroReserve = IRound4GenesisPerp(address(perpSr)).reserves();
            vm.prank(address(0xBEEF));
            (bool redeemZeroReserveSuccess, bytes memory redeemZeroReserveRet) =
                address(controller).call(abi.encodeWithSignature("redeem2(uint256,uint256,uint256)", 100, 0, 0));
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_genesis_zero_reserve_supply\",\"supplyBeforeRedeem\":",
                    vm.toString(zeroReserveSupply),
                    ",\"idle\":",
                    vm.toString(zeroReserve.underlyingBal),
                    ",\"trancheCount\":",
                    vm.toString(zeroReserve.trancheTokens.length),
                    ",\"redeemSuccess\":",
                    vm.toString(redeemZeroReserveSuccess),
                    ",\"redeemSelector\":\"",
                    vm.toString(_selector(redeemZeroReserveRet)),
                    "\",\"supplyAfterRedeem\":",
                    vm.toString(IRound4GenesisERC20(address(perpSr)).totalSupply()),
                    "}"
                )
            );
        }
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(data, 0x20))
            }
        }
    }
}
