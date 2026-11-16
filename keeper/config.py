from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .model import MaintenanceTask, default_tasks


ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
FORBIDDEN_SIGNING_FIELDS = {"privatekey", "mnemonic", "keystore", "seedphrase"}


@dataclass(frozen=True)
class KeeperConfig:
    chain_id: int
    read_rpc_urls: tuple[str, ...]
    submit_rpc_url: str | None
    from_address: str
    contracts: dict[str, str | None]
    state_file: Path
    live: bool = False
    poll_interval_sec: float = 15.0
    confirmations: int = 1
    gas_multiplier_bps: int = 12_000
    max_gas: int = 3_000_000
    rpc_timeout_sec: float = 10.0
    read_rpc_attempts: int = 3
    retry_base_delay_sec: float = 0.25

    @property
    def tasks(self) -> list[MaintenanceTask]:
        return default_tasks(self.contracts)


def _address(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        raise ValueError(f"{field} must be a 20-byte hex address")
    return value


def _contains_signing_material(value: Any) -> bool:
    if isinstance(value, dict):
        return any(
            str(key).replace("_", "").lower() in FORBIDDEN_SIGNING_FIELDS or _contains_signing_material(nested)
            for key, nested in value.items()
        )
    if isinstance(value, list):
        return any(_contains_signing_material(nested) for nested in value)
    return False


def parse_config(raw: dict[str, Any], base_dir: Path = Path(".")) -> KeeperConfig:
    if _contains_signing_material(raw):
        raise ValueError("private signing material is forbidden in Keeper config")
    if raw.get("schemaVersion") != 1:
        raise ValueError("unsupported keeper config schemaVersion")
    urls = raw.get("readRpcUrls")
    if not isinstance(urls, list) or not urls or not all(isinstance(url, str) and url for url in urls):
        raise ValueError("readRpcUrls must contain at least one URL")
    from_address = _address(raw.get("from"), "from")
    assert from_address is not None
    contract_raw = raw.get("contracts")
    if not isinstance(contract_raw, dict):
        raise ValueError("contracts must be an object")
    contracts = {
        key: _address(contract_raw.get(key), f"contracts.{key}", optional=True)
        for key in ("controller", "juniorVault", "seniorVault", "usdVault")
    }
    if not any(contracts.values()):
        raise ValueError("at least one maintenance contract address is required")
    state_value = raw.get("stateFile", ".keeper/state.json")
    if not isinstance(state_value, str) or not state_value:
        raise ValueError("stateFile must be a path")
    state_file = Path(state_value)
    if not state_file.is_absolute():
        state_file = base_dir / state_file
    submit_url = raw.get("submitRpcUrl")
    if submit_url is not None and (not isinstance(submit_url, str) or not submit_url):
        raise ValueError("submitRpcUrl must be null or a URL")
    live = bool(raw.get("live", False))
    if live and not submit_url:
        raise ValueError("live mode requires submitRpcUrl")
    config = KeeperConfig(
        chain_id=int(raw.get("chainId", 8453)),
        read_rpc_urls=tuple(urls),
        submit_rpc_url=submit_url,
        from_address=from_address,
        contracts=contracts,
        state_file=state_file,
        live=live,
        poll_interval_sec=float(raw.get("pollIntervalSec", 15)),
        confirmations=int(raw.get("confirmations", 1)),
        gas_multiplier_bps=int(raw.get("gasMultiplierBps", 12_000)),
        max_gas=int(raw.get("maxGas", 3_000_000)),
        rpc_timeout_sec=float(raw.get("rpcTimeoutSec", 10)),
        read_rpc_attempts=int(raw.get("readRpcAttempts", 3)),
        retry_base_delay_sec=float(raw.get("retryBaseDelaySec", 0.25)),
    )
    if config.chain_id <= 0 or config.confirmations <= 0:
        raise ValueError("chainId and confirmations must be positive")
    if (
        config.poll_interval_sec < 0
        or config.gas_multiplier_bps < 10_000
        or config.max_gas <= 0
        or config.read_rpc_attempts <= 0
        or config.retry_base_delay_sec < 0
    ):
        raise ValueError("invalid polling or gas policy")
    return config


def load_config(path: str | Path) -> KeeperConfig:
    config_path = Path(path).resolve()
    with config_path.open(encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, dict):
        raise ValueError("keeper config root must be an object")
    return parse_config(raw, config_path.parent)
