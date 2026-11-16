from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from keeper.local_anvil import LocalAnvilE2E, parse_deployment_log, require_loopback_rpc, write_keeper_config

from keeper_tests.helpers import CONTROLLER, JUNIOR, SENIOR, USD


class LocalAnvilUnitTests(unittest.TestCase):
    def test_deployment_log_parser_and_private_generated_config(self) -> None:
        log = """
        controller 0x0000000000000000000000000000000000001001
        jrVault: 0x0000000000000000000000000000000000001002
        srVault 0x0000000000000000000000000000000000001003
        usdVault 0x0000000000000000000000000000000000001004
        """
        addresses = parse_deployment_log(log)
        self.assertEqual(addresses["controller"], CONTROLLER)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "keeper.json"
            write_keeper_config(
                path,
                rpc_urls=["http://127.0.0.1:8545"],
                submit_rpc_url=None,
                addresses=addresses,
                state_file=Path(directory) / "state.json",
                live=False,
            )
            config = json.loads(path.read_text())
            self.assertEqual(config["chainId"], 31_337)
            self.assertEqual(config["contracts"]["juniorVault"], JUNIOR)
            self.assertEqual(config["contracts"]["seniorVault"], SENIOR)
            self.assertEqual(config["contracts"]["usdVault"], USD)
            self.assertNotIn("privateKey", path.read_text())
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_non_loopback_rpc_is_rejected(self) -> None:
        require_loopback_rpc("http://127.0.0.1:8545")
        require_loopback_rpc("http://[::1]:8545")
        with self.assertRaisesRegex(ValueError, "loopback"):
            require_loopback_rpc("https://mainnet.base.org")

    def test_missing_address_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "usdVault"):
            parse_deployment_log(
                f"controller {CONTROLLER}\njrVault {JUNIOR}\nsrVault {SENIOR}\n"
            )


@unittest.skipUnless(os.environ.get("RUN_KEEPER_ANVIL_E2E") == "1", "set RUN_KEEPER_ANVIL_E2E=1")
class LocalAnvilIntegrationTest(unittest.TestCase):
    def test_complete_local_keeper_lifecycle(self) -> None:
        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            result = LocalAnvilE2E(repo, output).run()
            deployment = json.loads((output / "deployment.json").read_text())
            self.assertEqual(set(deployment["attestations"]), {"controller", "juniorVault", "seniorVault", "usdVault"})
            health = json.loads((output / "keeper.live.health.json").read_text())
            self.assertEqual(health["status"], "degraded")
            self.assertFalse(health["pendingSubmission"])
            self.assertEqual(health["lastHardErrorCount"], 1)
            metrics = (output / "keeper.live.metrics.prom").read_text()
            self.assertIn('event="submitted"} 4', metrics)
            self.assertIn('event="receipt_confirmed"} 4', metrics)
            events = [json.loads(line) for line in (output / "keeper-events.jsonl").read_text().splitlines()]
            snapshots = [event for event in events if event.get("event") == "snapshot"]
            self.assertTrue(any(len(event.get("verifiedAttestations", {})) == 4 for event in snapshots))
            self.assertTrue((output / "keeper.live.alerts.jsonl").exists())
        self.assertEqual(result.dry_run_task, "controller_rebalance")
        self.assertTrue(result.idle_after_rebalance)
        self.assertGreaterEqual(result.rpc_failovers, 1)
        self.assertEqual(
            [entry["task"] for entry in result.submitted],
            ["controller_rebalance", "controller_upkeep", "controller_upkeep", "controller_rollover"],
        )


if __name__ == "__main__":
    unittest.main()
