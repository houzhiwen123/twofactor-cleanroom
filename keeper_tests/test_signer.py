from __future__ import annotations

import unittest

from keeper.signer import ExternalSignerClient, SignerBoundaryError

from keeper_tests.helpers import CALLER, CONTROLLER, FakeRpc


class ExternalSignerTests(unittest.TestCase):
    def test_managed_signer_preflight_and_one_valid_send(self) -> None:
        transport = FakeRpc(
            {
                "eth_chainId": "0x2105",
                "eth_getTransactionCount": "0x7",
                "eth_sendTransaction": "0x" + "12" * 32,
            },
            "https://signer.example",
        )
        signer = ExternalSignerClient(transport, CALLER, "managed-rpc")
        preflight = signer.preflight(8453)
        self.assertEqual(preflight.pending_nonce, 7)
        tx_hash = signer.request(
            "eth_sendTransaction",
            [{"from": CALLER, "to": CONTROLLER, "data": "0xabcdef01", "gas": "0x186a0"}],
        )
        self.assertEqual(tx_hash, "0x" + "12" * 32)
        self.assertEqual(sum(method == "eth_sendTransaction" for method, _ in transport.calls), 1)

    def test_preflight_rejects_wrong_chain_and_reports_unlisted_local_sender(self) -> None:
        wrong_chain = ExternalSignerClient(
            FakeRpc({"eth_chainId": "0x1"}, "https://signer.example"), CALLER, "managed-rpc"
        )
        with self.assertRaisesRegex(SignerBoundaryError, "chain ID mismatch"):
            wrong_chain.preflight(8453)

        locked = ExternalSignerClient(
            FakeRpc(
                {
                    "eth_chainId": "0x7a69",
                    "eth_getTransactionCount": "0x0",
                    "eth_accounts": lambda _method, _params, _index: [CONTROLLER],
                },
                "http://127.0.0.1:8545",
            ),
            CALLER,
            "local-unlocked",
        )
        self.assertFalse(locked.preflight(31337).account_enumerated)

    def test_adapter_rejects_every_nonmaintenance_shape_before_transport(self) -> None:
        transport = FakeRpc({"eth_sendTransaction": "0x" + "34" * 32}, "https://signer.example")
        signer = ExternalSignerClient(transport, CALLER, "managed-rpc")
        invalid = [
            {"from": CONTROLLER, "to": CONTROLLER, "data": "0xabcdef01", "gas": "0x1"},
            {"from": CALLER, "to": CONTROLLER, "data": "0xabcdef", "gas": "0x1"},
            {"from": CALLER, "to": CONTROLLER, "data": "0xabcdef01", "gas": "0x1", "value": "0x1"},
            {"from": CALLER, "to": CONTROLLER, "data": "0xabcdef01", "gas": "0x01"},
        ]
        for transaction in invalid:
            with self.assertRaises(SignerBoundaryError):
                signer.request("eth_sendTransaction", [transaction])
        with self.assertRaisesRegex(SignerBoundaryError, "forbids"):
            signer.request("eth_signTransaction", [])
        self.assertEqual(transport.calls, [])


if __name__ == "__main__":
    unittest.main()
