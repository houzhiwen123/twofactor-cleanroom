// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IERC20Round4Perp {
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IControllerRound4Perp {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function latestBondInfo() external view returns (BondInfo memory);
}

interface IPerpRound4View {
    struct ReserveData {
        uint256 underlyingBal;
        address[] trancheTokens;
    }

    function reserves() external view returns (ReserveData memory);
}

contract Round4MockTranche {
    address public immutable manager;
    bytes32 public immutable bondID;
    bool public immutable isSenior;

    constructor(address manager_, bytes32 bondID_, bool isSenior_) {
        manager = manager_;
        bondID = bondID_;
        isSenior = isSenior_;
    }

    function isMature() external pure returns (bool) {
        return false;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}

contract Round4PerpPermissionTest is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant OWNER_SAFE = 0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d;
    address private constant USER = address(0xBEEF);
    address private constant RANDOM_CALLER = address(0xCAFE);
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    bytes32 private constant RESERVE_SYNCED = 0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testRound4PerpCallerMatrixAndMetadata() public {
        IControllerRound4Perp.BondInfo memory latest = IControllerRound4Perp(CONTROLLER).latestBondInfo();
        address[2] memory perps = [PERP_SR, PERP_JR];
        address[3] memory callers = [OWNER_SAFE, CONTROLLER, RANDOM_CALLER];
        string[3] memory callerLabels = ["owner", "controller", "random"];

        for (uint256 p; p < perps.length; ++p) {
            IERC20Round4Perp token = IERC20Round4Perp(perps[p]);
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_perp_metadata\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"owner\":\"",
                    vm.toString(_readAddress(perps[p], bytes4(0x8da5cb5b))),
                    "\",\"controller\":\"",
                    vm.toString(_readAddress(perps[p], bytes4(0xf77c4791))),
                    "\",\"decimals\":",
                    vm.toString(uint256(token.decimals())),
                    ",\"name\":\"",
                    token.name(),
                    "\",\"symbol\":\"",
                    token.symbol(),
                    "\",\"maxTrancheCount\":",
                    vm.toString(_readUint(perps[p], bytes4(0x650c699a))),
                    "}"
                )
            );

            for (uint256 c; c < callers.length; ++c) {
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "updateController",
                    abi.encodeWithSignature("updateController(address)", CONTROLLER)
                );
                _probe(perps[p], callerLabels[c], callers[c], "recover", abi.encodeWithSignature("recover()"));
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "primeApproval",
                    abi.encodeWithSignature("primeApproval(address)", BONDS_MANAGER)
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "revokeApproval",
                    abi.encodeWithSignature("revokeApproval(address)", BONDS_MANAGER)
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "registerTranche",
                    abi.encodeWithSignature("registerTranche(address)", p == 0 ? latest.srTranche : latest.jrTranche)
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "transferReservesTo",
                    abi.encodeWithSignature(
                        "transferReservesTo(address,(uint256,(address,uint256)[]))", USER, _emptyReserveAmounts()
                    )
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "handleTransferReservesIn",
                    abi.encodeWithSignature(
                        "handleTransferReservesIn((uint256,(address,uint256)[]))", _emptyReserveAmounts()
                    )
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "mintTo",
                    abi.encodeWithSignature("mintTo(address,uint256)", USER, uint256(1))
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "burnFrom",
                    abi.encodeWithSignature("burnFrom(address,uint256)", USER, uint256(1))
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "logBalance",
                    abi.encodeWithSignature("logBalance(address)", CBBTC)
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "init",
                    abi.encodeWithSignature(
                        "init(string,string,address,address)",
                        p == 0 ? "cbBTC Senior" : "cbBTC Junior",
                        p == 0 ? "cbBTC-SR" : "cbBTC-JR",
                        CONTROLLER,
                        OWNER_SAFE
                    )
                );
                _probe(
                    perps[p],
                    callerLabels[c],
                    callers[c],
                    "maxTrancheCount",
                    abi.encodeWithSignature("maxTrancheCount()")
                );
            }
        }
    }

    function testRound4PerpApprovalAndRecoveryEffects() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        address[2] memory tranches = [
            IControllerRound4Perp(CONTROLLER).latestBondInfo().srTranche,
            IControllerRound4Perp(CONTROLLER).latestBondInfo().jrTranche
        ];
        for (uint256 p; p < perps.length; ++p) {
            uint256 snapshot = vm.snapshotState();
            vm.prank(CONTROLLER);
            (bool primeSuccess, bytes memory primeRet) =
                perps[p].call(abi.encodeWithSignature("primeApproval(address)", BONDS_MANAGER));
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_prime_approval\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"success\":",
                    vm.toString(primeSuccess),
                    ",\"selector\":\"",
                    vm.toString(_selector(primeRet)),
                    "\",\"underlyingAllowance\":",
                    vm.toString(IERC20Round4Perp(CBBTC).allowance(perps[p], BONDS_MANAGER)),
                    ",\"trancheAllowance\":",
                    vm.toString(IERC20Round4Perp(tranches[p]).allowance(perps[p], BONDS_MANAGER)),
                    "}"
                )
            );
            require(vm.revertToState(snapshot), "prime snapshot restore failed");

            snapshot = vm.snapshotState();
            deal(CBBTC, perps[p], 1234);
            uint256 ownerBefore = IERC20Round4Perp(CBBTC).balanceOf(OWNER_SAFE);
            uint256 controllerBefore = IERC20Round4Perp(CBBTC).balanceOf(CONTROLLER);
            uint256 perpBefore = IERC20Round4Perp(CBBTC).balanceOf(perps[p]);
            vm.prank(CONTROLLER);
            (bool recoverSuccess, bytes memory recoverRet) = perps[p].call(abi.encodeWithSignature("recover()"));
            uint256 perpAfter = IERC20Round4Perp(CBBTC).balanceOf(perps[p]);
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_recover_underlying\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"success\":",
                    vm.toString(recoverSuccess),
                    ",\"selector\":\"",
                    vm.toString(_selector(recoverRet)),
                    "\",\"perpBalanceBefore\":",
                    vm.toString(perpBefore),
                    ",\"perpBalanceAfter\":",
                    vm.toString(perpAfter),
                    ",\"ownerDelta\":",
                    vm.toString(IERC20Round4Perp(CBBTC).balanceOf(OWNER_SAFE) - ownerBefore),
                    ",\"controllerDelta\":",
                    vm.toString(IERC20Round4Perp(CBBTC).balanceOf(CONTROLLER) - controllerBefore),
                    ",\"perpDelta\":",
                    vm.toString(perpBefore - IERC20Round4Perp(CBBTC).balanceOf(perps[p])),
                    "}"
                )
            );
            require(vm.revertToState(snapshot), "recover snapshot restore failed");
        }

        uint256 snapshot = vm.snapshotState();
        deal(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, PERP_SR, 777);
        uint256 strayBefore = IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(PERP_SR);
        uint256 ownerUsdcBefore = IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(OWNER_SAFE);
        uint256 controllerUsdcBefore =
            IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(CONTROLLER);
        vm.prank(CONTROLLER);
        (bool straySuccess, bytes memory strayRet) = PERP_SR.call(abi.encodeWithSignature("recover()"));
        uint256 strayAfter = IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(PERP_SR);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_recover_stray_token\",\"success\":",
                vm.toString(straySuccess),
                ",\"selector\":\"",
                vm.toString(_selector(strayRet)),
                "\",\"perpBalanceBefore\":",
                vm.toString(strayBefore),
                ",\"perpBalanceAfter\":",
                vm.toString(strayAfter),
                ",\"ownerStrayDelta\":",
                vm.toString(
                    IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(OWNER_SAFE) - ownerUsdcBefore
                ),
                ",\"controllerStrayDelta\":",
                vm.toString(
                    IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(CONTROLLER)
                        - controllerUsdcBefore
                ),
                ",\"perpStrayDelta\":",
                vm.toString(
                    strayBefore - IERC20Round4Perp(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913).balanceOf(PERP_SR)
                ),
                "}"
            )
        );
        require(vm.revertToState(snapshot), "stray recover snapshot restore failed");
    }

    function testRound4PerpUpdateControllerEffect() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        address newController = address(0xB0B);
        for (uint256 p; p < perps.length; ++p) {
            uint256 snapshot = vm.snapshotState();
            address oldController = _readAddress(perps[p], bytes4(0xf77c4791));
            address owner = _readAddress(perps[p], bytes4(0x8da5cb5b));
            vm.prank(owner);
            (bool updateSuccess, bytes memory updateRet) =
                perps[p].call(abi.encodeWithSignature("updateController(address)", newController));
            address afterController = _readAddress(perps[p], bytes4(0xf77c4791));
            vm.prank(oldController);
            (bool oldControllerSuccess, bytes memory oldControllerRet) =
                perps[p].call(abi.encodeWithSignature("mintTo(address,uint256)", USER, 1));
            vm.prank(newController);
            (bool newControllerSuccess, bytes memory newControllerRet) =
                perps[p].call(abi.encodeWithSignature("mintTo(address,uint256)", USER, 1));
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_update_controller_effect\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"oldController\":\"",
                    vm.toString(oldController),
                    "\",\"newController\":\"",
                    vm.toString(afterController),
                    "\",\"ownerUpdateSuccess\":",
                    vm.toString(updateSuccess),
                    ",\"updateSelector\":\"",
                    vm.toString(_selector(updateRet)),
                    "\",\"oldControllerCanMint\":",
                    vm.toString(oldControllerSuccess),
                    ",\"oldControllerSelector\":\"",
                    vm.toString(_selector(oldControllerRet)),
                    "\",\"newControllerCanMint\":",
                    vm.toString(newControllerSuccess),
                    ",\"newControllerSelector\":\"",
                    vm.toString(_selector(newControllerRet)),
                    "\"}"
                )
            );
            require(vm.revertToState(snapshot), "controller update snapshot restore failed");
        }
    }

    function testRound4PerpTransferReserveSyncOrder() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        address[2] memory tranches = [
            IControllerRound4Perp(CONTROLLER).latestBondInfo().srTranche,
            IControllerRound4Perp(CONTROLLER).latestBondInfo().jrTranche
        ];
        for (uint256 p; p < perps.length; ++p) {
            uint256 snapshot = vm.snapshotState();
            address[] memory beforeTokens = IPerpRound4View(perps[p]).reserves().trancheTokens;
            deal(CBBTC, perps[p], 1);
            deal(tranches[p], perps[p], 1);
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            assets[0] = tranches[p];
            amounts[0] = 1;
            vm.recordLogs();
            vm.prank(CONTROLLER);
            (bool success, bytes memory returnData) = perps[p].call(
                abi.encodeWithSignature(
                    "transferReservesTo(address,(uint256,(address,uint256)[]))",
                    USER,
                    _reserveAmounts(assets, amounts, 1)
                )
            );
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 syncCount;
            string memory syncTopics = "[";
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].topics.length == 0 || logs[i].topics[0] != RESERVE_SYNCED) continue;
                (address asset, uint256 amount) = abi.decode(logs[i].data, (address, uint256));
                if (syncCount != 0) syncTopics = string.concat(syncTopics, ",");
                syncTopics = string.concat(
                    syncTopics, "{\"asset\":\"", vm.toString(asset), "\",\"amount\":", vm.toString(amount), "}"
                );
                ++syncCount;
            }
            syncTopics = string.concat(syncTopics, "]");
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_transfer_reserves_order\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"selector\":\"",
                    vm.toString(_selector(returnData)),
                    "\",\"syncCount\":",
                    vm.toString(syncCount),
                    ",\"syncDataOrder\":",
                    syncTopics,
                    ",\"before\":\"",
                    _joinAddresses(beforeTokens),
                    "\",\"after\":\"",
                    _joinAddresses(IPerpRound4View(perps[p]).reserves().trancheTokens),
                    "}"
                )
            );
            require(vm.revertToState(snapshot), "transfer snapshot restore failed");
        }
    }

    function testRound4PerpFullTrancheTransferDeregistration() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        for (uint256 p; p < perps.length; ++p) {
            uint256 snapshot = vm.snapshotState();
            IPerpRound4View perp = IPerpRound4View(perps[p]);
            IPerpRound4View.ReserveData memory reserveBefore = perp.reserves();
            uint256 idleBefore = reserveBefore.underlyingBal;
            address[] memory tokensBefore = reserveBefore.trancheTokens;
            address selected;
            uint256 selectedBalance;
            for (uint256 i; i < tokensBefore.length; ++i) {
                uint256 balance = IERC20Round4Perp(tokensBefore[i]).balanceOf(perps[p]);
                if (balance > 0) {
                    selected = tokensBefore[i];
                    selectedBalance = balance;
                    break;
                }
            }
            require(selected != address(0), "no funded tranche in reserves");
            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            assets[0] = selected;
            amounts[0] = selectedBalance;
            vm.prank(CONTROLLER);
            (bool success, bytes memory returnData) = perps[p].call(
                abi.encodeWithSignature(
                    "transferReservesTo(address,(uint256,(address,uint256)[]))",
                    USER,
                    _reserveAmounts(assets, amounts, 0)
                )
            );
            IPerpRound4View.ReserveData memory reserveAfter = perp.reserves();
            uint256 idleAfter = reserveAfter.underlyingBal;
            address[] memory tokensAfter = reserveAfter.trancheTokens;
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_full_tranche_transfer\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"success\":",
                    vm.toString(success),
                    ",\"selector\":\"",
                    vm.toString(_selector(returnData)),
                    "\",\"token\":\"",
                    vm.toString(selected),
                    "\",\"balanceMoved\":",
                    vm.toString(selectedBalance),
                    ",\"idleBefore\":",
                    vm.toString(idleBefore),
                    ",\"idleAfter\":",
                    vm.toString(idleAfter),
                    ",\"tokensBefore\":\"",
                    _joinAddresses(tokensBefore),
                    "\",\"tokensAfter\":\"",
                    _joinAddresses(tokensAfter),
                    "\"}"
                )
            );
            require(vm.revertToState(snapshot), "full-transfer snapshot restore failed");
        }
    }

    function testRound4PerpMaxTrancheCount() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        for (uint256 p; p < perps.length; ++p) {
            uint256 snapshot = vm.snapshotState();
            IPerpRound4View perp = IPerpRound4View(perps[p]);
            uint256 maxCount = _readUint(perps[p], bytes4(0x650c699a));
            uint256 count = perp.reserves().trancheTokens.length;
            uint256 firstFailure = type(uint256).max;
            bytes4 firstSelector;
            for (uint256 i = count; i < maxCount; ++i) {
                bytes32 bondID = bytes32(uint256(100_000 + p * 1_000 + i));
                address fake = address(new Round4MockTranche(BONDS_MANAGER, bondID, p == 0));
                vm.mockCall(BONDS_MANAGER, abi.encodeWithSignature("isValidBond(bytes32)", bondID), abi.encode(true));
                vm.mockCall(
                    BONDS_MANAGER,
                    abi.encodeWithSignature(p == 0 ? "srTranche(bytes32)" : "jrTranche(bytes32)", bondID),
                    abi.encode(fake)
                );
                vm.prank(CONTROLLER);
                (bool success, bytes memory returnData) =
                    perps[p].call(abi.encodeWithSignature("registerTranche(address)", fake));
                if (!success) {
                    firstFailure = i;
                    firstSelector = _selector(returnData);
                    break;
                }
            }
            bytes32 extraBondID = bytes32(uint256(999_999 + p));
            address extra = address(new Round4MockTranche(BONDS_MANAGER, extraBondID, p == 0));
            vm.mockCall(BONDS_MANAGER, abi.encodeWithSignature("isValidBond(bytes32)", extraBondID), abi.encode(true));
            vm.mockCall(
                BONDS_MANAGER,
                abi.encodeWithSignature(p == 0 ? "srTranche(bytes32)" : "jrTranche(bytes32)", extraBondID),
                abi.encode(extra)
            );
            vm.prank(CONTROLLER);
            (bool extraSuccess, bytes memory extraReturn) =
                perps[p].call(abi.encodeWithSignature("registerTranche(address)", extra));
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_max_tranche_count\",\"perp\":\"",
                    vm.toString(perps[p]),
                    "\",\"maxTrancheCount\":",
                    vm.toString(maxCount),
                    ",\"initialCount\":",
                    vm.toString(count),
                    ",\"firstFailureIndex\":",
                    vm.toString(firstFailure),
                    ",\"firstFailureSelector\":\"",
                    vm.toString(firstSelector),
                    "\",\"countBeforeExtra\":",
                    vm.toString(perp.reserves().trancheTokens.length),
                    ",\"extraSuccess\":",
                    vm.toString(extraSuccess),
                    ",\"extraSelector\":\"",
                    vm.toString(_selector(extraReturn)),
                    "\",\"countAfterExtra\":",
                    vm.toString(perp.reserves().trancheTokens.length),
                    "}"
                )
            );
            require(vm.revertToState(snapshot), "max-count snapshot restore failed");
        }
    }

    function _probe(address perp, string memory callerLabel, address caller, string memory action, bytes memory data)
        private
    {
        uint256 snapshot = vm.snapshotState();
        if (keccak256(bytes(action)) == keccak256("burnFrom")) deal(perp, USER, 1);
        vm.prank(caller);
        (bool success, bytes memory returnData) = perp.call(data);
        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_perp_permission\",\"perp\":\"",
                vm.toString(perp),
                "\",\"action\":\"",
                action,
                "\",\"caller\":\"",
                callerLabel,
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returnData)),
                "\",\"returnLength\":",
                vm.toString(returnData.length),
                "}"
            )
        );
        if (keccak256(bytes(action)) == keccak256("updateController")) {
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_update_controller_effect\",\"perp\":\"",
                    vm.toString(perp),
                    "\",\"controller\":\"",
                    vm.toString(_readAddress(perp, bytes4(0xf77c4791))),
                    "\"}"
                )
            );
        }
        if (keccak256(bytes(action)) == keccak256("registerTranche")) {
            address[] memory trancheTokens = IPerpRound4View(perp).reserves().trancheTokens;
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_register_reserves\",\"perp\":\"",
                    vm.toString(perp),
                    "\",\"caller\":\"",
                    callerLabel,
                    "\",\"count\":",
                    vm.toString(trancheTokens.length),
                    ",\"tokens\":\"",
                    _joinAddresses(trancheTokens),
                    "\"}"
                )
            );
        }
        if (
            keccak256(bytes(action)) == keccak256("primeApproval")
                || keccak256(bytes(action)) == keccak256("revokeApproval")
        ) {
            console2.log(
                string.concat(
                    "OBS:{\"kind\":\"round4_approval_effect\",\"perp\":\"",
                    vm.toString(perp),
                    "\",\"action\":\"",
                    action,
                    "\",\"cbBTCToManager\":",
                    vm.toString(IERC20Round4Perp(CBBTC).allowance(perp, BONDS_MANAGER)),
                    "}"
                )
            );
        }
        require(vm.revertToState(snapshot), "matrix snapshot restore failed");
    }

    function _emptyReserveAmounts() private pure returns (ReserveAmounts memory amounts) {
        amounts.underlyingAmt = 0;
        amounts.trancheAmts = new TokenAmount[](0);
    }

    function _reserveAmounts(address[] memory assets, uint256[] memory amounts, uint256 underlying)
        private
        pure
        returns (ReserveAmounts memory reserveAmounts)
    {
        reserveAmounts.underlyingAmt = underlying;
        reserveAmounts.trancheAmts = _tokenAmounts(assets, amounts);
    }

    function _tokenAmounts(address[] memory assets, uint256[] memory amounts)
        private
        pure
        returns (TokenAmount[] memory rows)
    {
        rows = new TokenAmount[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            rows[i] = TokenAmount(assets[i], amounts[i]);
        }
    }

    function _joinAddresses(address[] memory accounts) private view returns (string memory result) {
        for (uint256 i; i < accounts.length; ++i) {
            if (i != 0) result = string.concat(result, ",");
            result = string.concat(result, vm.toString(accounts[i]));
        }
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    function _readAddress(address target, bytes4 selector) private view returns (address result) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && data.length >= 32, "address getter failed");
        result = abi.decode(data, (address));
    }

    function _readUint(address target, bytes4 selector) private view returns (uint256 result) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        require(ok && data.length >= 32, "uint getter failed");
        result = abi.decode(data, (uint256));
    }

    function _selector(bytes memory returnData) private pure returns (bytes4 selector) {
        if (returnData.length >= 4) {
            assembly {
                selector := mload(add(returnData, 32))
            }
        }
    }
}
