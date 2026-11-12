#!/usr/bin/env python3
"""Verify the independently derived exact FeePolicy model against all target rows."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WAD = 10**18
Point = tuple[int, int]
Curve = tuple[Point, Point, Point, Point]


DEFAULT = {
    "sub_up": (
        (0, 0),
        (1_078_564_994_000_000_000, 0),
        (1_105_439_994_000_000_000, 20_000_000_000_000_000),
        (2 * WAD, 50_000_000_000_000_000),
    ),
    "sub_down": (
        (0, 50_000_000_000_000_000),
        (1_003_564_994_000_000_000, 20_000_000_000_000_000),
        (1_028_564_994_000_000_000, 0),
        (2 * WAD, 0),
    ),
    "vm_up": ((0, 0), (WAD, 0), (1_025_000_000_000_000_000, 50_000_000_000_000_000), (1_076_250_000_000_000_000, WAD)),
    "vm_down": ((928_571_429_000_000_000, WAD), (975_000_000_000_000_000, 50_000_000_000_000_000), (WAD, 0), (2 * WAD, 0)),
}
ZERO: Curve = ((0, 0), (WAD, 0), (WAD + 100, 0), (2 * WAD, 0))
INC: Curve = ((0, 0), (WAD, 0), (WAD + 100, 100), (2 * WAD, 1_000))
DEC: Curve = ((0, 1_000), (WAD, 100), (WAD + 100, 0), (2 * WAD, 0))
RATIONAL_INC: Curve = ((0, 0), (WAD, 0), (WAD + 43, 32), (2 * WAD, 1_000))
RATIONAL_DEC: Curve = ((0, 1_000), (WAD, 4), (WAD + 5, 0), (2 * WAD, 0))


def translated_inc(origin: int, p1: int = 0, p4: int = 2 * WAD) -> Curve:
    return ((p1, 0), (origin, 0), (origin + 43, 32), (p4, 1_000))


def translated_dec(origin: int, p1: int = 0, p4: int = 2 * WAD) -> Curve:
    return ((p1, 1_000), (origin, 32), (origin + 43, 0), (p4, 0))


def translated_dec_4_5(origin: int) -> Curve:
    return ((0, 1_000), (origin, 4), (origin + 5, 0), (2 * WAD, 0))


def segment(points: Curve, left: int, right: int) -> tuple[Point, Point]:
    midpoint_twice = left + right
    for index in range(3):
        if midpoint_twice <= 2 * points[index + 1][0]:
            return points[index], points[index + 1]
    return points[2], points[3]


def segment_average(points: Curve, left: int, right: int) -> int:
    (x0, y0), (x1, y1) = segment(points, left, right)
    dx = x1 - x0
    if dx == 0:
        return y1
    if y1 >= y0:
        dy = y1 - y0
        return y0 + ((left + right) * dy) // (2 * dx) - (x0 * dy) // dx
    dy = y0 - y1
    return y0 + (x0 * dy) // dx - ((left + right) * dy) // (2 * dx)


def average(points: Curve, start: int, end: int) -> int:
    if start == end:
        return 0
    lo, hi = sorted((start, end))
    cuts = [lo, *(x for x, _ in points if lo < x < hi), hi]
    area = sum((right - left) * segment_average(points, left, right) for left, right in zip(cuts, cuts[1:]))
    return min(area // (hi - lo), WAD)


def semantic_curves(case_id: int) -> dict[str, Curve]:
    if case_id < 400:
        return DEFAULT
    if 400 <= case_id <= 417:
        return {"sub_up": INC, "sub_down": DEC, "vm_up": ZERO, "vm_down": ZERO}
    if 430 <= case_id <= 447:
        return {"sub_up": ZERO, "sub_down": ZERO, "vm_up": INC, "vm_down": DEC}
    if 450 <= case_id <= 455 or 456 <= case_id <= 461:
        return {"sub_up": RATIONAL_INC, "sub_down": RATIONAL_DEC, "vm_up": ZERO, "vm_down": ZERO}
    if 470 <= case_id <= 475:
        return {"sub_up": translated_inc(1_078_564_994_000_000_000), "sub_down": RATIONAL_DEC, "vm_up": ZERO, "vm_down": ZERO}
    if 476 <= case_id <= 481:
        return {"sub_up": translated_inc(WAD + 1), "sub_down": RATIONAL_DEC, "vm_up": ZERO, "vm_down": ZERO}
    raise ValueError(f"unknown semantic case {case_id}")


def base_fee(row: dict, side: str) -> int:
    if not 300 <= row["case_id"] <= 305:
        return 0
    if row["is_flash"]:
        return 34_567_890_123_456_789 if side == "SR" else 45_678_901_234_567_890
    return 12_345_678_901_234_567 if side == "SR" else 23_456_789_012_345_678


def verify_semantic_matrix() -> tuple[int, list[dict]]:
    doc = json.loads((ROOT / "evidence/fee-policy-semantics-matrix.before-fix.json").read_text())
    mismatches = []
    comparisons = 0
    for row in doc["observations"]:
        curves = semantic_curves(row["case_id"])
        sub_name = "sub_up" if row["sub_dr_post"] > row["sub_dr_pre"] else "sub_down"
        vm_name = "vm_up" if row["vm_dr_post"] > row["vm_dr_pre"] else "vm_down"
        impact = average(curves[sub_name], row["sub_dr_pre"], row["sub_dr_post"])
        impact += average(curves[vm_name], row["vm_dr_pre"], row["vm_dr_post"])
        for side in ("SR", "JR"):
            comparisons += 1
            predicted = base_fee(row, side) + impact
            actual = row["sides"][side]["target_total_fee"]
            protocol_max = 70_000_000_000_000_000 if row["evidence_class"].endswith("SYNTHETIC_CONFIG") else 0
            predicted_protocol = min(predicted, protocol_max)
            actual_protocol = row["sides"][side]["target_protocol_fee"]
            if predicted != actual or predicted_protocol != actual_protocol:
                mismatches.append(
                    {
                        "case_id": row["case_id"],
                        "side": side,
                        "predicted": predicted,
                        "actual": actual,
                        "predicted_protocol": predicted_protocol,
                        "actual_protocol": actual_protocol,
                    }
                )
    return comparisons, mismatches


def closure_curve(row: dict) -> Curve:
    group = row["group"]
    origin = row["origin"]
    if group in {0, 1, 2, 3, 10, 11}:
        p1 = origin - 101 if group == 10 else 0
        p4 = origin + 144 if group == 11 else 2 * WAD
        return translated_inc(origin, p1, p4)
    if group in {4, 5, 6, 7, 12, 13}:
        p1 = origin - 101 if group == 12 else 0
        p4 = origin + 144 if group == 13 else 2 * WAD
        return translated_dec(origin, p1, p4)
    if group in {8, 9}:
        return translated_dec_4_5(origin)
    raise ValueError(f"unknown closure group {group}")


def verify_closure_matrix() -> tuple[int, list[dict]]:
    doc = json.loads((ROOT / "evidence/target-fee-policy-rounding-closure.json").read_text())
    mismatches = []
    for row in doc["observations"]:
        predicted = average(closure_curve(row), row["start"], row["end"])
        actual = row["target_total_fee"]
        if predicted != actual:
            mismatches.append(
                {
                    "group": row["group_name"],
                    "origin_shift": row["origin_shift"],
                    "interval_offset": row["interval_offset"],
                    "predicted": predicted,
                    "actual": actual,
                }
            )
    return len(doc["observations"]), mismatches


def markdown(result: dict) -> str:
    return f"""# FeePolicy exact clean-room model

## Result

- Semantic-matrix side comparisons: `{result['semantic_comparisons']}`; mismatches: `{result['semantic_mismatches']}`.
- Rounding-closure observations: `{result['closure_observations']}`; mismatches: `{result['closure_mismatches']}`.
- Combined exact predictions: `{result['combined_matches']}/{result['combined_comparisons']}` with no tolerance.

## Derived arithmetic

For one linear segment from `(x0, y0)` to `(x1, y1)`, let `[left, right]` be the part of the operation interval inside that segment and `dx = x1 - x0`.

For a rising segment (`dy = y1 - y0`):

```text
segmentAverage = y0
               + floor((left + right) * dy / (2 * dx))
               - floor(x0 * dy / dx)
```

For a falling segment (`dy = y0 - y1`):

```text
segmentAverage = y0
               + floor(x0 * dy / dx)
               - floor((left + right) * dy / (2 * dx))
```

An interval crossing curve knots is split at every knot. Each segment average is multiplied by its width, the areas are summed, and the final sum is divided by the complete interval width with floor rounding. Equal pre/post DR contributes zero. Each DR component is capped independently at `1e18`; base and both components are then summed without a final total cap.

## Evidence boundary

This formula was independently derived from target outputs. It was not copied from verified source or inferred from target source code. The verifier consumes the previously archived target matrices and must report zero mismatches.

## Reproduce

```sh
python3 script/verify_fee_policy_exact_model.py
```
"""


def main() -> None:
    semantic_count, semantic_mismatches = verify_semantic_matrix()
    closure_count, closure_mismatches = verify_closure_matrix()
    result = {
        "schema": "fee-policy-exact-model-verification/v1",
        "semantic_comparisons": semantic_count,
        "semantic_mismatches": len(semantic_mismatches),
        "closure_observations": closure_count,
        "closure_mismatches": len(closure_mismatches),
        "combined_comparisons": semantic_count + closure_count,
        "combined_matches": semantic_count + closure_count - len(semantic_mismatches) - len(closure_mismatches),
        "mismatches": {"semantic": semantic_mismatches, "closure": closure_mismatches},
    }
    if semantic_mismatches or closure_mismatches:
        raise SystemExit(json.dumps(result, indent=2))
    (ROOT / "evidence/fee-policy-exact-model-verification.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n"
    )
    (ROOT / "evidence/FEE_POLICY_EXACT_MODEL.md").write_text(markdown(result))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
