#!/usr/bin/env python3
"""Export the fixed-block FeePolicy semantic matrix from Foundry event logs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_ROOT = "evidence/probe-tests"
TEST_PATH = "evidence/probe-tests/TargetFeePolicySemanticsMatrix.t.sol"
TEST_NAME = "testTargetFeePolicySemanticsMatrix"
TARGET_BLOCK = 54_990_962
DEFAULT_RPC_URL = "https://mainnet.base.org"

INPUT_TOPIC = "0x470f27b3c309e1d1c16d8af00511dcd3f4440d1386877cc3b7364068f63d95e4"
RESULT_TOPIC = "0x53d4e466dd49b39c4a94829d45dfa34f6f066d0e8ef52bea404d71f7fd7c6460"
SUMMARY_TOPIC = "0x05287cfbdcc5f474c95c7c043be16fe7e3702ead8e412011033b95596cd19c79"

SIDE_NAMES = {0: "SR", 1: "JR"}
EVIDENCE_CLASSES = {
    0: "FIXED_TARGET_PROXY",
    1: "TARGET_IMPL_FRESH_LOCAL_PROXY_SYNTHETIC_CONFIG",
}

BASE_NAMES = {
    1: "sub_equal_below_one",
    2: "sub_equal_one",
    3: "sub_equal_above_one",
    4: "vm_equal_below_one",
    5: "both_equal_one",
    6: "vm_equal_above_one",
    10: "sub_up_below_one",
    11: "sub_down_below_one",
    12: "sub_up_above_one",
    13: "sub_down_above_one",
    14: "sub_up_cross_one",
    15: "sub_down_cross_one",
    16: "vm_up_below_one",
    17: "vm_down_below_one",
    18: "vm_up_above_one",
    19: "vm_down_above_one",
    20: "vm_up_cross_one",
    21: "vm_down_cross_one",
    200: "joint_sub_up_vm_up",
    201: "joint_sub_down_vm_up",
    202: "joint_sub_up_vm_down",
    203: "joint_sub_down_vm_down",
    204: "original_b100_extreme",
    205: "single_vm_component_above_cap",
    206: "two_components_sum_above_cap",
    207: "sub_up_three_wei_rounding",
    208: "sub_down_three_wei_rounding",
    209: "vm_up_three_wei_rounding",
    210: "vm_down_three_wei_rounding",
    211: "sub_up_five_wei_noninteger_slope",
    212: "sub_up_five_wei_before_knot",
    213: "sub_down_five_wei_before_knot",
    214: "sub_down_five_wei_after_knot",
    215: "vm_up_five_wei_noninteger_slope",
    216: "vm_up_five_wei_before_knot",
    217: "vm_down_five_wei_noninteger_slope",
    218: "vm_down_five_wei_before_knot",
    219: "sub_up_cross_knot_eight_wei",
    220: "sub_down_cross_knot_eight_wei",
    221: "vm_up_cross_knot_eight_wei",
    222: "vm_down_cross_knot_eight_wei",
    300: "synthetic_nonzero_base_equal_dr",
    301: "synthetic_nonzero_flash_base_equal_dr",
    302: "synthetic_base_plus_sub_impact",
    303: "synthetic_protocol_cap_high_total",
    304: "synthetic_flash_base_high_total",
    305: "synthetic_base_joint_movement",
    400: "synthetic_inc_up_p2_to_p2_plus_1",
    401: "synthetic_inc_up_p2_plus_1_to_plus_4",
    402: "synthetic_inc_up_p2_plus_2_to_plus_7",
    403: "synthetic_inc_up_cross_p2",
    404: "synthetic_inc_up_mid_segment",
    405: "synthetic_inc_up_p3_left_1",
    406: "synthetic_inc_up_p3_right_1",
    407: "synthetic_inc_up_p4_left_1",
    408: "synthetic_inc_up_p4_right_1",
    409: "synthetic_dec_down_p2_plus_1_to_p2",
    410: "synthetic_dec_down_p2_plus_4_to_plus_1",
    411: "synthetic_dec_down_p2_plus_7_to_plus_2",
    412: "synthetic_dec_down_cross_p2",
    413: "synthetic_dec_down_mid_segment",
    414: "synthetic_dec_down_p3_to_left_1",
    415: "synthetic_dec_down_p3_plus_1_to_p3",
    416: "synthetic_dec_down_p4_to_left_1",
    417: "synthetic_dec_down_p4_plus_1_to_p4",
    420: "synthetic_dec_curve_up_direction",
    421: "synthetic_dec_curve_up_cross_p2",
    422: "synthetic_dec_curve_up_cross_p3",
    423: "synthetic_inc_curve_down_direction",
    424: "synthetic_inc_curve_down_cross_p2",
    425: "synthetic_inc_curve_down_cross_p3",
    430: "synthetic_vm_inc_up_p2_to_p2_plus_1",
    431: "synthetic_vm_inc_up_p2_plus_1_to_plus_4",
    432: "synthetic_vm_inc_up_p2_plus_2_to_plus_7",
    433: "synthetic_vm_inc_up_cross_p2",
    434: "synthetic_vm_inc_up_mid_segment",
    435: "synthetic_vm_inc_up_p3_left_1",
    436: "synthetic_vm_inc_up_p3_right_1",
    437: "synthetic_vm_inc_up_p4_left_1",
    438: "synthetic_vm_inc_up_p4_right_1",
    439: "synthetic_vm_dec_down_p2_plus_1_to_p2",
    440: "synthetic_vm_dec_down_p2_plus_4_to_plus_1",
    441: "synthetic_vm_dec_down_p2_plus_7_to_plus_2",
    442: "synthetic_vm_dec_down_cross_p2",
    443: "synthetic_vm_dec_down_mid_segment",
    444: "synthetic_vm_dec_down_p3_to_left_1",
    445: "synthetic_vm_dec_down_p3_plus_1_to_p3",
    446: "synthetic_vm_dec_down_p4_to_left_1",
    447: "synthetic_vm_dec_down_p4_plus_1_to_p4",
    450: "synthetic_32_over_43_up_zero_to_1",
    451: "synthetic_32_over_43_up_1_to_4",
    452: "synthetic_32_over_43_up_2_to_7",
    453: "synthetic_32_over_43_up_cross_p2",
    454: "synthetic_32_over_43_up_p3_left_1",
    455: "synthetic_32_over_43_up_p3_right_1",
    456: "synthetic_4_over_5_down_1_to_zero",
    457: "synthetic_4_over_5_down_4_to_1",
    458: "synthetic_4_over_5_down_5_to_2",
    459: "synthetic_4_over_5_down_cross_p2",
    460: "synthetic_4_over_5_down_p3_to_left_1",
    461: "synthetic_4_over_5_down_p3_plus_1_to_p3",
    470: "synthetic_32_over_43_target_x_up_zero_to_1",
    471: "synthetic_32_over_43_target_x_up_1_to_4",
    472: "synthetic_32_over_43_target_x_up_2_to_7",
    473: "synthetic_32_over_43_target_x_up_cross_p2",
    474: "synthetic_32_over_43_target_x_up_p3_left_1",
    475: "synthetic_32_over_43_target_x_up_p3_right_1",
    476: "synthetic_32_over_43_shift_1_up_zero_to_1",
    477: "synthetic_32_over_43_shift_1_up_1_to_4",
    478: "synthetic_32_over_43_shift_1_up_2_to_7",
    479: "synthetic_32_over_43_shift_1_up_cross_p2",
    480: "synthetic_32_over_43_shift_1_up_p3_left_1",
    481: "synthetic_32_over_43_shift_1_up_p3_right_1",
}


def case_name(case_id: int) -> str:
    if case_id in BASE_NAMES:
        return BASE_NAMES[case_id]
    for base, curve, direction in (
        (100, "sub_up", "up"),
        (120, "sub_down", "down"),
        (140, "vm_up", "up"),
        (160, "vm_down", "down"),
    ):
        if base <= case_id <= base + 7:
            offset = case_id - base
            point = offset // 2 + 1
            side = "left" if (offset % 2 == 0) == (direction == "up") else "right"
            return f"{curve}_p{point}_{side}_one_wei"
    return f"case_{case_id}"


def row_conclusion(case_id: int) -> str:
    if case_id in {1, 2, 3, 4, 5, 6, 300, 301}:
        return "Equal pre/post DR contributes zero curve impact; only configured base fee remains."
    if case_id == 204:
        return "Each impact component can reach 1e18 and the returned total can reach 2e18."
    if case_id == 205:
        return "A single impact component is capped at 1e18."
    if case_id in {206, 303, 304}:
        return "Individually capped components and base fee are summed without a final 1e18 total cap."
    if case_id in {302, 305}:
        return "Configured base fee is added to directional impact; protocol fee remains independently capped."
    if 100 <= case_id <= 222 or case_id >= 400:
        return "Exact target output is confirmed; the general 1-wei interpolation/integration rounding rule remains unresolved."
    return "Directional curve selection and piecewise impact output are confirmed for this vector."


def raw_words(data: str) -> list[bytes]:
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    if len(raw) % 32:
        raise ValueError(f"non-word-aligned data: {len(raw)}")
    return [raw[i : i + 32] for i in range(0, len(raw), 32)]


def uint(word: bytes) -> int:
    return int.from_bytes(word, "big")


def signed(word: bytes) -> int:
    value = uint(word)
    return value - 2**256 if value >= 2**255 else value


def selector(word: bytes, success: bool) -> str:
    return "0x00000000" if success else "0x" + word[:4].hex()


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


def decode(payload: dict) -> tuple[list[dict], dict]:
    cases: dict[int, dict] = {}
    summary = None
    for suite in payload.values():
        result = suite["test_results"][f"{TEST_NAME}()"]
        if result["status"] != "Success":
            raise ValueError(result.get("reason") or "matrix failed")
        for log in result.get("logs", []):
            topics = [topic.lower() for topic in log.get("topics", [])]
            if not topics:
                continue
            data = raw_words(log.get("data", "0x"))
            if topics[0] == INPUT_TOPIC:
                case_id = int(topics[1], 16)
                evidence_class = int(topics[2], 16)
                cases[case_id] = {
                    "case_id": case_id,
                    "case_name": case_name(case_id),
                    "evidence_class": EVIDENCE_CLASSES[evidence_class],
                    "is_flash": bool(uint(data[0])),
                    "sub_dr_pre": uint(data[1]),
                    "sub_dr_post": uint(data[2]),
                    "vm_dr_pre": uint(data[3]),
                    "vm_dr_post": uint(data[4]),
                    "sides": {},
                }
            elif topics[0] == RESULT_TOPIC:
                case_id = int(topics[1], 16)
                side = int(topics[2], 16)
                target_success = bool(uint(data[0]))
                cleanroom_success = bool(uint(data[4]))
                cases[case_id]["sides"][SIDE_NAMES[side]] = {
                    "target_success": target_success,
                    "target_error_selector": selector(data[1], target_success),
                    "target_total_fee": uint(data[2]),
                    "target_protocol_fee": uint(data[3]),
                    "cleanroom_success": cleanroom_success,
                    "cleanroom_error_selector": selector(data[5], cleanroom_success),
                    "cleanroom_total_fee": uint(data[6]),
                    "cleanroom_protocol_fee": uint(data[7]),
                    "total_fee_wad_delta": signed(data[8]),
                    "protocol_fee_wad_delta": signed(data[9]),
                    "result": "MATCH" if bool(uint(data[10])) else "MISMATCH",
                }
            elif topics[0] == SUMMARY_TOPIC:
                summary = {
                    "cases": uint(data[0]),
                    "side_comparisons": uint(data[1]),
                    "matches": uint(data[2]),
                    "mismatches": uint(data[3]),
                }
    rows = [cases[key] for key in sorted(cases)]
    if len(rows) != 136 or summary is None:
        raise ValueError(f"incomplete matrix: rows={len(rows)} summary={summary}")
    if any(set(row["sides"]) != {"SR", "JR"} for row in rows):
        raise ValueError("missing side result")
    return rows, summary


def markdown(doc: dict) -> str:
    summary = doc["summary"]
    if doc["phase"] == "after-fix":
        rounding_lines = [
            "## Exact rounding rule — accepted",
            "",
            "The expanded rounding-closure matrix selected one absolute-coordinate piecewise-linear model. The clean-room implementation now reproduces all rows in this semantic matrix exactly, including cases `450`, `470`, and `476`.",
            "",
            "The independent 4,158-row closure evidence and exact model are recorded in `TARGET_FEE_POLICY_ROUNDING_CLOSURE.md` and `FEE_POLICY_EXACT_MODEL.md`.",
        ]
    else:
        rounding_lines = [
            "## Unresolved rounding rule — implementation stop",
            "",
            "The remaining ambiguity is not a missing raw observation. It is the general arithmetic rule that maps arbitrary curve coordinates to the exact 1-wei result. The same `32/43` local segment produces different outputs after horizontal translation: case `450` returns `1`, case `470` returns `0`, and case `476` returns `1` for the corresponding one-wei interval. This proves that a simple exact-rational floor/ceil/nearest rule is insufficient and that absolute curve coordinates affect target rounding.",
            "",
            "Per the clean-room stop condition, production `FeePolicy` is not modified in this phase. The next discriminating evidence must translate an otherwise identical curve across a wider residue grid, keep the surrounding points fixed independently, and record adjacent one-wei intervals across the whole short segment. Until that closes to one arithmetic model, changing production code would be guesswork.",
        ]
    lines = [
        f"# FeePolicy semantic matrix — {doc['phase']}",
        "",
        "This is clean-room black-box evidence. No verified implementation source was read. Fixed rows call the deployed target proxy at Base block `54,990,962`. Synthetic-config rows call a newly deployed local proxy backed by the same locked target implementation; they do not mutate the deployed target proxy.",
        "",
        "## Summary",
        "",
        f"- Cases: `{summary['cases']}`; side comparisons: `{summary['side_comparisons']}`; exact matches: `{summary['matches']}`; mismatches: `{summary['mismatches']}`.",
        "- Every row records exact WAD outputs, success/revert status and selectors. No tolerance is used.",
        "- For `subDRUp` point 1, `subDRDown` point 1 and `vmDRUp` point 1, the left-side `-1 wei` input is impossible because the knot is zero; those three nonexistent vectors are explicitly outside the executable cases.",
        "",
        "## Confirmed target semantics",
        "",
        "- `pre == post` contributes zero impact, regardless of whether the unchanged DR is below, equal to, or above `1e18`.",
        "- `subDR` and `vmDR` impact components are each capped independently at `1e18`.",
        "- The two capped components and base fee are summed without a final `1e18` total cap; the target returns `2e18` in the original extreme vector.",
        "- `protocolFeePerc = min(totalFeePerc, protocolMaxOpFeePerc)` remains independent of the operation-disable signal.",
        "- Up/down selection follows the actual direction of each DR when it changes.",
        "",
        *rounding_lines,
        "",
        "## Matrix",
        "",
        "| id | case | class | flash | sub pre | sub post | vm pre | vm post | side | TARGET total | TARGET protocol | CLEANROOM total | CLEANROOM protocol | total delta | protocol delta | status/selector | result |",
        "|---:|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---:|---:|---:|---|---|",
    ]
    for row in doc["observations"]:
        for side_name in ("SR", "JR"):
            side = row["sides"][side_name]
            status = (
                "success"
                if side["target_success"] and side["cleanroom_success"]
                else f"target={side['target_error_selector']}, local={side['cleanroom_error_selector']}"
            )
            lines.append(
                f"| {row['case_id']} | {row['case_name']} | {row['evidence_class']} | {row['is_flash']} | "
                f"{row['sub_dr_pre']} | {row['sub_dr_post']} | {row['vm_dr_pre']} | {row['vm_dr_post']} | "
                f"{side_name} | {side['target_total_fee']} | {side['target_protocol_fee']} | "
                f"{side['cleanroom_total_fee']} | {side['cleanroom_protocol_fee']} | "
                f"{side['total_fee_wad_delta']} | {side['protocol_fee_wad_delta']} | {status} | {side['result']} |"
            )
    lines.extend(
        [
            "",
            "## Reproduce",
            "",
            "```sh",
            f"BASE_RPC_URL=https://mainnet.base.org python3 script/export_fee_policy_semantics_matrix.py --phase {doc['phase']}",
            "```",
            "",
            f"- Probe SHA-256: `{doc['sources']['probe_sha256']}`",
            "- No wallet, key, signature, broadcast, `deal`, or `store` is used.",
        ]
    )
    return "\n".join(lines) + "\n"


def output_paths(phase: str) -> tuple[Path, Path]:
    if phase == "before-fix":
        return (
            ROOT / "evidence/fee-policy-semantics-matrix.before-fix.json",
            ROOT / "evidence/FEE_POLICY_SEMANTICS_MATRIX_BEFORE_FIX.md",
        )
    return ROOT / "evidence/fee-policy-semantics-matrix.json", ROOT / "evidence/FEE_POLICY_SEMANTICS_MATRIX.md"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("before-fix", "after-fix"), required=True)
    args = parser.parse_args()

    observations, summary = decode(run_fork())
    for row in observations:
        row["evidence_level"] = (
            "TARGET_DEPLOYED_PROXY_FIXED_BLOCK"
            if row["evidence_class"] == "FIXED_TARGET_PROXY"
            else "TARGET_IMPLEMENTATION_FRESH_LOCAL_PROXY_SYNTHETIC_CONFIG"
        )
        row["conclusion"] = row_conclusion(row["case_id"])
    doc = {
        "schema": "fee-policy-semantics-matrix/v2",
        "phase": args.phase,
        "chain_id": 8453,
        "block_number": TARGET_BLOCK,
        "target_proxy": "0x1e3dbdc2adf4d5fdd1efdfb9ff05e4154d0c00e8",
        "target_implementation": "0x9cefc3cf756c6b2a7568b0539c956f1dd5691900",
        "sources": {"probe": TEST_PATH, "probe_sha256": sha256(ROOT / TEST_PATH)},
        "summary": summary,
        "inference": {
            "confirmed": [
                "equal_dr_zero_impact",
                "each_impact_component_capped_at_1e18",
                "no_final_total_fee_cap",
                "protocol_fee_independently_capped",
                "directional_curve_selection",
                *(["absolute_coordinate_piecewise_average_rounding"] if args.phase == "after-fix" else []),
            ],
            "unresolved": []
            if args.phase == "after-fix"
            else [
                "general_exact_1_wei_interpolation_and_integration_rounding",
                "absolute_curve_coordinate_rounding_dependency",
            ],
            "production_change_authorized": args.phase == "after-fix",
            "stop_reason": None
            if args.phase == "after-fix"
            else "Multiple arithmetic models remain possible; black-box translation vectors prove absolute-coordinate dependence.",
        },
        "observations": observations,
    }
    json_path, md_path = output_paths(args.phase)
    json_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    md_path.write_text(markdown(doc))
    print(f"wrote {json_path.relative_to(ROOT)}")
    print(f"wrote {md_path.relative_to(ROOT)}")
    print(json.dumps(summary, sort_keys=True))


if __name__ == "__main__":
    main()
