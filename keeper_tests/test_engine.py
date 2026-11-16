from __future__ import annotations

import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from keeper.config import ContractAttestation
from keeper.engine import KeeperEngine
from keeper.rpc import RpcResponseError, RpcTransportError
from keeper.state import KeeperState

from keeper_tests.helpers import CONTROLLER, FakeRpc, config, snapshot_responses


NO_OP = RpcResponseError(-32000, "execution reverted", "0x00219cf1")
NO_ROLLOVER = RpcResponseError(-32000, "execution reverted", "0xbbb27b39")
OUTSIDE_WINDOW = RpcResponseError(-32000, "execution reverted", "0xb4675acc")


class EngineTests(unittest.TestCase):
    def test_fixed_block_simulation_classifies_known_business_reverts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory))
            rpc = FakeRpc(snapshot_responses(calls=[NO_OP, NO_ROLLOVER, OUTSIDE_WINDOW]))
            result = KeeperEngine(cfg, rpc, KeeperState(cfg.state_file)).run_cycle()
            self.assertEqual(result["status"], "dry_run")
            self.assertEqual([item["status"] for item in result["simulations"]], ["not_needed"] * 3)
            call_blocks = [params[1] for method, params in rpc.calls if method == "eth_call"]
            self.assertEqual(call_blocks, ["0x64"] * 3)

    def test_unknown_revert_is_hard_error_not_a_task(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory))
            unknown = RpcResponseError(-32000, "execution reverted", "0xdeadbeef")
            rpc = FakeRpc(snapshot_responses(calls=[unknown, NO_ROLLOVER, OUTSIDE_WINDOW]))
            result = KeeperEngine(cfg, rpc, KeeperState(cfg.state_file)).run_cycle()
            self.assertEqual(result["simulations"][0]["status"], "error")
            self.assertEqual(result["event"]["hardErrorCount"], 1)

    def test_live_cycle_submits_only_highest_priority_then_locks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory), live=True)
            rpc = FakeRpc(snapshot_responses(calls=["0x", "0x", "0x"]))
            tx_hash = "0x" + "12" * 32
            submit = FakeRpc({"eth_sendTransaction": tx_hash}, "fake://submit")
            state = KeeperState(cfg.state_file)
            result = KeeperEngine(cfg, rpc, state, submit_rpc=submit, allow_broadcast=True).run_cycle()
            self.assertEqual(result["status"], "submitted")
            self.assertEqual(result["event"]["task"], "controller_upkeep")
            self.assertEqual(len(submit.calls), 1)
            self.assertEqual(state.pending[CONTROLLER.lower()]["status"], "pending")

    def test_ambiguous_send_is_never_retried(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory), live=True)
            rpc = FakeRpc(snapshot_responses(calls=["0x", NO_ROLLOVER, OUTSIDE_WINDOW]))
            submit = FakeRpc({"eth_sendTransaction": RpcTransportError("connection dropped")}, "fake://submit")
            state = KeeperState(cfg.state_file)
            engine = KeeperEngine(cfg, rpc, state, submit_rpc=submit, allow_broadcast=True)
            first = engine.run_cycle()
            second = engine.run_cycle()
            self.assertEqual(first["status"], "submission_ambiguous")
            self.assertEqual(second["status"], "submission_blocked")
            self.assertEqual(len(submit.calls), 1)
            self.assertEqual(state.pending[CONTROLLER.lower()]["status"], "ambiguous")

    def test_receipt_confirmation_clears_lock_and_requires_rescan(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory), live=True)
            state = KeeperState(cfg.state_file)
            tx_hash = "0x" + "34" * 32
            state.set_pending(
                CONTROLLER,
                {"task": "controller_upkeep", "target": CONTROLLER, "status": "pending", "txHash": tx_hash},
            )
            rpc = FakeRpc(
                {
                    "eth_getTransactionReceipt": {"status": "0x1", "blockNumber": "0x63"},
                    "eth_blockNumber": "0x64",
                }
            )
            result = KeeperEngine(cfg, rpc, state).run_cycle()
            self.assertEqual(result["status"], "receipt_confirmed")
            self.assertTrue(result["event"]["rescanRequired"])
            self.assertEqual(state.pending, {})
            self.assertFalse(any(method == "eth_call" for method, _ in rpc.calls))

    def test_chain_id_and_code_are_validated_before_calls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory))
            wrong_chain = FakeRpc({"eth_chainId": "0x1"})
            with self.assertRaisesRegex(RuntimeError, "chain ID mismatch"):
                KeeperEngine(cfg, wrong_chain, KeeperState(cfg.state_file)).run_cycle()

            no_code = FakeRpc(snapshot_responses(calls=[], code="0x"))
            with self.assertRaisesRegex(RuntimeError, "has no code"):
                KeeperEngine(cfg, no_code, KeeperState(cfg.state_file)).run_cycle()

    def test_config_live_flag_without_cli_opt_in_remains_dry_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cfg = config(Path(directory), live=True)
            rpc = FakeRpc(snapshot_responses(calls=["0x", NO_ROLLOVER, OUTSIDE_WINDOW]))
            submit = FakeRpc({"eth_sendTransaction": "0x" + "56" * 32})
            result = KeeperEngine(cfg, rpc, KeeperState(cfg.state_file), submit_rpc=submit).run_cycle()
            self.assertEqual(result["status"], "dry_run")
            self.assertEqual(submit.calls, [])

    def test_fixed_block_proxy_and_implementation_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            implementation = "0x0000000000000000000000000000000000002001"
            proxy_hash = "0x" + "11" * 32
            implementation_hash = "0x" + "22" * 32
            cfg = replace(
                config(Path(directory)),
                deployment_id="pinned-local",
                attestations={
                    "controller": ContractAttestation(proxy_hash, implementation, implementation_hash)
                },
            )
            responses = snapshot_responses(calls=[NO_OP, NO_ROLLOVER, OUTSIDE_WINDOW])
            responses.update(
                {
                    "eth_getCode": ["0x6000", "0x6001"],
                    "eth_getProof": [{"codeHash": proxy_hash}, {"codeHash": implementation_hash}],
                    "eth_getStorageAt": "0x" + "00" * 12 + implementation[2:],
                }
            )
            events = []
            result = KeeperEngine(
                cfg,
                FakeRpc(responses),
                KeeperState(cfg.state_file),
                emit=events.append,
            ).run_cycle()
            self.assertEqual(result["status"], "dry_run")
            snapshot = next(event for event in events if event["event"] == "snapshot")
            self.assertEqual(snapshot["verifiedAttestations"]["controller"]["implementation"], implementation)

            mismatched = replace(
                cfg,
                attestations={
                    "controller": ContractAttestation("0x" + "ff" * 32, implementation, implementation_hash)
                },
            )
            bad_responses = snapshot_responses(calls=[])
            bad_responses.update({"eth_getProof": {"codeHash": proxy_hash}})
            with self.assertRaisesRegex(RuntimeError, "proxy codehash mismatch"):
                KeeperEngine(
                    mismatched,
                    FakeRpc(bad_responses),
                    KeeperState(mismatched.state_file),
                ).run_cycle()


if __name__ == "__main__":
    unittest.main()
