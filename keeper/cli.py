from __future__ import annotations

import argparse
import json
import sys
import time
from typing import Any

from .config import load_config
from .engine import KeeperEngine
from .rpc import HttpJsonRpcClient, RpcAttempt, RpcPool
from .state import KeeperState


def _write_event(event: dict[str, Any]) -> None:
    print(json.dumps(event, separators=(",", ":"), sort_keys=True), flush=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Clean-room maintenance Keeper (dry-run by default)")
    parser.add_argument("--config", required=True, help="path to keeper JSON config")
    parser.add_argument("--loop", action="store_true", help="poll continuously instead of one cycle")
    parser.add_argument(
        "--allow-broadcast",
        action="store_true",
        help="second live-mode opt-in; requires live=true and submitRpcUrl in config",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        config = load_config(args.config)
        clients = [HttpJsonRpcClient(url, config.rpc_timeout_sec) for url in config.read_rpc_urls]
        pool = RpcPool(
            clients,
            on_failover=lambda attempt: _write_event(
                {"event": "rpc_failover", "endpoint": attempt.endpoint, "error": attempt.error}
            ),
            max_attempts=config.read_rpc_attempts,
            base_backoff_sec=config.retry_base_delay_sec,
        )
        submitter = HttpJsonRpcClient(config.submit_rpc_url, config.rpc_timeout_sec) if config.submit_rpc_url else None
        engine = KeeperEngine(
            config,
            pool,
            KeeperState(config.state_file),
            submit_rpc=submitter,
            allow_broadcast=args.allow_broadcast,
            emit=_write_event,
        )
        while True:
            try:
                engine.run_cycle()
            except Exception as exc:
                _write_event({"event": "cycle_error", "error": type(exc).__name__, "message": str(exc)})
                if not args.loop:
                    return 1
            if not args.loop:
                return 0
            time.sleep(config.poll_interval_sec)
    except (OSError, ValueError) as exc:
        print(f"keeper configuration error: {exc}", file=sys.stderr)
        return 2
