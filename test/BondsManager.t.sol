// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {ITranche} from "../src/interfaces/ITranche.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPriceOracle} from "./mocks/MockPriceOracle.sol";
import {SettlementReference} from "./ref/SettlementReference.sol";

contract BondsManagerTest is Test {
    uint256 private constant WAD = 1e18;

    MockERC20 private underlying;
    MockPriceOracle private oracle;
    BondsManager private manager;

    function setUp() public {
        vm.warp(1_800_000_000);
        underlying = new MockERC20("cbBTC", "cbBTC", 8);
        oracle = new MockPriceOracle(80_248_101_897_110_000_000_000);
        Tranche trancheImplementation = new Tranche();
        BondsManager implementation = new BondsManager();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation), address(this), abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
        );
        manager = BondsManager(address(proxy));
        manager.addAsset(address(underlying));
        manager.updateOracle(address(underlying), address(oracle));
        manager.addIssuer(address(this));
    }

    function testBondIdAndDepositConstructionVector() public {
        uint64 ratio = 300_000_000_000_000_000;
        uint64 maturity = uint64(block.timestamp + 100);
        (bytes32 bondID, IBondsManager.BondData memory bond) =
            manager.createBond(address(underlying), ratio, maturity);
        bytes32 expectedID =
            keccak256(abi.encode(address(manager), address(underlying), ratio, maturity, oracle.price()));
        assertEq(bondID, expectedID);
        assertEq(ITranche(bond.senior).manager(), address(manager));
        assertEq(ITranche(bond.senior).bondID(), bondID);
        assertTrue(ITranche(bond.senior).isSenior());
        assertFalse(ITranche(bond.junior).isSenior());

        underlying.mint(address(this), 250_003);
        underlying.approve(address(manager), type(uint256).max);
        (, IBondsManager.TokenAmount memory sr, IBondsManager.TokenAmount memory jr) =
            _deposit(bondID, 250_003);
        assertEq(sr.amount, 6_018_679_865);
        assertEq(jr.amount, 14_043_586_353);
        assertEq(manager.bondClaim(bondID), 250_003);
        assertEq(ITranche(bond.senior).decimals(), 8);
    }

    function testSettlementAndTwoCeilingVectors() public view {
        (uint256 senior, uint256 junior) = manager.computeSettlement(
            500_000_000_000_000_000,
            77_232_982,
            81_145_332_071_360_000_000_000,
            75_056_153_820_660_000_000_000
        );
        assertEq(senior, 41_749_382);
        assertEq(junior, 35_483_600);

        (senior, junior) = manager.computeSettlement(
            500_000_000_000_000_000,
            168_577,
            84_015_086_985_250_000_000_000,
            81_145_332_071_360_000_000_000
        );
        assertEq(senior, 87_270);
        assertEq(junior, 81_307);

        (senior, junior) = manager.computeSettlement(700_000_000_000_000_000, 999_999, 90e18, 110e18);
        assertEq(senior, 572_728);
        assertEq(junior, 427_271);
        assertEq(senior + junior, 999_999);
    }

    function testTrancheValueRatioAndVolatilityVector() public {
        uint256 open = 81_145_332_071_360_000_000_000;
        oracle.setPrice(open);
        (bytes32 bondID,) = manager.createBond(
            address(underlying), 500_000_000_000_000_000, uint64(block.timestamp + 1000)
        );
        underlying.mint(address(this), 77_232_982);
        underlying.approve(address(manager), type(uint256).max);
        _deposit(bondID, 77_232_982);
        oracle.setPrice(75_056_153_820_660_000_000_000);

        IBondsManager.TrancheData memory senior = manager.trancheData(bondID, true);
        IBondsManager.TrancheData memory junior = manager.trancheData(bondID, false);
        assertEq(senior.trancheClaim, 41_749_382);
        assertEq(junior.trancheClaim, 35_483_600);
        assertEq(senior.valueRatio, 540_564_159_493_414_355);
        assertEq(junior.valueRatio, 459_435_840_506_585_644);
        assertEq(senior.volatilityMultiplier, 0);
        assertEq(junior.volatilityMultiplier, 2_176_582_477_538_919_392);
    }

    function testMatureRedemptionPaysResidualClaims() public {
        oracle.setPrice(84_015_086_985_250_000_000_000);
        (bytes32 bondID, IBondsManager.BondData memory bond) = manager.createBond(
            address(underlying), 500_000_000_000_000_000, uint64(block.timestamp + 20)
        );
        underlying.mint(address(this), 168_577);
        underlying.approve(address(manager), type(uint256).max);
        _deposit(bondID, 168_577);
        oracle.setPrice(81_145_332_071_360_000_000_000);
        vm.warp(bond.maturityDate);
        assertTrue(manager.tryMature(bondID));
        assertEq(manager.bondClaim(bondID), 168_577);

        uint256 srSupply = ITranche(bond.senior).totalSupply();
        uint256 jrSupply = ITranche(bond.junior).totalSupply();
        assertEq(manager.redeemMature(bondID, true, srSupply), 87_270);
        assertEq(manager.redeemMature(bondID, false, jrSupply), 81_307);
        assertEq(manager.bondClaim(bondID), 0);
        assertEq(ITranche(bond.senior).totalSupply(), 0);
        assertEq(ITranche(bond.junior).totalSupply(), 0);
    }

    function testMatureZeroSupplyCannotClaimResidual() public {
        oracle.setPrice(WAD);
        (bytes32 bondID,) = manager.createBond(
            address(underlying), 500_000_000_000_000_000, uint64(block.timestamp + 5)
        );
        underlying.mint(address(this), 1);
        underlying.approve(address(manager), 1);
        _deposit(bondID, 1);
        vm.warp(block.timestamp + 5);
        assertTrue(manager.tryMature(bondID));
        assertEq(ITranche(manager.srTranche(bondID)).totalSupply(), 0);
        assertEq(manager.redeemMature(bondID, true, 0), 0);
        assertEq(manager.bondClaim(bondID), 1);
    }

    function testFuzzSettlementMatchesIndependentModel(
        uint64 ratio,
        uint128 balance,
        uint96 openPrice,
        uint96 closePrice
    ) public view {
        vm.assume(ratio <= WAD);
        vm.assume(closePrice != 0);
        uint256 expectedSenior;
        uint256 expectedJunior;
        (expectedSenior, expectedJunior) =
            SettlementReference.settle(ratio, balance, openPrice, closePrice);
        (uint256 actualSenior, uint256 actualJunior) =
            manager.computeSettlement(ratio, balance, openPrice, closePrice);
        assertEq(actualSenior, expectedSenior);
        assertEq(actualJunior, expectedJunior);
        assertEq(actualSenior + actualJunior, balance);
        assertLe(actualSenior, balance);
    }

    function testFuzzImmatureRedemptionUsesFractionalProRata(uint96 amount, uint64 srSeed, uint64 jrSeed)
        public
    {
        amount = uint96(bound(amount, 2, 1e12));
        oracle.setPrice(WAD);
        (bytes32 bondID, IBondsManager.BondData memory bond) =
            manager.createBond(address(underlying), 500_000_000_000_000_000, uint64(block.timestamp + 100));
        underlying.mint(address(this), amount);
        underlying.approve(address(manager), type(uint256).max);
        _deposit(bondID, amount);

        uint256 srSupply = ITranche(bond.senior).totalSupply();
        uint256 jrSupply = ITranche(bond.junior).totalSupply();
        uint256 srAvail = uint256(srSeed) % (srSupply + 1);
        uint256 jrAvail = uint256(jrSeed) % (jrSupply + 1);
        (uint256 paid, IBondsManager.TokenAmount memory srBurn, IBondsManager.TokenAmount memory jrBurn) =
            manager.redeemImmature(bondID, srAvail, jrAvail);
        uint256 expected;
        if (srSupply != 0 && (jrSupply == 0 || srAvail * jrSupply <= jrAvail * srSupply)) {
            expected = amount * srAvail / srSupply;
        } else if (jrSupply != 0) {
            expected = amount * jrAvail / jrSupply;
        }
        assertEq(paid, expected);
        assertLe(paid, amount);
        assertLe(srBurn.amount, srAvail);
        assertLe(jrBurn.amount, jrAvail);
    }

    function testImmatureRedemptionHandlesWideProductComparisons() public {
        uint256 amount = 10 ** 40;
        oracle.setPrice(WAD);
        (bytes32 bondID, IBondsManager.BondData memory bond) =
            manager.createBond(address(underlying), 500_000_000_000_000_000, uint64(block.timestamp + 100));
        underlying.mint(address(this), amount);
        underlying.approve(address(manager), amount);
        _deposit(bondID, amount);

        uint256 srSupply = ITranche(bond.senior).totalSupply();
        uint256 jrSupply = ITranche(bond.junior).totalSupply();
        (uint256 paid, IBondsManager.TokenAmount memory srBurn, IBondsManager.TokenAmount memory jrBurn) =
            manager.redeemImmature(bondID, srSupply, jrSupply - 1);
        assertEq(paid, amount - 2);
        assertEq(srBurn.amount, srSupply - 1);
        assertEq(jrBurn.amount, jrSupply - 1);
        assertEq(manager.bondClaim(bondID), 2);
    }

    function testBondIssuerSchedulingAndMaturityCleanup() public {
        BondIssuer implementation = new BondIssuer();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            abi.encodeCall(BondIssuer.init, (address(manager), address(underlying)))
        );
        BondIssuer issuer = BondIssuer(address(proxy));
        manager.addIssuer(address(issuer));

        (bool issued, BondIssuer.BondInfo memory info) = issuer.issue();
        assertTrue(issued);
        assertEq(info.manager, address(manager));
        assertEq(issuer.latestBondID(), info.bondID);
        assertEq(issuer.activeBondIDs().length, 1);
        (issued,) = issuer.issue();
        assertFalse(issued);

        vm.warp(manager.maturityDate(info.bondID));
        assertTrue(issuer.cleanupMature());
        assertEq(issuer.activeBondIDs().length, 0);
        assertTrue(manager.isMature(info.bondID));
    }

    function _deposit(bytes32 bondID, uint256 amount)
        private
        returns (uint256 output, IBondsManager.TokenAmount memory sr, IBondsManager.TokenAmount memory jr)
    {
        (sr, jr) = manager.deposit(bondID, amount);
        output = amount;
    }
}
