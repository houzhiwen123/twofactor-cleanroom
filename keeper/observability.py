from __future__ import annotations

import json
import os
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any, Callable

from .config import KeeperConfig


ALERT_RULES: dict[str, tuple[str, str, str]] = {
    "rpc_failover": (
        "warning",
        "RPC_FAILOVER",
        "Read RPC failed over; check the unhealthy provider and recent latency/error rate.",
    ),
    "blocked": (
        "critical",
        "TASK_BLOCKED",
        "No transaction was sent; inspect the higher-priority simulation error before resuming.",
    ),
    "submission_ambiguous": (
        "critical",
        "SUBMISSION_AMBIGUOUS",
        "Do not retry; reconcile the signer/RPC transaction by sender and nonce, then clear state manually.",
    ),
    "submission_blocked": (
        "critical",
        "SUBMISSION_BLOCKED",
        "Keeper is locked; reconcile the ambiguous submission before restarting live operation.",
    ),
    "receipt_reverted": (
        "critical",
        "RECEIPT_REVERTED",
        "Pause live operation and inspect the confirmed revert and dependency state before resuming.",
    ),
    "cycle_error": (
        "critical",
        "CYCLE_ERROR",
        "Inspect configuration/RPC health and keep live operation stopped until a dry-run succeeds.",
    ),
}


def _atomic_write(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _append_private_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(descriptor, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)


def _metric_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class KeeperObserver:
    def __init__(
        self,
        config: KeeperConfig,
        *,
        stream: Callable[[dict[str, Any]], None] | None = None,
        clock: Callable[[], float] = time.time,
    ):
        self.config = config
        self.stream = stream or (lambda _event: None)
        self.clock = clock
        self.started_at = int(clock())
        self.status = "starting"
        self.last_event = "starting"
        self.last_event_at = self.started_at
        self.last_cycle_at = 0
        self.last_success_at = 0
        self.pending_submission = False
        self.last_hard_error_count = 0
        self.event_counts: Counter[str] = Counter()
        self.alert_counts: Counter[str] = Counter()
        self._last_alert_at: dict[str, int] = {}
        self._write_outputs()

    def _alert(self, *, severity: str, code: str, message: str, action: str, timestamp: int) -> None:
        previous = self._last_alert_at.get(code)
        if previous is not None and timestamp - previous < self.config.alert_cooldown_sec:
            return
        self._last_alert_at[code] = timestamp
        alert = {
            "event": "alert",
            "timestamp": timestamp,
            "deploymentId": self.config.deployment_id,
            "severity": severity,
            "code": code,
            "message": message,
            "action": action,
        }
        self.alert_counts[severity] += 1
        if self.config.alerts_file:
            _append_private_json(self.config.alerts_file, alert)
        self.stream(alert)

    def _apply(self, event: dict[str, Any]) -> None:
        kind = str(event.get("event", "unknown"))
        timestamp = int(event["timestamp"])
        self.event_counts[kind] += 1
        self.last_event = kind
        self.last_event_at = timestamp

        if kind == "snapshot":
            self.last_cycle_at = timestamp
            self.last_hard_error_count = 0
        elif kind in ("idle", "submitted", "receipt_confirmed"):
            self.status = "degraded" if self.last_hard_error_count else "healthy"
            self.last_success_at = timestamp
        elif kind == "simulation" and event.get("status") == "error":
            self.last_hard_error_count += 1
            self.status = "degraded"
            self._alert(
                severity="warning",
                code="SIMULATION_ERROR",
                message=f"Unknown deterministic error in task {event.get('task', 'unknown')}.",
                action="Inspect the selector/error and keep that task disabled until its behavior is understood.",
                timestamp=timestamp,
            )
        elif kind == "dry_run_complete":
            self.last_success_at = timestamp
            self.last_hard_error_count = int(event.get("hardErrorCount", 0))
            self.status = "degraded" if self.last_hard_error_count else "healthy"
            if self.last_hard_error_count and self.event_counts["simulation"] == 0:
                self._alert(
                    severity="warning",
                    code="SIMULATION_HARD_ERRORS",
                    message=f"Dry-run observed {self.last_hard_error_count} unknown deterministic error(s).",
                    action="Inspect simulation selectors and keep broadcasting disabled until understood.",
                    timestamp=timestamp,
                )
        elif kind == "rpc_failover":
            self.status = "degraded"
        elif kind in ("blocked", "submission_ambiguous", "submission_blocked", "receipt_reverted", "cycle_error"):
            self.status = "critical"

        if kind == "submitted":
            self.pending_submission = True
        elif kind in ("receipt_confirmed", "receipt_reverted"):
            self.pending_submission = False
        elif kind in ("receipt_pending", "submission_ambiguous", "submission_blocked"):
            self.pending_submission = True

        if kind == "receipt_pending":
            age = int(event.get("pendingAgeSec", 0))
            if age >= self.config.pending_critical_sec:
                self.status = "critical"
                self._alert(
                    severity="critical",
                    code="RECEIPT_STALE_CRITICAL",
                    message=f"Pending maintenance transaction is {age} seconds old.",
                    action="Check the transaction/nonce; do not manually resend until the original is reconciled.",
                    timestamp=timestamp,
                )
            elif age >= self.config.pending_warning_sec:
                self.status = "degraded"
                self._alert(
                    severity="warning",
                    code="RECEIPT_STALE_WARNING",
                    message=f"Pending maintenance transaction is {age} seconds old.",
                    action="Check signer and RPC propagation while preserving the single-flight lock.",
                    timestamp=timestamp,
                )

        rule = ALERT_RULES.get(kind)
        if rule:
            severity, code, action = rule
            self._alert(
                severity=severity,
                code=code,
                message=f"Keeper emitted {kind} for deployment {self.config.deployment_id}.",
                action=action,
                timestamp=timestamp,
            )

    def _health(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "deploymentId": self.config.deployment_id,
            "status": self.status,
            "startedAt": self.started_at,
            "lastEvent": self.last_event,
            "lastEventAt": self.last_event_at,
            "lastCycleAt": self.last_cycle_at,
            "lastSuccessAt": self.last_success_at,
            "pendingSubmission": self.pending_submission,
            "lastHardErrorCount": self.last_hard_error_count,
            "alertCounts": dict(sorted(self.alert_counts.items())),
        }

    def _metrics(self) -> str:
        deployment = _metric_label(self.config.deployment_id)
        status_value = {"starting": 0, "healthy": 1, "degraded": 2, "critical": 3}[self.status]
        lines = [
            "# HELP keeper_health_status Keeper health: 0 starting, 1 healthy, 2 degraded, 3 critical.",
            "# TYPE keeper_health_status gauge",
            f'keeper_health_status{{deployment="{deployment}"}} {status_value}',
            "# HELP keeper_pending_submission Whether one maintenance transaction is in flight.",
            "# TYPE keeper_pending_submission gauge",
            f'keeper_pending_submission{{deployment="{deployment}"}} {int(self.pending_submission)}',
            "# HELP keeper_last_event_timestamp_seconds Unix time of the most recent event.",
            "# TYPE keeper_last_event_timestamp_seconds gauge",
            f'keeper_last_event_timestamp_seconds{{deployment="{deployment}"}} {self.last_event_at}',
            "# HELP keeper_last_success_timestamp_seconds Unix time of the most recent successful cycle outcome.",
            "# TYPE keeper_last_success_timestamp_seconds gauge",
            f'keeper_last_success_timestamp_seconds{{deployment="{deployment}"}} {self.last_success_at}',
            "# HELP keeper_simulation_hard_errors Unknown deterministic errors in the latest dry-run.",
            "# TYPE keeper_simulation_hard_errors gauge",
            f'keeper_simulation_hard_errors{{deployment="{deployment}"}} {self.last_hard_error_count}',
            "# HELP keeper_events_total Keeper events observed since process start.",
            "# TYPE keeper_events_total counter",
        ]
        for event, count in sorted(self.event_counts.items()):
            lines.append(f'keeper_events_total{{deployment="{deployment}",event="{_metric_label(event)}"}} {count}')
        lines.extend(
            [
                "# HELP keeper_alerts_total Keeper alerts emitted since process start.",
                "# TYPE keeper_alerts_total counter",
            ]
        )
        for severity, count in sorted(self.alert_counts.items()):
            lines.append(
                f'keeper_alerts_total{{deployment="{deployment}",severity="{_metric_label(severity)}"}} {count}'
            )
        return "\n".join(lines) + "\n"

    def _write_outputs(self) -> None:
        if self.config.health_file:
            _atomic_write(
                self.config.health_file,
                json.dumps(self._health(), indent=2, sort_keys=True) + "\n",
            )
        if self.config.metrics_file:
            _atomic_write(self.config.metrics_file, self._metrics())

    def emit(self, raw_event: dict[str, Any]) -> None:
        event = dict(raw_event)
        event.setdefault("timestamp", int(self.clock()))
        self.stream(event)
        self._apply(event)
        self._write_outputs()
