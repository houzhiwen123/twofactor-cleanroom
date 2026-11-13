import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT / "src"
OUT_ROOT = ROOT / "out"
MAX_RUNTIME_BYTES = 24_000
CONTROLLER_MAX_RUNTIME_BYTES = 22_500
UNDERLYING_PERP_VAULT_MAX_RUNTIME_BYTES = 18_000


def main() -> int:
    source_files = {
        path.relative_to(ROOT).as_posix()
        for path in SOURCE_ROOT.rglob("*.sol")
    }
    if not source_files:
        print("No Solidity source files found under src/", file=sys.stderr)
        return 1

    found_sources: set[str] = set()
    oversized: list[tuple[str, str, int, int]] = []

    for artifact_path in sorted(OUT_ROOT.rglob("*.json")):
        try:
            artifact = json.loads(artifact_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            print(f"Could not read {artifact_path}: {error}", file=sys.stderr)
            return 1

        metadata = artifact.get("metadata")
        if not isinstance(metadata, dict):
            continue
        compilation_target = metadata.get("settings", {}).get("compilationTarget", {})
        if not isinstance(compilation_target, dict):
            continue
        for source_name, contract_name in compilation_target.items():
            if source_name not in source_files:
                continue
            found_sources.add(source_name)
            deployed_bytecode = artifact.get("deployedBytecode", {})
            if isinstance(deployed_bytecode, dict):
                code = deployed_bytecode.get("object", "") or ""
            elif isinstance(deployed_bytecode, str):
                code = deployed_bytecode
            else:
                code = ""
            code = code.removeprefix("0x")
            if len(code) % 2:
                print(
                    f"Invalid deployed bytecode length for {source_name}:{contract_name}",
                    file=sys.stderr,
                )
                return 1
            size = len(code) // 2
            print(f"{source_name}:{contract_name}: {size} runtime bytes")
            if source_name == "src/controller/PerpController.sol" and contract_name == "PerpController":
                limit = CONTROLLER_MAX_RUNTIME_BYTES
            elif source_name == "src/vault/UnderlyingPerpVault.sol" and contract_name == "UnderlyingPerpVault":
                limit = UNDERLYING_PERP_VAULT_MAX_RUNTIME_BYTES
            else:
                limit = MAX_RUNTIME_BYTES
            if size > limit:
                oversized.append((source_name, contract_name, size, limit))

    missing_sources = sorted(source_files - found_sources)
    if missing_sources:
        print(
            "Missing compiled artifacts for src files: " + ", ".join(missing_sources),
            file=sys.stderr,
        )
        return 1

    if oversized:
        for source_name, contract_name, size, limit in oversized:
            print(
                f"Runtime size exceeds {limit} bytes: "
                f"{source_name}:{contract_name} is {size} bytes",
                file=sys.stderr,
            )
        return 1

    print(
        f"PerpController is at most {CONTROLLER_MAX_RUNTIME_BYTES} bytes; "
        f"UnderlyingPerpVault is at most {UNDERLYING_PERP_VAULT_MAX_RUNTIME_BYTES} bytes; "
        f"all other src contract runtimes are at most {MAX_RUNTIME_BYTES} bytes."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
