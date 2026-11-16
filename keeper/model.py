from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any


NO_OP = "0x00219cf1"
OUT_OF_REBALANCE_WINDOW = "0xb4675acc"
LAST_REBALANCE_TOO_RECENT = "0xa3b3f090"
INSUFFICIENT_ROLLOVER = "0xbbb27b39"
OP_UNAVAILABLE = "0xf0b62b3b"


@dataclass(frozen=True)
class MaintenanceTask:
    """One permissionless maintenance call.

    Priorities and cross-task ordering are BNB-DESIGN. Function selectors and
    the benign business reverts are backed by the public target evidence.
    """

    name: str
    target: str
    calldata: str
    priority: int
    benign_selectors: frozenset[str] = field(default_factory=frozenset)
    evidence: str = "TARGET-CONFIRMED entry; BNB-DESIGN scheduling"

    @property
    def normalized_target(self) -> str:
        return self.target.lower()


@dataclass(frozen=True)
class SimulationResult:
    task: MaintenanceTask
    status: str
    block_number: int
    return_data: str | None = None
    revert_selector: str | None = None
    error: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "task": self.task.name,
            "target": self.task.target,
            "priority": self.task.priority,
            "status": self.status,
            "blockNumber": self.block_number,
            "returnData": self.return_data,
            "revertSelector": self.revert_selector,
            "error": self.error,
        }


def default_tasks(contracts: dict[str, str | None]) -> list[MaintenanceTask]:
    """Build the conservative public-maintenance task catalog.

    USD Vault ``swap`` is intentionally absent: it is an authorized inventory
    callback, not a permissionless keeper entry point.
    """

    definitions = (
        ("controller_upkeep", "controller", "0x2cf4704a", 10, {NO_OP}),
        ("controller_rollover", "controller", "0xb056b49a", 20, {INSUFFICIENT_ROLLOVER}),
        (
            "controller_rebalance",
            "controller",
            "0x7d7c2a1c",
            30,
            {OUT_OF_REBALANCE_WINDOW, LAST_REBALANCE_TOO_RECENT},
        ),
        (
            "junior_vault_rebalance",
            "juniorVault",
            "0x7d7c2a1c",
            40,
            {NO_OP, LAST_REBALANCE_TOO_RECENT, OP_UNAVAILABLE},
        ),
        (
            "senior_vault_rebalance",
            "seniorVault",
            "0x7d7c2a1c",
            41,
            {NO_OP, LAST_REBALANCE_TOO_RECENT, OP_UNAVAILABLE},
        ),
        ("usd_vault_upkeep", "usdVault", "0x2cf4704a", 50, {NO_OP}),
        (
            "usd_vault_rebalance",
            "usdVault",
            "0x7d7c2a1c",
            60,
            {NO_OP, LAST_REBALANCE_TOO_RECENT, OP_UNAVAILABLE},
        ),
    )
    tasks: list[MaintenanceTask] = []
    for name, key, calldata, priority, benign in definitions:
        address = contracts.get(key)
        if address:
            tasks.append(
                MaintenanceTask(
                    name=name,
                    target=address,
                    calldata=calldata,
                    priority=priority,
                    benign_selectors=frozenset(value.lower() for value in benign),
                )
            )
    return sorted(tasks, key=lambda task: (task.priority, task.name))
