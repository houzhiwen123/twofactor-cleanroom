// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {UnderlyingSingleAssetRouter} from "../src/router/UnderlyingSingleAssetRouter.sol";
import {UnderlyingPerpVault} from "../src/vault/UnderlyingPerpVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";

library OperationalFeeConfig {
    uint256 private constant WAD = 1e18;

    function flat(uint64 basePerc, uint64 flashBasePerc, uint64 impactPerc)
        internal
        pure
        returns (FeePolicy.Fees memory fees)
    {
        FeePolicy.Curve memory curve = FeePolicy.Curve({
            p1: FeePolicy.Point(0, impactPerc),
            p2: FeePolicy.Point(WAD, impactPerc),
            p3: FeePolicy.Point(2 * WAD, impactPerc),
            p4: FeePolicy.Point(3 * WAD, impactPerc)
        });
        fees = FeePolicy.Fees({
            subDRUp: curve,
            subDRDown: curve,
            vmDRUp: curve,
            vmDRDown: curve,
            basePerc: basePerc,
            flashBasePerc: flashBasePerc
        });
    }
}

abstract contract OperationalRealFixture is Test {
    uint256 internal constant INITIAL_UNDERLYING = 100_000_000;
    uint256 internal constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 internal constant INITIAL_PRICE = 80_000e18;
    uint256 internal constant VAULT_SEED = 1_000_000;
    address internal constant DEAD = address(0xdead);

    struct LocalSystem {
        MockERC20 underlying;
        MockPriceOracle oracle;
        BondsManager manager;
        BondIssuer issuer;
        PerpToken perpSr;
        PerpToken perpJr;
        FeePolicy feePolicy;
        PerpController controller;
        GenesisSeeder seeder;
    }

    LocalSystem internal system;
    UnderlyingPerpVault internal seniorVault;
    UnderlyingPerpVault internal juniorVault;
    UnderlyingSingleAssetRouter internal router;

    function _deployOperationalSystem(address genesisReceiver) internal {
        vm.warp(1_800_000_000);
        system.underlying = new MockERC20("cbBTC", "cbBTC", 8);
        system.oracle = new MockPriceOracle(INITIAL_PRICE);

        Tranche trancheImplementation = new Tranche();
        BondsManager managerImplementation = new BondsManager();
        system.manager = BondsManager(
            address(
                new TransparentUpgradeableProxy(
                    address(managerImplementation),
                    address(this),
                    abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
                )
            )
        );
        system.manager.addAsset(address(system.underlying));
        system.manager.updateOracle(address(system.underlying), address(system.oracle));

        BondIssuer issuerImplementation = new BondIssuer();
        system.issuer = BondIssuer(
            address(
                new TransparentUpgradeableProxy(
                    address(issuerImplementation),
                    address(this),
                    abi.encodeCall(BondIssuer.init, (address(system.manager), address(system.underlying)))
                )
            )
        );
        system.manager.addIssuer(address(system.issuer));

        system.perpSr = new PerpToken(
            "Clean-room cbBTC Senior",
            "cr-cbBTC-SR",
            address(system.underlying),
            address(system.manager),
            address(0),
            false,
            address(this)
        );
        system.perpJr = new PerpToken(
            "Clean-room cbBTC Junior",
            "cr-cbBTC-JR",
            address(system.underlying),
            address(system.manager),
            address(0),
            true,
            address(this)
        );

        PerpController controllerImplementation = new PerpController();
        system.controller = PerpController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImplementation),
                    address(this),
                    abi.encodeCall(
                        PerpController.init,
                        (address(system.underlying), address(system.perpSr), address(system.perpJr))
                    )
                )
            )
        );
        system.perpSr.updateController(address(system.controller));
        system.perpJr.updateController(address(system.controller));

        FeePolicy feeImplementation = new FeePolicy();
        system.feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), address(this), abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        system.controller.updateFeePolicy(address(system.feePolicy));
        system.controller.updatePerpBalancer(address(new PerpBalancer()));
        system.controller.updateIssuer(address(system.issuer));
        system.controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory firstBond) = system.issuer.issue();
        assertTrue(issued);
        system.underlying.mint(address(this), INITIAL_UNDERLYING);
        system.underlying.approve(address(system.manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            system.manager.deposit(firstBond.bondID, INITIAL_UNDERLYING);

        system.seeder = new GenesisSeeder(address(this));
        system.underlying.mint(address(system.seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(srInput.token).transfer(address(system.seeder), srInput.amount);
        IERC20(jrInput.token).transfer(address(system.seeder), jrInput.amount);
        system.controller.updateKeeper(address(system.seeder));
        system.seeder
            .bootstrap(
                system.controller,
                srInput.token,
                srInput.amount,
                jrInput.token,
                jrInput.amount,
                MAX_JR_IDLE_TOP_UP,
                genesisReceiver
            );
        system.controller.updateKeeper(address(this));
        system.controller.pauseUserOps(false);

        seniorVault = _deployUnderlyingVault(true);
        juniorVault = _deployUnderlyingVault(false);
        router = new UnderlyingSingleAssetRouter();
    }

    function _deployUnderlyingVault(bool senior) internal returns (UnderlyingPerpVault vault) {
        UnderlyingPerpVault implementation = new UnderlyingPerpVault();
        vault = UnderlyingPerpVault(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        UnderlyingPerpVault.init,
                        (
                            senior ? "Invariant SR Vault" : "Invariant JR Vault",
                            senior ? "iSR" : "iJR",
                            address(system.underlying),
                            address(system.controller),
                            senior,
                            senior
                        )
                    )
                )
            )
        );
        system.underlying.mint(address(this), VAULT_SEED);
        system.underlying.approve(address(vault), VAULT_SEED);
        vault.initDeposit(VAULT_SEED);
        vault.updateMinRebalanceAmt(1);
        vault.updateMaxFlashFeePerc(uint64(5e15));
    }

    function _trackedUnderlying(address handler, address[3] memory actors) internal view returns (uint256 total) {
        total = system.underlying.balanceOf(address(this)) + system.underlying.balanceOf(handler)
            + system.underlying.balanceOf(address(system.manager)) + system.underlying.balanceOf(address(system.issuer))
            + system.underlying.balanceOf(address(system.controller))
            + system.underlying.balanceOf(address(system.perpSr)) + system.underlying.balanceOf(address(system.perpJr))
            + system.underlying.balanceOf(address(system.seeder)) + system.underlying.balanceOf(address(seniorVault))
            + system.underlying.balanceOf(address(juniorVault)) + system.underlying.balanceOf(address(router));
        for (uint256 i; i < actors.length; ++i) {
            total += system.underlying.balanceOf(actors[i]);
        }
    }
}

contract OperationalStatefulHandler is Test {
    MockERC20 public immutable underlying;
    MockPriceOracle public immutable oracle;
    BondsManager public immutable manager;
    BondIssuer public immutable issuer;
    PerpToken public immutable perpSr;
    PerpToken public immutable perpJr;
    FeePolicy public immutable feePolicy;
    PerpController public immutable controller;
    UnderlyingPerpVault public immutable seniorVault;
    UnderlyingPerpVault public immutable juniorVault;
    UnderlyingSingleAssetRouter public immutable router;

    address[3] public actors = [address(0xA11CE), address(0xB0B), address(0xCA11)];
    bool public atomicityBroken;
    uint256 public successfulCalls;
    uint256 public revertedCalls;

    constructor(
        MockERC20 underlying_,
        MockPriceOracle oracle_,
        BondsManager manager_,
        BondIssuer issuer_,
        PerpToken perpSr_,
        PerpToken perpJr_,
        FeePolicy feePolicy_,
        PerpController controller_,
        UnderlyingPerpVault seniorVault_,
        UnderlyingPerpVault juniorVault_,
        UnderlyingSingleAssetRouter router_
    ) {
        underlying = underlying_;
        oracle = oracle_;
        manager = manager_;
        issuer = issuer_;
        perpSr = perpSr_;
        perpJr = perpJr_;
        feePolicy = feePolicy_;
        controller = controller_;
        seniorVault = seniorVault_;
        juniorVault = juniorVault_;
        router = router_;
    }

    function depositRouter(uint8 actorSeed, bool senior, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        uint256 amount = bound(uint256(rawAmount), 1, 2_000_000);
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(router), type(uint256).max);
        try router.depositUnderlying(address(vault), amount, 0, 2) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function redeemRouter(uint8 actorSeed, bool senior, uint96 rawNotes) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 notes = bound(uint256(rawNotes), 1, balance);
        vm.startPrank(actor);
        vault.approve(address(router), type(uint256).max);
        try router.redeemUnderlying(address(vault), notes, 0) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function directRedeem(uint8 actorSeed, bool senior, uint96 rawNotes) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 notes = bound(uint256(rawNotes), 1, balance);
        vm.prank(actor);
        try vault.redeem(notes) returns (uint256, uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
    }

    function directDeposit(uint8 actorSeed, bool senior, uint96 rawUnderlying) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        PerpToken perp = senior ? perpSr : perpJr;
        uint256 amount = bound(uint256(rawUnderlying), 1, 1_000_000);
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(vault), type(uint256).max);
        perp.approve(address(vault), type(uint256).max);
        try vault.deposit(amount, perp.balanceOf(actor)) returns (uint256) {
            successfulCalls += 1;
        } catch {
            revertedCalls += 1;
        }
        vm.stopPrank();
    }

    function donateUnderlying(uint8 actorSeed, uint8 destinationSeed, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 1, 500_000);
        underlying.mint(actor, amount);
        address destination;
        uint256 choice = uint256(destinationSeed) % 4;
        if (choice == 0) destination = address(seniorVault);
        else if (choice == 1) destination = address(juniorVault);
        else if (choice == 2) destination = address(perpSr);
        else destination = address(perpJr);
        vm.prank(actor);
        underlying.transfer(destination, amount);
    }

    function donatePerp(uint8 actorSeed, bool senior, bool toVault, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        PerpToken perp = senior ? perpSr : perpJr;
        uint256 balance = perp.balanceOf(actor);
        if (balance == 0) return;
        uint256 amount = bound(uint256(rawAmount), 1, balance);
        address destination = toVault ? address(senior ? seniorVault : juniorVault) : address(perp);
        vm.prank(actor);
        perp.transfer(destination, amount);
    }

    function changePrice(uint96 rawPrice) external {
        oracle.setPrice(bound(uint256(rawPrice), 8_000e18, 800_000e18));
    }

    function advanceEpoch(uint96 rawPrice) external {
        vm.warp(block.timestamp + 604_800);
        oracle.setPrice(bound(uint256(rawPrice), 8_000e18, 800_000e18));
        (bool ok,) = address(controller).call(abi.encodeCall(PerpController.upkeep, ()));
        if (ok) successfulCalls += 1;
        else revertedCalls += 1;
    }

    function bondMint(uint8 actorSeed, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        uint256 amount = bound(uint256(rawAmount), 100_000, 2_000_000);
        BondIssuer.BondInfo memory info = issuer.latestBondInfo();
        underlying.mint(actor, amount);
        vm.startPrank(actor);
        underlying.approve(address(manager), type(uint256).max);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            manager.deposit(info.bondID, amount);
        IERC20(srInput.token).approve(address(controller), type(uint256).max);
        IERC20(jrInput.token).approve(address(controller), type(uint256).max);
        (bool ok,) = address(controller)
            .call(
                abi.encodeCall(
                    PerpController.mint2,
                    (
                        PerpController.TokenAmount(srInput.token, srInput.amount),
                        PerpController.TokenAmount(jrInput.token, jrInput.amount),
                        0,
                        0
                    )
                )
            );
        vm.stopPrank();
        if (ok) successfulCalls += 1;
        else revertedCalls += 1;
    }

    function rollover() external {
        (bool ok,) = address(controller).call(abi.encodeCall(PerpController.rollover, ()));
        if (ok) successfulCalls += 1;
        else revertedCalls += 1;
    }

    function rebalance(bool senior, bool minting) external {
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        (uint256 subDr,) = controller.systemDeviations();
        bool targetBelow = senior ? minting : !minting;
        uint96 target = targetBelow ? uint96(subDr / 2) : uint96(subDr * 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (bool ok,) = address(vault).call(abi.encodeCall(UnderlyingPerpVault.rebalance, ()));
        if (ok) successfulCalls += 1;
        else revertedCalls += 1;
    }

    function togglePause(bool senior) external {
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        if (vault.paused()) vault.unpause();
        else vault.pause();
    }

    function acceptFeePolicyOwnership() external {
        feePolicy.acceptOwnership();
    }

    function setFeeStress(uint64 rawBasePerc, uint64 rawFlashBasePerc, uint64 rawImpactPerc) external {
        uint64 basePerc = uint64(bound(uint256(rawBasePerc), 0, 1e18));
        uint64 flashBasePerc = uint64(bound(uint256(rawFlashBasePerc), 0, 1e18));
        uint64 impactPerc = uint64(bound(uint256(rawImpactPerc), 0, 1e18));
        FeePolicy.Fees memory fees = OperationalFeeConfig.flat(basePerc, flashBasePerc, impactPerc);
        feePolicy.updateFeeParams(fees, fees);
        successfulCalls += 1;
    }

    function failedMinOutDeposit(uint8 actorSeed, bool senior, uint96 rawAmount) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        uint256 amount = bound(uint256(rawAmount), 1, 1_000_000);
        underlying.mint(actor, amount);
        vm.prank(actor);
        underlying.approve(address(router), type(uint256).max);
        bytes32 beforeState = _failureFingerprint(actor, vault);
        vm.prank(actor);
        (bool ok,) = address(router)
            .call(
                abi.encodeCall(
                    UnderlyingSingleAssetRouter.depositUnderlying, (address(vault), amount, type(uint256).max, 2)
                )
            );
        if (ok || _failureFingerprint(actor, vault) != beforeState) atomicityBroken = true;
    }

    function failedMinOutRedeem(uint8 actorSeed, bool senior, uint96 rawNotes) external {
        address actor = _actor(actorSeed);
        UnderlyingPerpVault vault = senior ? seniorVault : juniorVault;
        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;
        uint256 notes = bound(uint256(rawNotes), 1, balance);
        vm.prank(actor);
        vault.approve(address(router), notes);
        bytes32 beforeState = _failureFingerprint(actor, vault);
        vm.prank(actor);
        (bool ok,) = address(router)
            .call(
                abi.encodeCall(UnderlyingSingleAssetRouter.redeemUnderlying, (address(vault), notes, type(uint256).max))
            );
        if (ok || _failureFingerprint(actor, vault) != beforeState) atomicityBroken = true;
    }

    function _failureFingerprint(address actor, UnderlyingPerpVault vault) private view returns (bytes32) {
        PerpToken selectedPerp = vault.isPerpSrVault() ? perpSr : perpJr;
        return keccak256(
            abi.encode(
                underlying.balanceOf(actor),
                underlying.balanceOf(address(vault)),
                underlying.balanceOf(address(router)),
                selectedPerp.balanceOf(actor),
                selectedPerp.balanceOf(address(vault)),
                selectedPerp.balanceOf(address(router)),
                vault.balanceOf(actor),
                vault.balanceOf(address(router)),
                vault.totalSupply(),
                perpSr.totalSupply(),
                perpJr.totalSupply(),
                underlying.balanceOf(address(controller)),
                controller.collectedFeeBal(address(underlying)),
                controller.collectedFeeBal(address(perpSr)),
                controller.collectedFeeBal(address(perpJr)),
                controller.protocolFeeBals(address(underlying)),
                controller.protocolFeeBals(address(perpSr)),
                controller.protocolFeeBals(address(perpJr))
            )
        );
    }

    function _actor(uint8 seed) private view returns (address) {
        return actors[uint256(seed) % actors.length];
    }
}

contract OperationalStatefulInvariantTest is StdInvariant, OperationalRealFixture {
    OperationalStatefulHandler internal handler;

    function setUp() public {
        _deployOperationalSystem(address(this));
        handler = new OperationalStatefulHandler(
            system.underlying,
            system.oracle,
            system.manager,
            system.issuer,
            system.perpSr,
            system.perpJr,
            system.feePolicy,
            system.controller,
            seniorVault,
            juniorVault,
            router
        );
        targetContract(address(handler));
        seniorVault.updateKeeper(address(handler));
        juniorVault.updateKeeper(address(handler));
        seniorVault.transferOwnership(address(handler));
        juniorVault.transferOwnership(address(handler));
        system.feePolicy.transferOwnership(address(handler));
        handler.acceptFeePolicyOwnership();

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = handler.depositRouter.selector;
        selectors[1] = handler.redeemRouter.selector;
        selectors[2] = handler.directRedeem.selector;
        selectors[3] = handler.directDeposit.selector;
        selectors[4] = handler.donateUnderlying.selector;
        selectors[5] = handler.donatePerp.selector;
        selectors[6] = handler.changePrice.selector;
        selectors[7] = handler.advanceEpoch.selector;
        selectors[8] = handler.bondMint.selector;
        selectors[9] = handler.rollover.selector;
        selectors[10] = handler.rebalance.selector;
        selectors[11] = handler.togglePause.selector;
        selectors[12] = handler.failedMinOutDeposit.selector;
        selectors[13] = handler.failedMinOutRedeem.selector;
        selectors[14] = handler.setFeeStress.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_UnderlyingSupplyIsFullyAccounted() public view {
        address[3] memory actors = [handler.actors(0), handler.actors(1), handler.actors(2)];
        assertEq(_trackedUnderlying(address(handler), actors), system.underlying.totalSupply());
    }

    function invariant_PerpSuppliesEqualTrackedBalances() public view {
        assertEq(_trackedPerp(system.perpSr), system.perpSr.totalSupply());
        assertEq(_trackedPerp(system.perpJr), system.perpJr.totalSupply());
    }

    function invariant_VaultSuppliesAndLockedLiquidityAreIntact() public view {
        _assertVaultSupply(seniorVault);
        _assertVaultSupply(juniorVault);
    }

    function invariant_RouterNeverRetainsUserAssets() public view {
        assertEq(system.underlying.balanceOf(address(router)), 0);
        assertEq(system.perpSr.balanceOf(address(router)), 0);
        assertEq(system.perpJr.balanceOf(address(router)), 0);
        assertEq(seniorVault.balanceOf(address(router)), 0);
        assertEq(juniorVault.balanceOf(address(router)), 0);
    }

    function invariant_ReserveArraysAreUniqueAndMatchControllerValue() public view {
        (
            PerpController.SystemState memory state,
            PerpBalancer.ReserveData memory sr,
            PerpBalancer.ReserveData memory jr
        ) = system.controller.systemReserveState();
        assertEq(_reserveValueAndValidate(system.perpSr, sr), state.perpSr.reserveValue);
        assertEq(_reserveValueAndValidate(system.perpJr, jr), state.perpJr.reserveValue);
    }

    function invariant_ExpectedFailuresAreAtomic() public view {
        assertFalse(handler.atomicityBroken());
    }

    function _trackedPerp(PerpToken perp) private view returns (uint256 total) {
        total = perp.balanceOf(address(this)) + perp.balanceOf(address(handler)) + perp.balanceOf(address(router))
            + perp.balanceOf(address(seniorVault)) + perp.balanceOf(address(juniorVault))
            + perp.balanceOf(address(system.controller)) + perp.balanceOf(address(system.manager))
            + perp.balanceOf(address(system.issuer)) + perp.balanceOf(address(system.seeder))
            + perp.balanceOf(address(system.perpSr)) + perp.balanceOf(address(system.perpJr)) + perp.balanceOf(DEAD);
        for (uint256 i; i < 3; ++i) {
            total += perp.balanceOf(handler.actors(i));
        }
    }

    function _assertVaultSupply(UnderlyingPerpVault vault) private view {
        uint256 accounted = vault.balanceOf(address(this)) + vault.balanceOf(address(handler))
            + vault.balanceOf(address(router)) + vault.balanceOf(address(vault))
            + vault.balanceOf(address(system.controller));
        for (uint256 i; i < 3; ++i) {
            accounted += vault.balanceOf(handler.actors(i));
        }
        assertEq(accounted, vault.totalSupply());
        assertEq(vault.balanceOf(address(vault)), vault.MINIMUM_LIQUIDITY());
        assertGe(vault.totalSupply(), vault.MINIMUM_LIQUIDITY());
    }

    function _reserveValueAndValidate(PerpToken perp, PerpBalancer.ReserveData memory data)
        private
        view
        returns (uint256 value)
    {
        assertEq(data.underlyingBal, system.underlying.balanceOf(address(perp)));
        assertLe(data.trancheData.length, perp.maxTrancheCount());
        value = data.underlyingBal;
        for (uint256 i; i < data.trancheData.length; ++i) {
            assertEq(data.trancheData[i].balance, IERC20(data.trancheData[i].data.tranche).balanceOf(address(perp)));
            value += data.trancheData[i].value;
            for (uint256 j; j < i; ++j) {
                assertTrue(data.trancheData[i].data.tranche != data.trancheData[j].data.tranche);
            }
        }
    }
}

contract OperationalEconomicAttackTest is OperationalRealFixture {
    address private constant ATTACKER = address(0xBAD);
    address private constant VICTIM = address(0xB0B);

    function setUp() public {
        _deployOperationalSystem(address(this));
    }

    function testDonationRoundTripCannotProfitAgainstJuniorVault() public {
        uint256 attackerCapital = 12_000_000;
        system.underlying.mint(ATTACKER, attackerCapital);
        vm.startPrank(ATTACKER);
        system.underlying.approve(address(router), type(uint256).max);
        uint256 attackerNotes = router.depositUnderlying(address(juniorVault), 1_000_000, 0, 2);
        system.underlying.transfer(address(juniorVault), 10_000_000);
        vm.stopPrank();

        system.underlying.mint(VICTIM, 1_000_000);
        vm.startPrank(VICTIM);
        system.underlying.approve(address(router), type(uint256).max);
        uint256 victimNotes = router.depositUnderlying(address(juniorVault), 1_000_000, 0, 2);
        vm.stopPrank();
        assertGt(victimNotes, 0);

        vm.startPrank(ATTACKER);
        juniorVault.approve(address(router), attackerNotes);
        router.redeemUnderlying(address(juniorVault), attackerNotes, 0);
        vm.stopPrank();

        assertLe(system.underlying.balanceOf(ATTACKER), attackerCapital);
        assertEq(system.underlying.balanceOf(address(router)), 0);
    }

    function testRepeatedTinyRouterRoundTripsCannotCreateUnderlying() public {
        uint256 capital = 10_000;
        system.underlying.mint(ATTACKER, capital);
        vm.startPrank(ATTACKER);
        system.underlying.approve(address(router), type(uint256).max);
        for (uint256 i = 1; i <= 32; ++i) {
            uint256 notes = router.depositUnderlying(address(juniorVault), i, 0, 2);
            if (notes != 0) {
                juniorVault.approve(address(router), notes);
                router.redeemUnderlying(address(juniorVault), notes, 0);
            }
        }
        vm.stopPrank();

        assertLe(system.underlying.balanceOf(ATTACKER), capital);
        assertEq(system.underlying.balanceOf(address(router)), 0);
        assertEq(system.perpJr.balanceOf(address(router)), 0);
    }

    function testExtremePriceShockStillAllowsProRataBasketExit() public {
        system.underlying.mint(ATTACKER, 2_000_000);
        vm.startPrank(ATTACKER);
        system.underlying.approve(address(router), type(uint256).max);
        uint256 srNotes = router.depositUnderlying(address(seniorVault), 1_000_000, 0, 2);
        uint256 jrNotes = router.depositUnderlying(address(juniorVault), 1_000_000, 0, 2);
        vm.stopPrank();
        assertGt(srNotes, 0);
        assertGt(jrNotes, 0);

        system.oracle.setPrice(40_000e18);
        vm.startPrank(ATTACKER);
        seniorVault.redeem(srNotes);
        juniorVault.redeem(jrNotes);
        vm.stopPrank();

        assertEq(seniorVault.balanceOf(ATTACKER), 0);
        assertEq(juniorVault.balanceOf(ATTACKER), 0);
        assertEq(seniorVault.balanceOf(address(seniorVault)), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.balanceOf(address(juniorVault)), juniorVault.MINIMUM_LIQUIDITY());
        assertEq(system.underlying.balanceOf(address(router)), 0);
    }
}

contract OperationalEconomicHardeningPhase2Test is OperationalRealFixture {
    uint256 private constant WAD = 1e18;
    address private constant ACTOR = address(0xA71AC);

    function setUp() public {
        _deployOperationalSystem(address(this));
    }

    function testHundredPercentFeeFailureIsAtomicAndRecoveryRestoresExit() public {
        uint256 notes = _routerDeposit(juniorVault, 2_000_000);
        assertGt(notes, 0);
        assertTrue(_configureAndTryRebalance(juniorVault, true));
        assertGt(system.perpJr.balanceOf(address(juniorVault)), 0);

        vm.prank(ACTOR);
        juniorVault.approve(address(router), notes);
        _setFlatFees(0, uint64(WAD), 0);
        bytes32 beforeState = _exitFingerprint(juniorVault);

        vm.prank(ACTOR);
        vm.expectRevert(PerpController.OpDisabled.selector);
        router.redeemUnderlying(address(juniorVault), notes, 0);
        assertEq(_exitFingerprint(juniorVault), beforeState);

        _setFlatFees(0, 0, uint64(WAD));
        FeePolicy.OpFees memory rawSignal = system.feePolicy
            .computeOpFees(
                FeePolicy.OpFeeInput({
                    isPerpSrOp: false,
                    isFlashOp: true,
                    systemDeviation: FeePolicy.OpSystemChange({
                        subDRPre: 9e17, subDRPost: 11e17, vmDRPre: 9e17, vmDRPost: 11e17
                    })
                })
            );
        assertEq(rawSignal.totalFeePerc, 2 * WAD);

        _setFlatFees(0, 0, 0);
        vm.prank(ACTOR);
        uint256 underlyingOut = router.redeemUnderlying(address(juniorVault), notes, 0);
        assertGt(underlyingOut, 0);
        assertEq(juniorVault.balanceOf(ACTOR), 0);
        _assertGlobalAccounting();
    }

    function testEightEpochExtremePriceRolloverRebalanceAndBasketExit() public {
        (uint256 seniorNotes, uint256 juniorNotes) = _routerDepositBoth(4_000_000);
        uint256[8] memory prices =
            [uint256(82_000e18), 79_000e18, 84_000e18, 8_000e18, 800_000e18, 40_000e18, 160_000e18, 80_000e18];
        uint256 upkeepSuccesses;
        uint256 rolloverSuccesses;
        uint256 rebalanceSuccesses;

        for (uint256 i; i < prices.length; ++i) {
            vm.warp(block.timestamp + 604_800);
            system.oracle.setPrice(prices[i]);
            (bool upkeepOk,) = address(system.controller).call(abi.encodeCall(PerpController.upkeep, ()));
            if (upkeepOk) upkeepSuccesses += 1;

            if (i < 3) _balancedControllerMint(2_000_000);
            if (_configureAndTryRebalance(seniorVault, i % 2 == 0)) rebalanceSuccesses += 1;
            if (_configureAndTryRebalance(juniorVault, i % 2 != 0)) rebalanceSuccesses += 1;

            (bool rolloverOk,) = address(system.controller).call(abi.encodeCall(PerpController.rollover, ()));
            if (rolloverOk) rolloverSuccesses += 1;
        }

        assertGt(upkeepSuccesses, 0);
        assertGt(rebalanceSuccesses, 0);
        assertGt(rolloverSuccesses, 0);

        system.oracle.setPrice(INITIAL_PRICE);
        vm.startPrank(ACTOR);
        seniorVault.redeem(seniorNotes);
        juniorVault.redeem(juniorNotes);
        vm.stopPrank();

        assertEq(seniorVault.balanceOf(ACTOR), 0);
        assertEq(juniorVault.balanceOf(ACTOR), 0);
        assertEq(seniorVault.balanceOf(address(seniorVault)), seniorVault.MINIMUM_LIQUIDITY());
        assertEq(juniorVault.balanceOf(address(juniorVault)), juniorVault.MINIMUM_LIQUIDITY());
        _assertGlobalAccounting();
    }

    function testAlternatingSingleSidePriceShockFlowsRemainExitAvailable() public {
        for (uint256 i; i < 8; ++i) {
            system.oracle.setPrice(INITIAL_PRICE);
            UnderlyingPerpVault vault = i % 2 == 0 ? seniorVault : juniorVault;
            uint256 notes = _routerDeposit(vault, 500_000 + i);
            assertGt(notes, 0);

            system.oracle.setPrice(i % 4 < 2 ? 8_000e18 : 800_000e18);
            vm.prank(ACTOR);
            vault.redeem(notes / 2);
        }

        system.oracle.setPrice(INITIAL_PRICE);
        uint256 remainingSenior = seniorVault.balanceOf(ACTOR);
        uint256 remainingJunior = juniorVault.balanceOf(ACTOR);
        vm.startPrank(ACTOR);
        if (remainingSenior != 0) seniorVault.redeem(remainingSenior);
        if (remainingJunior != 0) juniorVault.redeem(remainingJunior);
        vm.stopPrank();

        assertEq(seniorVault.balanceOf(ACTOR), 0);
        assertEq(juniorVault.balanceOf(ACTOR), 0);
        _assertGlobalAccounting();
    }

    function _routerDepositBoth(uint256 amountEach) private returns (uint256 seniorNotes, uint256 juniorNotes) {
        system.underlying.mint(ACTOR, 2 * amountEach);
        vm.startPrank(ACTOR);
        system.underlying.approve(address(router), type(uint256).max);
        seniorNotes = router.depositUnderlying(address(seniorVault), amountEach, 0, 2);
        juniorNotes = router.depositUnderlying(address(juniorVault), amountEach, 0, 2);
        vm.stopPrank();
        assertGt(seniorNotes, 0);
        assertGt(juniorNotes, 0);
    }

    function _routerDeposit(UnderlyingPerpVault vault, uint256 amount) private returns (uint256 notes) {
        system.underlying.mint(ACTOR, amount);
        vm.startPrank(ACTOR);
        system.underlying.approve(address(router), type(uint256).max);
        notes = router.depositUnderlying(address(vault), amount, 0, 2);
        vm.stopPrank();
    }

    function _balancedControllerMint(uint256 amount) private {
        BondIssuer.BondInfo memory info = system.issuer.latestBondInfo();
        system.underlying.mint(address(this), amount);
        system.underlying.approve(address(system.manager), amount);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            system.manager.deposit(info.bondID, amount);
        IERC20(srInput.token).approve(address(system.controller), srInput.amount);
        IERC20(jrInput.token).approve(address(system.controller), jrInput.amount);
        system.controller
            .mint2(
                PerpController.TokenAmount(srInput.token, srInput.amount),
                PerpController.TokenAmount(jrInput.token, jrInput.amount),
                0,
                0
            );
    }

    function _configureAndTryRebalance(UnderlyingPerpVault vault, bool minting) private returns (bool ok) {
        (uint256 subDr,) = system.controller.systemDeviations();
        bool targetBelow = vault.isPerpSrVault() ? minting : !minting;
        uint96 target = targetBelow ? uint96(subDr / 2) : uint96(subDr * 2);
        vault.updateTargetDR(target, IUnderlyingPerpVault.DRRange(target, target));
        (ok,) = address(vault).call(abi.encodeCall(UnderlyingPerpVault.rebalance, ()));
    }

    function _setFlatFees(uint64 basePerc, uint64 flashBasePerc, uint64 impactPerc) private {
        FeePolicy.Fees memory fees = OperationalFeeConfig.flat(basePerc, flashBasePerc, impactPerc);
        system.feePolicy.updateFeeParams(fees, fees);
    }

    function _exitFingerprint(UnderlyingPerpVault vault) private view returns (bytes32) {
        PerpToken selectedPerp = vault.isPerpSrVault() ? system.perpSr : system.perpJr;
        return keccak256(
            abi.encode(
                system.underlying.balanceOf(ACTOR),
                system.underlying.balanceOf(address(vault)),
                system.underlying.balanceOf(address(router)),
                selectedPerp.balanceOf(ACTOR),
                selectedPerp.balanceOf(address(vault)),
                selectedPerp.balanceOf(address(router)),
                vault.balanceOf(ACTOR),
                vault.balanceOf(address(router)),
                vault.totalSupply(),
                system.perpSr.totalSupply(),
                system.perpJr.totalSupply(),
                system.controller.collectedFeeBal(address(system.underlying)),
                system.controller.collectedFeeBal(address(system.perpSr)),
                system.controller.collectedFeeBal(address(system.perpJr))
            )
        );
    }

    function _assertGlobalAccounting() private view {
        address[3] memory actors = [ACTOR, address(0), address(0)];
        assertEq(_trackedUnderlying(address(0), actors), system.underlying.totalSupply());
        assertEq(_trackedPerpWithActor(system.perpSr), system.perpSr.totalSupply());
        assertEq(_trackedPerpWithActor(system.perpJr), system.perpJr.totalSupply());
        assertEq(system.underlying.balanceOf(address(router)), 0);
        assertEq(system.perpSr.balanceOf(address(router)), 0);
        assertEq(system.perpJr.balanceOf(address(router)), 0);
    }

    function _trackedPerpWithActor(PerpToken perp) private view returns (uint256) {
        return perp.balanceOf(address(this)) + perp.balanceOf(ACTOR) + perp.balanceOf(address(router))
            + perp.balanceOf(address(seniorVault)) + perp.balanceOf(address(juniorVault))
            + perp.balanceOf(address(system.controller)) + perp.balanceOf(address(system.manager))
            + perp.balanceOf(address(system.issuer)) + perp.balanceOf(address(system.seeder))
            + perp.balanceOf(address(system.perpSr)) + perp.balanceOf(address(system.perpJr)) + perp.balanceOf(DEAD);
    }
}
