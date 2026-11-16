from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .attestation import observe_contract_identity
from .config import ADDRESS_RE, CONTRACT_KEYS, DEPLOYMENT_ID_RE, ZERO_ADDRESS
from .rpc import HttpJsonRpcClient, safe_endpoint


def _hex_int(value: Any, field: str) -> int:
    if not isinstance(value, str) or not value.startswith("0x"):
        raise RuntimeError(f"{field} is not a hex quantity")
    return int(value, 16)


def _block_number(value: str) -> int:
    try:
        number = int(value, 0)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("block must be a positive decimal or 0x-prefixed integer") from exc
    if number < 0:
        raise argparse.ArgumentTypeError("block must be non-negative")
    return number


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


def load_manifest_input(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        raw = json.load(handle)
    if not isinstance(raw, dict):
        raise ValueError("manifest input root must be an object")
    unknown = sorted(set(raw) - {"schemaVersion", "deploymentId", "chainId", "contracts"})
    if unknown:
        raise ValueError("unknown manifest input fields: " + ", ".join(unknown))
    if raw.get("schemaVersion") != 1:
        raise ValueError("unsupported manifest input schemaVersion")
    deployment_id = raw.get("deploymentId")
    if not isinstance(deployment_id, str) or not DEPLOYMENT_ID_RE.fullmatch(deployment_id):
        raise ValueError("deploymentId is invalid")
    chain_id = raw.get("chainId")
    if not isinstance(chain_id, int) or chain_id <= 0:
        raise ValueError("chainId must be a positive integer")
    contract_raw = raw.get("contracts")
    if not isinstance(contract_raw, dict):
        raise ValueError("contracts must be an object")
    unknown_contracts = sorted(set(contract_raw) - set(CONTRACT_KEYS))
    if unknown_contracts:
        raise ValueError("unknown contract keys: " + ", ".join(unknown_contracts))
    contracts: dict[str, str] = {}
    for key in CONTRACT_KEYS:
        address = contract_raw.get(key)
        if address is None:
            continue
        if not isinstance(address, str) or not ADDRESS_RE.fullmatch(address) or address.lower() == ZERO_ADDRESS:
            raise ValueError(f"contracts.{key} must be a nonzero 20-byte address")
        contracts[key] = address
    if not contracts:
        raise ValueError("at least one contract address is required")
    if len({address.lower() for address in contracts.values()}) != len(contracts):
        raise ValueError("contract addresses must be unique")
    return {"deploymentId": deployment_id, "chainId": chain_id, "contracts": contracts}


def generate_manifest(
    rpc: Any,
    source: dict[str, Any],
    block_number: int,
    *,
    endpoint: str,
) -> dict[str, Any]:
    chain_id = _hex_int(rpc.request("eth_chainId", []), "eth_chainId")
    if chain_id != source["chainId"]:
        raise RuntimeError(f"chain ID mismatch: expected {source['chainId']}, got {chain_id}")
    block_tag = hex(block_number)
    first_block = rpc.request("eth_getBlockByNumber", [block_tag, False])
    if not isinstance(first_block, dict) or first_block.get("number") != block_tag:
        raise RuntimeError("RPC returned an inconsistent pinned block")
    block_hash = first_block.get("hash")
    if not isinstance(block_hash, str) or len(block_hash) != 66:
        raise RuntimeError("pinned block is missing a valid hash")

    identities: dict[str, dict[str, Any]] = {}
    config_attestations: dict[str, dict[str, str]] = {}
    for key, proxy in source["contracts"].items():
        observed = observe_contract_identity(rpc, proxy, block_tag)
        identities[key] = observed.to_dict()
        config_attestations[key] = {
            "proxyCodeHash": observed.proxy_code_hash,
            "implementation": observed.implementation,
            "implementationCodeHash": observed.implementation_code_hash,
        }

    final_block = rpc.request("eth_getBlockByNumber", [block_tag, False])
    if not isinstance(final_block, dict) or final_block.get("hash") != block_hash:
        raise RuntimeError("pinned block changed while generating manifest")
    return {
        "schemaVersion": 1,
        "classification": "REVIEW-REQUIRED/READ-ONLY",
        "deploymentId": source["deploymentId"],
        "chainId": chain_id,
        "blockNumber": block_number,
        "blockHash": block_hash.lower(),
        "blockTimestamp": _hex_int(first_block.get("timestamp"), "block timestamp"),
        "sourceEndpoint": safe_endpoint(endpoint),
        "contracts": identities,
        "configFragment": {
            "deployment": {
                "id": source["deploymentId"],
                "attestations": config_attestations,
            }
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Generate a fixed-block clean-room Keeper deployment manifest")
    parser.add_argument("--input", required=True, help="reviewed deployment-address JSON")
    parser.add_argument("--rpc-url", required=True, help="read-only HTTP(S) JSON-RPC endpoint")
    parser.add_argument("--block", required=True, type=_block_number, help="explicit decimal or 0x block number")
    parser.add_argument("--output", required=True, help="mode-0600 manifest output path")
    parser.add_argument("--rpc-timeout", type=float, default=15.0)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    parsed = urlsplit(args.rpc_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        print("manifest error: rpc-url must be HTTP(S)", file=sys.stderr)
        return 2
    if args.rpc_timeout <= 0:
        print("manifest error: rpc-timeout must be positive", file=sys.stderr)
        return 2
    try:
        source = load_manifest_input(Path(args.input))
        manifest = generate_manifest(
            HttpJsonRpcClient(args.rpc_url, args.rpc_timeout),
            source,
            args.block,
            endpoint=args.rpc_url,
        )
        output = Path(args.output).resolve()
        _atomic_json(output, manifest)
        print(
            json.dumps(
                {
                    "classification": manifest["classification"],
                    "output": str(output),
                    "blockNumber": manifest["blockNumber"],
                    "blockHash": manifest["blockHash"],
                    "contractCount": len(manifest["contracts"]),
                },
                sort_keys=True,
            )
        )
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"manifest error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
