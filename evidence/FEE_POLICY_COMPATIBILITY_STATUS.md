# FeePolicy compatibility status — accepted

## Outcome

The clean-room `FeePolicy` compatibility error is fixed. The independently derived arithmetic
matches every archived target observation exactly; no tolerance is used. This accepts the fee
module only. It does not claim that the local Genesis state is a target Controller state or that
every synthetic exit vector is executable against the deployed target.

## Fixed evidence

- Base chain ID: `8453`; fixed block: `54,990,962`.
- Target FeePolicy proxy: `0x1e3dbdc2adf4d5fdd1efdfb9ff05e4154d0c00e8`.
- Target FeePolicy implementation: `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900`.
- Original exit differential: `0/40` before the fix, `40/40` after it.
- Semantic matrix: `184/272` before the fix, `272/272` after it.
- Rounding-closure matrix: `4,158/4,158` exact predictions.
- Combined independent exact-model verification: `4,430/4,430`.

Rows classified `FIXED_TARGET_PROXY` call the deployed target proxy at the fixed public block.
Rows classified `TARGET_IMPL_FRESH_LOCAL_PROXY_SYNTHETIC_CONFIG` call a newly deployed local
proxy backed by the code-locked target implementation. They do not mutate the deployed target
proxy. No verified source, wallet, key, signature, broadcast, `deal`, or `store` is used.

## Accepted semantics

| Rule | Result |
|---|---|
| Unchanged DR | contributes zero impact |
| Direction | selects the curve from the actual pre/post direction |
| Per-component cap | subDR and vmDR impacts are each capped at `1e18` |
| Final cap | none; base plus both components may exceed `1e18` |
| Protocol fee | independently `min(totalFee, protocolMaxOpFeePerc)` |
| Segment arithmetic | absolute-coordinate segment average described in `FEE_POLICY_EXACT_MODEL.md` |
| Cross-knot arithmetic | width-weighted segment areas, then one final floor division |

The 32/43 residue grid, decreasing mirrors, surrounding-point controls, adjacent intervals and
cross-knot vectors close the earlier rounding ambiguity. The exact model predicts all 4,430
target comparisons.

## Controller disable signal

- The target FeePolicy returns `2e18` for the archived extreme vector.
- Prior target Controller fork evidence records a within-liquidity input-side fee of
  `1001851303674000670 >= 1e18` reverting `OpDisabled()` (`0x07380a2e`) in
  `CODEX_REVIEW_PROBES.md` H5.
- The corrected clean-room FeePolicy returns `2e18` for the same extreme DR tuple, and the local
  Controller regression rejects it with the same `OpDisabled()` selector.

This proves the target Controller's observed `>=1e18` disable boundary and the clean-room behavior
at exactly `2e18`. An exact deployed-target Controller transaction whose natural state itself
produces exactly `2e18` was not manufactured, because the evidence rules forbid target storage or
balance mutation. That narrower point remains an evidence-boundary note, not a production blocker.

## Before/after

| Check | Before | After |
|---|---:|---:|
| Original 40-vector exact match | `0/40` | `40/40` |
| First vector TARGET / clean-room | `24668775771025119` / `737786924881158484` | `24668775771025119` / `24668775771025119` |
| Extreme B-100 TARGET / clean-room | `2e18` / `1e18` | `2e18` / `2e18` |
| Semantic comparisons | `184/272` | `272/272` |
| Exact-model comparisons | unresolved | `4430/4430` |

The old 73%–74% local Genesis outputs were a local arithmetic bug, not target behavior. The
regenerated local report now uses the corrected fee module while keeping its state classification
as `LOCAL CLEANROOM / BNB-DESIGN`.

## Verification

- Offline Foundry suite: `115 passed; 0 failed; 0 skipped`.
- Fixed-block target probe suites: `4 passed; 0 failed`.
- `FeePolicy` runtime: `8,665 bytes` (before-fix baseline `8,725`).
- `PerpController` runtime: `22,475 bytes`, below the project `22,500`-byte guard.
- Controller frozen storage layout: unchanged from the 84/84 baseline.
- Runtime-size guard, `forge fmt --check`, and `git diff --check`: passed.

## Deferred work

Real-holder Vault, Controller and Router exit replay remains a separate later phase. No max-fee,
queue, staged-exit or curve redesign was implemented in this compatibility fix.
