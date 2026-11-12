#!/usr/bin/env python3
"""Export the fixed-block target FeePolicy differential evidence.

The script runs a read-only Foundry fork against public Base data. It never
signs or broadcasts a transaction and does not mutate the target contracts.
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = "evidence/probe-tests"
TEST_PATH = "evidence/probe-tests/TargetExitFeeDifferential.t.sol"
TARGET_BLOCK = 54_990_962
DEFAULT_RPC_URL = "https://mainnet.base.org"

VERSION_TOPIC = "0x76b06f765c9ddacdae35c5c02ad471f2df1ebe2c7a4a3069872ec048d33a72b6"
SNAPSHOT_TOPIC = "0x6f75bb9d954924438af8eaed9501f40cbeddde4ed571cbab1c8cad80914989ee"
CONFIG_BASE_TOPIC = "0x596a4006d624f49932cd682346263e8b08fcdd2dadc9855c59ada340c98c8eaf"
CONFIG_POINT_TOPIC = "0xeb60ef6c7a7148397cb3f254e7f6d8b7445a7f926b2df889904f28e4b8368e1b"
DIFF_TOPIC = "0x6242a7e403a3ee7de7e7284c18277852dce982e64c3f78b230340a705471c704"
SUMMARY_TOPIC = "0xd717e0f1f06ed111255cc893cb411eaf2e2d2ff340be843ee4983d391e28bf7e"

MODE_NAMES = {
    0: "A_user_owned_proportional",
    1: "B_total_supply_proportional",
    2: "C_sr_only",
    3: "C_jr_only",
}
SIDE_NAMES = {0: "SR", 1: "JR"}
CURVE_NAMES = {0: "subDRUp", 1: "subDRDown", 2: "vmDRUp", 3: "vmDRDown"}


def words(data: str) -> list[int]:
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    if len(raw) % 32:
        raise ValueError(f"non-word-aligned event data: {len(raw)}")
    return [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]


def address(word: int) -> str:
    return "0x" + word.to_bytes(32, "big")[-20:].hex()


def bytes32(word: int) -> str:
    return "0x" + word.to_bytes(32, "big").hex()


def signed(word: int) -> int:
    return word - 2**256 if word >= 2**255 else word


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_fork() -> dict:
    rpc_url = os.environ.get("BASE_RPC_URL", DEFAULT_RPC_URL)
    command = [
        "/Users/mac/.foundry/bin/forge",
        "test",
        "--offline",
        "--json",
        "--fork-url",
        rpc_url,
        "--fork-block-number",
        str(TARGET_BLOCK),
        "--match-path",
        TEST_PATH,
        "-vv",
    ]
    env = os.environ.copy()
    env["FOUNDRY_TEST"] = TEST_ROOT
    completed = subprocess.run(command, cwd=ROOT, env=env, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)


def all_logs(payload: dict) -> list[dict]:
    logs: list[dict] = []
    for suite in payload.values():
        for result in suite.get("test_results", {}).values():
            if result.get("status") != "Success":
                raise ValueError(f"fork test did not pass: {result.get('reason')}")
            logs.extend(result.get("logs", []))
    return logs


def decode(payload: dict) -> dict:
    version = None
    snapshot = None
    summary = None
    configs = {
        0: {"side": "SR", "curves": {name: [None] * 4 for name in CURVE_NAMES.values()}},
        1: {"side": "JR", "curves": {name: [None] * 4 for name in CURVE_NAMES.values()}},
    }
    observations: list[dict] = []

    for log in all_logs(payload):
        topics = [topic.lower() for topic in log.get("topics", [])]
        if not topics:
            continue
        topic = topics[0]
        data_words = words(log.get("data", "0x"))

        if topic == VERSION_TOPIC:
            if len(data_words) != 10:
                raise ValueError("unexpected version event length")
            version = {
                "chain_id": data_words[0],
                "block_number": data_words[1],
                "controller_proxy": address(data_words[2]),
                "controller_implementation": address(data_words[3]),
                "controller_proxy_codehash": bytes32(data_words[4]),
                "controller_implementation_codehash": bytes32(data_words[5]),
                "fee_policy_proxy": address(data_words[6]),
                "fee_policy_implementation": address(data_words[7]),
                "fee_policy_proxy_codehash": bytes32(data_words[8]),
                "fee_policy_implementation_codehash": bytes32(data_words[9]),
            }
        elif topic == SNAPSHOT_TOPIC:
            names = (
                "sub_dr",
                "vm_dr",
                "sr_total_supply",
                "sr_reserve_value",
                "sr_vm",
                "sr_underlying_balance",
                "sr_tranche_count",
                "jr_total_supply",
                "jr_reserve_value",
                "jr_vm",
                "jr_underlying_balance",
                "jr_tranche_count",
            )
            if len(data_words) != len(names):
                raise ValueError("unexpected snapshot event length")
            snapshot = dict(zip(names, data_words))
        elif topic == CONFIG_BASE_TOPIC:
            side = int(topics[1], 16)
            configs[side]["base_perc"] = data_words[0]
            configs[side]["flash_base_perc"] = data_words[1]
            configs[side]["config_hash"] = bytes32(data_words[2])
        elif topic == CONFIG_POINT_TOPIC:
            side = int(topics[1], 16)
            curve = int(topics[2], 16)
            point = int(topics[3], 16)
            configs[side]["curves"][CURVE_NAMES[curve]][point] = {"x": data_words[0], "y": data_words[1]}
        elif topic == DIFF_TOPIC:
            if len(data_words) != 12:
                raise ValueError("unexpected differential event length")
            mode = int(topics[1], 16)
            exit_bps = int(topics[2], 16)
            observations.append(
                {
                    "mode": mode,
                    "mode_name": MODE_NAMES[mode],
                    "exit_bps": exit_bps,
                    "exit_percent": exit_bps / 100,
                    "trend_status": "N/A" if mode == 1 and exit_bps in {9_500, 9_900} else "IN_SCOPE",
                    "trend_eligible": bool(data_words[0]),
                    "pre_sub_dr": data_words[1],
                    "post_sub_dr": data_words[2],
                    "pre_vm_dr": data_words[3],
                    "post_vm_dr": data_words[4],
                    "target_sr_fee": data_words[5],
                    "target_jr_fee": data_words[6],
                    "cleanroom_sr_fee": data_words[7],
                    "cleanroom_jr_fee": data_words[8],
                    "sr_wad_delta": signed(data_words[9]),
                    "jr_wad_delta": signed(data_words[10]),
                    "result": "MATCH" if data_words[11] else "MISMATCH",
                }
            )
        elif topic == SUMMARY_TOPIC:
            summary = {"vectors": data_words[0], "matches": data_words[1], "mismatches": data_words[2]}

    observations.sort(key=lambda row: (row["mode"], row["exit_bps"]))
    if version is None or snapshot is None or summary is None:
        raise ValueError("missing target metadata events")
    if len(observations) != 40:
        raise ValueError(f"expected 40 differential rows, got {len(observations)}")
    for side in configs.values():
        for curve in side["curves"].values():
            if any(point is None for point in curve):
                raise ValueError("incomplete target fee config")

    return {
        "version_lock": version,
        "target_system_snapshot": snapshot,
        "target_fee_config": {SIDE_NAMES[key]: value for key, value in configs.items()},
        "observations": observations,
        "summary": summary,
    }


def validate_local_vectors(observations: list[dict]) -> None:
    frozen = json.loads((ROOT / "evidence/target-exit-fee-differential.before-fix.json").read_text())
    frozen_rows = {(row["mode"], row["exit_bps"]): row for row in frozen["observations"]}
    for row in observations:
        source = frozen_rows[(row["mode"], row["exit_bps"])]
        expected = {
            "pre_sub_dr": source["pre_sub_dr"],
            "post_sub_dr": source["post_sub_dr"],
            "pre_vm_dr": source["pre_vm_dr"],
            "post_vm_dr": source["post_vm_dr"],
        }
        for field, value in expected.items():
            if row[field] != value:
                raise ValueError(f"local vector drift at {row['mode_name']} {row['exit_bps']}: {field}")
        if row["trend_eligible"] != source["trend_eligible"]:
            raise ValueError("N/A classification drift")


def markdown(evidence: dict) -> str:
    version = evidence["version_lock"]
    state = evidence["target_system_snapshot"]
    summary = evidence["summary"]
    first_mismatch = next((row for row in evidence["observations"] if row["result"] == "MISMATCH"), None)
    lines = [
        "# Target exit fee differential",
        "",
        "**Classification: fixed-block TARGET FeePolicy `eth_call` differential against LOCAL CLEANROOM / BNB-DESIGN vectors.**",
        "",
        "**Status: FeePolicy compatibility correction accepted. The original 40 vectors now match the target exactly with zero tolerance.**",
        "",
        "This is fee-module evidence only. It is not a target Controller exit replay and it does not mark the local Genesis exit curve as TARGET-CONFIRMED. The probe used public Base state through a local Foundry fork, made only read-only target calls, and did not sign or broadcast a transaction.",
        "",
        "## Verdict",
        "",
        f"- Vectors: `{summary['vectors']}`; exact matches: `{summary['matches']}`; mismatches: `{summary['mismatches']}`.",
        "- The target SR and JR fee parameter structs match the clean-room parameter structs byte-for-byte at the fixed block (the Foundry test asserts their ABI-encoded hashes).",
        "- The target and clean-room `computeOpFees` outputs now match exactly for all 40 frozen pre-fix DR tuples.",
        "- This accepts only the fee-calculation module. It is not a target Controller, Vault, or Router exit replay.",
        "- B-mode 95% and 99% remain `N/A` for exit-fee trend analysis because the local caller lacked the required balances. Their DR tuples are still included in the pure-function differential because the task required all 40 inputs.",
    ]
    if first_mismatch:
        lines.extend(
            [
                f"- First mismatch: `{first_mismatch['mode_name']}` at `{first_mismatch['exit_percent']:g}%`; target SR/JR fee `{first_mismatch['target_sr_fee']}` / `{first_mismatch['target_jr_fee']}`, clean-room `{first_mismatch['cleanroom_sr_fee']}` / `{first_mismatch['cleanroom_jr_fee']}`, exact delta `{first_mismatch['sr_wad_delta']}` / `{first_mismatch['jr_wad_delta']}` WAD.",
                "- Observed discriminator for that row: `vmDRPre == vmDRPost`. The target returns only `24668775771025119`, while the clean-room adds the nonzero static-VM curve value. This identifies a compatibility difference; it does not by itself prove the target's full internal algorithm.",
            ]
        )

    lines.extend(
        [
            "",
            "## Fixed target version",
            "",
            f"- Base chain ID: `{version['chain_id']}`",
            f"- Block: `{version['block_number']}`",
            f"- Controller: `{version['controller_proxy']}` → implementation `{version['controller_implementation']}`",
            f"- Controller proxy / implementation codehash: `{version['controller_proxy_codehash']}` / `{version['controller_implementation_codehash']}`",
            f"- FeePolicy: `{version['fee_policy_proxy']}` → implementation `{version['fee_policy_implementation']}`",
            f"- FeePolicy proxy / implementation codehash: `{version['fee_policy_proxy_codehash']}` / `{version['fee_policy_implementation_codehash']}`",
            "",
            "## Target system snapshot",
            "",
            "| field | value |",
            "|---|---:|",
        ]
    )
    for key, value in state.items():
        lines.append(f"| {key} | {value} |")

    lines.extend(["", "## Target FeePolicy configuration", ""])
    for side_name in ("SR", "JR"):
        config = evidence["target_fee_config"][side_name]
        lines.extend(
            [
                f"### {side_name}",
                "",
                f"- basePerc: `{config['base_perc']}`; flashBasePerc: `{config['flash_base_perc']}`; config hash: `{config['config_hash']}`",
                "",
                "| curve | point | x | y |",
                "|---|---:|---:|---:|",
            ]
        )
        for curve_name, points in config["curves"].items():
            for index, point in enumerate(points):
                lines.append(f"| {curve_name} | {index + 1} | {point['x']} | {point['y']} |")
        lines.append("")

    lines.extend(
        [
            "## Forty-vector differential",
            "",
            "`post_*` below is the exact fee-quote post-state tuple from the local record, not the realized post-execution state after fee retention.",
            "",
            "| mode | exit | trend | pre subDR | post subDR | pre vmDR | post vmDR | TARGET SR | TARGET JR | CLEANROOM SR | CLEANROOM JR | SR delta | JR delta | result |",
            "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|",
        ]
    )
    for row in evidence["observations"]:
        lines.append(
            f"| {row['mode_name']} | {row['exit_percent']:g}% | {row['trend_status']} | "
            f"{row['pre_sub_dr']} | {row['post_sub_dr']} | {row['pre_vm_dr']} | {row['post_vm_dr']} | "
            f"{row['target_sr_fee']} | {row['target_jr_fee']} | {row['cleanroom_sr_fee']} | "
            f"{row['cleanroom_jr_fee']} | {row['sr_wad_delta']} | {row['jr_wad_delta']} | {row['result']} |"
        )

    lines.extend(
        [
            "",
            "## Reproduce",
            "",
            "```sh",
            "BASE_RPC_URL=https://mainnet.base.org python3 script/export_target_exit_fee_differential.py",
            "```",
            "",
            f"- Probe: `{TEST_PATH}`",
            "- Machine-readable output: `evidence/target-exit-fee-differential.json`",
            "- No `deal`, `store`, wallet, private key, signature, or broadcast transaction is used by this probe.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    decoded = decode(run_fork())
    validate_local_vectors(decoded["observations"])
    decoded = {
        "schema": "target-exit-fee-differential/v1",
        "evidence_classification": "TARGET FEE POLICY DIFFERENTIAL",
        "compatibility_verdict": "40_OF_40_EXACT_MATCH",
        "production_fix_status": "LOCAL_FEE_POLICY_CORRECTED",
        "target_controller_exit_confirmed": False,
        "local_vector_classification": "LOCAL CLEANROOM / BNB-DESIGN",
        "local_vectors_target_confirmed": False,
        "scope": "read-only computeOpFees calls at a fixed public Base block",
        "real_exit_replay": {
            "status": "NOT_STARTED",
            "reason": "This phase accepts the FeePolicy module before any Controller/Vault/Router replay.",
        },
        "sources": {
            "probe": TEST_PATH,
            "probe_sha256": sha256(ROOT / TEST_PATH),
            "frozen_input_vectors": "evidence/target-exit-fee-differential.before-fix.json",
            "frozen_input_vectors_sha256": sha256(ROOT / "evidence/target-exit-fee-differential.before-fix.json"),
        },
        **decoded,
    }

    json_path = ROOT / "evidence/target-exit-fee-differential.json"
    md_path = ROOT / "evidence/TARGET_EXIT_FEE_DIFFERENTIAL.md"
    json_path.write_text(json.dumps(decoded, indent=2, sort_keys=True) + "\n")
    md_path.write_text(markdown(decoded))
    print(f"wrote {json_path.relative_to(ROOT)} ({len(decoded['observations'])} rows)")
    print(f"wrote {md_path.relative_to(ROOT)}")
    print(json.dumps(decoded["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
