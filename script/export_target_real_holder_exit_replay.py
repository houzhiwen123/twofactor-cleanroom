#!/usr/bin/env python3
"""Export strict transaction-index target exit replays.

The probe uses public Base data and local Foundry forks only. It never signs or
broadcasts a transaction and never uses deal/store to manufacture target state.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = "evidence/probe-tests"
TEST_PATH = "evidence/probe-tests/TargetRealHolderExitReplay.t.sol"
JSON_PATH = ROOT / "evidence/target-real-holder-exit-replay.json"
MARKDOWN_PATH = ROOT / "evidence/TARGET_REAL_HOLDER_EXIT_REPLAY.md"
DEFAULT_RPC_URL = "https://mainnet.base.org"

REPLAY_TOPIC = "0xc74103e438af19f06d2f911e9e7946cc66bab69178ef6f672cde4eef0ac83cf7"
VERSION_TOPIC = "0x2f73f1b035d492412fa5edac0322273e22c0e84873fc66550d13f9602302943a"
CONTROLLER_TOPIC = "0x5c628b7dcb90cadb6e4fc7839e4e0c294b68b261685c5dc9295dd1be0eeb30b7"
ASSET_TOPIC = "0x2f6b665c85be23cb1dfb8017ff3e6407fccf306ee5e03c01630fd1bc773c05cb"
FEE_TOPIC = "0x11f2a3e97465bccb481a94605d6e0d990846421b17ddedf095322e324e69906d"
CONTROLLER_EVENT_TOPIC = "0xce8f945c4358207e5121c570116efa44b18df9a8df21c3103b2e26dfb0bd49fe"
VAULT_TOPIC = "0xd8b6c686a0ad333cc1106c7607752d84a202d6b293a02e399fa9f0abf8d1d2b2"
ROUTER_TOPIC = "0x8a5b85b84e415129577f4b9cd844550e14718aed043512ba124f1dff36a0a4c0"
FAILURE_TOPIC = "0x5d37d2e838f61f8d40721d034009b41501778b30dbca63f7a4731cb4379b8f9a"

LAYERS = {0: "Controller", 1: "USD Vault", 2: "SingleAsset Router"}
COMPONENTS = {
    (0, 0): "Controller",
    (0, 1): "FeePolicy",
    (1, 0): "USD Vault",
    (2, 0): "SingleAsset Router",
    (2, 1): "USD Vault",
    (2, 2): "DEX Strategy",
}


def words(data: str) -> list[int]:
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    if len(raw) % 32:
        raise ValueError(f"non-word-aligned event data: {len(raw)}")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def address(word: int) -> str:
    return "0x" + word.to_bytes(32, "big")[-20:].hex()


def bytes32(word: int) -> str:
    return "0x" + word.to_bytes(32, "big").hex()


def selector(word: int) -> str:
    return "0x" + word.to_bytes(32, "big")[:4].hex()


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_fork() -> dict:
    command = [
        "/Users/mac/.foundry/bin/forge",
        "test",
        "--offline",
        "--json",
        "--threads",
        "1",
        "--match-path",
        TEST_PATH,
        "-vv",
    ]
    env = os.environ.copy()
    env["FOUNDRY_TEST"] = TEST_ROOT
    env.setdefault("BASE_RPC_URL", DEFAULT_RPC_URL)
    completed = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(completed.stdout)


def all_logs(payload: dict) -> list[dict]:
    logs: list[dict] = []
    for suite in payload.values():
        for name, result in suite.get("test_results", {}).items():
            if result.get("status") != "Success":
                raise ValueError(f"fork test failed: {name}: {result.get('reason')}")
            logs.extend(result.get("logs", []))
    return logs


def decode(payload: dict) -> dict:
    vectors: dict[int, dict] = {}
    versions: list[dict] = []
    controller = None
    assets: list[dict] = []
    fees: list[dict] = []
    controller_events: list[dict] = []
    vault = None
    router = None
    failures: list[dict] = []

    for log in all_logs(payload):
        topics = [topic.lower() for topic in log.get("topics", [])]
        if not topics:
            continue
        topic = topics[0]
        data = words(log.get("data", "0x"))

        if topic == REPLAY_TOPIC:
            layer = int(topics[1], 16)
            vectors[layer] = {
                "layer": LAYERS[layer],
                "transaction_hash": topics[2],
                "block_number": data[0],
                "transaction_index": data[1],
                "natural_holder": address(data[2]),
                "classification": "TARGET-CONFIRMED",
                "prestate": "strict transaction-hash fork",
            }
        elif topic == VERSION_TOPIC:
            layer = int(topics[1], 16)
            component = int(topics[2], 16)
            versions.append(
                {
                    "layer": LAYERS[layer],
                    "component": COMPONENTS[(layer, component)],
                    "target": address(data[0]),
                    "implementation": address(data[1]),
                    "target_codehash": bytes32(data[2]),
                    "implementation_codehash": bytes32(data[3]),
                    "proxy_kind": "EIP-1967" if data[1] else "direct_or_non_EIP1967",
                }
            )
        elif topic == CONTROLLER_TOPIC:
            names = (
                "jr_input",
                "min_value",
                "pre_sub_dr",
                "post_sub_dr",
                "pre_vm_dr",
                "post_vm_dr",
                "jr_total_fee",
                "jr_protocol_fee",
                "underlying_out",
                "tranche_count",
                "jr_supply_before",
                "jr_supply_after",
                "collected_fee_before",
                "collected_fee_after",
            )
            controller = dict(zip(names, data))
            controller["classification"] = "TARGET-CONFIRMED"
        elif topic == ASSET_TOPIC:
            names = (
                "reserve_before",
                "reserve_after",
                "user_delta",
                "returned_amount",
                "value_before",
                "value_after",
            )
            row = dict(zip(names, data))
            row["asset_index"] = int(topics[1], 16)
            row["token"] = address(int(topics[2], 16))
            row["conserved"] = row["reserve_before"] == row["reserve_after"] + row["user_delta"]
            assets.append(row)
        elif topic == FEE_TOPIC:
            side = int(topics[1], 16)
            fees.append(
                {
                    "side": "SR" if side == 0 else "JR",
                    "target_total": data[0],
                    "target_protocol": data[1],
                    "cleanroom_total": data[2],
                    "cleanroom_protocol": data[3],
                    "exact_match": bool(data[4]),
                    "classification": "TARGET-CONFIRMED_vs_LOCAL-CLEANROOM",
                }
            )
        elif topic == CONTROLLER_EVENT_TOPIC:
            controller_events.append(
                {
                    "side": "SR" if int(topics[1], 16) == 0 else "JR",
                    "event_topic": topics[2],
                    "token": address(int(topics[3], 16)),
                    "total_fee_amount": data[0],
                    "protocol_fee_amount": data[1],
                }
            )
        elif topic == VAULT_TOPIC:
            names = (
                "notes_input",
                "quote_usd",
                "quote_perp_sr",
                "actual_usd",
                "actual_perp_sr",
                "note_supply_before",
                "note_supply_after",
                "vault_usd_before",
                "vault_usd_after",
                "vault_perp_sr_before",
                "vault_perp_sr_after",
            )
            vault = dict(zip(names, data))
            vault["classification"] = "TARGET-CONFIRMED"
            vault["local_implementation"] = "NO_LOCAL_IMPLEMENTATION"
        elif topic == ROUTER_TOPIC:
            router = {
                "notes_input": data[0],
                "historical_min_out": data[1],
                "actual_usd_out": data[2],
                "direct_vault_usd_out": data[3],
                "vault_perp_sr_out": data[4],
                "dex_usd_out": data[5],
                "health_check": bool(data[6]),
                "max_iters_present": bool(data[7]),
                "strategy": address(data[8]),
                "classification": "TARGET-CONFIRMED",
                "local_implementation": "NO_LOCAL_IMPLEMENTATION",
            }
        elif topic == FAILURE_TOPIC:
            layer = int(topics[1], 16)
            failures.append(
                {
                    "layer": LAYERS[layer],
                    "attempted_input": data[0],
                    "boundary_value": data[1],
                    "error_selector": selector(data[2]),
                    "state_unchanged": bool(data[3]),
                    "classification": "TARGET-CONFIRMED_SYNTHETIC_CALL_NATURAL_BALANCE",
                }
            )

    if set(vectors) != {0, 1, 2}:
        raise ValueError(f"missing replay vectors: {sorted(vectors)}")
    if controller is None or vault is None or router is None:
        raise ValueError("missing success result event")
    if len(failures) != 3:
        raise ValueError(f"expected three failure boundaries, got {len(failures)}")
    if len(fees) != 2 or not all(row["exact_match"] for row in fees):
        raise ValueError("FeePolicy exact compatibility missing")
    if not any(row["side"] == "JR" for row in controller_events):
        raise ValueError("Controller JR OpFees event missing")
    if not all(row["conserved"] for row in assets):
        raise ValueError("Controller reserve conservation failed")

    versions.sort(key=lambda row: (row["layer"], row["component"]))
    assets.sort(key=lambda row: row["asset_index"])
    failures.sort(key=lambda row: row["layer"])
    return {
        "task": "TARGET_REAL_HOLDER_EXIT_REPLAY",
        "scope": {
            "network": "Base",
            "chain_id": 8453,
            "source": "public read-only RPC and local Foundry transaction-hash forks",
            "balance_policy": "natural historical balances only; no deal/store",
        },
        "vectors": [vectors[index] for index in sorted(vectors)],
        "version_locks": versions,
        "controller": controller,
        "controller_assets": assets,
        "controller_events": controller_events,
        "fee_policy_differential": fees,
        "vault": vault,
        "router": router,
        "failure_boundaries": failures,
        "summary": {
            "success_vectors": 3,
            "failure_boundaries": 3,
            "fee_policy_exact_matches": 2,
            "controller_events_observed": len(controller_events),
            "controller_assets_conserved": all(row["conserved"] for row in assets),
        },
    }


def markdown(evidence: dict) -> str:
    controller = evidence["controller"]
    vault = evidence["vault"]
    router = evidence["router"]
    lines = [
        "# Target real-holder exit replay",
        "",
        "**Classification: TARGET-CONFIRMED historical success vectors plus synthetic local-fork boundary calls using the same natural balances.**",
        "",
        "No target balance or storage was manufactured with `deal`/`store`. Every fork starts at the exact transaction-hash prestate, which includes all earlier transactions in the block.",
        "",
        "## Result",
        "",
        "| Layer | Success evidence | Failure boundary | Local clean-room status |",
        "|---|---|---|---|",
        "| Controller | Natural JR holder calls `redeem2` from tx-prestate | aggregate `minVal + 1` reverts atomically | FeePolicy compared exactly; Controller end-to-end not claimed |",
        "| USD Vault | Original natural-holder `redeem` transaction replayed | natural note balance + 1 reverts atomically | NO_LOCAL_IMPLEMENTATION |",
        "| SingleAsset Router | Original ERC-4337 exit replayed | exact output succeeds; exact output + 1 reverts atomically | NO_LOCAL_IMPLEMENTATION |",
        "",
        "## Version-locked vectors",
        "",
        "| Layer | Block | transactionIndex | Transaction | Natural holder |",
        "|---|---:|---:|---|---|",
    ]
    for row in evidence["vectors"]:
        lines.append(
            f"| {row['layer']} | {row['block_number']} | {row['transaction_index']} | `{row['transaction_hash']}` | `{row['natural_holder']}` |"
        )
    lines.extend(
        [
            "",
            "### Contract versions",
            "",
            "| Layer | Component | Target | Implementation | Target codehash | Implementation codehash |",
            "|---|---|---|---|---|---|",
        ]
    )
    for row in evidence["version_locks"]:
        lines.append(
            f"| {row['layer']} | {row['component']} | `{row['target']}` | `{row['implementation']}` | `{row['target_codehash']}` | `{row['implementation_codehash']}` |"
        )
    lines.extend(
        [
            "",
            "## Controller direct exit",
            "",
            f"Natural JR input: `{controller['jr_input']}`; aggregate minimum value: `{controller['min_value']}`. The exit returned `{controller['underlying_out']}` cbBTC units and `{controller['tranche_count']}` tranche asset(s).",
            "",
            "| Metric | Before | After |",
            "|---|---:|---:|",
            f"| subDR | {controller['pre_sub_dr']} | {controller['post_sub_dr']} |",
            f"| vmDR | {controller['pre_vm_dr']} | {controller['post_vm_dr']} |",
            f"| JR totalSupply | {controller['jr_supply_before']} | {controller['jr_supply_after']} |",
            f"| Controller collected JR fee | {controller['collected_fee_before']} | {controller['collected_fee_after']} |",
            "",
            f"Returned JR fee: total `{controller['jr_total_fee']}`, protocol `{controller['jr_protocol_fee']}` WAD.",
            "",
            "### Reserve-asset conservation",
            "",
            "| # | Token | Reserve before | Reserve after | User delta | Returned | Conserved |",
            "|---:|---|---:|---:|---:|---:|---|",
        ]
    )
    for row in evidence["controller_assets"]:
        lines.append(
            f"| {row['asset_index']} | `{row['token']}` | {row['reserve_before']} | {row['reserve_after']} | {row['user_delta']} | {row['returned_amount']} | {'yes' if row['conserved'] else 'no'} |"
        )
    lines.extend(
        [
            "",
            "### FeePolicy differential",
            "",
            "| Side | Target total | Clean-room total | Target protocol | Clean-room protocol | Result |",
            "|---|---:|---:|---:|---:|---|",
        ]
    )
    for row in evidence["fee_policy_differential"]:
        lines.append(
            f"| {row['side']} | {row['target_total']} | {row['cleanroom_total']} | {row['target_protocol']} | {row['cleanroom_protocol']} | {'MATCH' if row['exact_match'] else 'MISMATCH'} |"
        )
    lines.extend(
        [
            "",
            "### Controller events",
            "",
            "| Side | Topic | Token | Total fee amount | Protocol fee amount |",
            "|---|---|---|---:|---:|",
        ]
    )
    for row in evidence["controller_events"]:
        lines.append(
            f"| {row['side']} | `{row['event_topic']}` | `{row['token']}` | {row['total_fee_amount']} | {row['protocol_fee_amount']} |"
        )
    lines.extend(
        [
            "",
            "## USD Vault exit",
            "",
            f"The target quote for `{vault['notes_input']}` notes was `{vault['quote_usd']}` USDC units plus `{vault['quote_perp_sr']}` Perp SR units. The historical transaction delivered exactly `{vault['actual_usd']}` and `{vault['actual_perp_sr']}`. Vault balance deltas and note-supply burn match those outputs exactly.",
            "",
            "This is **TARGET-CONFIRMED** only. The clean-room Vault does not exist yet.",
            "",
            "## SingleAsset Router exit",
            "",
            f"The historical route burned `{router['notes_input']}` Vault notes, used minOut `{router['historical_min_out']}`, and delivered `{router['actual_usd_out']}` USDC units through strategy `{router['strategy']}`. The Vault supplied `{router['direct_vault_usd_out']}` USDC directly plus `{router['vault_perp_sr_out']}` Perp SR; the DEX leg produced `{router['dex_usd_out']}` USDC. `healthCheck` was `{str(router['health_check']).lower()}`.",
            "",
            "The observed six-argument exit ABI has **no `maxIters` field**. The report records that absence instead of inventing a value. Direct local-fork calls proved minOut is inclusive at the actual output and reverts atomically at actual output + 1.",
            "",
            "This is **TARGET-CONFIRMED** only. The clean-room Router does not exist yet.",
            "",
            "## Exact failure boundaries",
            "",
            "| Layer | Attempted input | Boundary | Selector | State unchanged |",
            "|---|---:|---:|---|---|",
        ]
    )
    for row in evidence["failure_boundaries"]:
        lines.append(
            f"| {row['layer']} | {row['attempted_input']} | {row['boundary_value']} | `{row['error_selector']}` | {'yes' if row['state_unchanged'] else 'no'} |"
        )
    lines.extend(
        [
            "",
            "## Minimal Vault clean-room interface and behavior checklist",
            "",
            "The next implementation needs only the behavior demonstrated here before broader features are added:",
            "",
            "- ERC-20 note `balanceOf`, `totalSupply`, `approve` and allowance semantics used by Routers.",
            "- `computeRedemptionAmts(notes)` returns the exact pro-rata USDC and Perp SR quote with target rounding.",
            "- `redeem(notes)` burns exactly the supplied notes and transfers both quoted assets to `msg.sender`.",
            "- `usdBalance()` and `perpSrBalance()` track actual redeemable reserves; the observed exit conserves both assets exactly.",
            "- A natural balance + 1 input reverts atomically with the recorded selector.",
            "- Router allowance consumption, direct USDC leg, Perp SR → Controller → cbBTC leg, DEX strategy swap, health check and inclusive `minOut` must remain one atomic transaction.",
            "- Capacity/session and rebalance behavior are outside this three-vector exit scope and remain UNKNOWN here.",
            "",
            "## Reproduce",
            "",
            "```sh",
            "cd analysis/2factor/twofactor-cleanroom-codex",
            "BASE_RPC_URL=https://mainnet.base.org python3 script/export_target_real_holder_exit_replay.py",
            "```",
            "",
            "Strict transaction-index reconstruction may take several minutes per vector on a public RPC.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    payload = run_fork()
    evidence = decode(payload)
    evidence["provenance"] = {
        "baseline_commit": subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True
        ).stdout.strip(),
        "probe": TEST_PATH,
        "probe_sha256": sha256(ROOT / TEST_PATH),
        "exporter": "script/export_target_real_holder_exit_replay.py",
        "exporter_sha256": sha256(Path(__file__)),
    }
    JSON_PATH.write_text(json.dumps(evidence, indent=2) + "\n")
    MARKDOWN_PATH.write_text(markdown(evidence))
    print(json.dumps(evidence["summary"], indent=2))


if __name__ == "__main__":
    main()
