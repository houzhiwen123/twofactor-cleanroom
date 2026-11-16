from __future__ import annotations

from collections import defaultdict
from pathlib import Path
from typing import Any

from keeper.config import KeeperConfig


CONTROLLER = "0x0000000000000000000000000000000000001001"
JUNIOR = "0x0000000000000000000000000000000000001002"
SENIOR = "0x0000000000000000000000000000000000001003"
USD = "0x0000000000000000000000000000000000001004"
CALLER = "0x000000000000000000000000000000000000bEEF"


class FakeRpc:
    def __init__(self, responses: dict[str, Any] | None = None, endpoint: str = "fake://rpc"):
        self.responses = responses or {}
        self.endpoint = endpoint
        self.calls: list[tuple[str, list[Any]]] = []
        self.counts = defaultdict(int)

    def request(self, method: str, params: list[Any]) -> Any:
        self.calls.append((method, params))
        index = self.counts[method]
        self.counts[method] += 1
        response = self.responses.get(method)
        if isinstance(response, list):
            if not response:
                raise AssertionError(f"no fake response left for {method}")
            value = response.pop(0)
        else:
            value = response
        if callable(value):
            value = value(method, params, index)
        if isinstance(value, Exception):
            raise value
        if value is None and method not in self.responses:
            raise AssertionError(f"unexpected RPC method {method}")
        return value


def config(tmp_path: Path, *, contracts: dict[str, str | None] | None = None, live: bool = False) -> KeeperConfig:
    return KeeperConfig(
        chain_id=8453,
        read_rpc_urls=("fake://read",),
        submit_rpc_url="fake://submit" if live else None,
        from_address=CALLER,
        contracts=contracts
        or {"controller": CONTROLLER, "juniorVault": None, "seniorVault": None, "usdVault": None},
        state_file=tmp_path / "keeper-state.json",
        live=live,
        poll_interval_sec=0,
        confirmations=1,
        gas_multiplier_bps=12_000,
        max_gas=3_000_000,
        rpc_timeout_sec=1,
        read_rpc_attempts=3,
        retry_base_delay_sec=0,
    )


def snapshot_responses(*, calls: list[Any], code: str = "0x6000") -> dict[str, Any]:
    return {
        "eth_chainId": "0x2105",
        "eth_blockNumber": "0x64",
        "eth_getBlockByNumber": {"number": "0x64", "hash": "0xabc", "timestamp": "0x3e8"},
        "eth_getBalance": "0xde0b6b3a7640000",
        "eth_getCode": code,
        "eth_call": calls,
        "eth_estimateGas": "0x186a0",
    }
