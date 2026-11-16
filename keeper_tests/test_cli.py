from __future__ import annotations

import json
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from keeper.cli import main

from keeper_tests.helpers import CALLER, CONTROLLER, FakeRpc, snapshot_responses
from keeper_tests.test_engine import NO_OP, NO_ROLLOVER, OUTSIDE_WINDOW


class CliTests(unittest.TestCase):
    def test_preflight_only_is_a_dry_fixed_block_cycle(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "keeper.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "chainId": 8453,
                        "readRpcUrls": ["http://127.0.0.1:8545"],
                        "submitRpcUrl": None,
                        "submissionMode": "disabled",
                        "from": CALLER,
                        "contracts": {"controller": CONTROLLER},
                        "deployment": {"id": "cli-test", "attestations": {}},
                        "stateFile": str(root / "state.json"),
                        "observability": {
                            "healthFile": str(root / "health.json"),
                            "metricsFile": str(root / "metrics.prom"),
                            "alertsFile": str(root / "alerts.jsonl"),
                        },
                    }
                )
            )
            os.chmod(config_path, 0o600)
            rpc = FakeRpc(snapshot_responses(calls=[NO_OP, NO_ROLLOVER, OUTSIDE_WINDOW]))
            output = StringIO()
            with patch("keeper.cli.HttpJsonRpcClient", return_value=rpc), redirect_stdout(output):
                self.assertEqual(main(["--config", str(config_path), "--preflight-only"]), 0)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertIn("dry_run_complete", [event["event"] for event in events])
            self.assertEqual(events[-1]["event"], "preflight_complete")
            self.assertFalse(any(method == "eth_sendTransaction" for method, _ in rpc.calls))

    def test_preflight_only_rejects_broadcast_flags(self) -> None:
        stderr = StringIO()
        with patch("sys.stderr", stderr):
            self.assertEqual(main(["--config", "unused", "--preflight-only", "--allow-broadcast"]), 2)
        self.assertIn("cannot be combined", stderr.getvalue())

    def test_failed_deployment_preflight_is_structured_and_critical(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config_path = root / "keeper.json"
            health_path = root / "health.json"
            config_path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "chainId": 8453,
                        "readRpcUrls": ["http://127.0.0.1:8545"],
                        "submissionMode": "disabled",
                        "from": CALLER,
                        "contracts": {"controller": CONTROLLER},
                        "deployment": {"id": "wrong-chain-test"},
                        "observability": {"healthFile": str(health_path)},
                    }
                )
            )
            rpc = FakeRpc({"eth_chainId": "0x1"})
            output = StringIO()
            with patch("keeper.cli.HttpJsonRpcClient", return_value=rpc), redirect_stdout(output):
                self.assertEqual(main(["--config", str(config_path), "--preflight-only"]), 1)
            events = [json.loads(line) for line in output.getvalue().splitlines()]
            self.assertEqual(events[-2]["event"], "cycle_error")
            self.assertEqual(events[-2]["phase"], "deployment_preflight")
            self.assertEqual(events[-1]["code"], "CYCLE_ERROR")
            self.assertEqual(json.loads(health_path.read_text())["status"], "critical")


if __name__ == "__main__":
    unittest.main()
