#!/usr/bin/env python3
"""Export the fixed-block target FeePolicy rounding-closure matrix."""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = "evidence/probe-tests"
TEST_PATH = "evidence/probe-tests/TargetFeePolicyRoundingClosure.t.sol"
TEST_NAME = "testTargetFeePolicyRoundingClosure"
TARGET_BLOCK = 54_990_962
DEFAULT_RPC_URL = "https://mainnet.base.org"

GROUP_NAMES = {
    0: "inc_32_43_residue_grid",
    1: "inc_32_43_target_band_first_interval",
    2: "inc_32_43_cross_lower_knot",
    3: "inc_32_43_cross_upper_knot",
    4: "dec_32_43_residue_grid",
    5: "dec_32_43_target_band_first_interval",
    6: "dec_32_43_cross_lower_knot",
    7: "dec_32_43_cross_upper_knot",
    8: "dec_4_5_residue_grid",
    9: "dec_4_5_target_band_first_interval",
    10: "inc_32_43_near_p1_control",
    11: "inc_32_43_near_p4_control",
    12: "dec_32_43_near_p1_control",
    13: "dec_32_43_near_p4_control",
}


def keccak_topic(signature: str) -> str:
    return subprocess.check_output(
        ["/Users/mac/.foundry/bin/cast", "keccak", signature], text=True
    ).strip().lower()


OBSERVATION_TOPIC = keccak_topic(
    "RoundingObservation(uint8,uint16,uint16,uint256,uint256,uint256,bool,bytes4,uint256,uint256)"
)
SUMMARY_TOPIC = keccak_topic("RoundingClosureSummary(uint256)")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_fork() -> dict:
    command = [
        "/Users/mac/.foundry/bin/forge",
        "test",
        "--offline",
        "--json",
        "--fork-url",
        os.environ.get("BASE_RPC_URL", DEFAULT_RPC_URL),
        "--fork-block-number",
        str(TARGET_BLOCK),
        "--match-path",
        TEST_PATH,
        "--match-test",
        TEST_NAME,
        "-vv",
    ]
    env = os.environ.copy()
    env["FOUNDRY_TEST"] = TEST_ROOT
    completed = subprocess.run(command, cwd=ROOT, env=env, check=True, capture_output=True, text=True)
    return json.loads(completed.stdout)


def words(data: str) -> list[bytes]:
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    if len(raw) % 32:
        raise ValueError(f"non-word-aligned event data: {len(raw)}")
    return [raw[i : i + 32] for i in range(0, len(raw), 32)]


def uint(word: bytes) -> int:
    return int.from_bytes(word, "big")


def decode(payload: dict) -> tuple[list[dict], int]:
    observations: list[dict] = []
    summary = None
    for suite in payload.values():
        result = suite["test_results"][f"{TEST_NAME}()"]
        if result["status"] != "Success":
            raise ValueError(result.get("reason") or "rounding closure probe failed")
        for log in result.get("logs", []):
            topics = [topic.lower() for topic in log.get("topics", [])]
            if not topics:
                continue
            data = words(log.get("data", "0x"))
            if topics[0] == OBSERVATION_TOPIC:
                if len(data) != 7:
                    raise ValueError(f"unexpected observation words: {len(data)}")
                group = int(topics[1], 16)
                observations.append(
                    {
                        "group": group,
                        "group_name": GROUP_NAMES[group],
                        "origin_shift": int(topics[2], 16),
                        "interval_offset": int(topics[3], 16),
                        "origin": uint(data[0]),
                        "start": uint(data[1]),
                        "end": uint(data[2]),
                        "success": bool(uint(data[3])),
                        "error_selector": "0x" + data[4][:4].hex(),
                        "target_total_fee": uint(data[5]),
                        "target_protocol_fee": uint(data[6]),
                    }
                )
            elif topics[0] == SUMMARY_TOPIC:
                summary = uint(data[0])
    observations.sort(key=lambda row: (row["group"], row["origin_shift"], row["interval_offset"]))
    if summary != 4_158 or len(observations) != summary:
        raise ValueError(f"incomplete closure matrix: rows={len(observations)} summary={summary}")
    if any(not row["success"] or row["error_selector"] != "0x00000000" for row in observations):
        raise ValueError("unexpected target revert")
    return observations, summary


def group_summary(observations: list[dict]) -> dict:
    grouped: dict[int, list[dict]] = defaultdict(list)
    for row in observations:
        grouped[row["group"]].append(row)
    output = {}
    for group, rows in sorted(grouped.items()):
        output[GROUP_NAMES[group]] = {
            "rows": len(rows),
            "unique_outputs": sorted(set(row["target_total_fee"] for row in rows)),
            "output_counts": {
                str(value): count for value, count in sorted(Counter(row["target_total_fee"] for row in rows).items())
            },
        }
    return output


def compact_sequence(rows: list[dict]) -> str:
    return ",".join(str(row["target_total_fee"]) for row in rows)


def markdown(doc: dict) -> str:
    rows = doc["observations"]
    by_group: dict[int, list[dict]] = defaultdict(list)
    for row in rows:
        by_group[row["group"]].append(row)

    inc_first = [row for row in by_group[0] if row["interval_offset"] == 0]
    inc_target = by_group[1]
    dec_first = [row for row in by_group[4] if row["interval_offset"] == 0]
    dec_target = by_group[5]
    control_groups = (10, 11, 12, 13)

    lines = [
        "# Target FeePolicy rounding closure matrix",
        "",
        "Clean-room black-box evidence from a fresh local proxy backed by the code-locked target implementation at public Base block `54,990,962`. The deployed target proxy is not mutated.",
        "",
        "## Coverage",
        "",
        f"- Exact observations: `{doc['summary']['observations']}`; successful: `{doc['summary']['successes']}`; reverts: `0`.",
        "- Rising and falling `32/43` segments: every origin shift `0..42` and every adjacent one-wei interval `0..42`.",
        "- Falling `4/5` controls: every origin shift and adjacent interval `0..4`.",
        "- Both lower/upper cross-knot intervals and independent near-`p1` / near-`p4` controls.",
        "",
        "## First-interval coordinate fingerprints",
        "",
        "The following values are ordered by origin shift. They are exact target WAD integer outputs, not percentages rounded for display.",
        "",
        f"- Rising `32/43`, `WAD + shift`: `{compact_sequence(inc_first)}`",
        f"- Rising `32/43`, `TARGET_X + shift`: `{compact_sequence(inc_target)}`",
        f"- Falling `32/43`, `WAD + shift`: `{compact_sequence(dec_first)}`",
        f"- Falling `32/43`, `TARGET_X + shift`: `{compact_sequence(dec_target)}`",
        "",
        "## Group summary",
        "",
        "| group | rows | unique target outputs |",
        "|---|---:|---|",
    ]
    for name, summary in doc["group_summary"].items():
        values = ", ".join(str(value) for value in summary["unique_outputs"])
        lines.append(f"| {name} | {summary['rows']} | `{values}` |")

    lines.extend(
        [
            "",
            "## Surrounding-point controls",
            "",
            "These controls keep the tested `p2/p3` segment unchanged while moving only `p1` or `p4`. Full rows are in the JSON.",
            "",
        ]
    )
    for group in control_groups:
        lines.append(f"- {GROUP_NAMES[group]}: `{compact_sequence(by_group[group])}`")

    lines.extend(
        [
            "",
            "## Reproduce",
            "",
            "```sh",
            "BASE_RPC_URL=https://mainnet.base.org python3 script/export_fee_policy_rounding_closure.py",
            "```",
            "",
            f"- Probe SHA-256: `{doc['sources']['probe_sha256']}`",
            "- No verified source, wallet, private key, signature, broadcast, `deal`, or `store` is used.",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    observations, count = decode(run_fork())
    doc = {
        "schema": "target-fee-policy-rounding-closure/v1",
        "chain_id": 8453,
        "block_number": TARGET_BLOCK,
        "target_implementation": "0x9cefc3cf756c6b2a7568b0539c956f1dd5691900",
        "evidence_classification": "TARGET_IMPLEMENTATION_FRESH_LOCAL_PROXY_SYNTHETIC_CONFIG",
        "sources": {"probe": TEST_PATH, "probe_sha256": sha256(ROOT / TEST_PATH)},
        "summary": {"observations": count, "successes": count, "reverts": 0},
        "group_summary": group_summary(observations),
        "observations": observations,
    }
    json_path = ROOT / "evidence/target-fee-policy-rounding-closure.json"
    md_path = ROOT / "evidence/TARGET_FEE_POLICY_ROUNDING_CLOSURE.md"
    json_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    md_path.write_text(markdown(doc))
    print(f"wrote {json_path.relative_to(ROOT)} ({count} rows)")
    print(f"wrote {md_path.relative_to(ROOT)}")
    print(json.dumps(doc["summary"], sort_keys=True))


if __name__ == "__main__":
    main()
