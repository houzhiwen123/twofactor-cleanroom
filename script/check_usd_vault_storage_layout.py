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
    ("_sessionBudgetUsdVal", "4", 0, "uint128"),
    ("_sessionOpenedAtSec", "4", 16, "uint64"),
    ("_sessionIsMintingPerp", "4", 24, "bool"),
    ("_rebalanceFreqSec", "4", 25, "uint32"),
    ("_rebalanceOffsetSec", "5", 0, "uint32"),
    ("_maxDeploymentVelocityPerc", "5", 4, "uint64"),
    ("_targetDR", "5", 12, "uint96"),
    ("_minOpUsdVal", "6", 0, "uint128"),
    ("_eqDRLower", "6", 16, "uint96"),
    ("_activeRebalanceDelaySec", "6", 28, "uint32"),
    ("_eqDRUpper", "7", 0, "uint96"),
    ("_dexStrategy", "7", 12, "address"),
    ("_usdOracle", "8", 0, "address"),
    ("_isSwapper", "9", 0, "mapping(address => bool)"),
    ("_maxUsdDeviationPerc", "10", 0, "uint64"),
    ("_maxUnderlyingDeviationPerc", "10", 8, "uint64"),
    ("_maxFlashMintFeePerc", "10", 16, "uint64"),
    ("_maxFlashRedeemFeePerc", "10", 24, "uint64"),
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

    print("UsdVault storage layout preserves slots 0-7 and appends phase-5B execution dependencies and guard limits.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
