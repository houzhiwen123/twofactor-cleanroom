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

    print("UnderlyingPerpVault phase-1 storage layout matches the frozen baseline.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
