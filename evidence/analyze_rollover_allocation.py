#!/usr/bin/env python3

import json
import re
from pathlib import Path

WAD = 10**18
ROOT = Path(__file__).resolve().parent
LOGS = (
    ROOT / "rollover_direct_functions.log",
    ROOT / "rollover_allocation_cases.log",
)


def observations(path):
    for line in path.read_text().splitlines():
        match = re.search(r"OBS:(\{.*\})", line)
        if not match:
            continue
        try:
            item = json.loads(match.group(1))
        except json.JSONDecodeError:
            continue
        if item.get("kind") == "balancer_case":
            yield item


def ceil_div(numerator, denominator):
    if denominator == 0:
        raise ZeroDivisionError("cannot invert a zero valueRatio")
    return (numerator + denominator - 1) // denominator


def predict(item, average_target):
    state = item["calls"]["computePerpSrRolloverState_SR"]["decoded"]
    fresh = state["freshSrTrs"]
    stale_value = state["totalStaleVal"]
    if not fresh:
        return {}, 0

    non_latest = fresh[:-1]
    if average_target:
        values = [row[3] for row in fresh]
        average = ceil_div(sum(values) + stale_value, len(fresh))
        target = max(max((row[3] for row in non_latest), default=0), average)
    else:
        target = max((row[3] for row in non_latest), default=0)

    topups = {row[0]: 0 for row in fresh}
    remaining = stale_value
    for row in non_latest:
        topup = min(max(target - row[3], 0), remaining)
        topups[row[0]] = topup
        remaining -= topup
    topups[fresh[-1][0]] = remaining

    deposits = {}
    for row in fresh:
        topup = topups[row[0]]
        deposits[row[0]] = ceil_div(topup * WAD, row[11]) if topup else 0
    return deposits, target


def format_deposits(deposits):
    return ",".join(
        f"{bond_id[-6:]}:{amount}"
        for bond_id, amount in deposits.items()
        if amount
    ) or "-"


def main():
    cases = []
    for log in LOGS:
        cases.extend(observations(log))

    seen = set()
    unique_cases = []
    for item in cases:
        label = item["label"]
        if label in seen:
            continue
        seen.add(label)
        unique_cases.append(item)

    basic_matches = 0
    corrected_matches = 0
    for item in unique_cases:
        label = item["label"]
        standard = item["calls"]["computeRolloverPolicy_combined"]["decoded"]
        actual = {
            entry["bondID"]: entry["underlyingAmt"]
            for entry in standard["execution"]["freshBondDepositAmts"]
        }
        basic, _ = predict(item, average_target=False)
        corrected, target = predict(item, average_target=True)
        basic_ok = basic == actual
        corrected_ok = corrected == actual
        basic_matches += basic_ok
        corrected_matches += corrected_ok
        print(
            f"{label}\tH={'MATCH' if basic_ok else 'MISMATCH'}"
            f"\tcorrected={'MATCH' if corrected_ok else 'MISMATCH'}"
            f"\ttarget={target}"
            f"\tobserved={format_deposits(actual)}"
        )
        if not basic_ok or not corrected_ok:
            print(
                f"  predicted H={format_deposits(basic)}"
                f" corrected={format_deposits(corrected)}"
            )

    count = len(unique_cases)
    print(
        f"SUMMARY cases={count} H={basic_matches}/{count}"
        f" corrected={corrected_matches}/{count}"
    )


if __name__ == "__main__":
    main()
