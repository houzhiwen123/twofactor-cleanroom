from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from keeper.observability import KeeperObserver

from keeper_tests.helpers import config


class KeeperObserverTests(unittest.TestCase):
    def test_health_metrics_and_deduplicated_alerts_are_private(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [100.0]
            cfg = replace(
                config(root),
                deployment_id="prod-a",
                health_file=root / "health.json",
                metrics_file=root / "metrics.prom",
                alerts_file=root / "alerts.jsonl",
                alert_cooldown_sec=300,
            )
            streamed: list[dict[str, object]] = []
            observer = KeeperObserver(cfg, stream=streamed.append, clock=lambda: now[0])
            observer.emit({"event": "rpc_failover", "endpoint": "https://rpc.example", "error": "timeout"})
            now[0] = 101
            observer.emit({"event": "rpc_failover", "endpoint": "https://rpc.example", "error": "timeout"})
            now[0] = 102
            observer.emit({"event": "blocked", "reason": "unknown deterministic error"})

            health = json.loads(cfg.health_file.read_text())
            self.assertEqual(health["status"], "critical")
            self.assertEqual(health["alertCounts"], {"critical": 1, "warning": 1})
            metrics = cfg.metrics_file.read_text()
            self.assertIn('keeper_events_total{deployment="prod-a",event="rpc_failover"} 2', metrics)
            self.assertIn('keeper_events_total{deployment="prod-a",event="blocked"} 1', metrics)
            alerts = [json.loads(line) for line in cfg.alerts_file.read_text().splitlines()]
            self.assertEqual([alert["code"] for alert in alerts], ["RPC_FAILOVER", "TASK_BLOCKED"])
            self.assertEqual(sum(event.get("event") == "alert" for event in streamed), 2)
            for path in (cfg.health_file, cfg.metrics_file, cfg.alerts_file):
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_stale_receipt_has_warning_and_critical_boundaries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cfg = replace(
                config(root),
                deployment_id="prod-b",
                alerts_file=root / "alerts.jsonl",
                alert_cooldown_sec=0,
                pending_warning_sec=10,
                pending_critical_sec=20,
            )
            observer = KeeperObserver(cfg, clock=lambda: 200)
            observer.emit({"event": "receipt_pending", "pendingAgeSec": 10})
            self.assertEqual(observer.status, "degraded")
            observer.emit({"event": "receipt_pending", "pendingAgeSec": 20})
            self.assertEqual(observer.status, "critical")
            alerts = [json.loads(line) for line in cfg.alerts_file.read_text().splitlines()]
            self.assertEqual(
                [alert["code"] for alert in alerts],
                ["RECEIPT_STALE_WARNING", "RECEIPT_STALE_CRITICAL"],
            )


if __name__ == "__main__":
    unittest.main()
