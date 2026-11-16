from __future__ import annotations

import math
import re
import time
from typing import Any, Callable

from .config import KeeperConfig
from .model import MaintenanceTask, SimulationResult
from .rpc import RpcResponseError, RpcTransportError
from .state import KeeperState


TX_HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")


def _hex_int(value: str) -> int:
    return int(value, 16)


class KeeperEngine:
    def __init__(
        self,
        config: KeeperConfig,
        read_rpc: Any,
        state: KeeperState,
        *,
        submit_rpc: Any | None = None,
        allow_broadcast: bool = False,
        emit: Callable[[dict[str, Any]], None] | None = None,
        clock: Callable[[], float] = time.time,
    ):
        self.config = config
        self.read_rpc = read_rpc
        self.submit_rpc = submit_rpc
        self.state = state
        self.allow_broadcast = allow_broadcast
        self.emit = emit or (lambda _event: None)
        self.clock = clock

    @property
    def broadcast_enabled(self) -> bool:
        return self.config.live and self.allow_broadcast and self.submit_rpc is not None

    def _event(self, kind: str, **fields: Any) -> dict[str, Any]:
        event = {"event": kind, "timestamp": int(self.clock()), **fields}
        self.emit(event)
        return event

    def _snapshot(self) -> tuple[int, str]:
        chain_id = _hex_int(self.read_rpc.request("eth_chainId", []))
        if chain_id != self.config.chain_id:
            raise RuntimeError(f"chain ID mismatch: expected {self.config.chain_id}, got {chain_id}")
        block_tag = self.read_rpc.request("eth_blockNumber", [])
        block_number = _hex_int(block_tag)
        block = self.read_rpc.request("eth_getBlockByNumber", [block_tag, False])
        if not isinstance(block, dict) or block.get("number") != block_tag:
            raise RuntimeError("RPC returned an inconsistent block snapshot")
        sender_balance = _hex_int(self.read_rpc.request("eth_getBalance", [self.config.from_address, block_tag]))
        code_sizes: dict[str, int] = {}
        for target in sorted({task.normalized_target for task in self.config.tasks}):
            code = self.read_rpc.request("eth_getCode", [target, block_tag])
            if not isinstance(code, str) or code in ("0x", "0x0"):
                raise RuntimeError(f"maintenance target has no code at block {block_number}: {target}")
            code_sizes[target] = max((len(code) - 2) // 2, 0)
        self._event(
            "snapshot",
            chainId=chain_id,
            blockNumber=block_number,
            blockTag=block_tag,
            blockHash=block.get("hash"),
            blockTimestamp=_hex_int(block["timestamp"]) if block.get("timestamp") else None,
            senderBalanceWei=sender_balance,
            targetCodeBytes=code_sizes,
        )
        return block_number, block_tag

    def simulate(self, task: MaintenanceTask, block_number: int, block_tag: str) -> SimulationResult:
        transaction = {"from": self.config.from_address, "to": task.target, "data": task.calldata}
        try:
            result = self.read_rpc.request("eth_call", [transaction, block_tag])
            simulation = SimulationResult(task, "executable", block_number, return_data=result)
        except RpcResponseError as exc:
            selector = exc.revert_selector
            if selector and selector in task.benign_selectors:
                simulation = SimulationResult(task, "not_needed", block_number, revert_selector=selector)
            else:
                simulation = SimulationResult(
                    task,
                    "error",
                    block_number,
                    revert_selector=selector,
                    error=str(exc),
                )
        self._event("simulation", **simulation.to_dict())
        return simulation

    def _reconcile_pending(self) -> dict[str, Any] | None:
        if not self.state.pending:
            return None
        # Global single-flight is a conservative BNB-DESIGN policy. The state
        # remains keyed per target so a future reviewed policy can relax it.
        target, record = next(iter(self.state.pending.items()))
        status = record.get("status")
        tx_hash = record.get("txHash")
        if status in ("submitting", "ambiguous") or not tx_hash:
            return self._event(
                "submission_blocked",
                target=target,
                task=record.get("task"),
                reason="ambiguous submission requires operator reconciliation",
            )
        receipt = self.read_rpc.request("eth_getTransactionReceipt", [tx_hash])
        if receipt is None:
            return self._event("receipt_pending", target=target, task=record.get("task"), txHash=tx_hash)
        current_block = _hex_int(self.read_rpc.request("eth_blockNumber", []))
        receipt_block = _hex_int(receipt["blockNumber"])
        confirmations = current_block - receipt_block + 1
        if confirmations < self.config.confirmations:
            return self._event(
                "receipt_pending",
                target=target,
                task=record.get("task"),
                txHash=tx_hash,
                confirmations=confirmations,
            )
        succeeded = _hex_int(receipt.get("status", "0x0")) == 1
        self.state.clear_pending(target)
        return self._event(
            "receipt_confirmed" if succeeded else "receipt_reverted",
            target=target,
            task=record.get("task"),
            txHash=tx_hash,
            blockNumber=receipt_block,
            confirmations=confirmations,
            rescanRequired=True,
        )

    def _submit(self, task: MaintenanceTask, block_number: int, block_tag: str) -> dict[str, Any]:
        transaction = {"from": self.config.from_address, "to": task.target, "data": task.calldata}
        estimate = _hex_int(self.read_rpc.request("eth_estimateGas", [transaction, block_tag]))
        gas = math.ceil(estimate * self.config.gas_multiplier_bps / 10_000)
        if gas > self.config.max_gas:
            raise RuntimeError(f"gas estimate {gas} exceeds configured maxGas {self.config.max_gas}")
        transaction["gas"] = hex(gas)
        record = {
            "task": task.name,
            "target": task.target,
            "status": "submitting",
            "submittedAt": int(self.clock()),
            "submittedBlock": block_number,
        }
        self.state.set_pending(task.normalized_target, record)
        try:
            tx_hash = self.submit_rpc.request("eth_sendTransaction", [transaction])
            if not isinstance(tx_hash, str) or not TX_HASH_RE.fullmatch(tx_hash):
                raise RpcTransportError("submit RPC returned an invalid transaction hash")
        except Exception as exc:
            record["status"] = "ambiguous"
            record["error"] = type(exc).__name__
            self.state.set_pending(task.normalized_target, record)
            return self._event(
                "submission_ambiguous",
                task=task.name,
                target=task.target,
                reason=type(exc).__name__,
            )
        record["status"] = "pending"
        record["txHash"] = tx_hash
        record["gas"] = gas
        self.state.set_pending(task.normalized_target, record)
        return self._event("submitted", task=task.name, target=task.target, txHash=tx_hash, gas=gas)

    def run_cycle(self) -> dict[str, Any]:
        pending = self._reconcile_pending()
        if pending is not None:
            return {"status": pending["event"], "event": pending}

        block_number, block_tag = self._snapshot()
        simulations = [self.simulate(task, block_number, block_tag) for task in self.config.tasks]
        executable = next((result for result in simulations if result.status == "executable"), None)
        hard_errors = [result for result in simulations if result.status == "error"]
        if not self.broadcast_enabled:
            event = self._event(
                "dry_run_complete",
                blockNumber=block_number,
                executableTask=executable.task.name if executable else None,
                hardErrorCount=len(hard_errors),
            )
            return {"status": "dry_run", "event": event, "simulations": [item.to_dict() for item in simulations]}
        if executable is None:
            status = "blocked" if hard_errors else "idle"
            event = self._event(status, blockNumber=block_number, hardErrorCount=len(hard_errors))
            return {"status": status, "event": event, "simulations": [item.to_dict() for item in simulations]}
        if any(error.task.priority < executable.task.priority for error in hard_errors):
            event = self._event(
                "blocked",
                blockNumber=block_number,
                reason="higher-priority task has an unknown deterministic error",
            )
            return {"status": "blocked", "event": event, "simulations": [item.to_dict() for item in simulations]}
        event = self._submit(executable.task, block_number, block_tag)
        return {"status": event["event"], "event": event, "simulations": [item.to_dict() for item in simulations]}
