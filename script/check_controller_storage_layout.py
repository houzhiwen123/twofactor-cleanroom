import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "out" / "PerpController.sol" / "PerpController.json"

EXPECTED_STORAGE = [
    ("underlying", "0", 0, "address"),
    ("perpSr", "1", 0, "address"),
    ("perpJr", "2", 0, "address"),
    ("feePolicy", "3", 0, "address"),
    ("balancer", "4", 0, "address"),
    ("issuer", "5", 0, "address"),
    ("keeper", "6", 0, "address"),
    ("underlyingOracle", "7", 0, "address"),
    ("targetSystemRatio", "8", 0, "uint256"),
    ("targetPerpJrVM", "9", 0, "uint256"),
    ("valueCap", "10", 0, "uint256"),
    ("minCleanupVal", "11", 0, "uint256"),
    ("perpJrReservedUnderlyingAmt", "12", 0, "uint256"),
    ("perpJrReservedUnderlyingPerc", "13", 0, "uint64"),
    ("minMaturitySec", "13", 8, "uint32"),
    ("rebalanceFreqSec", "13", 12, "uint32"),
    ("rebalanceWindowOffsetSec", "13", 16, "uint32"),
    ("rebalanceWindowLengthSec", "13", 20, "uint32"),
    ("lastRebalanceTimestampSec", "13", 24, "uint64"),
    ("userOpsPaused", "14", 0, "bool"),
    ("systemOpsPaused", "14", 1, "bool"),
    ("collectedFeeBal", "15", 0, "mapping(address => uint256)"),
    ("protocolFeeBals", "16", 0, "mapping(address => uint256)"),
    ("_latestBondInfo", "17", 0, "struct PerpController.BondInfo"),
]

EXPECTED_BOND_INFO = [
    ("manager", "0", 0, "address"),
    ("bondID", "1", 0, "bytes32"),
    ("srTranche", "2", 0, "address"),
    ("jrTranche", "3", 0, "address"),
]


def normalized_rows(entries: list[dict], types: dict) -> list[tuple[str, str, int, str]]:
    rows = []
    for entry in entries:
        type_id = entry["type"]
        rows.append(
            (
                entry["label"],
                entry["slot"],
                entry["offset"],
                types[type_id]["label"],
            )
        )
    return rows


def main() -> int:
    try:
        artifact = json.loads(ARTIFACT.read_text())
        layout = artifact["storageLayout"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"Could not read Controller storage layout from {ARTIFACT}: {error}", file=sys.stderr)
        return 1

    types = layout["types"]
    actual_storage = normalized_rows(layout["storage"], types)
    if actual_storage != EXPECTED_STORAGE:
        print("PerpController storage layout changed.", file=sys.stderr)
        print(f"Expected: {EXPECTED_STORAGE}", file=sys.stderr)
        print(f"Actual:   {actual_storage}", file=sys.stderr)
        return 1

    bond_info_type = next(
        entry["type"] for entry in layout["storage"] if entry["label"] == "_latestBondInfo"
    )
    actual_bond_info = normalized_rows(types[bond_info_type]["members"], types)
    if actual_bond_info != EXPECTED_BOND_INFO:
        print("PerpController.BondInfo storage layout changed.", file=sys.stderr)
        print(f"Expected: {EXPECTED_BOND_INFO}", file=sys.stderr)
        print(f"Actual:   {actual_bond_info}", file=sys.stderr)
        return 1

    print("PerpController storage layout matches the frozen 84/84 baseline.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
