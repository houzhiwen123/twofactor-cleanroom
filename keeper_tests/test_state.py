from __future__ import annotations

import stat
import tempfile
import unittest
from pathlib import Path

from keeper.state import KeeperState


class StateTests(unittest.TestCase):
    def test_state_is_atomic_private_and_reloadable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "nested/state.json"
            state = KeeperState(path)
            state.set_pending("0xabc", {"status": "ambiguous", "task": "test"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(KeeperState(path).pending["0xabc"]["status"], "ambiguous")


if __name__ == "__main__":
    unittest.main()
