# FeePolicy compatibility status — evidence-stage stop

## Outcome

The original `TARGET_EXIT_FEE_DIFFERENTIAL` result is formally classified as a clean-room
`FeePolicy` compatibility bug. The production contract has **not** been changed because the
black-box matrix does not yet identify one unique exact arithmetic rule for every 1-wei input.

This is the required evidence-stage stop: changing `FeePolicy` now would replace a demonstrated
bug with an unverified rounding guess.

## Fixed evidence

- Base chain ID: `8453`.
- Fixed block: `54,990,962`.
- Target FeePolicy proxy: `0x1e3dbdc2adf4d5fdd1efdfb9ff05e4154d0c00e8`.
- Target FeePolicy implementation: `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900`.
- Original exit differential: `0/40` exact matches.
- Semantic matrix: `136` cases, `272` SR/JR comparisons, `184` exact matches and `88`
  mismatches against the unmodified clean-room implementation.

Rows classified `FIXED_TARGET_PROXY` call the deployed target proxy at the fixed public block.
Rows classified `TARGET_IMPL_FRESH_LOCAL_PROXY_SYNTHETIC_CONFIG` call a newly deployed local proxy
backed by the same code-locked implementation. They do not mutate the deployed proxy. No verified
source, wallet, key, signature, broadcast, `deal`, or `store` is used.

## Confirmed target semantics

| Rule | Discriminating evidence | Level |
|---|---|---|
| An unchanged DR contributes zero curve impact, below, at, or above `1e18` | cases `1`–`6`, `300`, `301` | target deployed proxy plus synthetic config |
| Up/down selection follows the actual direction when the DR changes | cases `10`–`21`, `200`–`203` | target deployed proxy |
| `subDR` and `vmDR` impact components are each capped independently at `1e18` | cases `204`–`206` | target deployed proxy |
| There is no final `1e18` cap on total fee | case `204` returns `2e18`; cases `206`, `303`, `304` exceed `1e18` | target deployed proxy plus synthetic config |
| Base fee is added after impact components | cases `300`–`305` | synthetic config |
| Protocol fee is independently capped by `protocolMaxOpFeePerc` | cases `300`–`305` | synthetic config |
| The same configured curve produces the same result in the subDR and vmDR fields | cases `400`–`447` | synthetic config |

These rules are sufficient to reject the current clean-room semantics, but not sufficient to
implement the target arithmetic exactly.

## Exact blocker

The same local `32/43` rising segment was translated horizontally while preserving its local
shape and interval inputs:

| case | segment origin | interval | TARGET | current clean-room |
|---:|---:|---:|---:|---:|
| `450` | `1e18` | origin to origin + 1 | `1` | `0` |
| `470` | `1.078564994e18` | origin to origin + 1 | `0` | `0` |
| `476` | `1e18 + 1` | origin to origin + 1 | `1` | `0` |

A floor, ceiling, nearest-integer, or exact-rational rule that depends only on the local slope and
local offsets cannot explain all three observations. The target's 1-wei result depends on an
absolute coordinate or another curve-wide arithmetic intermediate. Multiple candidate algorithms
remain compatible with the existing rows.

## Missing discriminating vectors

Before a production change is authorized, the next evidence round must add:

1. The identical `32/43` segment translated across a complete `0..42` residue grid, with the
   surrounding curve points held constant.
2. Every adjacent one-wei interval across the 43-unit short segment for each discriminating
   translation, not only the first and last interval.
3. A control that keeps `p2`/`p3` identical while independently changing `p1` and `p4`, to determine
   whether curve-wide points enter the arithmetic.
4. Horizontally translated decreasing curves, including both the existing `4/5` short segment and
   a decreasing `32/43` mirror.
5. Cross-knot intervals for the translated curves after one candidate model predicts all
   single-segment rows.

Only one arithmetic model that predicts every row exactly may be implemented. The completed
matrix must then be rerun against both the target and clean-room policies.

## Before/after status

| Check | Before | Current evidence-stage result |
|---|---:|---:|
| Original 40-vector exact match | `0/40` | production unchanged; still `0/40` |
| First vector TARGET / clean-room | `24668775771025119` / `737786924881158484` | unchanged |
| Extreme B-100 TARGET / clean-room | `2e18` / `1e18` | target semantics confirmed; fix pending |
| Production `FeePolicy` | incompatible | intentionally unchanged |

The 73%–74% values in `GENESIS_EXIT_FEE_CURVE.md` are retained only as `PRE-FIX LOCAL BUG`
regression evidence. They are not target expected values.

## Deferred acceptance items

- A minimal production `FeePolicy` patch.
- `40/40` original differential and full new-matrix equality.
- The target Controller's user-visible behavior and exact revert selector when the target policy
  returns `2e18`.
- Real-holder Vault, Controller, and Router exit replay.

The Controller/real-holder items remain deferred because this phase was explicitly limited to fee
calculation until exact differential equality is reached.

## Verification at the evidence-stage stop

- Offline Foundry suite: `113 passed; 0 failed; 0 skipped`.
- `FeePolicy` runtime: `8,725 bytes` (unchanged).
- `PerpController` runtime: `22,475 bytes`, below the project `22,500`-byte guard.
- Controller frozen storage layout: unchanged from the 84/84 baseline.
- Runtime-size guard: passed.
- `forge fmt --check`: passed.
- `git diff --check`: passed.
