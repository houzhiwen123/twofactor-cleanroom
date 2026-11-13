// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {IUnderlyingPerpVault} from "../src/interfaces/IUnderlyingPerpVault.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

contract UnderlyingPerpVaultRealIntegrationTest is Test {
    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    uint256 private constant VAULT_SEED = 1_000_000;
    address private constant RECEIVER = address(0xBEEF);

    struct LocalSystem {
        MockERC20 underlying;
        MockPriceOracle oracle;
        BondsManager manager;
        BondIssuer issuer;
        PerpToken perpSr;
        PerpToken perpJr;
        PerpController controller;
        FeePolicy feePolicy;
        PerpBalancer balancer;
        GenesisSeeder seeder;
        bytes32 bondID;
        address srTranche;
        address jrTranche;
        uint256 srAmount;
        uint256 jrAmount;
    }

    function setUp() public {
        vm.warp(1_800_000_000);
    }

    function testRealComponentsSeniorMintRebalanceConservesAssetsAndAccountsFees() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        _configureCorrectiveTarget(vault, s.controller);

        (uint256 planned, bool isMinting) = vault.computeRebalanceAmount();
        assertTrue(isMinting);
        assertEq(planned, VAULT_SEED, "vault underlying must bind the mint capacity");

        (PerpController.SystemState memory beforeState,,) = s.controller.systemReserveState();
        uint256 trackedUnderlyingBefore = _trackedUnderlying(s, vault);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();
        uint256 vaultUnderlyingBefore = s.underlying.balanceOf(address(vault));
        uint256 vaultPerpBefore = s.perpSr.balanceOf(address(vault));
        uint256 controllerPerpBefore = s.perpSr.balanceOf(address(s.controller));
        uint256 supplyBefore = s.perpSr.totalSupply();

        vm.prank(address(0xCAFE));
        vault.rebalance();

        (PerpController.SystemState memory afterState,,) = s.controller.systemReserveState();
        uint256 supplyDelta = s.perpSr.totalSupply() - supplyBefore;
        uint256 vaultPerpDelta = s.perpSr.balanceOf(address(vault)) - vaultPerpBefore;
        uint256 controllerPerpDelta = s.perpSr.balanceOf(address(s.controller)) - controllerPerpBefore;

        assertEq(vaultUnderlyingBefore - s.underlying.balanceOf(address(vault)), planned);
        assertEq(afterState.perpSr.reserveValue - beforeState.perpSr.reserveValue, planned);
        assertGt(supplyDelta, 0);
        assertEq(vaultPerpDelta + controllerPerpDelta, supplyDelta, "all minted shares must be accounted");
        assertEq(_trackedUnderlying(s, vault), trackedUnderlyingBefore);
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore);
        assertGt(vault.lastRebalanceTimestampSec(), 0);
    }

    function testRealComponentsJuniorRedeemRebalanceConservesGrossAndBurnsExactShares() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, false);

        uint256 donatedPerp = s.perpJr.balanceOf(RECEIVER) / 20;
        vm.prank(RECEIVER);
        s.perpJr.transfer(address(vault), donatedPerp);
        _configureCorrectiveTarget(vault, s.controller);

        (uint256 planned, bool isMinting) = vault.computeRebalanceAmount();
        assertFalse(isMinting);
        assertGt(planned, 0);

        (PerpController.SystemState memory beforeState,,) = s.controller.systemReserveState();
        uint256 perpIn = Math.mulDiv(planned, beforeState.perpJr.totalSupply, beforeState.perpJr.reserveValue);
        uint256 grossUnderlying = Math.mulDiv(perpIn, beforeState.perpJr.reserveValue, beforeState.perpJr.totalSupply);
        uint256 trackedUnderlyingBefore = _trackedUnderlying(s, vault);
        uint256 underlyingSupplyBefore = s.underlying.totalSupply();
        uint256 vaultUnderlyingBefore = s.underlying.balanceOf(address(vault));
        uint256 controllerUnderlyingBefore = s.underlying.balanceOf(address(s.controller));
        uint256 vaultPerpBefore = s.perpJr.balanceOf(address(vault));
        uint256 supplyBefore = s.perpJr.totalSupply();

        vault.rebalance();

        (PerpController.SystemState memory afterState,,) = s.controller.systemReserveState();
        uint256 vaultUnderlyingDelta = s.underlying.balanceOf(address(vault)) - vaultUnderlyingBefore;
        uint256 controllerUnderlyingDelta = s.underlying.balanceOf(address(s.controller)) - controllerUnderlyingBefore;

        assertEq(vaultPerpBefore - s.perpJr.balanceOf(address(vault)), perpIn);
        assertEq(supplyBefore - s.perpJr.totalSupply(), perpIn);
        assertEq(beforeState.perpJr.reserveValue - afterState.perpJr.reserveValue, grossUnderlying);
        assertEq(
            vaultUnderlyingDelta + controllerUnderlyingDelta, grossUnderlying, "net output plus fee must equal gross"
        );
        assertEq(_trackedUnderlying(s, vault), trackedUnderlyingBefore);
        assertEq(s.underlying.totalSupply(), underlyingSupplyBefore);
    }

    function testRealControllerFailureRollsBackVaultAndSystemState() public {
        LocalSystem memory s = _deployLiveSystem();
        UnderlyingPerpVault vault = _deployVault(s, true);
        _configureCorrectiveTarget(vault, s.controller);
        (uint256 planned,) = vault.computeRebalanceAmount();
        assertGt(planned, 0);

        s.controller.pauseUserOps(true);
        bytes32 beforeFingerprint = _fingerprint(s, vault);

        vm.expectRevert(PerpController.UserOpsPaused.selector);
        vault.rebalance();

        assertEq(_fingerprint(s, vault), beforeFingerprint);
        assertEq(vault.lastRebalanceTimestampSec(), 0);
    }

    function _deployLiveSystem() private returns (LocalSystem memory s) {
        s.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        s.oracle = new MockPriceOracle(INITIAL_PRICE);

        Tranche trancheImplementation = new Tranche();
        BondsManager managerImplementation = new BondsManager();
        s.manager = BondsManager(
            address(
                new TransparentUpgradeableProxy(
                    address(managerImplementation),
                    address(this),
                    abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
                )
            )
        );
        s.manager.addAsset(address(s.underlying));
        s.manager.updateOracle(address(s.underlying), address(s.oracle));

        BondIssuer issuerImplementation = new BondIssuer();
        s.issuer = BondIssuer(
            address(
                new TransparentUpgradeableProxy(
                    address(issuerImplementation),
                    address(this),
                    abi.encodeCall(BondIssuer.init, (address(s.manager), address(s.underlying)))
                )
            )
        );
        s.manager.addIssuer(address(s.issuer));

        s.perpSr = new PerpToken(
            "Clean-room cbBTC Senior",
            "cr-cbBTC-SR",
            address(s.underlying),
            address(s.manager),
            address(0),
            false,
            address(this)
        );
        s.perpJr = new PerpToken(
            "Clean-room cbBTC Junior",
            "cr-cbBTC-JR",
            address(s.underlying),
            address(s.manager),
            address(0),
            true,
            address(this)
        );

        PerpController controllerImplementation = new PerpController();
        s.controller = PerpController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImplementation),
                    address(this),
                    abi.encodeCall(PerpController.init, (address(s.underlying), address(s.perpSr), address(s.perpJr)))
                )
            )
        );
        s.perpSr.updateController(address(s.controller));
        s.perpJr.updateController(address(s.controller));

        FeePolicy feeImplementation = new FeePolicy();
        s.feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        s.balancer = new PerpBalancer();
        s.controller.updateFeePolicy(address(s.feePolicy));
        s.controller.updatePerpBalancer(address(s.balancer));
        s.controller.updateIssuer(address(s.issuer));
        s.controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory info) = s.issuer.issue();
        assertTrue(issued);
        s.bondID = info.bondID;
        s.srTranche = info.srTranche;
        s.jrTranche = info.jrTranche;

        s.underlying.mint(address(this), INITIAL_UNDERLYING);
        s.underlying.approve(address(s.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            s.manager.deposit(s.bondID, INITIAL_UNDERLYING);
        s.srAmount = srInput.amount;
        s.jrAmount = jrInput.amount;

        s.seeder = new GenesisSeeder(address(this));
        s.underlying.mint(address(s.seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(s.srTranche).transfer(address(s.seeder), s.srAmount);
        IERC20(s.jrTranche).transfer(address(s.seeder), s.jrAmount);
        s.controller.updateKeeper(address(s.seeder));
        s.seeder.bootstrap(s.controller, s.srTranche, s.srAmount, s.jrTranche, s.jrAmount, MAX_JR_IDLE_TOP_UP, RECEIVER);
        s.controller.updateKeeper(address(this));
        s.controller.pauseUserOps(false);
    }

    function _deployVault(LocalSystem memory s, bool senior) private returns (UnderlyingPerpVault vault) {
        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            senior ? "Real SR Vault" : "Real JR Vault",
                            senior ? "rvSR" : "rvJR",
                            address(s.underlying),
                            address(s.controller),
                            senior,
                            senior
                        )
                    )
                )
            )
        );
        s.underlying.mint(address(this), VAULT_SEED);
        s.underlying.approve(address(vault), VAULT_SEED);
        vault.initDeposit(VAULT_SEED);
        vault.updateMinRebalanceAmt(1);
        vault.updateMaxFlashFeePerc(uint64(1e18));
    }

    function _configureCorrectiveTarget(UnderlyingPerpVault vault, PerpController controller) private {
        (uint256 subDr,) = controller.systemDeviations();
        uint96 target = uint96(subDr / 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
    }

    function _trackedUnderlying(LocalSystem memory s, UnderlyingPerpVault vault) private view returns (uint256) {
        return s.underlying.balanceOf(address(s.manager)) + s.underlying.balanceOf(address(s.perpSr))
            + s.underlying.balanceOf(address(s.perpJr)) + s.underlying.balanceOf(address(s.controller))
            + s.underlying.balanceOf(address(s.seeder)) + s.underlying.balanceOf(address(this))
            + s.underlying.balanceOf(RECEIVER) + s.underlying.balanceOf(address(vault));
    }

    function _fingerprint(LocalSystem memory s, UnderlyingPerpVault vault) private view returns (bytes32) {
        (PerpController.SystemState memory state,,) = s.controller.systemReserveState();
        return keccak256(
            abi.encode(
                state,
                s.underlying.balanceOf(address(vault)),
                s.perpSr.balanceOf(address(vault)),
                s.perpSr.totalSupply(),
                s.underlying.balanceOf(address(s.controller)),
                s.perpSr.balanceOf(address(s.controller)),
                vault.lastRebalanceTimestampSec()
            )
        );
    }
}
