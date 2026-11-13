import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "out" / "UnderlyingPerpVault.sol" / "UnderlyingPerpVault.json"

EXPECTED_STORAGE = [
    ("underlying", "0", 0, "address"),
    ("perp", "1", 0, "address"),
    ("perpController", "2", 0, "address"),
    ("keeper", "3", 0, "address"),
    ("underlyingUnitAmt", "3", 20, "uint96"),
    ("isPerpSrVault", "4", 0, "bool"),
    ("mintsAboveTarget", "4", 1, "bool"),
    ("_vaultInitialized", "4", 2, "bool"),
    ("_phase2", "5", 0, "struct UnderlyingPerpVault.Phase2Storage"),
]

EXPECTED_PHASE2_MEMBERS = [
    ("targetDR", "0", 0, "uint96"),
    ("rebalanceFreqSec", "0", 12, "uint32"),
    ("rebalanceOffsetSec", "0", 16, "uint32"),
    ("lastRebalanceTimestampSec", "0", 20, "uint64"),
    ("eqDRLower", "1", 0, "uint96"),
    ("eqDRUpper", "1", 12, "uint96"),
    ("maxFlashFeePerc", "1", 24, "uint64"),
    ("minRebalanceVal", "2", 0, "uint128"),
]


def main() -> int:
    try:
        artifact = json.loads(ARTIFACT.read_text())
        layout = artifact["storageLayout"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"Could not read UnderlyingPerpVault storage layout from {ARTIFACT}: {error}", file=sys.stderr)
        return 1

    types = layout["types"]
    actual = [
        (entry["label"], entry["slot"], entry["offset"], types[entry["type"]]["label"])
        for entry in layout["storage"]
    ]
    if actual != EXPECTED_STORAGE:
        print("UnderlyingPerpVault storage layout changed.", file=sys.stderr)
        print(f"Expected: {EXPECTED_STORAGE}", file=sys.stderr)
        print(f"Actual:   {actual}", file=sys.stderr)
        return 1

    phase2_entry = next(entry for entry in layout["storage"] if entry["label"] == "_phase2")
    phase2_type = types[phase2_entry["type"]]
    phase2_members = [
        (entry["label"], entry["slot"], entry["offset"], types[entry["type"]]["label"])
        for entry in phase2_type["members"]
    ]
    if phase2_type.get("numberOfBytes") != "96" or phase2_members != EXPECTED_PHASE2_MEMBERS:
        print("UnderlyingPerpVault phase-2 append layout changed.", file=sys.stderr)
        print(f"Expected: {EXPECTED_PHASE2_MEMBERS}", file=sys.stderr)
        print(f"Actual:   {phase2_members}", file=sys.stderr)
        return 1

    print("UnderlyingPerpVault phase-1 prefix and phase-2 slot 5-7 append layout match the frozen baseline.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
