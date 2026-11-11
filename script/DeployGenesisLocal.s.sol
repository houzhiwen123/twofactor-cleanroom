// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BondIssuer} from "../src/bond/BondIssuer.sol";
import {BondsManager} from "../src/bond/BondsManager.sol";
import {Tranche} from "../src/bond/Tranche.sol";
import {PerpController} from "../src/controller/PerpController.sol";
import {GenesisSeeder} from "../src/deploy/GenesisSeeder.sol";
import {IBondsManager} from "../src/interfaces/IBondsManager.sol";
import {PerpToken} from "../src/perp/PerpToken.sol";
import {FeePolicy} from "../src/policy/FeePolicy.sol";
import {PerpBalancer} from "../src/policy/PerpBalancer.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockPriceOracle} from "../test/mocks/MockPriceOracle.sol";

/// @notice Secret-free local simulation of a complete clean-room Genesis deployment.
/// @dev Run without --broadcast. It deploys only local mocks and never reads a key or RPC URL.
contract DeployGenesisLocal is Script {
    using SafeERC20 for IERC20;

    uint256 private constant INITIAL_UNDERLYING = 100_000_000;
    uint256 private constant MAX_JR_IDLE_TOP_UP = INITIAL_UNDERLYING + 1_000;
    uint256 private constant INITIAL_PRICE = 80_000e18;
    address private constant LOCAL_ADMIN = address(0xA11CE);

    function run() external {
        vm.warp(1_800_000_000);
        vm.startBroadcast(LOCAL_ADMIN);

        MockERC20 underlying = new MockERC20("cbBTC", "cbBTC", 8);
        MockPriceOracle oracle = new MockPriceOracle(INITIAL_PRICE);
        Tranche trancheImplementation = new Tranche();

        BondsManager managerImplementation = new BondsManager();
        BondsManager manager = BondsManager(
            address(
                new TransparentUpgradeableProxy(
                    address(managerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(BondsManager.init, (address(trancheImplementation)))
                )
            )
        );
        manager.addAsset(address(underlying));
        manager.updateOracle(address(underlying), address(oracle));

        BondIssuer issuerImplementation = new BondIssuer();
        BondIssuer issuer = BondIssuer(
            address(
                new TransparentUpgradeableProxy(
                    address(issuerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(BondIssuer.init, (address(manager), address(underlying)))
                )
            )
        );
        manager.addIssuer(address(issuer));

        PerpToken perpSr = new PerpToken(
            "Clean-room cbBTC Senior",
            "cr-cbBTC-SR",
            address(underlying),
            address(manager),
            address(0),
            false,
            LOCAL_ADMIN
        );
        PerpToken perpJr = new PerpToken(
            "Clean-room cbBTC Junior",
            "cr-cbBTC-JR",
            address(underlying),
            address(manager),
            address(0),
            true,
            LOCAL_ADMIN
        );

        PerpController controllerImplementation = new PerpController();
        PerpController controller = PerpController(
            address(
                new TransparentUpgradeableProxy(
                    address(controllerImplementation),
                    LOCAL_ADMIN,
                    abi.encodeCall(PerpController.init, (address(underlying), address(perpSr), address(perpJr)))
                )
            )
        );
        perpSr.updateController(address(controller));
        perpJr.updateController(address(controller));

        FeePolicy feeImplementation = new FeePolicy();
        FeePolicy feePolicy = FeePolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(feeImplementation), LOCAL_ADMIN, abi.encodeCall(FeePolicy.init, ())
                )
            )
        );
        PerpBalancer balancer = new PerpBalancer();
        controller.updateFeePolicy(address(feePolicy));
        controller.updatePerpBalancer(address(balancer));
        controller.updateIssuer(address(issuer));
        controller.setUnderlyingOracle();

        (bool issued, BondIssuer.BondInfo memory firstBond) = issuer.issue();
        require(issued, "first bond not issued");

        underlying.mint(LOCAL_ADMIN, INITIAL_UNDERLYING);
        underlying.approve(address(manager), INITIAL_UNDERLYING);
        (IBondsManager.TokenAmount memory srInput, IBondsManager.TokenAmount memory jrInput) =
            manager.deposit(firstBond.bondID, INITIAL_UNDERLYING);

        GenesisSeeder seeder = new GenesisSeeder(LOCAL_ADMIN);
        underlying.mint(address(seeder), MAX_JR_IDLE_TOP_UP);
        IERC20(srInput.token).safeTransfer(address(seeder), srInput.amount);
        IERC20(jrInput.token).safeTransfer(address(seeder), jrInput.amount);
        controller.updateKeeper(address(seeder));
        seeder.bootstrap(
            controller, srInput.token, srInput.amount, jrInput.token, jrInput.amount, MAX_JR_IDLE_TOP_UP, LOCAL_ADMIN
        );
        controller.updateKeeper(LOCAL_ADMIN);
        controller.pauseUserOps(false);
        (uint256 genesisSubDr, uint256 genesisVmDr) = controller.systemDeviations();
        vm.stopBroadcast();

        console2.log("underlying", address(underlying));
        console2.log("manager", address(manager));
        console2.log("issuer", address(issuer));
        console2.log("controller", address(controller));
        console2.log("perpSr", address(perpSr));
        console2.log("perpJr", address(perpJr));
        console2.log("firstBondSr", firstBond.srTranche);
        console2.log("firstBondJr", firstBond.jrTranche);
        console2.log("lockedSharesPerSide", seeder.MIN_LOCKED_SHARES());
        console2.log("genesisSubDR", genesisSubDr);
        console2.log("genesisVmDR", genesisVmDr);
        console2.log("userOpsPaused", controller.userOpsPaused());
    }
}
