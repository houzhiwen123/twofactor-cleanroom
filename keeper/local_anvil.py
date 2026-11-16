from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import socket
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .config import load_config
from .engine import KeeperEngine
from .rpc import HttpJsonRpcClient, RpcPool
from .state import KeeperState


LOCAL_ADMIN = "0x00000000000000000000000000000000000A11cE"
CHAIN_ID = 31_337
GENESIS_TIMESTAMP = 1_800_000_000
NEXT_ISSUE_TIMESTAMP = 1_800_558_000
FIRST_STALE_TIMESTAMP = 1_801_767_600
ADDRESS_KEYS = ("controller", "jrVault", "srVault", "usdVault")
ADDRESS_RE = re.compile(
    rf"\b({'|'.join(ADDRESS_KEYS)})\s*:?[ \t]+(0x[0-9a-fA-F]{{40}})\b"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def require_loopback_rpc(url: str) -> None:
    parsed = urlsplit(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("local E2E RPC must be an HTTP(S) loopback URL")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise ValueError("local E2E RPC must use a literal loopback IP") from exc
    if not address.is_loopback:
        raise ValueError("local E2E refuses every non-loopback RPC")


def parse_deployment_log(output: str) -> dict[str, str]:
    clean = ANSI_RE.sub("", output)
    addresses = {match.group(1): match.group(2) for match in ADDRESS_RE.finditer(clean)}
    missing = sorted(set(ADDRESS_KEYS) - set(addresses))
    if missing:
        raise ValueError("deployment output is missing addresses: " + ", ".join(missing))
    return addresses


def _atomic_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_keeper_config(
    path: Path,
    *,
    rpc_urls: list[str],
    submit_rpc_url: str | None,
    addresses: dict[str, str | None],
    state_file: Path,
    live: bool,
) -> None:
    for url in rpc_urls:
        require_loopback_rpc(url)
    if submit_rpc_url:
        require_loopback_rpc(submit_rpc_url)
    contracts = {
        "controller": addresses.get("controller"),
        "juniorVault": addresses.get("juniorVault") or addresses.get("jrVault"),
        "seniorVault": addresses.get("seniorVault") or addresses.get("srVault"),
        "usdVault": addresses.get("usdVault"),
    }
    _atomic_json(
        path,
        {
            "schemaVersion": 1,
            "chainId": CHAIN_ID,
            "readRpcUrls": rpc_urls,
            "submitRpcUrl": submit_rpc_url,
            "from": LOCAL_ADMIN,
            "contracts": contracts,
            "stateFile": str(state_file),
            "live": live,
            "pollIntervalSec": 0,
            "confirmations": 1,
            "gasMultiplierBps": 12_000,
            "maxGas": 15_000_000,
            "rpcTimeoutSec": 2,
            "readRpcAttempts": max(2, len(rpc_urls)),
            "retryBaseDelaySec": 0.01,
        },
    )


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


@dataclass
class LocalAnvilResult:
    deployment: dict[str, str]
    dry_run_task: str
    submitted: list[dict[str, str]]
    idle_after_rebalance: bool
    rpc_failovers: int

    def to_dict(self) -> dict[str, Any]:
        return {
            "classification": "LOCAL-CLEANROOM/BNB-DESIGN",
            "chainId": CHAIN_ID,
            "deployment": self.deployment,
            "dryRunTask": self.dry_run_task,
            "submitted": self.submitted,
            "idleAfterRebalance": self.idle_after_rebalance,
            "rpcFailovers": self.rpc_failovers,
        }


class LocalAnvilE2E:
    def __init__(
        self,
        repo_root: Path,
        output_dir: Path,
        *,
        anvil_path: Path = Path("/Users/mac/.foundry/bin/anvil"),
        forge_path: Path = Path("/Users/mac/.foundry/bin/forge"),
        deployment_timeout_sec: int = 1_800,
    ):
        self.repo_root = repo_root.resolve()
        self.output_dir = output_dir.resolve()
        self.anvil_path = anvil_path
        self.forge_path = forge_path
        self.deployment_timeout_sec = deployment_timeout_sec

    def _wait_for_rpc(self, rpc: HttpJsonRpcClient, process: subprocess.Popen[Any]) -> None:
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError("Anvil exited before its RPC became ready")
            try:
                if int(rpc.request("eth_chainId", []), 16) == CHAIN_ID:
                    return
            except Exception:
                time.sleep(0.05)
        raise TimeoutError("Anvil RPC did not become ready")

    @staticmethod
    def _set_timestamp(rpc: HttpJsonRpcClient, timestamp: int) -> None:
        rpc.request("evm_setNextBlockTimestamp", [timestamp])
        rpc.request("evm_mine", [])

    @staticmethod
    def _engine(config_path: Path, events: list[dict[str, Any]], *, allow_broadcast: bool) -> KeeperEngine:
        config = load_config(config_path)
        clients = [HttpJsonRpcClient(url, config.rpc_timeout_sec) for url in config.read_rpc_urls]
        pool = RpcPool(
            clients,
            on_failover=lambda attempt: events.append(
                {"event": "rpc_failover", "endpoint": attempt.endpoint, "error": attempt.error}
            ),
            max_attempts=config.read_rpc_attempts,
            base_backoff_sec=config.retry_base_delay_sec,
        )
        submitter = HttpJsonRpcClient(config.submit_rpc_url, config.rpc_timeout_sec) if config.submit_rpc_url else None
        return KeeperEngine(
            config,
            pool,
            KeeperState(config.state_file),
            submit_rpc=submitter,
            allow_broadcast=allow_broadcast,
            emit=events.append,
        )

    @staticmethod
    def _submit_and_confirm(engine: KeeperEngine, expected_task: str) -> dict[str, str]:
        submitted = engine.run_cycle()
        if submitted["status"] != "submitted" or submitted["event"].get("task") != expected_task:
            raise AssertionError(f"expected {expected_task} submission, got {submitted}")
        for _ in range(5):
            confirmation = engine.run_cycle()
            if confirmation["status"] == "receipt_confirmed":
                return {"task": expected_task, "txHash": submitted["event"]["txHash"]}
            if confirmation["status"] != "receipt_pending":
                raise AssertionError(f"unexpected confirmation result: {confirmation}")
            time.sleep(0.05)
        raise AssertionError(f"receipt did not confirm for {expected_task}")

    def _deploy(self, rpc_url: str) -> tuple[dict[str, str], str]:
        command = [
            str(self.forge_path),
            "script",
            "script/DeployGenesisLocal.s.sol:DeployGenesisLocal",
            "--rpc-url",
            rpc_url,
            "--broadcast",
            "--unlocked",
            "--sender",
            LOCAL_ADMIN,
            "-vv",
        ]
        environment = os.environ.copy()
        # Some developer shells export a catch-all HTTP proxy without a
        # loopback exception.  Forge honours those variables, which would send
        # this explicitly local RPC through the proxy and produce a misleading
        # HTTP 502.  Keep the E2E's transport boundary local as well as its URL.
        environment["NO_PROXY"] = "127.0.0.1,localhost"
        environment["no_proxy"] = "127.0.0.1,localhost"
        completed = subprocess.run(
            command,
            cwd=self.repo_root,
            env=environment,
            text=True,
            capture_output=True,
            timeout=self.deployment_timeout_sec,
            check=False,
        )
        output = completed.stdout + completed.stderr
        (self.output_dir / "forge-deployment.log").write_text(output, encoding="utf-8")
        if completed.returncode != 0:
            raise RuntimeError(f"local deployment failed with exit code {completed.returncode}")
        return parse_deployment_log(output), output

    def run(self) -> LocalAnvilResult:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        rpc_port = _free_port()
        bad_port = _free_port()
        rpc_url = f"http://127.0.0.1:{rpc_port}"
        bad_rpc_url = f"http://127.0.0.1:{bad_port}"
        require_loopback_rpc(rpc_url)
        anvil_log_path = self.output_dir / "anvil.log"
        with anvil_log_path.open("w", encoding="utf-8") as anvil_log:
            process = subprocess.Popen(
                [
                    str(self.anvil_path),
                    "--port",
                    str(rpc_port),
                    "--chain-id",
                    str(CHAIN_ID),
                    "--timestamp",
                    str(GENESIS_TIMESTAMP),
                    "--auto-impersonate",
                    # The harness never consumes an Anvil signing key.  Keep
                    # the autogenerated mnemonic/private-key banner out of the
                    # evidence directory as an additional safety boundary.
                    "--silent",
                    "--gas-limit",
                    "1000000000",
                ],
                cwd=self.repo_root,
                stdout=anvil_log,
                stderr=subprocess.STDOUT,
                text=True,
            )
            try:
                rpc = HttpJsonRpcClient(rpc_url, 2)
                self._wait_for_rpc(rpc, process)
                rpc.request("anvil_setBalance", [LOCAL_ADMIN, hex(10_000 * 10**18)])
                deployment, _ = self._deploy(rpc_url)
                manifest = {
                    "classification": "LOCAL-CLEANROOM/BNB-DESIGN",
                    "chainId": CHAIN_ID,
                    "rpcUrl": rpc_url,
                    "admin": LOCAL_ADMIN,
                    "contracts": deployment,
                }
                _atomic_json(self.output_dir / "deployment.json", manifest)

                dry_config_path = self.output_dir / "keeper.dry.json"
                live_config_path = self.output_dir / "keeper.live.json"
                dry_state_path = self.output_dir / "dry-state.json"
                live_state_path = self.output_dir / "live-state.json"
                controller_state_path = self.output_dir / "controller-only-state.json"
                # Every invocation creates a new ephemeral chain.  A prior
                # interrupted run's single-flight hash cannot be reconciled on
                # that new chain, so reset only this harness's generated state.
                for state_path in (dry_state_path, live_state_path, controller_state_path):
                    _atomic_json(state_path, {"schemaVersion": 1, "pending": {}})
                write_keeper_config(
                    dry_config_path,
                    rpc_urls=[bad_rpc_url, rpc_url],
                    submit_rpc_url=None,
                    addresses=deployment,
                    state_file=dry_state_path,
                    live=False,
                )
                write_keeper_config(
                    live_config_path,
                    rpc_urls=[rpc_url],
                    submit_rpc_url=rpc_url,
                    addresses=deployment,
                    state_file=live_state_path,
                    live=True,
                )

                events: list[dict[str, Any]] = []
                dry_engine = self._engine(dry_config_path, events, allow_broadcast=False)
                dry = dry_engine.run_cycle()
                dry_task = dry["event"].get("executableTask")
                if dry_task != "controller_rebalance":
                    raise AssertionError(f"expected genesis controller_rebalance, got {dry_task}")

                live_engine = self._engine(live_config_path, events, allow_broadcast=True)
                submitted = [self._submit_and_confirm(live_engine, "controller_rebalance")]

                controller_only_path = self.output_dir / "keeper.controller-only.json"
                write_keeper_config(
                    controller_only_path,
                    rpc_urls=[rpc_url],
                    submit_rpc_url=None,
                    addresses={
                        "controller": deployment["controller"],
                        "juniorVault": None,
                        "seniorVault": None,
                        "usdVault": None,
                    },
                    state_file=controller_state_path,
                    live=False,
                )
                controller_idle = self._engine(controller_only_path, events, allow_broadcast=False).run_cycle()
                idle_after_rebalance = controller_idle["event"].get("executableTask") is None
                if not idle_after_rebalance:
                    raise AssertionError("Controller should be idle immediately after rebalance")

                self._set_timestamp(rpc, NEXT_ISSUE_TIMESTAMP)
                submitted.append(self._submit_and_confirm(live_engine, "controller_upkeep"))

                self._set_timestamp(rpc, FIRST_STALE_TIMESTAMP)
                submitted.append(self._submit_and_confirm(live_engine, "controller_upkeep"))
                submitted.append(self._submit_and_confirm(live_engine, "controller_rollover"))

                result = LocalAnvilResult(
                    deployment=deployment,
                    dry_run_task=dry_task,
                    submitted=submitted,
                    idle_after_rebalance=idle_after_rebalance,
                    rpc_failovers=sum(1 for event in events if event.get("event") == "rpc_failover"),
                )
                _atomic_json(self.output_dir / "result.json", result.to_dict())
                with (self.output_dir / "keeper-events.jsonl").open("w", encoding="utf-8") as handle:
                    for event in events:
                        handle.write(json.dumps(event, separators=(",", ":"), sort_keys=True) + "\n")
                return result
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the clean-room Keeper against an ephemeral local Anvil")
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--output-dir", default=".keeper/anvil-e2e")
    parser.add_argument("--anvil", default="/Users/mac/.foundry/bin/anvil")
    parser.add_argument("--forge", default="/Users/mac/.foundry/bin/forge")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    runner = LocalAnvilE2E(
        Path(args.repo_root),
        Path(args.output_dir),
        anvil_path=Path(args.anvil),
        forge_path=Path(args.forge),
    )
    result = runner.run()
    print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
