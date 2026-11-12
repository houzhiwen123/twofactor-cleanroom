# FeePolicy compatibility pre-fix baseline

Frozen before changing `src/policy/FeePolicy.sol` for the target compatibility correction.

- Repository HEAD: `716c94c7a4f82e3b80835713f3e3e9a1382fdcd9`
- Offline suite: `113 passed; 0 failed; 0 skipped`
- Target differential at Base block `54,990,962`: `0 MATCH / 40 MISMATCH`
- Pre-fix differential JSON SHA-256: `7e6f52b7134c5a9c9fea7187248151d01efc3addc9680fe0fd490ccc7fd44fa3`
- Local exit-curve JSON SHA-256: `78706e0a7379c7e2db5fae5e3d4e0c129f5fd977098400ba2068226c9decc1f7`
- `FeePolicy` runtime: `8,725 bytes`
- `PerpController` runtime: `22,475 bytes`
- Runtime guard: passed (`PerpController <= 22,500`; other production contracts `<= 24,000`)
- Controller storage guard: passed; frozen slots `0-17` unchanged
- `forge fmt --check`: passed
- `git diff --check`: passed

Archived pre-fix artifacts:

- `evidence/TARGET_EXIT_FEE_DIFFERENTIAL_BEFORE_FIX.md`
- `evidence/target-exit-fee-differential.before-fix.json`

The worktree already contained the local Genesis exit-curve test, its reports, and exporters. They are preserved and are part of this focused compatibility work; no unrelated tracked file was overwritten.
