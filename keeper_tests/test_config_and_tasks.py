from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path

from keeper.config import load_config, parse_config
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

    def test_submission_modes_are_explicit_and_network_scoped(self) -> None:
        managed = parse_config(
            {
                "schemaVersion": 1,
                "chainId": 8453,
                "readRpcUrls": ["https://read.example/rpc-key"],
                "submitRpcUrl": "https://signer.example/rpc",
                "submissionMode": "managed-rpc",
                "from": CALLER,
                "contracts": {"controller": CONTROLLER},
            }
        )
        self.assertEqual(managed.submission_mode, "managed-rpc")
        with self.assertRaisesRegex(ValueError, "Base chain IDs"):
            parse_config(
                {
                    "schemaVersion": 1,
                    "chainId": 8453,
                    "readRpcUrls": ["http://127.0.0.1:8545"],
                    "submitRpcUrl": "http://127.0.0.1:8545",
                    "submissionMode": "local-unlocked",
                    "from": CALLER,
                    "contracts": {"controller": CONTROLLER},
                }
            )

    def test_rpc_urls_and_contract_identity_are_strict(self) -> None:
        base = {
            "schemaVersion": 1,
            "readRpcUrls": ["http://127.0.0.1:8545?secret=bad"],
            "from": CALLER,
            "contracts": {"controller": CONTROLLER},
        }
        with self.assertRaisesRegex(ValueError, "query parameters"):
            parse_config(base)
        base["readRpcUrls"] = ["http://127.0.0.1:8545"]
        base["contracts"] = {"controller": CONTROLLER, "juniorVault": CONTROLLER}
        with self.assertRaisesRegex(ValueError, "must be unique"):
            parse_config(base)

    def test_submission_enabled_config_file_must_be_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "keeper.json"
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "chainId": 8453,
                        "readRpcUrls": ["https://read.example/rpc"],
                        "submitRpcUrl": "https://signer.example/rpc",
                        "submissionMode": "managed-rpc",
                        "from": CALLER,
                        "contracts": {"controller": CONTROLLER},
                    }
                )
            )
            os.chmod(path, 0o644)
            with self.assertRaisesRegex(ValueError, "mode 0600"):
                load_config(path)
            os.chmod(path, 0o600)
            self.assertEqual(load_config(path).submission_mode, "managed-rpc")

    def test_live_mode_requires_deployment_attestation_and_observability(self) -> None:
        raw = {
            "schemaVersion": 1,
            "chainId": 31337,
            "readRpcUrls": ["http://127.0.0.1:8545"],
            "submitRpcUrl": "http://127.0.0.1:8545",
            "submissionMode": "local-unlocked",
            "from": CALLER,
            "contracts": {"controller": CONTROLLER},
            "deployment": {"id": "local-live", "attestations": {}},
            "live": True,
        }
        with self.assertRaisesRegex(ValueError, "requires deployment attestations"):
            parse_config(raw)
        raw["deployment"]["attestations"] = {
            "controller": {
                "proxyCodeHash": "0x" + "11" * 32,
                "implementation": "0x0000000000000000000000000000000000002001",
                "implementationCodeHash": "0x" + "22" * 32,
            }
        }
        with self.assertRaisesRegex(ValueError, "requires healthFile"):
            parse_config(raw)


if __name__ == "__main__":
    unittest.main()
