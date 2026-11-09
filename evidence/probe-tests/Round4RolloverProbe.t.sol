// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

interface IBalancerRound4Selection {
    struct TrancheData {
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

    struct ReserveTrancheData {
        TrancheData data;
        uint256 balance;
        uint256 value;
    }

    struct PerpSrRolloverState {
        uint256 staleUnderlyingBal;
        uint256 totalStaleVal;
        ReserveTrancheData[] staleSrTrs;
        ReserveTrancheData[] freshSrTrs;
    }

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct BondDepositParams {
        bytes32 bondID;
        uint256 underlyingAmt;
    }

    struct ReserveAmounts {
        uint256 underlyingAmt;
        TokenAmount[] trancheAmts;
    }

    struct RolloverExecution {
        ReserveAmounts stale;
        BondDepositParams[] freshBondDepositAmts;
        TokenAmount[] freshSrTrAmts;
        uint256 underlyingValRolled;
    }

    function computeRolloverPolicy(
        PerpSrRolloverState memory rolloverState,
        uint256[] memory unpairedStaleSrTrAmts,
        uint256 underlyingAmtAvail
    ) external pure returns (uint256 underlyingAmtToDeploy, RolloverExecution memory execution);

    function computeBackupRolloverPolicy(PerpSrRolloverState memory rolloverState, uint256 underlyingAmtAvail)
        external
        pure
        returns (RolloverExecution memory execution);
}

contract Round4BackupSelectionTest is Test {
    address private constant BALANCER = 0x30333a6B8744a1203D060E108dDC8C155059aCbf;
    address private constant BONDS_MANAGER = 0xe8c13955caED9c009fd2b335A10986407958fde3;
    uint256 private constant WAD = 1e18;
    uint256 private constant STALE_VALUE = 100_000_000;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), 54_990_962);
    }

    function testRound4BackupBondSelectionCandidates() public {
        _runCase(
            "base",
            [uint256(10_000_000), 11_000_000, 30_000_000],
            [uint64(0.3e18), 0.7e18, 0.9e18],
            [uint64(5 days), 2 days, 3 days]
        );
        _runCase(
            "maturity_reordered",
            [uint256(10_000_000), 11_000_000, 30_000_000],
            [uint64(0.3e18), 0.7e18, 0.9e18],
            [uint64(1 days), 3 days, 5 days]
        );
        _runCase(
            "ratios_reordered",
            [uint256(10_000_000), 11_000_000, 30_000_000],
            [uint64(0.7e18), 0.3e18, 0.9e18],
            [uint64(5 days), 2 days, 3 days]
        );
        _runCase(
            "values_reordered",
            [uint256(30_000_000), 10_000_000, 11_000_000],
            [uint64(0.3e18), 0.7e18, 0.9e18],
            [uint64(5 days), 2 days, 3 days]
        );
        _runCase(
            "price_down_30pct",
            [uint256(10_000_000), 11_000_000, 30_000_000],
            [uint64(0.7706e18), 0.7249e18, 0.7143e18],
            [uint64(5 days), 2 days, 3 days]
        );
        _runCase(
            "price_up_30pct",
            [uint256(10_000_000), 11_000_000, 30_000_000],
            [uint64(0.4149e18), 0.3903e18, 0.3846e18],
            [uint64(5 days), 2 days, 3 days]
        );
    }

    function _runCase(
        string memory label,
        uint256[3] memory values,
        uint64[3] memory valueRatios,
        uint64[3] memory maturities
    ) private {
        IBalancerRound4Selection.PerpSrRolloverState memory state;
        state.totalStaleVal = STALE_VALUE;
        state.staleSrTrs = new IBalancerRound4Selection.ReserveTrancheData[](1);
        state.staleSrTrs[0] = _row(bytes32("stale"), 1_000_000, 1_000_000, 0.5e18, 0.5e18, 0);
        state.freshSrTrs = new IBalancerRound4Selection.ReserveTrancheData[](3);
        for (uint256 i; i < 3; ++i) {
            bytes32 id = i == 0 ? bytes32("A") : i == 1 ? bytes32("B") : bytes32("C");
            state.freshSrTrs[i] = _row(id, values[i], values[i], valueRatios[i], 0.5e18, maturities[i]);
        }

        uint256[] memory unpaired = new uint256[](1);
        uint256 standardDeploy;
        IBalancerRound4Selection.RolloverExecution memory standard;
        (standardDeploy, standard) =
            IBalancerRound4Selection(BALANCER).computeRolloverPolicy(state, unpaired, 300_000_000);
        IBalancerRound4Selection.RolloverExecution memory backup =
            IBalancerRound4Selection(BALANCER).computeBackupRolloverPolicy(state, 300_000_000);

        uint256 selectedRatio;
        bytes32 selected;
        uint256 backupUnderlying;
        if (backup.freshBondDepositAmts.length != 0) {
            selected = backup.freshBondDepositAmts[0].bondID;
            backupUnderlying = backup.freshBondDepositAmts[0].underlyingAmt;
            for (uint256 i; i < 3; ++i) {
                if (state.freshSrTrs[i].data.bondID == selected) {
                    selectedRatio = state.freshSrTrs[i].data.valueRatio;
                    break;
                }
            }
        }

        uint256 minValueIndex = _minValue(values);
        uint256 minValuePerRatioIndex = _minValuePerRatio(values, valueRatios);
        uint256 maxRatioIndex = _maxRatio(valueRatios);
        uint256 nearestMaturityIndex = _minMaturity(maturities);
        uint256 averageTarget = _ceilDiv(STALE_VALUE + values[0] + values[1] + values[2], 3);
        uint256 target = averageTarget;
        if (values[0] > target) target = values[0];
        if (values[1] > target) target = values[1];
        uint256 standardFirstIndex = _firstTopUp(values, target);
        uint256 capByTwoS = 2 * STALE_VALUE;
        uint256 capFloorByRatio = selectedRatio == 0 ? 0 : STALE_VALUE * WAD / selectedRatio;
        uint256 capCeilByRatio = selectedRatio == 0 ? 0 : _ceilDiv(STALE_VALUE * WAD, selectedRatio);

        console2.log(
            string.concat(
                "OBS:{\"kind\":\"round4_backup_selection\",\"label\":\"",
                label,
                "\",\"rows\":",
                _rowsJson(values, valueRatios, maturities),
                ",\"totalStaleVal\":",
                vm.toString(STALE_VALUE),
                ",\"available\":300000000,\"standardDeploy\":",
                vm.toString(standardDeploy),
                ",\"standardDeposits\":",
                _depositsJson(standard.freshBondDepositAmts),
                ",\"backupSelected\":\"",
                vm.toString(selected),
                "\",\"backupUnderlying\":",
                vm.toString(backupUnderlying),
                ",\"selectedValueRatio\":",
                vm.toString(selectedRatio),
                ",\"cap2S\":",
                vm.toString(capByTwoS),
                ",\"capRatioFloor\":",
                vm.toString(capFloorByRatio),
                ",\"capRatioCeil\":",
                vm.toString(capCeilByRatio),
                ",\"candidates\":{\"latest\":\"C\",\"minValue\":\"",
                _id(minValueIndex),
                "\",\"minValuePerRatio\":\"",
                _id(minValuePerRatioIndex),
                "\",\"maxValueRatio\":\"",
                _id(maxRatioIndex),
                "\",\"standardFirstTopUp\":\"",
                _id(standardFirstIndex),
                "\",\"nearestMaturity\":\"",
                _id(nearestMaturityIndex),
                "\"}}"
            )
        );
    }

    function _row(bytes32 id, uint256 value, uint256 balance, uint64 valueRatio, uint64 trancheRatio, uint64 maturity)
        private
        pure
        returns (IBalancerRound4Selection.ReserveTrancheData memory result)
    {
        result.data = IBalancerRound4Selection.TrancheData({
            trancheSupply: balance,
            trancheClaim: balance,
            totalClaim: balance * 2,
            volatilityMultiplier: WAD,
            underlyingOpenPrice: 1e23,
            isMature: false,
            secondsToMaturity: maturity,
            trancheRatio: trancheRatio,
            valueRatio: valueRatio,
            bondID: id,
            isSenior: true,
            tranche: address(uint160(uint256(id))),
            counterpart: address(0),
            manager: BONDS_MANAGER
        });
        result.balance = balance;
        result.value = value;
    }

    function _rowsJson(uint256[3] memory values, uint64[3] memory ratios, uint64[3] memory maturities)
        private
        view
        returns (string memory)
    {
        return string.concat(
            "[{\"id\":\"A\",\"value\":",
            vm.toString(values[0]),
            ",\"vr\":",
            vm.toString(uint256(ratios[0])),
            ",\"maturity\":",
            vm.toString(uint256(maturities[0])),
            "},{\"id\":\"B\",\"value\":",
            vm.toString(values[1]),
            ",\"vr\":",
            vm.toString(uint256(ratios[1])),
            ",\"maturity\":",
            vm.toString(uint256(maturities[1])),
            "},{\"id\":\"C\",\"value\":",
            vm.toString(values[2]),
            ",\"vr\":",
            vm.toString(uint256(ratios[2])),
            ",\"maturity\":",
            vm.toString(uint256(maturities[2])),
            "}]"
        );
    }

    function _depositsJson(IBalancerRound4Selection.BondDepositParams[] memory deposits)
        private
        view
        returns (string memory result)
    {
        result = "[";
        for (uint256 i; i < deposits.length; ++i) {
            if (i != 0) result = string.concat(result, ",");
            result = string.concat(
                result,
                "{\"id\":\"",
                vm.toString(deposits[i].bondID),
                "\",\"underlying\":",
                vm.toString(deposits[i].underlyingAmt),
                "}"
            );
        }
        result = string.concat(result, "]");
    }

    function _minValue(uint256[3] memory values) private pure returns (uint256 index) {
        if (values[1] < values[index]) index = 1;
        if (values[2] < values[index]) index = 2;
    }

    function _minValuePerRatio(uint256[3] memory values, uint64[3] memory ratios) private pure returns (uint256 index) {
        for (uint256 i = 1; i < 3; ++i) {
            if (values[i] * ratios[index] < values[index] * ratios[i]) index = i;
        }
    }

    function _maxRatio(uint64[3] memory ratios) private pure returns (uint256 index) {
        if (ratios[1] > ratios[index]) index = 1;
        if (ratios[2] > ratios[index]) index = 2;
    }

    function _minMaturity(uint64[3] memory maturities) private pure returns (uint256 index) {
        if (maturities[1] < maturities[index]) index = 1;
        if (maturities[2] < maturities[index]) index = 2;
    }

    function _firstTopUp(uint256[3] memory values, uint256 target) private pure returns (uint256 index) {
        if (target > values[0]) return 0;
        if (target > values[1]) return 1;
        return 2;
    }

    function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
        return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
    }

    function _id(uint256 index) private pure returns (string memory) {
        return index == 0 ? "A" : index == 1 ? "B" : "C";
    }
}
