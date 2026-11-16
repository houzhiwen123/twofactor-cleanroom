from __future__ import annotations

import argparse
import json
import random
import tempfile
from collections import Counter
from dataclasses import replace
from pathlib import Path
from typing import Any

from .attestation import EIP1967_IMPLEMENTATION_SLOT
from .config import ContractAttestation, KeeperConfig
from .engine import KeeperEngine
from .manifest import _atomic_json
from .model import INSUFFICIENT_ROLLOVER, NO_OP, OUT_OF_REBALANCE_WINDOW
from .observability import KeeperObserver
from .rpc import RpcAttempt, RpcPool, RpcResponseError, RpcTransportError
from .signer import ExternalSignerClient
from .state import KeeperState


CONTROLLER = "0x0000000000000000000000000000000000001001"
IMPLEMENTATION = "0x0000000000000000000000000000000000002001"
CALLER = "0x000000000000000000000000000000000000beef"
PROXY_HASH = "0x" + "11" * 32
IMPLEMENTATION_HASH = "0x" + "22" * 32


class SoakBackend:
    def __init__(self, *, chain_id: int = 8453):
        self.chain_id = chain_id
        self.block_number = 1_000
        self.nonce = 0
        self.executable = False
        self.next_receipt_status = 1
        self.receipt_delay_blocks = 2
        self.ambiguous_next = False
        self.proxy_hash = PROXY_HASH
        self.implementation_hash = IMPLEMENTATION_HASH
        self.send_attempts = 0
        self.sent_hashes: list[str] = []
        self.receipts: dict[str, dict[str, Any]] = {}
        self.active_hash: str | None = None
        self.concurrent_send_violations = 0
        self.eth_call_count = 0

    @property
    def block_tag(self) -> str:
        return hex(self.block_number)

    @property
    def block_hash(self) -> str:
        return "0x" + f"{self.block_number:064x}"

    def advance(self, blocks: int = 1) -> None:
        self.block_number += blocks

    def read(self, method: str, params: list[Any]) -> Any:
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_blockNumber":
            return self.block_tag
        if method == "eth_getBlockByNumber":
            return {
                "number": params[0],
                "hash": "0x" + f"{int(params[0], 16):064x}",
                "timestamp": hex(1_800_000_000 + int(params[0], 16) * 2),
            }
        if method == "eth_getBalance":
            return hex(10**18)
        if method == "eth_getCode":
            address = params[0].lower()
            if address == CONTROLLER.lower():
                return "0x6000"
            if address == IMPLEMENTATION.lower():
                return "0x6001"
            return "0x"
        if method == "eth_getProof":
            address = params[0].lower()
            if address == CONTROLLER.lower():
                return {"codeHash": self.proxy_hash}
            if address == IMPLEMENTATION.lower():
                return {"codeHash": self.implementation_hash}
            return {"codeHash": "0x" + "00" * 32}
        if method == "eth_getStorageAt":
            if params[0].lower() != CONTROLLER.lower() or params[1] != EIP1967_IMPLEMENTATION_SLOT:
                return "0x" + "00" * 32
            return "0x" + "00" * 12 + IMPLEMENTATION[2:]
        if method == "eth_call":
            self.eth_call_count += 1
            selector = params[0]["data"].lower()
            if selector == "0x2cf4704a":
                if self.executable:
                    return "0x"
                raise RpcResponseError(-32000, "execution reverted", NO_OP)
            if selector == "0xb056b49a":
                raise RpcResponseError(-32000, "execution reverted", INSUFFICIENT_ROLLOVER)
            if selector == "0x7d7c2a1c":
                raise RpcResponseError(-32000, "execution reverted", OUT_OF_REBALANCE_WINDOW)
            raise RpcResponseError(-32000, "execution reverted", "0xdeadbeef")
        if method == "eth_estimateGas":
            return hex(100_000)
        if method == "eth_getTransactionReceipt":
            tx_hash = params[0]
            record = self.receipts.get(tx_hash)
            if record is None or self.block_number < record["availableAt"]:
                return None
            if self.active_hash == tx_hash:
                self.active_hash = None
            return {
                "status": hex(record["status"]),
                "blockNumber": hex(record["blockNumber"]),
                "transactionHash": tx_hash,
            }
        raise AssertionError(f"unexpected soak read method {method}")

    def submit(self, method: str, params: list[Any]) -> Any:
        if method == "eth_chainId":
            return hex(self.chain_id)
        if method == "eth_getTransactionCount":
            return hex(self.nonce)
        if method != "eth_sendTransaction":
            raise AssertionError(f"unexpected soak submit method {method}")
        self.send_attempts += 1
        if self.active_hash is not None:
            self.concurrent_send_violations += 1
        if self.ambiguous_next:
            self.ambiguous_next = False
            raise RpcTransportError("deterministic ambiguous send")
        self.nonce += 1
        tx_hash = "0x" + f"{self.nonce:064x}"
        self.sent_hashes.append(tx_hash)
        self.active_hash = tx_hash
        receipt_block = self.block_number + self.receipt_delay_blocks
        self.receipts[tx_hash] = {
            "status": self.next_receipt_status,
            "availableAt": receipt_block,
            "blockNumber": receipt_block,
        }
        self.executable = False
        return tx_hash


class SoakReadClient:
    def __init__(self, backend: SoakBackend, endpoint: str, fail_every: int, offset: int = 0):
        self.backend = backend
        self.endpoint = endpoint
        self.fail_every = fail_every
        self.offset = offset
        self.calls = 0

    def request(self, method: str, params: list[Any]) -> Any:
        self.calls += 1
        if self.fail_every and (self.calls + self.offset) % self.fail_every == 0:
            raise RpcTransportError(f"{self.endpoint}: injected transport fault")
        return self.backend.read(method, params)


class SoakSubmitTransport:
    endpoint = "https://managed-signer.invalid"

    def __init__(self, backend: SoakBackend):
        self.backend = backend

    def request(self, method: str, params: list[Any]) -> Any:
        return self.backend.submit(method, params)


def _config(root: Path, *, live: bool = True) -> KeeperConfig:
    return KeeperConfig(
        chain_id=8453,
        read_rpc_urls=("https://read-a.invalid", "https://read-b.invalid"),
        submit_rpc_url="https://managed-signer.invalid" if live else None,
        from_address=CALLER,
        contracts={"controller": CONTROLLER, "juniorVault": None, "seniorVault": None, "usdVault": None},
        state_file=root / "state.json",
        deployment_id="deterministic-soak",
        submission_mode="managed-rpc" if live else "disabled",
        attestations={
            "controller": ContractAttestation(PROXY_HASH, IMPLEMENTATION, IMPLEMENTATION_HASH)
        },
        alert_cooldown_sec=0,
        pending_warning_sec=4,
        pending_critical_sec=12,
        live=live,
        poll_interval_sec=0,
        confirmations=2,
        gas_multiplier_bps=12_000,
        max_gas=3_000_000,
        rpc_timeout_sec=1,
        read_rpc_attempts=2,
        retry_base_delay_sec=0,
    )


def _clock(backend: SoakBackend) -> float:
    return float(1_800_000_000 + backend.block_number * 2)


def _engine(
    backend: SoakBackend,
    config: KeeperConfig,
    events: list[dict[str, Any]],
) -> KeeperEngine:
    observer = KeeperObserver(config, stream=events.append, clock=lambda: _clock(backend))
    clients = [
        SoakReadClient(backend, "https://read-a.invalid", 19),
        SoakReadClient(backend, "https://read-b.invalid", 23, offset=7),
    ]
    pool = RpcPool(
        clients,
        on_failover=lambda attempt: observer.emit(
            {"event": "rpc_failover", "endpoint": attempt.endpoint, "error": attempt.error}
        ),
        max_attempts=2,
        base_backoff_sec=0,
    )
    signer = ExternalSignerClient(SoakSubmitTransport(backend), config.from_address, "managed-rpc")
    observer.emit(signer.preflight(config.chain_id).to_event("managed-rpc"))
    return KeeperEngine(
        config,
        pool,
        KeeperState(config.state_file),
        submit_rpc=signer,
        allow_broadcast=config.live,
        emit=observer.emit,
        clock=lambda: _clock(backend),
    )


def _event_counts(events: list[dict[str, Any]]) -> Counter[str]:
    return Counter(str(event.get("event")) for event in events)


def run_soak(cycles: int, seed: int, output_root: Path) -> dict[str, Any]:
    if cycles < 100:
        raise ValueError("soak cycles must be at least 100")
    rng = random.Random(seed)
    output_root.mkdir(parents=True, exist_ok=True)

    main_root = output_root / "main"
    main_config = _config(main_root)
    backend = SoakBackend()
    events: list[dict[str, Any]] = []
    engine = _engine(backend, main_config, events)
    statuses: Counter[str] = Counter()
    restarts = 0
    restart_after_first_submission = True

    for cycle in range(cycles):
        backend.advance()
        if not KeeperState(main_config.state_file).pending:
            backend.executable = rng.randrange(9) == 0
            backend.next_receipt_status = 0 if (backend.nonce + 1) % 7 == 0 else 1
        result = engine.run_cycle()
        statuses[result["status"]] += 1
        if result["status"] == "submitted" and restart_after_first_submission:
            engine = _engine(backend, main_config, events)
            restarts += 1
            restart_after_first_submission = False
        elif (cycle + 1) % 97 == 0:
            engine = _engine(backend, main_config, events)
            restarts += 1

    for _ in range(20):
        if not KeeperState(main_config.state_file).pending:
            break
        backend.advance()
        statuses[engine.run_cycle()["status"]] += 1

    main_events = _event_counts(events)
    confirmed_or_reverted = main_events["receipt_confirmed"] + main_events["receipt_reverted"]
    main_invariants = {
        "noConcurrentSend": backend.concurrent_send_violations == 0,
        "uniqueTransactionHashes": len(set(backend.sent_hashes)) == len(backend.sent_hashes),
        "allSentTransactionsReconciled": confirmed_or_reverted == len(backend.sent_hashes),
        "finalSingleFlightEmpty": KeeperState(main_config.state_file).pending == {},
        "receiptPendingObserved": main_events["receipt_pending"] > 0,
        "receiptRevertObserved": main_events["receipt_reverted"] > 0,
        "rpcFailoverObserved": main_events["rpc_failover"] > 0,
        "restartWhilePendingObserved": restarts > 0 and main_events["receipt_confirmed"] > 0,
    }

    ambiguous_root = output_root / "ambiguous"
    ambiguous_config = _config(ambiguous_root)
    ambiguous_backend = SoakBackend()
    ambiguous_backend.executable = True
    ambiguous_backend.ambiguous_next = True
    ambiguous_events: list[dict[str, Any]] = []
    ambiguous_engine = _engine(ambiguous_backend, ambiguous_config, ambiguous_events)
    first_ambiguous = ambiguous_engine.run_cycle()
    for _ in range(20):
        ambiguous_backend.advance()
        ambiguous_engine = _engine(ambiguous_backend, ambiguous_config, ambiguous_events)
        ambiguous_engine.run_cycle()
    ambiguous_record = next(iter(KeeperState(ambiguous_config.state_file).pending.values()))
    ambiguous_invariants = {
        "firstResultAmbiguous": first_ambiguous["status"] == "submission_ambiguous",
        "exactlyOneSendAttempt": ambiguous_backend.send_attempts == 1,
        "persistentAmbiguousLock": ambiguous_record.get("status") == "ambiguous",
        "blockedAfterRestart": _event_counts(ambiguous_events)["submission_blocked"] >= 20,
    }

    drift_root = output_root / "drift"
    drift_config = replace(_config(drift_root), live=False, submit_rpc_url=None, submission_mode="disabled")
    drift_backend = SoakBackend()
    drift_backend.proxy_hash = "0x" + "ff" * 32
    drift_events: list[dict[str, Any]] = []
    drift_engine = _engine(drift_backend, drift_config, drift_events)
    drift_rejected = False
    try:
        drift_engine.run_cycle()
    except RuntimeError as exc:
        drift_rejected = "proxy codehash mismatch" in str(exc)
    drift_invariants = {
        "attestationDriftRejected": drift_rejected,
        "noSimulationAfterDrift": drift_backend.eth_call_count == 0,
        "noSendAfterDrift": drift_backend.send_attempts == 0,
    }

    invariants = {**main_invariants, **ambiguous_invariants, **drift_invariants}
    result = {
        "schemaVersion": 1,
        "classification": "LOCAL-CLEANROOM/BNB-DESIGN",
        "seed": seed,
        "cyclesRequested": cycles,
        "passed": all(invariants.values()),
        "invariants": invariants,
        "main": {
            "statuses": dict(sorted(statuses.items())),
            "events": dict(sorted(main_events.items())),
            "restarts": restarts,
            "sendAttempts": backend.send_attempts,
            "uniqueTransactionHashes": len(set(backend.sent_hashes)),
            "confirmed": main_events["receipt_confirmed"],
            "reverted": main_events["receipt_reverted"],
            "rpcFailovers": main_events["rpc_failover"],
        },
        "ambiguous": {
            "sendAttempts": ambiguous_backend.send_attempts,
            "blockedEvents": _event_counts(ambiguous_events)["submission_blocked"],
            "pendingStatus": ambiguous_record.get("status"),
        },
        "attestationDrift": drift_invariants,
    }
    return result


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run deterministic clean-room Keeper chaos/soak scenarios")
    parser.add_argument("--cycles", type=int, default=1_000)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--output", default=".keeper/soak-result.json")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        with tempfile.TemporaryDirectory(prefix="keeper-soak-") as directory:
            result = run_soak(args.cycles, args.seed, Path(directory))
        output = Path(args.output).resolve()
        _atomic_json(output, result)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["passed"] else 1
    except (OSError, ValueError, RuntimeError, AssertionError) as exc:
        print(json.dumps({"classification": "LOCAL-CLEANROOM/BNB-DESIGN", "passed": False, "error": str(exc)}))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
