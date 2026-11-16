from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from keeper.soak import run_soak


class KeeperSoakTests(unittest.TestCase):
    def test_deterministic_long_sequence_preserves_safety_invariants(self) -> None:
        with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
            first = run_soak(300, 20261116, Path(first_dir))
            second = run_soak(300, 20261116, Path(second_dir))

        self.assertTrue(first["passed"])
        self.assertTrue(all(first["invariants"].values()))
        self.assertGreater(first["main"]["rpcFailovers"], 0)
        self.assertGreater(first["main"]["reverted"], 0)
        self.assertGreater(first["main"]["restarts"], 0)
        self.assertEqual(first["ambiguous"]["sendAttempts"], 1)
        self.assertEqual(first["ambiguous"]["pendingStatus"], "ambiguous")
        self.assertEqual(first, second)

    def test_soak_rejects_too_short_runs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, "at least 100"):
                run_soak(99, 1, Path(directory))


if __name__ == "__main__":
    unittest.main()
