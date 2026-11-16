from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from .config import load_config
from .engine import KeeperEngine
from .observability import KeeperObserver
from .rpc import HttpJsonRpcClient, RpcAttempt, RpcPool
from .signer import ExternalSignerClient
from .state import KeeperState


def _write_event(event: dict[str, Any]) -> None:
    print(json.dumps(event, separators=(",", ":"), sort_keys=True), flush=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Clean-room maintenance Keeper (dry-run by default)")
    parser.add_argument("--config", required=True, help="path to keeper JSON config")
    parser.add_argument("--loop", action="store_true", help="poll continuously instead of one cycle")
    parser.add_argument(
        "--preflight-only",
        action="store_true",
        help="validate deployment/signer and simulate one fixed block without broadcasting",
    )
    parser.add_argument(
        "--allow-broadcast",
        action="store_true",
        help="second live-mode opt-in; requires live=true and submitRpcUrl in config",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.preflight_only and (args.loop or args.allow_broadcast):
        print("keeper configuration error: --preflight-only cannot be combined with --loop or --allow-broadcast", file=sys.stderr)
        return 2
    try:
        config = load_config(args.config)
        observer = KeeperObserver(config, stream=_write_event)
        clients = [HttpJsonRpcClient(url, config.rpc_timeout_sec) for url in config.read_rpc_urls]
        pool = RpcPool(
            clients,
            on_failover=lambda attempt: observer.emit(
                {"event": "rpc_failover", "endpoint": attempt.endpoint, "error": attempt.error}
            ),
            max_attempts=config.read_rpc_attempts,
            base_backoff_sec=config.retry_base_delay_sec,
        )
        submitter = None
        if config.submit_rpc_url:
            transport = HttpJsonRpcClient(config.submit_rpc_url, config.rpc_timeout_sec)
            submitter = ExternalSignerClient(transport, config.from_address, config.submission_mode)
            try:
                observer.emit(submitter.preflight(config.chain_id).to_event(config.submission_mode))
            except Exception as exc:
                observer.emit(
                    {
                        "event": "cycle_error",
                        "phase": "submission_preflight",
                        "error": type(exc).__name__,
                        "message": str(exc),
                    }
                )
                return 1
        engine = KeeperEngine(
            config,
            pool,
            KeeperState(config.state_file),
            submit_rpc=submitter,
            allow_broadcast=args.allow_broadcast and not args.preflight_only,
            emit=observer.emit,
        )
        if args.preflight_only:
            try:
                result = engine.run_cycle()
            except Exception as exc:
                observer.emit(
                    {
                        "event": "cycle_error",
                        "phase": "deployment_preflight",
                        "error": type(exc).__name__,
                        "message": str(exc),
                    }
                )
                return 1
            observer.emit(
                {
                    "event": "preflight_complete",
                    "executableTask": result.get("event", {}).get("executableTask"),
                    "hardErrorCount": result.get("event", {}).get("hardErrorCount", 0),
                }
            )
            return 0
        while True:
            try:
                engine.run_cycle()
            except Exception as exc:
                observer.emit({"event": "cycle_error", "error": type(exc).__name__, "message": str(exc)})
                if not args.loop:
                    return 1
            if not args.loop:
                return 0
            time.sleep(config.poll_interval_sec)
    except (OSError, ValueError) as exc:
        print(f"keeper configuration error: {exc}", file=sys.stderr)
        return 2
