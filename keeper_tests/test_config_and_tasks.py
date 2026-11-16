from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from keeper.config import parse_config
from keeper.model import default_tasks

from keeper_tests.helpers import CALLER, CONTROLLER, JUNIOR, SENIOR, USD


class ConfigAndTaskTests(unittest.TestCase):
    def test_catalog_priority_and_authorized_swap_exclusion(self) -> None:
        tasks = default_tasks(
            {"controller": CONTROLLER, "juniorVault": JUNIOR, "seniorVault": SENIOR, "usdVault": USD}
        )
        self.assertEqual([task.priority for task in tasks], [10, 20, 30, 40, 41, 50, 60])
        self.assertEqual(tasks[0].name, "controller_upkeep")
        self.assertFalse(any(task.calldata.startswith("0x") and len(task.calldata) > 10 for task in tasks))
        self.assertFalse(any("swap" in task.name for task in tasks))

    def test_live_mode_requires_separate_submit_endpoint(self) -> None:
        raw = {
            "schemaVersion": 1,
            "chainId": 8453,
            "readRpcUrls": ["http://127.0.0.1:8545"],
            "submitRpcUrl": None,
            "from": CALLER,
            "contracts": {"controller": CONTROLLER},
            "live": True,
        }
        with self.assertRaisesRegex(ValueError, "submitRpcUrl"):
            parse_config(raw)

    def test_relative_state_path_is_scoped_to_config_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            config = parse_config(
                {
                    "schemaVersion": 1,
                    "readRpcUrls": ["http://127.0.0.1:8545"],
                    "from": CALLER,
                    "contracts": {"controller": CONTROLLER},
                    "stateFile": "state/keeper.json",
                },
                base,
            )
            self.assertEqual(config.state_file, base / "state/keeper.json")

    def test_private_signing_material_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "private signing material"):
            parse_config(
                {
                    "schemaVersion": 1,
                    "readRpcUrls": ["http://127.0.0.1:8545"],
                    "from": CALLER,
                    "contracts": {"controller": CONTROLLER},
                    "signer": {"private_key": "must-not-be-read"},
                }
            )


if __name__ == "__main__":
    unittest.main()
