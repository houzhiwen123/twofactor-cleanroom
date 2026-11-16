from __future__ import annotations

import json
import ipaddress
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .model import MaintenanceTask, default_tasks


ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
HASH_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")
DEPLOYMENT_ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
FORBIDDEN_SIGNING_FIELDS = {"privatekey", "mnemonic", "keystore", "seedphrase"}
CONTRACT_KEYS = ("controller", "juniorVault", "seniorVault", "usdVault")
SUBMISSION_MODES = {"disabled", "managed-rpc", "local-unlocked"}
ZERO_ADDRESS = "0x" + "00" * 20


@dataclass(frozen=True)
class ContractAttestation:
    proxy_code_hash: str
    implementation: str
    implementation_code_hash: str


@dataclass(frozen=True)
class KeeperConfig:
    chain_id: int
    read_rpc_urls: tuple[str, ...]
    submit_rpc_url: str | None
    from_address: str
    contracts: dict[str, str | None]
    state_file: Path
    deployment_id: str = "unconfigured"
    submission_mode: str = "disabled"
    attestations: dict[str, ContractAttestation] | None = None
    health_file: Path | None = None
    metrics_file: Path | None = None
    alerts_file: Path | None = None
    alert_cooldown_sec: float = 300.0
    pending_warning_sec: float = 300.0
    pending_critical_sec: float = 900.0
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
    if value.lower() == ZERO_ADDRESS:
        raise ValueError(f"{field} must not be the zero address")
    return value


def _hash(value: Any, field: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        raise ValueError(f"{field} must be a 32-byte hex hash")
    return value.lower()


def _path(value: Any, field: str, base_dir: Path, *, optional: bool = False) -> Path | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a path")
    path = Path(value)
    return path if path.is_absolute() else base_dir / path


def _rpc_url(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{field} must be a URL")
    parsed = urlsplit(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError(f"{field} must be an HTTP(S) URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError(f"{field} must not contain userinfo, query parameters or fragments")
    return value


def _literal_loopback(url: str) -> bool:
    hostname = urlsplit(url).hostname
    if not hostname:
        return False
    try:
        return ipaddress.ip_address(hostname).is_loopback
    except ValueError:
        return False


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
    url_values = raw.get("readRpcUrls")
    if not isinstance(url_values, list) or not url_values:
        raise ValueError("readRpcUrls must contain at least one URL")
    urls = [_rpc_url(url, f"readRpcUrls[{index}]") for index, url in enumerate(url_values)]
    if len(set(urls)) != len(urls):
        raise ValueError("readRpcUrls must not contain duplicates")
    from_address = _address(raw.get("from"), "from")
    assert from_address is not None
    contract_raw = raw.get("contracts")
    if not isinstance(contract_raw, dict):
        raise ValueError("contracts must be an object")
    contracts = {
        key: _address(contract_raw.get(key), f"contracts.{key}", optional=True)
        for key in CONTRACT_KEYS
    }
    if not any(contracts.values()):
        raise ValueError("at least one maintenance contract address is required")
    active_addresses = [address.lower() for address in contracts.values() if address]
    if len(set(active_addresses)) != len(active_addresses):
        raise ValueError("maintenance contract addresses must be unique")
    state_file = _path(raw.get("stateFile", ".keeper/state.json"), "stateFile", base_dir)
    assert state_file is not None
    submit_url = raw.get("submitRpcUrl")
    if submit_url is not None:
        submit_url = _rpc_url(submit_url, "submitRpcUrl")
    live = bool(raw.get("live", False))
    if live and not submit_url:
        raise ValueError("live mode requires submitRpcUrl")

    submission_mode = raw.get("submissionMode", "disabled")
    if submission_mode not in SUBMISSION_MODES:
        raise ValueError("submissionMode must be disabled, managed-rpc or local-unlocked")
    if submission_mode == "disabled" and submit_url is not None:
        raise ValueError("disabled submissionMode requires a null submitRpcUrl")
    if submission_mode != "disabled" and submit_url is None:
        raise ValueError("enabled submissionMode requires submitRpcUrl")
    if live and submission_mode == "disabled":
        raise ValueError("live mode requires an enabled submissionMode")

    chain_id = int(raw.get("chainId", 8453))
    if submission_mode == "managed-rpc":
        assert submit_url is not None
        if urlsplit(submit_url).scheme != "https":
            raise ValueError("managed-rpc submitRpcUrl must use HTTPS")
        if submit_url in urls:
            raise ValueError("managed-rpc submitRpcUrl must be separate from readRpcUrls")
    if submission_mode == "local-unlocked":
        assert submit_url is not None
        if not _literal_loopback(submit_url):
            raise ValueError("local-unlocked submitRpcUrl must use a literal loopback IP")
        if chain_id in (8453, 84532):
            raise ValueError("local-unlocked submission is forbidden on Base chain IDs")

    deployment_raw = raw.get("deployment", {})
    if not isinstance(deployment_raw, dict):
        raise ValueError("deployment must be an object")
    deployment_id = deployment_raw.get("id", "unconfigured")
    if not isinstance(deployment_id, str) or not DEPLOYMENT_ID_RE.fullmatch(deployment_id):
        raise ValueError("deployment.id must use 1-64 letters, numbers, dots, underscores or dashes")
    attestation_raw = deployment_raw.get("attestations", {})
    if not isinstance(attestation_raw, dict):
        raise ValueError("deployment.attestations must be an object")
    unknown_attestations = sorted(set(attestation_raw) - set(CONTRACT_KEYS))
    if unknown_attestations:
        raise ValueError("unknown deployment attestation keys: " + ", ".join(unknown_attestations))
    attestations: dict[str, ContractAttestation] = {}
    for key, address in contracts.items():
        item = attestation_raw.get(key)
        if item is None:
            continue
        if address is None or not isinstance(item, dict):
            raise ValueError(f"deployment.attestations.{key} must describe an active contract")
        implementation = _address(item.get("implementation"), f"deployment.attestations.{key}.implementation")
        assert implementation is not None
        attestations[key] = ContractAttestation(
            proxy_code_hash=_hash(item.get("proxyCodeHash"), f"deployment.attestations.{key}.proxyCodeHash"),
            implementation=implementation,
            implementation_code_hash=_hash(
                item.get("implementationCodeHash"),
                f"deployment.attestations.{key}.implementationCodeHash",
            ),
        )
    if live:
        missing_attestations = sorted(key for key, address in contracts.items() if address and key not in attestations)
        if missing_attestations:
            raise ValueError("live mode requires deployment attestations for: " + ", ".join(missing_attestations))
        if deployment_id == "unconfigured":
            raise ValueError("live mode requires an explicit deployment.id")

    observability_raw = raw.get("observability", {})
    if not isinstance(observability_raw, dict):
        raise ValueError("observability must be an object")
    health_file = _path(observability_raw.get("healthFile"), "observability.healthFile", base_dir, optional=True)
    metrics_file = _path(
        observability_raw.get("metricsFile"), "observability.metricsFile", base_dir, optional=True
    )
    alerts_file = _path(observability_raw.get("alertsFile"), "observability.alertsFile", base_dir, optional=True)
    if live and not all((health_file, metrics_file, alerts_file)):
        raise ValueError("live mode requires healthFile, metricsFile and alertsFile")
    output_paths = [state_file, *(path for path in (health_file, metrics_file, alerts_file) if path)]
    if len({path.resolve() for path in output_paths}) != len(output_paths):
        raise ValueError("state and observability output files must be distinct")
    alert_cooldown_sec = float(observability_raw.get("alertCooldownSec", 300))
    pending_warning_sec = float(observability_raw.get("pendingWarningSec", 300))
    pending_critical_sec = float(observability_raw.get("pendingCriticalSec", 900))
    if alert_cooldown_sec < 0 or pending_warning_sec <= 0 or pending_critical_sec <= pending_warning_sec:
        raise ValueError("invalid observability alert timing")

    config = KeeperConfig(
        chain_id=chain_id,
        read_rpc_urls=tuple(urls),
        submit_rpc_url=submit_url,
        from_address=from_address,
        contracts=contracts,
        state_file=state_file,
        deployment_id=deployment_id,
        submission_mode=submission_mode,
        attestations=attestations,
        health_file=health_file,
        metrics_file=metrics_file,
        alerts_file=alerts_file,
        alert_cooldown_sec=alert_cooldown_sec,
        pending_warning_sec=pending_warning_sec,
        pending_critical_sec=pending_critical_sec,
        live=live,
        poll_interval_sec=float(raw.get("pollIntervalSec", 15)),
        confirmations=int(raw.get("confirmations", 1)),
        gas_multiplier_bps=int(raw.get("gasMultiplierBps", 12_000)),
        max_gas=int(raw.get("maxGas", 3_000_000)),
        rpc_timeout_sec=float(raw.get("rpcTimeoutSec", 10)),
        read_rpc_attempts=int(raw.get("readRpcAttempts", 3)),
        retry_base_delay_sec=float(raw.get("retryBaseDelaySec", 0.25)),
    )
    if config.chain_id <= 0 or config.confirmations <= 0 or config.rpc_timeout_sec <= 0:
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
    config = parse_config(raw, config_path.parent)
    if config.submission_mode != "disabled" and config_path.stat().st_mode & 0o077:
        raise ValueError("submission-enabled keeper config must have mode 0600")
    return config
