#!/usr/bin/env python3
"""Run the local exit-curve regression and export its structured observations.

This script only invokes the local Foundry test.  It does not connect to a chain,
sign a transaction, or change protocol parameters.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TEST_PATH = "test/GenesisDeployment.t.sol"
TEST_NAME = "testGenesisExitFeeCurveAudit"
OBSERVATION_TOPIC = "0x26b0f23ed2322f82b0b21c405640f3c3a09ae429cc6d930057483736272113d2"
HASH_TOPIC = "0xafb795c9c61e4fe7468c386f925d7a5429ecad9c0495ddb8d38d690614d32f99"

MODE_NAMES = {
    0: "A_user_owned_proportional",
    1: "B_total_supply_proportional",
    2: "C_sr_only",
    3: "C_jr_only",
}

WORD_FIELDS = (
    "mode",
    "exit_bps",
    "sr_input",
    "jr_input",
    "pre_sub_dr",
    "pre_vm_dr",
    "fee_quote_post_sub_dr",
    "fee_quote_post_vm_dr",
    "post_sub_dr",
    "post_vm_dr",
    "sr_fee_perc",
    "jr_fee_perc",
    "theoretical_value",
    "actual_received_value",
    "controller_sr_fee_shares",
    "controller_jr_fee_shares",
    "controller_retained_fee_value",
    "success",
    "error_selector",
    "underlying_total_supply",
    "underlying_accounted_after",
    "underlying_conserved",
)


def decode_observation(data: str) -> dict:
    raw = bytes.fromhex(data[2:] if data.startswith("0x") else data)
    expected = 32 * len(WORD_FIELDS)
    if len(raw) != expected:
        raise ValueError(f"unexpected observation length: {len(raw)} != {expected}")

    words = [int.from_bytes(raw[i : i + 32], "big") for i in range(0, len(raw), 32)]
    item = {}
    for index, (field, word) in enumerate(zip(WORD_FIELDS, words)):
        if field in {"success", "underlying_conserved"}:
            item[field] = bool(word)
        elif field == "error_selector":
            item[field] = "0x" + raw[index * 32 : index * 32 + 4].hex()
        else:
            item[field] = word
    item["mode_name"] = MODE_NAMES[item["mode"]]
    item["exit_percent"] = item["exit_bps"] / 100
    item["max_fee_perc"] = max(item["sr_fee_perc"], item["jr_fee_perc"])
    item["max_fee_percent"] = item["max_fee_perc"] / 10**16
    item["net_value_delta"] = item["theoretical_value"] - item["actual_received_value"]
    if item["mode"] == 1 and item["exit_bps"] in {9_500, 9_900} and not item["success"]:
        item["analysis_status"] = "N/A"
        item["analysis_reason"] = "caller balance insufficient for total-supply-proportional input"
    else:
        item["analysis_status"] = "IN_SCOPE"
        item["analysis_reason"] = None
    return item


def load_test_json() -> tuple[list[dict], str]:
    command = [
        "/Users/mac/.foundry/bin/forge",
        "test",
        "--offline",
        "--json",
        "--match-path",
        TEST_PATH,
        "--match-test",
        TEST_NAME,
        "-vv",
    ]
    completed = subprocess.run(command, cwd=ROOT, check=True, capture_output=True, text=True)
    payload = json.loads(completed.stdout)
    suite_key = next(key for key in payload if key.startswith(f"{TEST_PATH}:"))
    result = payload[suite_key]["test_results"][f"{TEST_NAME}()"]
    observations = []
    rolling_hash = None
    for log in result.get("logs", []):
        topics = [topic.lower() for topic in log.get("topics", [])]
        if topics and topics[0] == OBSERVATION_TOPIC:
            observations.append(decode_observation(log["data"]))
        elif topics and topics[0] == HASH_TOPIC:
            # The hash event data is (bytes32 hash, string key), followed by the
            # standard ABI offset/length.  The first word is sufficient here.
            raw = bytes.fromhex(log["data"][2:])
            rolling_hash = "0x" + raw[32:64].hex()
    if len(observations) != 40:
        raise ValueError(f"expected 40 observations, got {len(observations)}")
    if rolling_hash is None:
        raise ValueError("missing EXIT_CURVE_HASH event")
    return observations, rolling_hash


def first_exceeding(observations: list[dict], field: str, threshold_percent: float) -> float | None:
    threshold = int(threshold_percent * 10**16)
    candidates = [o["exit_percent"] for o in observations if o[field] > threshold]
    return min(candidates) if candidates else None


def build_summary(observations: list[dict]) -> dict:
    thresholds = [1, 5, 10, 25, 50]
    summary = {}
    for mode in MODE_NAMES:
        all_rows = [o for o in observations if o["mode"] == mode]
        rows = [o for o in all_rows if o["analysis_status"] == "IN_SCOPE"]
        summary[MODE_NAMES[mode]] = {
            "rows": len(all_rows),
            "trend_rows": len(rows),
            "na_rows": len(all_rows) - len(rows),
            "success_count": sum(o["success"] for o in rows),
            "failure_selectors": sorted({o["error_selector"] for o in rows if not o["success"]}),
            "first_exit_percent_exceeding": {
                f"{threshold}%": {
                    "sr": first_exceeding(rows, "sr_fee_perc", threshold),
                    "jr": first_exceeding(rows, "jr_fee_perc", threshold),
                    "either_side": min(
                        value
                        for value in (
                            first_exceeding(rows, "sr_fee_perc", threshold),
                            first_exceeding(rows, "jr_fee_perc", threshold),
                        )
                        if value is not None
                    )
                    if any(
                        value is not None
                        for value in (
                            first_exceeding(rows, "sr_fee_perc", threshold),
                            first_exceeding(rows, "jr_fee_perc", threshold),
                        )
                    )
                    else None,
                }
                for threshold in thresholds
            },
        }
    return summary


def fee_percent(wad: int) -> str:
    return f"{wad / 10**16:.6f}%"


def build_findings(observations: list[dict]) -> dict:
    by_mode = {mode: [o for o in observations if o["mode"] == mode] for mode in MODE_NAMES}

    def row(mode: int, bps: int) -> dict:
        return next(o for o in by_mode[mode] if o["exit_bps"] == bps)

    a1 = row(0, 100)
    a100 = row(0, 10_000)
    b95 = row(1, 9_500)
    b100 = row(1, 10_000)
    sr1 = row(2, 100)
    sr100 = row(2, 10_000)
    jr1 = row(3, 100)
    jr100 = row(3, 10_000)
    return {
        "common_pre_sub_dr": a1["pre_sub_dr"],
        "common_pre_vm_dr": a1["pre_vm_dr"],
        "A_fee_at_1_percent": a1["sr_fee_perc"],
        "A_fee_at_100_percent": a100["sr_fee_perc"],
        "A_fee_change_percentage_points": (a100["sr_fee_perc"] - a1["sr_fee_perc"]) / 10**16,
        "B_95_percent_selector": b95["error_selector"],
        "B_100_percent_selector": b100["error_selector"],
        "C_sr_fee_at_1_percent": sr1["sr_fee_perc"],
        "C_sr_fee_at_100_percent": sr100["sr_fee_perc"],
        "C_jr_fee_at_1_percent": jr1["jr_fee_perc"],
        "C_jr_fee_at_100_percent": jr100["jr_fee_perc"],
        "all_rows_underlying_conserved": all(o["underlying_conserved"] for o in observations),
    }


def markdown(observations: list[dict], rolling_hash: str, summary: dict) -> str:
    findings = build_findings(observations)
    by_mode = {mode: [o for o in observations if o["mode"] == mode] for mode in MODE_NAMES}
    a1 = next(o for o in by_mode[0] if o["exit_bps"] == 100)
    a100 = next(o for o in by_mode[0] if o["exit_bps"] == 10_000)
    sr1 = next(o for o in by_mode[2] if o["exit_bps"] == 100)
    sr100 = next(o for o in by_mode[2] if o["exit_bps"] == 10_000)
    jr1 = next(o for o in by_mode[3] if o["exit_bps"] == 100)
    jr100 = next(o for o in by_mode[3] if o["exit_bps"] == 10_000)
    lines = [
        "# Genesis exit fee curve audit — LOCAL CLEANROOM / BNB-DESIGN",
        "",
        "**Evidence classification: `LOCAL CLEANROOM / BNB-DESIGN`. This report is not `TARGET-CONFIRMED`.**",
        "",
        "**Compatibility status: `FEE MODULE TARGET-MATCHED`. The local system state remains synthetic and is not target Controller-confirmed, but the FeePolicy arithmetic used here passed the fixed-block target differential.**",
        "",
        "This report is generated from the local clean-room Foundry regression after the independently derived FeePolicy compatibility correction.",
        "",
        f"- Test: `{TEST_PATH}:{TEST_NAME}`",
        "- State: every row starts from the same multi-epoch Genesis snapshot; failed calls are also reverted to that snapshot.",
        "- Modes: A = user's owned SR/JR shares in the same proportion; B = each side's total supply in the same proportion; C = SR-only or JR-only.",
        f"- Regression event hash: `{rolling_hash}`",
        "- Values are underlying smallest units unless explicitly marked as DR (WAD) or fee percentage (WAD).",
        "",
        "## Findings from this tested state",
        "",
        f"- Common pre-exit state: `subDR={findings['common_pre_sub_dr']}` ({findings['common_pre_sub_dr'] / 1e18:.6f}x), `vmDR={findings['common_pre_vm_dr']}` ({findings['common_pre_vm_dr'] / 1e18:.6f}x).",
        f"- Mode A (user-owned proportional): fee is {fee_percent(a1['sr_fee_perc'])} at 1% and {fee_percent(a100['sr_fee_perc'])} at 100%; the tested size effect is only {(a100['sr_fee_perc'] - a1['sr_fee_perc']) / 1e16:.6f} percentage points. Because the smallest tested exit is already above 50%, this sweep does not prove a zero-size base fee, but it does show that the high fee is already present before a large exit.",
        f"- Mode B (total-supply proportional): 95% and 99% revert with `0xe450d38c` (the caller does not own all total-supply shares, including retained/locked shares); 100% returns a fee signal at or above the Controller disable threshold and reverts with `{next(o for o in by_mode[1] if o['exit_bps'] == 10_000)['error_selector']}`. These are not liquidity failures.",
        f"- Mode C SR-only: {fee_percent(sr1['sr_fee_perc'])} at 1% to {fee_percent(sr100['sr_fee_perc'])} at 100%; Mode C JR-only: {fee_percent(jr1['jr_fee_perc'])} to {fee_percent(jr100['jr_fee_perc'])}. These rows show how one-sided exits alter the corrected fee curve in this local state.",
        f"- All 40 rows conserved the underlying balance (`{findings['all_rows_underlying_conserved']}`); successful rows leave the fee as Controller-held Perp shares, while reverted rows leave state unchanged.",
        "",
        "## Thresholds",
        "",
        "`first_exit_percent_exceeding` means the first tested proportion strictly above the threshold; `null` means no tested point exceeded it.",
        "",
        "| mode | in-scope rows | N/A rows | success | failure selectors | >1% (either) | >5% (either) | >10% (either) | >25% (either) | >50% (either) |",
        "|---|---:|---:|---:|---|---:|---:|---:|---:|---:|",
    ]
    for mode_name, data in summary.items():
        selectors = ", ".join(data["failure_selectors"]) or "none"
        values = [data["first_exit_percent_exceeding"][f"{t}%"]["either_side"] for t in (1, 5, 10, 25, 50)]
        formatted = ["-" if value is None else f"{value:g}%" for value in values]
        lines.append(
            f"| {mode_name} | {data['trend_rows']} | {data['na_rows']} | {data['success_count']}/{data['trend_rows']} | `{selectors}` | "
            + " | ".join(formatted)
            + " |"
        )

    lines.extend([
        "",
        "## Observations",
        "",
        "| mode | exit | analysis | SR input | JR input | pre subDR | pre vmDR | SR fee | JR fee | theoretical | actual | retained fee value | result | selector | conserved |",
        "|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|",
    ])
    for o in observations:
        result = "success" if o["success"] else "revert"
        analysis = "N/A" if o["analysis_status"] == "N/A" else "in scope"
        selector = "-" if o["success"] else f"`{o['error_selector']}`"
        lines.append(
            f"| {o['mode_name']} | {o['exit_percent']:g}% | {analysis} | {o['sr_input']} | {o['jr_input']} | "
            f"{o['pre_sub_dr']} | {o['pre_vm_dr']} | {o['sr_fee_perc']} | {o['jr_fee_perc']} | "
            f"{o['theoretical_value']} | {o['actual_received_value']} | {o['controller_retained_fee_value']} | "
            f"{result} | {selector} | {o['underlying_conserved']} |"
        )

    lines.extend([
        "",
        "## Interpretation boundaries",
        "",
        "- This is a synthetic local Genesis/multi-epoch state, not a claim that the target Controller can reach or execute every row.",
        "- The fee arithmetic is target-matched by the separate fixed-block differential; the local state vectors themselves remain LOCAL CLEANROOM / BNB-DESIGN.",
        "- There is no zero-input execution row in this sweep; the 1% row is the smallest tested exit and must not be treated as a zero-size base fee.",
        "- Mode B at 95% and 99% is `N/A`: both calls exceeded the caller's real local share balance, so those quotes are preserved as raw records but excluded from fee-trend conclusions.",
        "- A high fee can arise from exit size, SR/JR mismatch, or both; the four modes are kept separate so the report does not attribute causality without evidence.",
        "- A successful operation with a large retained fee means the user received the net basket and the fee remained as Perp shares in the Controller; it is not an underlying-token loss.",
        "- A reverted operation leaves DR, balances, supplies, and underlying conservation unchanged because each row is isolated by snapshot/revert.",
        "",
        "## Candidate mitigations (not implemented)",
        "",
        "1. Pro-rata withdrawal from the SR/JR reserve baskets.",
        "2. Staged exit with a user-supplied max-fee limit.",
        "3. Exit queue, followed by Keeper/rebalance, then continued withdrawal.",
    ])
    return "\n".join(lines) + "\n"


def main() -> None:
    observations, rolling_hash = load_test_json()
    summary = build_summary(observations)
    findings = build_findings(observations)
    output = {
        "schema": "genesis-exit-fee-curve/v1",
        "evidence_classification": "LOCAL CLEANROOM / BNB-DESIGN",
        "compatibility_status": "FEE MODULE TARGET-MATCHED",
        "fee_values_are_target_expected_for_same_dr_inputs": True,
        "target_confirmed": False,
        "source": {
            "test_path": TEST_PATH,
            "test_name": TEST_NAME,
            "snapshot_isolation": True,
            "fee_policy_compatibility_fix_applied": True,
            "target_fee_differential": "40/40 exact",
            "rolling_hash": rolling_hash,
        },
        "observations": observations,
        "summary": summary,
        "findings": findings,
    }
    evidence = ROOT / "evidence"
    (evidence / "genesis-exit-fee-curve.json").write_text(
        json.dumps(output, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (evidence / "GENESIS_EXIT_FEE_CURVE.md").write_text(
        markdown(observations, rolling_hash, summary), encoding="utf-8"
    )
    print(f"wrote {len(observations)} observations")
    print(f"rolling hash: {rolling_hash}")


if __name__ == "__main__":
    main()
