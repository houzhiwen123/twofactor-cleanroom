from __future__ import annotations

import unittest

from keeper.rpc import RpcPool, RpcResponseError, RpcTransportError, safe_endpoint

from keeper_tests.helpers import FakeRpc


class RpcTests(unittest.TestCase):
    def test_read_transport_failure_rotates_to_backup(self) -> None:
        first = FakeRpc({"eth_blockNumber": RpcTransportError("primary down")}, "https://secret@one.test/key?a=b")
        second = FakeRpc({"eth_blockNumber": "0x2a"}, "https://two.test")
        failures = []
        pool = RpcPool([first, second], failures.append)
        self.assertEqual(pool.request("eth_blockNumber", []), "0x2a")
        self.assertEqual(len(failures), 1)
        self.assertNotIn("secret", safe_endpoint(first.endpoint))
        self.assertNotIn("key", safe_endpoint(first.endpoint))
        self.assertNotIn("a=b", safe_endpoint(first.endpoint))

    def test_deterministic_revert_does_not_fail_over(self) -> None:
        revert = RpcResponseError(-32000, "execution reverted", "0x00219cf1")
        first = FakeRpc({"eth_call": revert}, "fake://one")
        second = FakeRpc({"eth_call": "0x"}, "fake://two")
        pool = RpcPool([first, second])
        with self.assertRaises(RpcResponseError):
            pool.request("eth_call", [{}, "latest"])
        self.assertEqual(second.calls, [])

    def test_single_read_endpoint_retries_with_bounded_backoff(self) -> None:
        client = FakeRpc(
            {"eth_blockNumber": [RpcTransportError("one"), RpcTransportError("two"), "0x2a"]},
            "fake://one",
        )
        delays = []
        pool = RpcPool([client], max_attempts=3, base_backoff_sec=0.1, sleep=delays.append)
        self.assertEqual(pool.request("eth_blockNumber", []), "0x2a")
        self.assertEqual(delays, [0.1, 0.2])


if __name__ == "__main__":
    unittest.main()
