#!/usr/bin/env python3
"""Bounded public-RPC discovery for successful PairRouter transactions.

The scanner uses only ERC-20 Transfer logs whose indexed from/to address is the
router. It does not trace calls, mutate chain state, or inspect target source.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import sys
import time
import urllib.error
import urllib.request


TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"


def rpc(url: str, method: str, params: list[object], request_id: int) -> object:
    payload = json.dumps(
        {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
    ).encode()
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"content-type": "application/json", "user-agent": "twofactor-cleanroom-evidence/1"},
        method="POST",
    )
    body: object | None = None
    last_error: Exception | None = None
    for attempt in range(4):
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                body = json.load(response)
            break
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as error:
            last_error = error
            if attempt < 3:
                time.sleep(attempt + 1)
    if body is None:
        raise RuntimeError(f"{method} transport failure after 4 attempts: {last_error}")
    if not isinstance(body, dict):
        raise RuntimeError(f"{method} returned a non-object response")
    if "error" in body:
        raise RuntimeError(f"{method} RPC error: {body['error']}")
    return body["result"]


def topic_address(address: str) -> str:
    normalized = address.lower().removeprefix("0x")
    if len(normalized) != 40:
        raise ValueError("router must be a 20-byte address")
    return "0x" + normalized.rjust(64, "0")


def get_logs(
    url: str,
    router_topic: str,
    token_addresses: list[str],
    start: int,
    end: int,
    request_id: int,
) -> tuple[list[dict[str, object]], int]:
    requests: list[tuple[str, list[object], int]] = []
    for topics in ([TRANSFER_TOPIC, router_topic], [TRANSFER_TOPIC, None, router_topic]):
        requests.append(
            (
                "eth_getLogs",
                [
                    {
                        "address": token_addresses,
                        "fromBlock": hex(start),
                        "toBlock": hex(end),
                        "topics": topics,
                    }
                ],
                request_id,
            )
        )
        request_id += 1
    logs: list[dict[str, object]] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(requests))) as executor:
        futures = [executor.submit(rpc, url, method, params, rpc_id) for method, params, rpc_id in requests]
        for future in futures:
            result = future.result()
            if not isinstance(result, list):
                raise RuntimeError("eth_getLogs returned a non-list result")
            logs.extend(result)
    return logs, request_id


def discover(args: argparse.Namespace) -> dict[str, object]:
    router = args.router.lower()
    router_topic = topic_address(router)
    token_addresses = [token.lower() for token in args.token]
    by_hash: dict[str, dict[str, object]] = {}
    request_id = 1

    start = args.from_block
    while start <= args.to_block:
        end = min(start + args.batch_size - 1, args.to_block)
        try:
            logs, request_id = get_logs(
                args.rpc_url, router_topic, token_addresses, start, end, request_id
            )
        except RuntimeError as error:
            if args.batch_size <= 1_000:
                raise
            raise RuntimeError(
                f"log query failed for {start}-{end}; retry with a smaller --batch-size: {error}"
            ) from error
        for log in logs:
            tx_hash = str(log["transactionHash"]).lower()
            row = by_hash.setdefault(
                tx_hash,
                {
                    "transactionHash": tx_hash,
                    "blockNumber": int(str(log["blockNumber"]), 16),
                    "transferLogs": [],
                },
            )
            row["transferLogs"].append(
                {
                    "token": str(log["address"]).lower(),
                    "logIndex": int(str(log["logIndex"]), 16),
                    "topics": log["topics"],
                    "data": log["data"],
                }
            )
        print(f"scanned {start}-{end}; candidates={len(by_hash)}", file=sys.stderr)
        start = end + 1

    rows: list[dict[str, object]] = []
    for tx_hash, row in sorted(by_hash.items(), key=lambda item: (item[1]["blockNumber"], item[0])):
        transaction = rpc(args.rpc_url, "eth_getTransactionByHash", [tx_hash], request_id)
        request_id += 1
        receipt = rpc(args.rpc_url, "eth_getTransactionReceipt", [tx_hash], request_id)
        request_id += 1
        if not isinstance(transaction, dict) or not isinstance(receipt, dict):
            continue
        to_address = (transaction.get("to") or "").lower()
        if to_address != router and not args.include_all_candidates:
            continue
        calldata = str(transaction.get("input") or "0x")
        rows.append(
            {
                **({key: value for key, value in row.items() if key != "transferLogs"} if args.summary_only else row),
                "transactionIndex": int(str(transaction["transactionIndex"]), 16),
                "from": str(transaction["from"]).lower(),
                "to": to_address,
                "topLevelToRouter": to_address == router,
                "selector": calldata[:10],
                "calldataBytes": max((len(calldata) - 2) // 2, 0),
                "status": int(str(receipt["status"]), 16),
            }
        )

    return {
        "classification": "PUBLIC_BASE_READ_ONLY_DISCOVERY",
        "router": router,
        "fromBlock": args.from_block,
        "toBlock": args.to_block,
        "batchSize": args.batch_size,
        "tokenAddresses": token_addresses,
        "topLevelTransactions": rows,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--router", required=True)
    parser.add_argument("--from-block", required=True, type=int)
    parser.add_argument("--to-block", required=True, type=int)
    parser.add_argument("--batch-size", type=int, default=50_000)
    parser.add_argument("--token", action="append", required=True)
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--include-all-candidates", action="store_true")
    return parser.parse_args()


def main() -> int:
    try:
        print(json.dumps(discover(parse_args()), indent=2, sort_keys=True))
        return 0
    except (RuntimeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
