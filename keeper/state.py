from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path
from typing import Any


class KeeperState:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, Any] = {"schemaVersion": 1, "pending": {}}
        self.load()

    @property
    def pending(self) -> dict[str, dict[str, Any]]:
        value = self.data.setdefault("pending", {})
        if not isinstance(value, dict):
            raise ValueError("keeper state pending field is corrupt")
        return value

    def load(self) -> None:
        if not self.path.exists():
            return
        with self.path.open(encoding="utf-8") as handle:
            loaded = json.load(handle)
        if not isinstance(loaded, dict) or loaded.get("schemaVersion") != 1:
            raise ValueError("unsupported keeper state file")
        self.data = loaded

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                json.dump(self.data, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def set_pending(self, target: str, record: dict[str, Any]) -> None:
        self.pending[target.lower()] = record
        self.save()

    def clear_pending(self, target: str) -> None:
        self.pending.pop(target.lower(), None)
        self.save()
