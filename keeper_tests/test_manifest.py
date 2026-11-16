from __future__ import annotations

import json
import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from keeper.manifest import _atomic_json, generate_manifest, load_manifest_input, main

from keeper_tests.helpers import CONTROLLER, FakeRpc


IMPLEMENTATION = "0x0000000000000000000000000000000000002001"
PROXY_HASH = "0x" + "11" * 32
IMPLEMENTATION_HASH = "0x" + "22" * 32
BLOCK_HASH = "0x" + "33" * 32


def manifest_rpc(*, final_hash: str = BLOCK_HASH) -> FakeRpc:
    return FakeRpc(
        {
            "eth_chainId": "0x2105",
            "eth_getBlockByNumber": [
                {"number": "0x64", "hash": BLOCK_HASH, "timestamp": "0x3e8"},
                {"number": "0x64", "hash": final_hash, "timestamp": "0x3e8"},
            ],
            "eth_getCode": ["0x6000", "0x6001"],
            "eth_getProof": [{"codeHash": PROXY_HASH}, {"codeHash": IMPLEMENTATION_HASH}],
            "eth_getStorageAt": "0x" + "00" * 12 + IMPLEMENTATION[2:],
        }
    )


class ManifestTests(unittest.TestCase):
    def test_fixed_block_manifest_and_private_atomic_output(self) -> None:
        source = {"deploymentId": "base-prod-a", "chainId": 8453, "contracts": {"controller": CONTROLLER}}
        manifest = generate_manifest(
            manifest_rpc(),
            source,
            100,
            endpoint="https://rpc.example/secret-provider-token?not-logged=yes",
        )
        self.assertEqual(manifest["blockHash"], BLOCK_HASH)
        self.assertEqual(manifest["sourceEndpoint"], "https://rpc.example")
        identity = manifest["contracts"]["controller"]
        self.assertEqual(identity["implementation"], IMPLEMENTATION)
        self.assertEqual(identity["proxyCodeHash"], PROXY_HASH)
        self.assertEqual(
            manifest["configFragment"]["deployment"]["attestations"]["controller"]["implementationCodeHash"],
            IMPLEMENTATION_HASH,
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "manifest.json"
            _atomic_json(output, manifest)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(output.read_text()), manifest)

    def test_manifest_input_is_strict_and_contains_only_addresses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "deploymentId": "reviewed-a",
                        "chainId": 8453,
                        "contracts": {"controller": CONTROLLER},
                    }
                )
            )
            loaded = load_manifest_input(path)
            self.assertEqual(loaded["contracts"], {"controller": CONTROLLER})
            path.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "deploymentId": "reviewed-a",
                        "chainId": 8453,
                        "contracts": {"controller": CONTROLLER},
                        "privateKey": "forbidden-by-schema",
                    }
                )
            )
            with self.assertRaisesRegex(ValueError, "unknown manifest input fields"):
                load_manifest_input(path)

    def test_manifest_rejects_block_hash_drift(self) -> None:
        source = {"deploymentId": "base-prod-a", "chainId": 8453, "contracts": {"controller": CONTROLLER}}
        with self.assertRaisesRegex(RuntimeError, "changed"):
            generate_manifest(
                manifest_rpc(final_hash="0x" + "44" * 32),
                source,
                100,
                endpoint="https://rpc.example",
            )

    def test_cli_writes_review_manifest_without_applying_it(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "input.json"
            output = Path(directory) / "output.json"
            source.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "deploymentId": "reviewed-a",
                        "chainId": 8453,
                        "contracts": {"controller": CONTROLLER},
                    }
                )
            )
            with patch("keeper.manifest.HttpJsonRpcClient", return_value=manifest_rpc()):
                with redirect_stdout(io.StringIO()):
                    result = main(
                        [
                            "--input",
                            str(source),
                            "--rpc-url",
                            "https://rpc.example/hidden-token",
                            "--block",
                            "100",
                            "--output",
                            str(output),
                        ]
                    )
            self.assertEqual(result, 0)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)
            written = json.loads(output.read_text())
            self.assertEqual(written["classification"], "REVIEW-REQUIRED/READ-ONLY")
            self.assertEqual(written["sourceEndpoint"], "https://rpc.example")


if __name__ == "__main__":
    unittest.main()
