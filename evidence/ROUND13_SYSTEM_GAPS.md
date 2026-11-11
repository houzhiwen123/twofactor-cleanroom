# Round 13 — backup selection, upkeep state machine, lazy boundary, and oracle configuration

## Scope and reproduction

All target calls used the local Base Anvil fork at `http://127.0.0.1:8545`, chain ID `8453`,
fork block `54,990,962`. The probe used public ABI calls and local Foundry state construction only.
No target source or frontend bundle was used, and no signed or real-chain transaction was sent.

```sh
BASE_RPC_URL=http://127.0.0.1:8545 \
FOUNDRY_TEST=evidence/round13-probes \
forge test --offline \
  --match-path evidence/round13-probes/Round13SystemGapProbe.t.sol --summary
```

Result: **8 passed, 0 failed, 0 skipped**. The compact raw observations are in
`evidence/round13_system_gap_results.log`.

## 1. Backup bond selection

Round 5 correctly refuted `argmin(abs(valueRatio - 0.5e18))`, but the target's public pure planner
allows a stronger discriminator. For every tested candidate ratio `r`, define:

```text
multiplier(r) = floor(1e36 / r)
score(r)      = abs(multiplier(r) - 2e18)
```

The target `computeBackupRolloverPolicy` selected the candidate with the smallest `score`. When
scores were equal after integer flooring, it retained the first candidate in the supplied fresh
array. This is a **derived black-box rule**, not a claim about target source structure.

Evidence:

- A `36`-pair grid, tested in both candidate orders, matched the rule `72/72`.
- For lower ratio `0.4`, the observed one-unit crossover was
  `0.666666666666666665 / 0.666666666666666666` in forward order and shifted one unit under the
  reversed tie order. The reciprocal-multiplier mirror is exactly `0.666666666666666666`.
- For lower ratio `0.45`, the crossover was `0.562499999999999999 / 0.5625`; the predicted mirror
  is `0.562499999999999999` after flooring.
- For lower ratio `0.390244`, the observed crossover surrounded
  `0.695651863894355551`, exactly the computed reciprocal mirror, with the one-unit tie behavior
  depending on candidate order.

This also explains the earlier near-tie: the comparison is made in reciprocal-multiplier space,
not by raw distance from `0.5`. Round 9 establishes that Controller calls this planner, and Round 5
already observed one actual backup execution matching its returned bond. A non-`0.5` selected bond
has not yet been exercised end-to-end through Controller, so that remains a regression-strengthening
task rather than a selection-rule blocker.

## 2. `upkeep()` four-state behavior

| Input state | Result | Durable state change |
|---|---|---|
| No maturity and no issuance due | Reverts `NoOp()` (`0x00219cf1`) | None; all attempted subcalls roll back |
| Issuance only | Success | Latest bond changes; SR/JR reserve rows each `3 -> 4`; no underlying movement |
| Maturity only | Success | Latest bond unchanged; mature rows removed and underlying returned to both Perps |
| Maturity and issuance together | Success | Latest bond changes; maturity settlement and new registration occur atomically |

Filtered call traces show the same coordinator skeleton in every state:

1. oracle `cachePrice()`;
2. SR `recover()`;
3. JR `recover()`;
4. issuer `issue()`;
5. SR and JR `registerTranche()` using the returned/current pair;
6. on success, oracle `resetCache()`; if neither recover nor issue did work, revert `NoOp()` before
   an explicit reset call, rolling the whole transaction back.

No `computePerpSrRolloverPlan`, `computeSystemRebalancePlan`, or `rebalance()` call appeared in any
of the four Round 13 traces. `lastRebalanceTimestampSec` remained `1,794,160,800` in every case.
The no-work probe recorded twelve internal trace logs before the final revert; these are rolled back
and must not be treated as committed events.

The maturity-only state used the public issuer timing setter on the local fork to separate maturity
from the next issuance window. This is a harness construction, not a claim that production cadence
normally has that separation.

## 3. Lazy SR flash-mint rollover boundary

Pinned vector: SR input `2,000,000`, pre-call stale SR value `41,875,890`.

| JR free liquidity | Result |
|---:|---|
| `3,999,999` | Reverts `InsufficientRollover()` (Round 10) |
| `4,000,000` through `4,000,003` | Flash mint succeeds, but stale value does not decrease |
| `4,000,004` | First one-unit stale reduction: `41,875,890 -> 41,875,889` |
| `8,423,503` | Partial completion (Round 10) |
| `8,423,504` | Full stale removal (Round 10) |

Round 13 therefore closes the missing no-progress/partial boundary to one unit. These values are
state- and amount-specific; they are regression vectors, not a universal constant formula.

## 4. Oracle configuration entries

The probe first changed keeper to a distinct local address so owner and keeper were not conflated.

| Entry | Random EOA | Distinct keeper | Owner | State effect |
|---|---|---|---|---|
| `setUnderlyingOracle()` | `OwnableUnauthorizedAccount` | same | success | Reads `BondsManager.oracleOf(cbBTC)` and writes that address to Controller |
| `resetUnderlyingOracle()` | `OwnableUnauthorizedAccount` | same | success | Sets Controller `underlyingOracle` to zero |

Neither successful entry emitted an event in the tested state. A selector-level local mock of
`oracleOf(cbBTC)` returning `0x...A11CE` caused `setUnderlyingOracle()` to store exactly that address,
which distinguishes registry lookup from retaining the previous value.

## 5. Size-constrained implementation order

Production code was intentionally unchanged in this round. The full offline suite remains
**70/70**, and runtime sizes remain:

| Contract | Runtime bytes | Project `24,000` margin |
|---|---:|---:|
| `PerpController` | `22,538` | `1,462` |
| `PerpBalancer` | `7,415` | `16,585` |
| `PerpToken` | `10,846` | `13,154` |

Recommended next implementation order:

1. Implement the derived backup selector inside `PerpBalancer`; this consumes Balancer headroom,
   not scarce Controller bytes.
2. Add `setUnderlyingOracle()` and `resetUnderlyingOracle()` as small owner-only Controller entries,
   with exact no-event behavior.
3. Add `upkeep()` by reusing existing `recover()` calls and `_issueAndRegister()`; change the helper
   to return whether a new bond was issued instead of duplicating issuance code.
4. Refactor the existing public rollover execution into one internal path before wiring lazy
   rollover from `flashMint2`; duplicating the current execution body would exceed the safe size
   budget quickly.
5. Run `forge build --sizes` and the `24,000`-byte guard after each individual change. If Controller
   approaches the guard, keep all pure selection/planning in `PerpBalancer`; do not introduce an
   executor role or `delegatecall` boundary.

## Remaining limits

- Backup selection is closed at the public planner boundary; one non-`0.5` end-to-end Controller
  execution should still be archived as a regression-strengthening case.
- Lazy results are exact only for the pinned state and `2,000,000` SR input.
- `upkeep()` was not observed calling rollover or rebalance in any tested state; the conclusion is
  limited to the fixed implementation and constructed states, not all possible historical versions.
