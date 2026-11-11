// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IControllerProbe, IFeePolicyProbe, IERC20Probe, IBondsManagerProbe} from "../probe-tests/ControllerProbe.t.sol";

interface IRound15Controller is IControllerProbe {
    function updateIssuer(address issuer_) external;
}

interface IRound15ERC20 is IERC20Probe {
    function allowance(address owner, address spender) external view returns (uint256);
}

contract Round15IssuerForwarder {
    address public immutable target;
    address public immutable managerOverride;
    bool public immutable overrideManager;

    constructor(address target_, address managerOverride_, bool overrideManager_) {
        target = target_;
        managerOverride = managerOverride_;
        overrideManager = overrideManager_;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (overrideManager && msg.sig == bytes4(keccak256("bondsManager()"))) {
            return abi.encode(managerOverride);
        }
        (bool success, bytes memory result) = target.staticcall(data);
        if (!success) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        return result;
    }
}

contract Round15ControllerGapProbe is Test {
    address private constant CONTROLLER = 0x682F3a053B0260daD4EbEee3924B1618B330A200;
    address private constant FEE_POLICY = 0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8;
    address private constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address private constant RANDOM = address(0xBEEF);
    address private constant WRONG_MANAGER = address(0xCAFE);
    uint256 private constant WAD = 1e18;
    uint256 private constant FORK_BLOCK = 54_990_962;

    IRound15Controller private controller;
    IFeePolicyProbe private feePolicy;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"), FORK_BLOCK);
        controller = IRound15Controller(CONTROLLER);
        feePolicy = IFeePolicyProbe(FEE_POLICY);
        assertEq(block.chainid, 8453);
    }

    function testRound15Mint2SrOnlyIgnoresZeroInputJrFee() public {
        _setFeePercs(false);
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            _depositLatestBond(1_000_000);
        _probeSingleSideMint("sr_only_high_jr_fee", srTranche, jrTranche, true);
    }

    function testRound15Mint2JrOnlyIgnoresZeroInputSrFee() public {
        _setFeePercs(true);
        (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche) =
            _depositLatestBond(1_000_000);
        _probeSingleSideMint("jr_only_high_sr_fee", srTranche, jrTranche, false);
    }

    function testRound15UpdateIssuerValidationMatrix() public {
        address currentIssuer = controller.issuer();
        address currentManager = _readAddress(currentIssuer, "bondsManager()");
        Round15IssuerForwarder transparent = new Round15IssuerForwarder(currentIssuer, address(0), false);
        Round15IssuerForwarder sameManager = new Round15IssuerForwarder(currentIssuer, currentManager, true);
        Round15IssuerForwarder zeroManager = new Round15IssuerForwarder(currentIssuer, address(0), true);
        Round15IssuerForwarder wrongManager = new Round15IssuerForwarder(currentIssuer, WRONG_MANAGER, true);

        _probeIssuer("current", currentIssuer);
        _probeIssuer("transparent_forwarder", address(transparent));
        _probeIssuer("same_manager_forwarder", address(sameManager));
        _probeIssuer("zero_manager_forwarder", address(zeroManager));
        _probeIssuer("wrong_manager_forwarder", address(wrongManager));
        _probeIssuer("zero", address(0));
        _probeIssuer("eoa", address(1));
    }

    function testRound15UpdateIssuerApprovalRotation() public {
        address currentIssuer = controller.issuer();
        address currentManager = _readAddress(currentIssuer, "bondsManager()");
        Round15IssuerForwarder wrongManager = new Round15IssuerForwarder(currentIssuer, WRONG_MANAGER, true);
        address perpJr = controller.perpJr();
        uint256 oldBefore = IRound15ERC20(CBBTC).allowance(perpJr, currentManager);
        uint256 newBefore = IRound15ERC20(CBBTC).allowance(perpJr, WRONG_MANAGER);
        vm.prank(controller.owner());
        controller.updateIssuer(address(wrongManager));
        uint256 oldAfter = IRound15ERC20(CBBTC).allowance(perpJr, currentManager);
        uint256 newAfter = IRound15ERC20(CBBTC).allowance(perpJr, WRONG_MANAGER);
        console2.log(
            string.concat(
                "OBS:R15_ISSUER_APPROVAL {\"oldBefore\":",
                vm.toString(oldBefore),
                ",\"newBefore\":",
                vm.toString(newBefore),
                ",\"oldAfter\":",
                vm.toString(oldAfter),
                ",\"newAfter\":",
                vm.toString(newAfter),
                "}"
            )
        );
        assertEq(controller.issuer(), address(wrongManager));
    }

    function _probeSingleSideMint(
        string memory label,
        IBondsManagerProbe.TokenAmount memory srTranche,
        IBondsManagerProbe.TokenAmount memory jrTranche,
        bool srInput
    ) private {
        vm.startPrank(RANDOM);
        IERC20Probe(srTranche.token).approve(CONTROLLER, type(uint256).max);
        IERC20Probe(jrTranche.token).approve(CONTROLLER, type(uint256).max);
        (bool success, bytes memory result) = CONTROLLER.call(
            abi.encodeWithSelector(
                IControllerProbe.mint2.selector,
                IControllerProbe.TokenAmount(srTranche.token, srInput ? srTranche.amount : 0),
                IControllerProbe.TokenAmount(jrTranche.token, srInput ? 0 : jrTranche.amount),
                0,
                0
            )
        );
        vm.stopPrank();

        bytes4 selector = _selector(result);
        uint256 srOut;
        uint256 jrOut;
        uint256 srFee;
        uint256 jrFee;
        if (success) {
            IControllerProbe.FeePerc memory srFeePerc;
            IControllerProbe.FeePerc memory jrFeePerc;
            (srOut, jrOut, srFeePerc, jrFeePerc) =
                abi.decode(result, (uint256, uint256, IControllerProbe.FeePerc, IControllerProbe.FeePerc));
            srFee = srFeePerc.totalFeePerc;
            jrFee = jrFeePerc.totalFeePerc;
        }
        console2.log(
            string.concat(
                "OBS:R15_MINT2_ZERO_SIDE {\"case\":\"",
                label,
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(selector),
                "\",\"srOut\":",
                vm.toString(srOut),
                ",\"jrOut\":",
                vm.toString(jrOut),
                ",\"srFee\":",
                vm.toString(srFee),
                ",\"jrFee\":",
                vm.toString(jrFee),
                "}"
            )
        );
        assertTrue(success, "single-side mint2 rejected the zero-input side fee");
        assertGt(srInput ? srOut : jrOut, 0, "active side minted no perp");
        assertEq(srInput ? srFee : jrFee, 0, "active side fee was not zero");
        assertEq(srInput ? jrFee : srFee, 0, "zero-input side fee was not zero");
    }

    function _depositLatestBond(uint256 amount)
        private
        returns (IBondsManagerProbe.TokenAmount memory srTranche, IBondsManagerProbe.TokenAmount memory jrTranche)
    {
        IControllerProbe.BondInfo memory info = controller.latestBondInfo();
        deal(CBBTC, RANDOM, amount);
        vm.startPrank(RANDOM);
        IERC20Probe(CBBTC).approve(info.manager, type(uint256).max);
        (srTranche, jrTranche) = IBondsManagerProbe(info.manager).deposit(info.bondID, amount);
        vm.stopPrank();
    }

    function _setFeePercs(bool srHigh) private {
        IFeePolicyProbe.PerpFeeParams memory sr = _zeroFeeCurves(feePolicy.perpSrFees());
        IFeePolicyProbe.PerpFeeParams memory jr = _zeroFeeCurves(feePolicy.perpJrFees());
        sr.basePerc = srHigh ? uint64(WAD) : 0;
        sr.flashBasePerc = srHigh ? uint64(WAD) : 0;
        jr.basePerc = srHigh ? 0 : uint64(WAD);
        jr.flashBasePerc = srHigh ? 0 : uint64(WAD);
        vm.prank(controller.owner());
        feePolicy.updateFeeParams(sr, jr);
    }

    function _zeroFeeCurves(IFeePolicyProbe.PerpFeeParams memory params)
        private
        pure
        returns (IFeePolicyProbe.PerpFeeParams memory)
    {
        params.subDRUp = _zeroCurve(params.subDRUp);
        params.subDRDown = _zeroCurve(params.subDRDown);
        params.vmDRUp = _zeroCurve(params.vmDRUp);
        params.vmDRDown = _zeroCurve(params.vmDRDown);
        return params;
    }

    function _zeroCurve(IFeePolicyProbe.Curve memory curve) private pure returns (IFeePolicyProbe.Curve memory) {
        curve.p1.y = 0;
        curve.p2.y = 0;
        curve.p3.y = 0;
        curve.p4.y = 0;
        return curve;
    }

    function _probeIssuer(string memory label, address candidate) private {
        uint256 snapshot = vm.snapshotState();
        vm.prank(controller.owner());
        (bool success, bytes memory result) =
            CONTROLLER.call(abi.encodeWithSelector(IRound15Controller.updateIssuer.selector, candidate));
        address stored = controller.issuer();
        console2.log(
            string.concat(
                "OBS:R15_ISSUER {\"case\":\"",
                label,
                "\",\"candidate\":\"",
                vm.toString(candidate),
                "\",\"success\":",
                vm.toString(success),
                ",\"selector\":\"",
                vm.toString(_selector(result)),
                "\",\"revertData\":\"",
                vm.toString(result),
                "\",\"stored\":\"",
                vm.toString(stored),
                "\"}"
            )
        );
        if (success) assertEq(stored, candidate, "successful issuer update stored another address");
        else assertEq(stored, controller.issuer(), "failed issuer update changed storage");
        require(vm.revertToState(snapshot), "issuer probe snapshot restore failed");
    }

    function _readAddress(address target, string memory signature) private view returns (address value) {
        (bool success, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        require(success && result.length >= 32, "address getter failed");
        value = abi.decode(result, (address));
    }

    function _selector(bytes memory data) private pure returns (bytes4 selector) {
        if (data.length < 4) return bytes4(0);
        assembly {
            selector := mload(add(data, 32))
        }
    }
}
