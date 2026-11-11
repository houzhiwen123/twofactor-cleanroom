// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

struct R7TrancheData {
    uint256 trancheSupply;
    uint256 trancheClaim;
    uint256 totalClaim;
    uint256 volatilityMultiplier;
    uint256 underlyingOpenPrice;
    bool isMature;
    uint64 secondsToMaturity;
    uint64 trancheRatio;
    uint64 valueRatio;
    bytes32 bondID;
    bool isSenior;
    address tranche;
    address counterpart;
    address manager;
}

struct R7ReserveTrancheData {
    R7TrancheData data;
    uint256 balance;
    uint256 value;
}

struct R7RichReserveData {
    uint256 underlyingBal;
    R7ReserveTrancheData[] trancheData;
}

struct R7TokenAmount {
    address token;
    uint256 amount;
}

struct R7ReserveTokens {
    uint256 underlyingBal;
    R7TokenAmount[] trancheTokens;
}

struct R7ReserveAmounts {
    uint256 underlyingAmt;
    R7TokenAmount[] trancheAmts;
}

struct R7OwnershipObservation {
    address owner;
    address initialPendingOwner;
    address proposedOwner;
    address pendingAfterTransfer;
    address ownerAfterAccept;
    address ownerAfterRenounce;
    bool transferSuccess;
    bytes4 transferSelector;
    bool randomAcceptSuccess;
    bytes4 randomAcceptSelector;
    bool acceptSuccess;
    bytes4 acceptSelector;
    bool renounceSuccess;
    bytes4 renounceSelector;
}

interface IR7Controller {
    struct BondInfo {
        address manager;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
    }

    function latestBondInfo() external view returns (BondInfo memory);
}

interface IR7ControllerAdmin {
    function owner() external view returns (address);
    function keeper() external view returns (address);
    function feePolicy() external view returns (address);
    function balancer() external view returns (address);
    function issuer() external view returns (address);
    function underlyingOracle() external view returns (address);
    function targetSystemRatio() external view returns (uint256);
    function targetPerpJrVM() external view returns (uint256);
    function valueCap() external view returns (uint256);
    function minCleanupVal() external view returns (uint256);
    function perpJrReservedUnderlyingAmt() external view returns (uint256);
    function perpJrReservedUnderlyingPerc() external view returns (uint64);
    function minMaturitySec() external view returns (uint32);
    function rebalanceFreqSec() external view returns (uint32);
    function lastRebalanceTimestampSec() external view returns (uint64);
    function rebalanceWindow(uint256 timestamp) external view returns (uint64 start, uint64 end);
}

interface IR7ControllerOps {
    struct FeePerc {
        uint256 totalFeePerc;
        uint256 protocolFeePerc;
    }

    function flashMint2(uint256 srUnderlying, uint256 jrUnderlying, uint256 minSr, uint256 minJr)
        external
        returns (uint256 srMinted, uint256 jrMinted, FeePerc memory srFees, FeePerc memory jrFees);
    function flashRedeem2(uint256 srRedeemed, uint256 jrRedeemed, uint256 minUnderlying)
        external
        returns (uint256 underlyingOut, FeePerc memory srFees, FeePerc memory jrFees);
    function rebalance() external;
}

interface IR7CachedOracle {
    function cachePrice() external;
}

interface IR7ERC20 {
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract Round7ReviewProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant PERP_SR = 0x4be28E7597A928835245a10E9161E0c44687b70b;
    address private constant PERP_JR = 0x8cd04668292dC32F519972495C179E4f02C0e8AB;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant PRICE_FEED = 0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D;
    address private constant SEQUENCER_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    address private constant RANDOM = address(0xBEEF);
    address private constant TRANSFER_RECIPIENT = address(0xCAFE);
    address private constant TRANSFER_SPENDER = address(0xD00D);
    address private constant NEW_CONTROLLER = address(0xCA11B00B);
    address private constant TEST_KEEPER = address(0xCA11);
    bytes4 private constant RESERVE_DATA_SELECTOR = 0x289cc9c8;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testR7RawReserveABIs() public {
        _probeReserveABI(PERP_SR, "SR");
        _probeReserveABI(PERP_JR, "JR");
    }

    function testR7Ownable2StepHandoff() public {
        _probeOwnershipHandoff(PERP_SR);
        _probeOwnershipHandoff(PERP_JR);
    }

    function testR7ControllerReplacementPermissionMatrix() public {
        IR7Controller.BondInfo memory latest = IR7Controller(CONTROLLER).latestBondInfo();
        address[2] memory perps = [PERP_SR, PERP_JR];
        for (uint256 p; p < perps.length; ++p) {
            address perp = perps[p];
            address owner = _readAddress(perp, bytes4(0x8da5cb5b));
            address oldController = _readAddress(perp, bytes4(0xf77c4791));
            address[4] memory callers = [owner, oldController, NEW_CONTROLLER, RANDOM];
            string[4] memory callerNames = ["owner", "oldController", "newController", "random"];
            address tranche = p == 0 ? latest.srTranche : latest.jrTranche;
            for (uint256 c; c < callers.length; ++c) {
                _probeRole(perp, "updateController", callers[c], callerNames[c], owner, false, tranche);
                _probeRole(perp, "mintTo", callers[c], callerNames[c], owner, true, tranche);
                _probeRole(perp, "burnFrom", callers[c], callerNames[c], owner, true, tranche);
                _probeRole(perp, "registerTranche", callers[c], callerNames[c], owner, true, tranche);
                _probeRole(perp, "transferReservesTo", callers[c], callerNames[c], owner, true, tranche);
                _probeRole(perp, "handleTransferReservesIn", callers[c], callerNames[c], owner, true, tranche);
                _probeRole(perp, "logBalance", callers[c], callerNames[c], owner, true, tranche);
                if (p == 1) {
                    _probeRole(perp, "primeApproval", callers[c], callerNames[c], owner, true, tranche);
                    _probeRole(perp, "revokeApproval", callers[c], callerNames[c], owner, true, tranche);
                }
            }
        }
    }

    function testR7PerpHolderTransfers() public {
        address[2] memory perps = [PERP_SR, PERP_JR];
        for (uint256 i; i < perps.length; ++i) {
            address perp = perps[i];
            uint256 snapshot = vm.snapshotState();
            string memory expectedName = i == 0 ? "cbBTC Senior" : "cbBTC Junior";
            string memory expectedSymbol = i == 0 ? "cbBTC-SR" : "cbBTC-JR";
            require(IR7ERC20(perp).decimals() == 8, "unexpected Perp decimals");
            require(
                keccak256(bytes(IR7ERC20(perp).name())) == keccak256(bytes(expectedName)),
                "unexpected Perp name"
            );
            require(
                keccak256(bytes(IR7ERC20(perp).symbol())) == keccak256(bytes(expectedSymbol)),
                "unexpected Perp symbol"
            );
            deal(perp, RANDOM, 1_000);
            vm.prank(RANDOM);
            bool transferSuccess = IR7ERC20(perp).transfer(TRANSFER_RECIPIENT, 400);
            vm.prank(RANDOM);
            bool approveSuccess = IR7ERC20(perp).approve(TRANSFER_SPENDER, 500);
            vm.prank(TRANSFER_SPENDER);
            bool transferFromSuccess = IR7ERC20(perp).transferFrom(RANDOM, address(this), 300);
            _logHolderTransfer(perp, transferSuccess, approveSuccess, transferFromSuccess);
            require(transferSuccess && approveSuccess && transferFromSuccess, "ERC20 holder transfer failed");
            require(IR7ERC20(perp).balanceOf(RANDOM) == 300, "unexpected holder balance");
            require(IR7ERC20(perp).balanceOf(TRANSFER_RECIPIENT) == 400, "unexpected transfer balance");
            require(IR7ERC20(perp).balanceOf(address(this)) == 300, "unexpected transferFrom balance");
            require(vm.revertToState(snapshot), "transfer snapshot restore failed");
        }
    }

    function testR7ControllerAdminAuthMatrix() public {
        IR7ControllerAdmin controller = IR7ControllerAdmin(CONTROLLER);
        uint256 snapshot = vm.snapshotState();
        address owner = controller.owner();
        vm.prank(owner);
        (bool keeperUpdateSuccess,) = CONTROLLER.call(abi.encodeWithSignature("updateKeeper(address)", TEST_KEEPER));
        require(keeperUpdateSuccess, "could not set distinct test keeper");
        address keeper = controller.keeper();
        address random = address(0xBEEF);
        require(keeper == TEST_KEEPER && keeper != owner, "keeper is not distinct from owner");
        console2.log(
            string.concat(
                "OBS:R7_ADMIN_ROLES {\"owner\":\"",
                vm.toString(owner),
                "\",\"keeper\":\"",
                vm.toString(keeper),
                "\",\"random\":\"",
                vm.toString(random),
                "\"}"
            )
        );

        bytes[] memory calls = new bytes[](12);
        string[] memory names = new string[](12);
        calls[0] = abi.encodeWithSignature("pauseUserOps(bool)", false);
        names[0] = "pauseUserOps";
        calls[1] = abi.encodeWithSignature("pauseSystemOps(bool)", false);
        names[1] = "pauseSystemOps";
        calls[2] = abi.encodeWithSignature(
            "updateDRTargets(uint256,uint256)", controller.targetSystemRatio(), controller.targetPerpJrVM()
        );
        names[2] = "updateDRTargets";
        calls[3] = abi.encodeWithSignature("updateFeePolicy(address)", controller.feePolicy());
        names[3] = "updateFeePolicy";
        calls[4] = abi.encodeWithSignature("updateIssuer(address)", controller.issuer());
        names[4] = "updateIssuer";
        calls[5] = abi.encodeWithSignature("updateKeeper(address)", keeper);
        names[5] = "updateKeeper";
        calls[6] = abi.encodeWithSignature(
            "updateLiquidityThresholds(uint256,uint64)",
            controller.perpJrReservedUnderlyingAmt(),
            controller.perpJrReservedUnderlyingPerc()
        );
        names[6] = "updateLiquidityThresholds";
        calls[7] = abi.encodeWithSignature("updateMinCleanupVal(uint256)", controller.minCleanupVal());
        names[7] = "updateMinCleanupVal";
        calls[8] = abi.encodeWithSignature("updatePerpBalancer(address)", controller.balancer());
        names[8] = "updatePerpBalancer";
        calls[9] = abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 3_600);
        names[9] = "updateRebalanceWindow";
        calls[10] = abi.encodeWithSignature("updateRolloverEligibility(uint32)", controller.minMaturitySec());
        names[10] = "updateRolloverEligibility";
        calls[11] = abi.encodeWithSignature("updateValueCap(uint256)", controller.valueCap());
        names[11] = "updateValueCap";

        bytes4 unauthorizedSelector = bytes4(keccak256("UnauthorizedCall()"));
        bytes4 ownableUnauthorizedSelector = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
        for (uint256 i; i < calls.length; ++i) {
            bool keeperOnly = i == 0 || i == 1 || i == 11;
            bytes4 deniedSelector = keeperOnly ? unauthorizedSelector : ownableUnauthorizedSelector;
            _probeAdminCall(names[i], "owner", owner, calls[i], !keeperOnly, deniedSelector);
            _probeAdminCall(names[i], "keeper", keeper, calls[i], keeperOnly, deniedSelector);
            _probeAdminCall(names[i], "random", random, calls[i], false, deniedSelector);
        }
        require(vm.revertToState(snapshot), "admin matrix snapshot restore failed");
    }

    function testR7ControllerSetterValidation() public {
        bytes4 invalidParam = bytes4(keccak256("InvalidParamDefn()"));
        bytes4 invalidPerc = bytes4(keccak256("InvalidPerc()"));
        _probeAdminValidation(
            "rebalance_freq_zero",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 0, 0, 1),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "rebalance_offset_at_freq",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_400, 3_600),
            true,
            bytes4(0)
        );
        _probeAdminValidation(
            "rebalance_offset_over_freq",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 86_401, 3_600),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "rebalance_length_zero",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 0),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "rebalance_length_over_freq",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 86_401),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "rebalance_valid",
            abi.encodeWithSignature("updateRebalanceWindow(uint32,uint32,uint32)", 86_400, 64_800, 3_600),
            true,
            bytes4(0)
        );
        _probeAdminValidation(
            "liquidity_perc_over_wad",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 0, 1e18 + 1),
            false,
            invalidPerc
        );
        _probeAdminValidation(
            "liquidity_perc_wad",
            abi.encodeWithSignature("updateLiquidityThresholds(uint256,uint64)", 0, 1e18),
            true,
            bytes4(0)
        );
        _probeAdminValidation(
            "dr_system_zero",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", 0, 1e18),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "dr_jr_zero",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", 1e18, 0),
            false,
            invalidParam
        );
        _probeAdminValidation(
            "dr_both_zero",
            abi.encodeWithSignature("updateDRTargets(uint256,uint256)", 0, 0),
            false,
            invalidParam
        );
        IR7ControllerAdmin controller = IR7ControllerAdmin(CONTROLLER);
        _probeAdminValidation(
            "dr_valid",
            abi.encodeWithSignature(
                "updateDRTargets(uint256,uint256)", controller.targetSystemRatio(), controller.targetPerpJrVM()
            ),
            true,
            bytes4(0)
        );
    }

    function testR7RebalanceSettlementPlanAumOrder() public {
        IR7ControllerAdmin controller = IR7ControllerAdmin(CONTROLLER);
        address feePolicy = controller.feePolicy();
        bytes4 opFeesSelector = bytes4(keccak256("computeOpFees((bool,bool,(uint256,uint256,uint256,uint256)))"));
        vm.mockCall(feePolicy, abi.encodePacked(opFeesSelector), abi.encode(uint256(1e15), uint256(0)));
        vm.mockCall(
            feePolicy,
            abi.encodeWithSignature("computeRebalanceVal(uint256,uint256,uint256)"),
            abi.encode(uint256(100), false)
        );
        vm.mockCall(feePolicy, abi.encodeWithSignature("perpSrAUMFeePerc()"), abi.encode(uint64(1e17)));
        vm.mockCall(feePolicy, abi.encodeWithSignature("perpJrAUMFeePerc()"), abi.encode(uint64(5e16)));

        uint256 initialTimestamp = block.timestamp;
        _refreshForkPrice(initialTimestamp);
        deal(CBBTC, RANDOM, 10_000_000);
        vm.prank(RANDOM);
        IR7ERC20(CBBTC).approve(CONTROLLER, type(uint256).max);
        vm.prank(RANDOM);
        (uint256 srMinted, uint256 jrMinted,,) = IR7ControllerOps(CONTROLLER).flashMint2(1_000_000, 1_000_000, 0, 0);
        vm.prank(RANDOM);
        IR7ControllerOps(CONTROLLER).flashRedeem2(srMinted / 10, jrMinted / 10, 0);

        uint256 srFees = _readUint(CONTROLLER, abi.encodeWithSignature("collectedFeeBal(address)", PERP_SR));
        uint256 jrFees = _readUint(CONTROLLER, abi.encodeWithSignature("collectedFeeBal(address)", PERP_JR));
        uint256 underlyingFees = _readUint(CONTROLLER, abi.encodeWithSignature("collectedFeeBal(address)", CBBTC));
        require(srFees != 0 && jrFees != 0 && underlyingFees != 0, "fee balances must be nonzero");

        uint256 frequency = controller.rebalanceFreqSec();
        uint256 minAllowedTimestamp = uint256(controller.lastRebalanceTimestampSec()) + frequency;
        uint256 candidate = block.timestamp + frequency * 3;
        if (candidate < minAllowedTimestamp) candidate = minAllowedTimestamp;
        (uint64 windowStart,) = controller.rebalanceWindow(candidate);
        while (windowStart < minAllowedTimestamp) {
            candidate += frequency;
            (windowStart,) = controller.rebalanceWindow(candidate);
        }
        vm.warp(windowStart);
        _refreshForkPrice(windowStart);

        console2.log(
            string.concat(
                "OBS:R7_REBALANCE_ORDER_INPUT {\"srCollected\":",
                vm.toString(srFees),
                ",\"jrCollected\":",
                vm.toString(jrFees),
                ",\"cbBtcCollected\":",
                vm.toString(underlyingFees),
                ",\"rebalancePlanValue\":100,\"srAumFeePerc\":100000000000000000,\"jrAumFeePerc\":50000000000000000,"
                "\"timestamp\":",
                vm.toString(windowStart),
                "}"
            )
        );
        vm.recordLogs();
        IR7ControllerOps(CONTROLLER).rebalance();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        bytes32 rebalanceTopic = keccak256("Rebalance(uint256,bool)");
        bytes32 aumTopic = keccak256("AumFees(address,uint256)");
        bytes32 reserveSyncedTopic = keccak256("ReserveSynced(address,uint256)");
        uint256 srBurnIndex = type(uint256).max;
        uint256 jrBurnIndex = type(uint256).max;
        uint256 cbBtcFeeTransferIndex = type(uint256).max;
        uint256 rebalanceIndex = type(uint256).max;
        uint256 reserveTransferIndex = type(uint256).max;
        uint256 srAumIndex = type(uint256).max;
        uint256 jrAumIndex = type(uint256).max;
        uint256 aumCount;
        uint256 reserveSyncedCount;

        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length == 0) continue;
            if (
                (entry.emitter == PERP_SR || entry.emitter == PERP_JR) && entry.topics[0] == reserveSyncedTopic
            ) {
                (address token, uint256 balance) = abi.decode(entry.data, (address, uint256));
                require(token != address(0), "zero ReserveSynced token");
                ++reserveSyncedCount;
                console2.log(
                    string.concat(
                        "OBS:R7_RESERVE_SYNC {\"index\":",
                        vm.toString(i),
                        ",\"perp\":\"",
                        vm.toString(entry.emitter),
                        "\",\"token\":\"",
                        vm.toString(token),
                        "\",\"balance\":",
                        vm.toString(balance),
                        "}"
                    )
                );
            }
            if (entry.topics[0] == transferTopic && entry.topics.length == 3) {
                address from = address(uint160(uint256(entry.topics[1])));
                address to = address(uint160(uint256(entry.topics[2])));
                uint256 amount = abi.decode(entry.data, (uint256));
                if (entry.emitter == PERP_SR && from == CONTROLLER && to == address(0)) {
                    srBurnIndex = i;
                    _logRebalanceOrderEvent(i, "feePerpBurnSR", PERP_SR, amount);
                }
                if (entry.emitter == PERP_JR && from == CONTROLLER && to == address(0)) {
                    jrBurnIndex = i;
                    _logRebalanceOrderEvent(i, "feePerpBurnJR", PERP_JR, amount);
                }
                if (entry.emitter == CBBTC && from == CONTROLLER && to == PERP_JR && amount == underlyingFees) {
                    cbBtcFeeTransferIndex = i;
                    _logRebalanceOrderEvent(i, "cbBtcFeeTransferToJR", CBBTC, amount);
                }
                if (entry.emitter == CBBTC && from == PERP_JR && to == PERP_SR && amount != 0) {
                    reserveTransferIndex = i;
                    _logRebalanceOrderEvent(i, "reserveTransferJRtoSR", CBBTC, amount);
                }
            }
            if (entry.emitter == CONTROLLER && entry.topics[0] == rebalanceTopic) {
                rebalanceIndex = i;
                (uint256 rebalanceValue, bool srPays) = abi.decode(entry.data, (uint256, bool));
                require(rebalanceValue == 100 && !srPays, "unexpected rebalance event");
                _logRebalanceOrderEvent(i, "Rebalance", CONTROLLER, rebalanceValue);
            }
            if (entry.emitter == CONTROLLER && entry.topics[0] == aumTopic) {
                ++aumCount;
                address token = address(uint160(uint256(entry.topics[1])));
                uint256 amount = abi.decode(entry.data, (uint256));
                require(amount != 0, "AUM fee must be nonzero");
                if (token == PERP_SR) {
                    srAumIndex = i;
                    _logRebalanceOrderEvent(i, "AumFeesSR", token, amount);
                }
                if (token == PERP_JR) {
                    jrAumIndex = i;
                    _logRebalanceOrderEvent(i, "AumFeesJR", token, amount);
                }
            }
        }

        require(srBurnIndex < cbBtcFeeTransferIndex, "SR fee burn order");
        require(jrBurnIndex < cbBtcFeeTransferIndex, "JR fee burn order");
        require(cbBtcFeeTransferIndex < rebalanceIndex, "cbBTC fee transfer order");
        require(rebalanceIndex < reserveTransferIndex, "reserve transfer order");
        require(reserveTransferIndex < srAumIndex, "SR AUM order");
        require(srAumIndex < jrAumIndex && aumCount == 2, "JR AUM order");
        require(reserveSyncedCount != 0, "missing ReserveSynced");
    }

    function decodeReserves(bytes calldata returndata)
        external
        pure
        returns (uint256 underlyingBal, R7TokenAmount[] memory trancheTokens)
    {
        R7ReserveTokens memory result = abi.decode(returndata, (R7ReserveTokens));
        return (result.underlyingBal, result.trancheTokens);
    }

    function _refreshForkPrice(uint256 timestamp) private {
        bytes4 latestRoundDataSelector = bytes4(keccak256("latestRoundData()"));
        vm.mockCall(
            PRICE_FEED,
            abi.encodeWithSelector(latestRoundDataSelector),
            abi.encode(uint80(1), int256(7_482_940_645_796), timestamp, timestamp, uint80(1))
        );
        uint256 startedAt = timestamp > 3_601 ? timestamp - 3_601 : 0;
        vm.mockCall(
            SEQUENCER_FEED,
            abi.encodeWithSelector(latestRoundDataSelector),
            abi.encode(uint80(1), int256(0), startedAt, timestamp, uint80(1))
        );
        address oracle = IR7ControllerAdmin(CONTROLLER).underlyingOracle();
        require(oracle != address(0), "underlying oracle missing");
        vm.prank(RANDOM);
        IR7CachedOracle(oracle).cachePrice();
    }

    function _logRebalanceOrderEvent(uint256 index, string memory kind, address emitter, uint256 amount) private {
        console2.log(
            string.concat(
                "OBS:R7_REBALANCE_ORDER_EVENT {\"index\":",
                vm.toString(index),
                ",\"kind\":\"",
                kind,
                "\",\"emitter\":\"",
                vm.toString(emitter),
                "\",\"amount\":",
                vm.toString(amount),
                "}"
            )
        );
    }

    function decodeRichReserveData(bytes calldata returndata)
        external
        pure
        returns (uint256 underlyingBal, uint256 trancheCount)
    {
        R7RichReserveData memory result = abi.decode(returndata, (R7RichReserveData));
        return (result.underlyingBal, result.trancheData.length);
    }

    function _probeReserveABI(address perp, string memory label) private {
        (bool reservesOk, bytes memory reservesData) =
            perp.staticcall(abi.encodeWithSelector(bytes4(keccak256("reserves()"))));
        _logRaw(perp, label, "reserves", reservesOk, reservesData);
        if (reservesOk) {
            try this.decodeReserves(reservesData) returns (
                uint256 underlyingBal,
                R7TokenAmount[] memory tokenAmounts
            ) {
                console2.log(
                    string.concat(
                        "OBS:R7_RESERVES_DECODE {\"perp\":\"",
                        vm.toString(perp),
                        "\",\"underlyingBal\":",
                        vm.toString(underlyingBal),
                        ",\"count\":",
                        vm.toString(tokenAmounts.length),
                        "}"
                    )
                );
                for (uint256 i; i < tokenAmounts.length; ++i) {
                    console2.log(
                        string.concat(
                            "OBS:R7_RESERVE_TOKEN {\"perp\":\"",
                            vm.toString(perp),
                            "\",\"index\":",
                            vm.toString(i),
                            ",\"token\":\"",
                            vm.toString(tokenAmounts[i].token),
                            "\",\"amount\":",
                            vm.toString(tokenAmounts[i].amount),
                            "}"
                        )
                    );
                }
            } catch (bytes memory reason) {
                console2.log(
                    string.concat(
                        "OBS:R7_RESERVES_DECODE_FAILED {\"perp\":\"",
                        vm.toString(perp),
                        "\",\"reason\":\"",
                        vm.toString(reason),
                        "\"}"
                    )
                );
            }
        }

        (bool reserveDataOk, bytes memory reserveDataBytes) =
            perp.staticcall(abi.encodeWithSelector(RESERVE_DATA_SELECTOR));
        _logRaw(perp, label, "reserveData", reserveDataOk, reserveDataBytes);
        if (reserveDataOk) {
            try this.decodeRichReserveData(reserveDataBytes) returns (uint256 underlyingBal, uint256 trancheCount) {
                console2.log(
                    string.concat(
                        "OBS:R7_RICH_DECODE {\"perp\":\"",
                        vm.toString(perp),
                        "\",\"underlyingBal\":",
                        vm.toString(underlyingBal),
                        ",\"trancheCount\":",
                        vm.toString(trancheCount),
                        "}"
                    )
                );
            } catch (bytes memory reason) {
                console2.log(
                    string.concat(
                        "OBS:R7_RICH_DECODE_FAILED {\"perp\":\"",
                        vm.toString(perp),
                        "\",\"reason\":\"",
                        vm.toString(reason),
                        "\"}"
                    )
                );
            }
        }
    }

    function _logRaw(address perp, string memory label, string memory method, bool success, bytes memory returndata)
        private
    {
        console2.log(
            string.concat(
                "OBS:R7_RAW {\"label\":\"",
                label,
                "\",\"perp\":\"",
                vm.toString(perp),
                "\",\"method\":\"",
                method,
                "\",\"success\":",
                vm.toString(success),
                ",\"length\":",
                vm.toString(returndata.length),
                "}"
            )
        );
        console2.logBytes(returndata);
        for (uint256 i; i < returndata.length / 32; ++i) {
            bytes32 word;
            assembly ("memory-safe") {
                word := mload(add(add(returndata, 0x20), mul(i, 0x20)))
            }
            console2.log(
                string.concat(
                    "OBS:R7_WORD {\"label\":\"",
                    label,
                    "\",\"method\":\"",
                    method,
                    "\",\"index\":",
                    vm.toString(i),
                    ",\"value\":\"",
                    vm.toString(uint256(word)),
                    "\"}"
                )
            );
        }
    }

    function _probeAdminCall(
        string memory method,
        string memory callerName,
        address caller,
        bytes memory callData,
        bool expectedSuccess,
        bytes4 expectedSelector
    ) private
    {
        uint256 snapshot = vm.snapshotState();
        vm.prank(caller);
        (bool success, bytes memory returndata) = CONTROLLER.call(callData);
        console2.log(
            string.concat(
                "OBS:R7_ADMIN_CALL {\"method\":\"",
                method,
                "\",\"caller\":\"",
                callerName,
                "\",\"callerAddress\":\"",
                vm.toString(caller),
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returndata)),
                "\",\"returnLength\":",
                vm.toString(returndata.length),
                "}"
            )
        );
        require(success == expectedSuccess, "unexpected admin authorization result");
        if (!expectedSuccess) require(_selector(returndata) == expectedSelector, "unexpected admin selector");
        require(vm.revertToState(snapshot), "admin snapshot restore failed");
    }

    function _probeAdminValidation(
        string memory caseName,
        bytes memory callData,
        bool expectedSuccess,
        bytes4 expectedSelector
    ) private {
        uint256 snapshot = vm.snapshotState();
        address owner = IR7ControllerAdmin(CONTROLLER).owner();
        vm.prank(owner);
        (bool success, bytes memory returndata) = CONTROLLER.call(callData);
        console2.log(
            string.concat(
                "OBS:R7_ADMIN_VALIDATION {\"case\":\"",
                caseName,
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returndata)),
                "\",\"returnLength\":",
                vm.toString(returndata.length),
                "}"
            )
        );
        require(success == expectedSuccess, "unexpected setter validation result");
        if (!expectedSuccess) require(_selector(returndata) == expectedSelector, "unexpected setter selector");
        require(vm.revertToState(snapshot), "validation snapshot restore failed");
    }

    function _probeRole(
        address perp,
        string memory action,
        address caller,
        string memory callerName,
        address owner,
        bool updateControllerFirst,
        address tranche
    ) private {
        uint256 snapshot = vm.snapshotState();
        if (updateControllerFirst) {
            vm.prank(owner);
            (bool updateSuccess, bytes memory updateReturndata) =
                perp.call(abi.encodeWithSignature("updateController(address)", NEW_CONTROLLER));
            require(
                updateSuccess,
                string.concat("controller replacement failed: ", vm.toString(_selector(updateReturndata)))
            );
        }

        bytes memory callData;
        if (keccak256(bytes(action)) == keccak256("updateController")) {
            callData = abi.encodeWithSignature("updateController(address)", address(0xDAD));
        } else if (keccak256(bytes(action)) == keccak256("mintTo")) {
            callData = abi.encodeWithSignature("mintTo(address,uint256)", RANDOM, 0);
        } else if (keccak256(bytes(action)) == keccak256("burnFrom")) {
            callData = abi.encodeWithSignature("burnFrom(address,uint256)", RANDOM, 0);
        } else if (keccak256(bytes(action)) == keccak256("registerTranche")) {
            callData = abi.encodeWithSignature("registerTranche(address)", tranche);
        } else if (keccak256(bytes(action)) == keccak256("transferReservesTo")) {
            R7ReserveAmounts memory amounts;
            amounts.trancheAmts = new R7TokenAmount[](0);
            callData =
                abi.encodeWithSignature("transferReservesTo(address,(uint256,(address,uint256)[]))", RANDOM, amounts);
        } else if (keccak256(bytes(action)) == keccak256("handleTransferReservesIn")) {
            R7ReserveAmounts memory amounts;
            amounts.trancheAmts = new R7TokenAmount[](0);
            callData = abi.encodeWithSignature("handleTransferReservesIn((uint256,(address,uint256)[]))", amounts);
        } else if (keccak256(bytes(action)) == keccak256("logBalance")) {
            callData = abi.encodeWithSignature("logBalance(address)", CBBTC);
        } else if (keccak256(bytes(action)) == keccak256("primeApproval")) {
            callData = abi.encodeWithSignature("primeApproval(address)", BONDS_MANAGER);
        } else {
            callData = abi.encodeWithSignature("revokeApproval(address)", BONDS_MANAGER);
        }

        vm.prank(caller);
        (bool success, bytes memory returndata) = perp.call(callData);
        console2.log(
            string.concat(
                "OBS:R7_PERP_ROLE {\"perp\":\"",
                vm.toString(perp),
                "\",\"action\":\"",
                action,
                "\",\"caller\":\"",
                callerName,
                "\",\"callerAddress\":\"",
                vm.toString(caller),
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(returndata)),
                "\",\"returnLength\":",
                vm.toString(returndata.length),
                "}"
            )
        );
        bool expectedSuccess = updateControllerFirst ? caller == NEW_CONTROLLER : caller == owner;
        require(success == expectedSuccess, "unexpected Perp role authorization result");
        if (!expectedSuccess) {
            bytes4 expectedSelector = updateControllerFirst
                ? bytes4(keccak256("UnauthorizedCall()"))
                : bytes4(keccak256("OwnableUnauthorizedAccount(address)"));
            require(_selector(returndata) == expectedSelector, "unexpected Perp authorization selector");
        }
        require(vm.revertToState(snapshot), "permission snapshot restore failed");
    }

    function _logHolderTransfer(address perp, bool transferSuccess, bool approveSuccess, bool transferFromSuccess)
        private
        view
    {
        console2.log(
            string.concat(
                "OBS:R7_ERC20_TRANSFER {\"perp\":\"",
                vm.toString(perp),
                "\",\"name\":\"",
                IR7ERC20(perp).name(),
                "\",\"symbol\":\"",
                IR7ERC20(perp).symbol(),
                "\",\"decimals\":",
                vm.toString(uint256(IR7ERC20(perp).decimals())),
                ",\"transferSuccess\":",
                vm.toString(transferSuccess),
                ",\"approveSuccess\":",
                vm.toString(approveSuccess),
                ",\"transferFromSuccess\":",
                vm.toString(transferFromSuccess),
                ",\"holderBalance\":",
                vm.toString(IR7ERC20(perp).balanceOf(RANDOM)),
                ",\"recipientBalance\":",
                vm.toString(IR7ERC20(perp).balanceOf(TRANSFER_RECIPIENT)),
                ",\"transferFromRecipientBalance\":",
                vm.toString(IR7ERC20(perp).balanceOf(address(this))),
                "}"
            )
        );
    }

    function _probeOwnershipHandoff(address perp) private {
        uint256 snapshot = vm.snapshotState();
        R7OwnershipObservation memory observation;
        observation.owner = _readAddress(perp, bytes4(0x8da5cb5b));
        observation.proposedOwner = NEW_CONTROLLER;
        observation.initialPendingOwner = _readAddress(perp, bytes4(keccak256("pendingOwner()")));

        vm.prank(observation.owner);
        {
            (bool success, bytes memory returndata) =
                perp.call(abi.encodeWithSignature("transferOwnership(address)", observation.proposedOwner));
            observation.transferSuccess = success;
            observation.transferSelector = _selector(returndata);
        }
        observation.pendingAfterTransfer = _readAddress(perp, bytes4(keccak256("pendingOwner()")));

        vm.prank(RANDOM);
        {
            (bool success, bytes memory returndata) = perp.call(abi.encodeWithSignature("acceptOwnership()"));
            observation.randomAcceptSuccess = success;
            observation.randomAcceptSelector = _selector(returndata);
        }
        vm.prank(observation.proposedOwner);
        {
            (bool success, bytes memory returndata) = perp.call(abi.encodeWithSignature("acceptOwnership()"));
            observation.acceptSuccess = success;
            observation.acceptSelector = _selector(returndata);
        }
        observation.ownerAfterAccept = _readAddress(perp, bytes4(0x8da5cb5b));

        vm.prank(observation.proposedOwner);
        {
            (bool success, bytes memory returndata) = perp.call(abi.encodeWithSignature("renounceOwnership()"));
            observation.renounceSuccess = success;
            observation.renounceSelector = _selector(returndata);
        }
        observation.ownerAfterRenounce = _readAddress(perp, bytes4(0x8da5cb5b));
        _logOwnershipObservation(perp, observation);

        require(
            observation.transferSuccess && observation.pendingAfterTransfer == observation.proposedOwner,
            "two-step ownership proposal failed"
        );
        require(
            !observation.randomAcceptSuccess && observation.acceptSuccess
                && observation.ownerAfterAccept == observation.proposedOwner,
            "ownership acceptance mismatch"
        );
        require(
            observation.randomAcceptSelector == bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
            "unexpected acceptOwnership authorization selector"
        );
        require(
            observation.renounceSuccess && observation.ownerAfterRenounce == address(0),
            "ownership renunciation mismatch"
        );
        require(vm.revertToState(snapshot), "ownership snapshot restore failed");
    }

    function _logOwnershipObservation(address perp, R7OwnershipObservation memory o) private view {
        console2.log(
            string.concat(
                "OBS:R7_OWNABLE2STEP {\"perp\":\"",
                vm.toString(perp),
                "\",\"owner\":\"",
                vm.toString(o.owner),
                "\",\"pendingInitially\":\"",
                vm.toString(o.initialPendingOwner),
                "\",\"proposed\":\"",
                vm.toString(o.proposedOwner),
                "\",\"pendingAfterTransfer\":\"",
                vm.toString(o.pendingAfterTransfer),
                "\"}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R7_OWNABLE2STEP_CALLS {\"perp\":\"",
                vm.toString(perp),
                "\",\"transferSuccess\":",
                vm.toString(o.transferSuccess),
                ",\"transferSelector\":\"",
                vm.toString(o.transferSelector),
                "\",\"randomAcceptSuccess\":",
                vm.toString(o.randomAcceptSuccess),
                ",\"randomAcceptSelector\":\"",
                vm.toString(o.randomAcceptSelector),
                "\"}"
            )
        );
        console2.log(
            string.concat(
                "OBS:R7_OWNABLE2STEP_ACCEPT {\"perp\":\"",
                vm.toString(perp),
                "\",\"acceptSuccess\":",
                vm.toString(o.acceptSuccess),
                ",\"acceptSelector\":\"",
                vm.toString(o.acceptSelector),
                "\",\"ownerAfterAccept\":\"",
                vm.toString(o.ownerAfterAccept),
                "\",\"renounceSuccess\":",
                vm.toString(o.renounceSuccess),
                ",\"renounceSelector\":\"",
                vm.toString(o.renounceSelector),
                "\",\"ownerAfterRenounce\":\"",
                vm.toString(o.ownerAfterRenounce),
                "\"}"
            )
        );
    }

    function _readAddress(address target, bytes4 selector) private view returns (address result) {
        (bool success, bytes memory returndata) = target.staticcall(abi.encodeWithSelector(selector));
        require(success && returndata.length >= 32, "address read failed");
        result = abi.decode(returndata, (address));
    }

    function _readUint(address target, bytes memory callData) private view returns (uint256 result) {
        (bool success, bytes memory returndata) = target.staticcall(callData);
        require(success && returndata.length >= 32, "uint read failed");
        result = abi.decode(returndata, (uint256));
    }

    function _selector(bytes memory returndata) private pure returns (bytes4 result) {
        if (returndata.length >= 4) {
            assembly ("memory-safe") {
                result := mload(add(returndata, 0x20))
            }
        }
    }
}
