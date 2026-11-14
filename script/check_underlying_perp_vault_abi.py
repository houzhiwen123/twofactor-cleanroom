import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "out" / "UnderlyingPerpVault.sol" / "UnderlyingPerpVault.json"
FREEZE = ROOT / "evidence" / "underlying-perp-vault-abi-freeze.json"


def canonical_abi(abi: list[dict[str, object]]) -> str:
    """Ignore only top-level artifact ordering; preserve all ABI field and tuple ordering."""
    entries = sorted(
        abi,
        key=lambda entry: json.dumps(entry, sort_keys=True, separators=(",", ":")),
    )
    return json.dumps(entries, sort_keys=True, separators=(",", ":"))


def main() -> int:
    try:
        artifact = json.loads(ARTIFACT.read_text())
        frozen = json.loads(FREEZE.read_text())
        abi = artifact["abi"]
    except (OSError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(f"Could not read UnderlyingPerpVault ABI freeze inputs: {error}", file=sys.stderr)
        return 1

    if not isinstance(abi, list):
        print("UnderlyingPerpVault artifact ABI is not a list.", file=sys.stderr)
        return 1

    actual_count = len(abi)
    actual_hash = hashlib.sha256(canonical_abi(abi).encode()).hexdigest()
    expected_count = frozen.get("abiEntryCount")
    expected_hash = frozen.get("canonicalSha256")

    if actual_count != expected_count or actual_hash != expected_hash:
        print("UnderlyingPerpVault ABI changed.", file=sys.stderr)
        print(f"Expected entries/hash: {expected_count} / {expected_hash}", file=sys.stderr)
        print(f"Actual entries/hash:   {actual_count} / {actual_hash}", file=sys.stderr)
        return 1

    print(
        "UnderlyingPerpVault complete ABI matches the Phase 3 frozen baseline "
        f"({actual_count} entries, sha256 {actual_hash})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
