import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "out" / "UsdVault.sol" / "UsdVault.json"

EXPECTED_STORAGE = [
    ("_usdToken", "0", 0, "contract IERC20"),
    ("_perpSrToken", "1", 0, "contract IERC20"),
    ("_underlyingToken", "2", 0, "contract IERC20"),
    ("_perpController", "3", 0, "address"),
]


def main() -> int:
    try:
        artifact = json.loads(ARTIFACT.read_text())
        layout = artifact["storageLayout"]
    except (OSError, json.JSONDecodeError, KeyError) as error:
        print(f"Could not read USD Vault storage layout from {ARTIFACT}: {error}", file=sys.stderr)
        return 1

    types = layout["types"]
    actual = [
        (entry["label"], entry["slot"], entry["offset"], types[entry["type"]]["label"])
        for entry in layout["storage"]
    ]
    if actual != EXPECTED_STORAGE:
        print("UsdVault storage layout changed.", file=sys.stderr)
        print(f"Expected: {EXPECTED_STORAGE}", file=sys.stderr)
        print(f"Actual:   {actual}", file=sys.stderr)
        return 1

    print("UsdVault storage layout preserves the frozen phase-1 slots and appends phase-2 state.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
