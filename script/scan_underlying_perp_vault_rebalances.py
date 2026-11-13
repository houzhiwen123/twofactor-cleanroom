#!/usr/bin/env python3
"""Scan public Base logs for UnderlyingPerpVault Rebalance events.

The scanner is deliberately narrow: two known vault proxies, one event topic,
and a caller-supplied block range. It only performs read-only JSON-RPC calls.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


VAULTS = {
    "junior": "0xebee489b84c1b3408838a87a691a4370aed139db",
    "senior": "0x805d7ee7f03de39f2f30f3a7069c6d46642398cb",
}
REBALANCE_TOPIC = "0xd2412c662f48f974143bb2428ce115c948201145d7b96f0eded33ccc43db383d"


class Rpc:
    def __init__(self, url: str) -> None:
        self.url = url
        self.request_id = 0

    def call(self, method: str, params: list[Any]) -> Any:
        self.request_id += 1
        body = json.dumps(
            {
                "jsonrpc": "2.0",
                "id": self.request_id,
                "method": method,
                "params": params,
            }
        ).encode()
        last_error: Exception | None = None
        for attempt in range(6):
            request = urllib.request.Request(
                self.url,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "twofactor-cleanroom-rebalance-scanner/1.0",
                },
                method="POST",
            )
            try:
                with urllib.request.urlopen(request, timeout=60) as response:
                    payload = json.loads(response.read())
                if "error" in payload:
                    raise RuntimeError(f"{method}: {payload['error']}")
                return payload["result"]
            except (OSError, KeyError, RuntimeError, ValueError) as error:
                last_error = error
                if attempt == 5:
                    break
                time.sleep(min(2**attempt, 12))
        raise RuntimeError(f"{method} failed: {last_error}")


def number(value: str | int | None) -> int:
    if value is None:
        return 0
    if isinstance(value, int):
        return value
    return int(value, 16) if value.startswith("0x") else int(value)


def words(data: str) -> list[int]:
    raw = data.removeprefix("0x")
    return [int(raw[offset : offset + 64], 16) for offset in range(0, len(raw), 64)]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--from-block", type=int, required=True)
    parser.add_argument("--to-block", type=int, required=True)
    parser.add_argument("--chunk-size", type=int, default=50_000)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.from_block > args.to_block:
        parser.error("from-block must be <= to-block")
    if args.chunk_size < 1 or args.chunk_size > 50_000:
        parser.error("chunk-size must be between 1 and 50,000")

    rpc = Rpc(args.rpc_url)
    address_to_side = {address: side for side, address in VAULTS.items()}
    raw_logs: list[dict[str, Any]] = []
    cursor = args.from_block
    while cursor <= args.to_block:
        end = min(cursor + args.chunk_size - 1, args.to_block)
        logs = rpc.call(
            "eth_getLogs",
            [
                {
                    "fromBlock": hex(cursor),
                    "toBlock": hex(end),
                    "address": list(address_to_side),
                    "topics": [REBALANCE_TOPIC],
                }
            ],
        )
        raw_logs.extend(logs)
        print(f"logs {cursor:,}-{end:,}: {len(logs)}", file=sys.stderr, flush=True)
        cursor = end + 1

    tx_cache: dict[str, dict[str, Any]] = {}
    receipt_cache: dict[str, dict[str, Any]] = {}
    block_cache: dict[str, dict[str, Any]] = {}
    records: list[dict[str, Any]] = []
    for entry in raw_logs:
        tx_hash = entry["transactionHash"].lower()
        block_hex = entry["blockNumber"]
        if tx_hash not in tx_cache:
            tx_cache[tx_hash] = rpc.call("eth_getTransactionByHash", [tx_hash])
            receipt_cache[tx_hash] = rpc.call("eth_getTransactionReceipt", [tx_hash])
        if block_hex not in block_cache:
            block_cache[block_hex] = rpc.call("eth_getBlockByNumber", [block_hex, False])

        decoded = words(entry["data"])
        if len(decoded) != 3:
            raise RuntimeError(f"unexpected Rebalance payload for {tx_hash}: {entry['data']}")
        transaction = tx_cache[tx_hash]
        receipt = receipt_cache[tx_hash]
        records.append(
            {
                "side": address_to_side[entry["address"].lower()],
                "vault": entry["address"].lower(),
                "blockNumber": number(block_hex),
                "blockTimestamp": number(block_cache[block_hex]["timestamp"]),
                "transactionIndex": number(entry["transactionIndex"]),
                "logIndex": number(entry["logIndex"]),
                "transactionHash": tx_hash,
                "from": transaction["from"].lower(),
                "to": (transaction.get("to") or "").lower() or None,
                "topLevelSelector": transaction.get("input", "0x")[:10],
                "status": number(receipt["status"]),
                "gasUsed": number(receipt["gasUsed"]),
                "drBefore": str(decoded[0]),
                "underlyingAmount": str(decoded[1]),
                "isMintingPerp": decoded[2] != 0,
                "topics": entry["topics"],
                "data": entry["data"],
            }
        )

    records.sort(key=lambda row: (row["blockNumber"], row["transactionIndex"], row["logIndex"]))
    report = {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "chainId": 8453,
        "readOnly": True,
        "broadcastTransactions": False,
        "event": "Rebalance(uint256,uint256,bool)",
        "topic": REBALANCE_TOPIC,
        "vaults": VAULTS,
        "range": {"fromBlock": args.from_block, "toBlock": args.to_block},
        "recordCount": len(records),
        "records": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(args.output), "records": len(records)}))


if __name__ == "__main__":
    main()
