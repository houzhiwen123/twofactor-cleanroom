# Round 10 fork probes

Probe-only observations from a local Base Anvil fork. No target source or
frontend bundle, wallet key, or non-local transaction was used. No files under
`src/` or `test/` were changed.

## Version lock

| Item | Value |
|---|---|
| Chain / pinned block | `8453` / `54990962` |
| Pinned block hash | `0x1dff8df5543b16d844a672968579d9d341675728a9a3f3203f1e05bee332bc67` |
| Local fork RPC | `http://127.0.0.1:8547` (local Anvil, forked from the pinned Base block) |
| Controller proxy / implementation / implementation codehash | `0x682F3a053B0260daD4EbEee3924B1618B330A200` / `0x16e324bae2098317477129a5e71f770bff51f02a` / `0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31` |
| PerpBalancer / codehash | `0x30333a6B8744a1203D060E108dDC8C155059aCbf` / `0x540e400d7517059a0d44fe7ed777c00c5b667c5a118cb98b322f24e713dbb1f8` |
| BondIssuer proxy / implementation / implementation codehash | `0xc56CCbF6219B780c879544FEe0404bD3B49fEBB0` / `0xe024bd4967185456df3de7d2365919b5fb89763b` / `0x2a5e0beeb8cdfd88b98395e5e11dccdb915a7be3f8e5e9502819aaa67864cbe8` |
| BondsManager proxy / implementation / implementation codehash | `0xe8c13955caED9c009fd2b335A10986407958fde3` / `0x427758ed7ba97d3602125f957cd9e6716fddaac2` / `0xb2318665f51d6ea433c3f7ac358765d48a4dace3da3e708bdaa94f54ef6a16c6` |
| PerpSR proxy / implementation / implementation codehash | `0x4be28E7597A928835245a10E9161E0c44687b70b` / `0x96fc14b136300f9136c0d589ed7a787b66571574` / `0x1d57fb7d55c334bb60b1a6cf666790a5e3e95d24ea6044a1a70a5e5762ce1a53` |
| PerpJR proxy / implementation / implementation codehash | `0x8cd04668292dC32F519972495C179E4f02C0e8AB` / `0x8e9ed1138060434e56a5f7965017391c93631529` / `0xa34e6fcb0bf4e6b4ad9978a870df69fd9adb607f572e2cfad291c12c093d0ebb` |
| cbBTC / price feed / sequencer feed | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` / `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` / `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` |

The complete proxy and implementation codehash table is also archived in
`reviewer_fork_versions.log`. The keeper and owner at this pinned block are
both the Safe `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`.

## Reproduce

Reuse the local Anvil fork on port `8547`, whose chain ID is `8453`; the test
selects pinned block `54990962` from it. From the repository root:

```sh
FOUNDRY_SRC=evidence/round10-empty-src \
FOUNDRY_TEST=evidence/probe-tests/Round10Probe.t.sol \
BASE_RPC_URL=http://127.0.0.1:8547 \
forge test --via-ir --optimizer-runs 1 \
  --match-path Round10Probe.t.sol -vv

FOUNDRY_SRC=evidence/round10-empty-src \
FOUNDRY_TEST=evidence/probe-tests/Round10Probe.t.sol \
BASE_RPC_URL=http://127.0.0.1:8547 \
forge test --via-ir --optimizer-runs 1 \
  --match-path Round10Probe.t.sol \
  --match-test testDPublicRolloverTraceAtHighLiquidity -vvvvv

FOUNDRY_SRC=evidence/round10-empty-src \
FOUNDRY_TEST=evidence/probe-tests/Round10Probe.t.sol \
BASE_RPC_URL=http://127.0.0.1:8547 \
forge test --via-ir --optimizer-runs 1 \
  --match-path Round10Probe.t.sol \
  --match-test testDLazyFlashMint2TraceAtHighLiquidity -vvvvv

FOUNDRY_SRC=evidence/round10-empty-src \
FOUNDRY_TEST=evidence/probe-tests/Round10Probe.t.sol \
BASE_RPC_URL=http://127.0.0.1:8547 \
forge test --via-ir --optimizer-runs 1 \
  --match-path Round10Probe.t.sol \
  --match-test testBMaturedBeforeNextIssueWindow -vvvvv

FOUNDRY_SRC=evidence/round10-empty-src \
FOUNDRY_TEST=evidence/probe-tests/Round10Probe.t.sol \
BASE_RPC_URL=http://127.0.0.1:8547 \
forge test --via-ir --optimizer-runs 1 \
  --match-path Round10Probe.t.sol \
  --match-test testDUpkeepAtMaturityBeforeIssueDue -vvvvv
```

For all Round 10 `vm.mockCall` oracle overrides, the price feed has
`decimals() = 8`, the sequencer feed has `decimals() = 0`, and only
`latestRoundData()` is mocked. At a test timestamp `t`, the price tuple is
`(pinnedRoundId, answer, t, t, pinnedAnsweredInRound)` and the sequencer tuple
is `(pinnedRoundId, 0, t-3601, t, pinnedAnsweredInRound)`. The mock does not
replace runtime code; the pinned feed addresses and unmodified codehashes are
listed above and detailed in `ROUND9_PROBES.md`.

## B. Caller permissions and upkeep states

The test snapshots and restores the same state between random EOA `0xBEEF`,
configured keeper, and owner Safe callers. Numeric status codes in the scan
logs mean: `0` revert, `1` partial stale-value reduction, `2` all stale value
removed, `3` no stale value before the call, `4` success without a stale-value
reduction. Exact selectors and emitted event counts are logged per attempt.

| State / entry point | Result |
|---|---|
| Work-state `upkeep()` | Random `0xBEEF`, configured keeper, and owner Safe all succeeded; 18 events each. |
| Work-state `rollover()` | The same three callers all succeeded; 49 events each. |
| No-op `upkeep()` | All three callers reverted `NoOp()` (`0x00219cf1`); zero events. |
| No-op `rollover()` | All three callers reverted `InsufficientRollover()` (`0xbbb27b39`); zero events. |
| Matured bond while issuance is not due | On the fork, owner changed issuer interval from `604800` to `4838400` seconds, keeping offset `68400`. The existing real bond `0x93dc…177ca8` matured at `1796324400`; next issue window was `1798743600`. Keeper `upkeep()` succeeded with 24 events and the latest bond stayed unchanged. Trace also shows the issue-window timestamp remained `1793905200` after the attempted upkeep. |
| Default rebalance window `(86400,64800,86400)` at `1794247201` | Window `[1794247200,1794333600)`, `lastRebalance=1794160800`; keeper `upkeep()` reverted `NoOp()` (`0x00219cf1`), zero events. It did not trigger rebalance in this snapshot. |

Under the default issuer interval, the first observed maturity timestamp
`1795114800` equals the next issue window, so that default snapshot does not
separate maturity from issuance. The distinct matured-before-issue case above
uses the issuer's public timing setter on the local fork. Caller rows are in
`round10_b_callers.log:6-17`; the default window is
`round10_b_default_window.log:6-7`; the decoupled maturity setup and result are
`round10_probe_results.log:652-654` and
`round10_b_matured_before_issue_adjusted_cadence.log:179-180,562-569,712-715,784-800`.
At the attempted upkeep time `1795114801`, `issue()` returned `bondIssued=false`;
`lastIssueWindowTimestamp` remained `1793905200`. The real existing bond then
matured at `1796324400`, before the next issue window.

## C. Backup bond selection

The standalone harness creates three real bonds by calling `upkeep()` from the
configured keeper at three issue windows, with price answers `0.8x`, `1.0x`,
and `1.25x` the pinned baseline; it then deposits through the real
BondsManager and transfers the resulting tranche tokens to the Perps. Price
answers are changed only with the archived selector-level oracle mock. It
records the full two reserve arrays and planner arguments/returns for 15 cases.
Three cases independently raise one real-issued candidate's planner-input
`valueRatio` by `1e16` (0.01 WAD); these are in-memory planner-input mutations,
not changes to issuer state. The `maturity_order_permuted` and reversed
candidate-order cases also mutate only planner calldata; they are not claims
about changing the on-chain bond order. A backup-branch match is reported per
case rather than assumed.

| Cases | Variation |
|---|---|
| `base`, `price_minus_30`, `price_minus_10`, `price_plus_10`, `price_plus_30`, `near_tie` | BTC price movement from the issue-price baseline |
| `maturity_order_permuted`, `candidate_order_reversed`, `near_tie_reversed` | Planner-input order changes |
| `value_ratio_A_plus_1pct`, `value_ratio_B_plus_1pct`, `value_ratio_C_plus_1pct` | Add `1e16` to one real-issued candidate's planner-input senior `valueRatio` at a time |
| `existing_balance_A_plus_1m`, `existing_balance_B_plus_1m`, `existing_balance_C_plus_1m` | Legitimate BondsManager deposits and tranche transfers add balance to each real-issued candidate in turn |

Base-case candidate features are shown below; each candidate's senior and
junior side has its own `valueRatio`, balance, and value. Full, per-case SR/JR
planner arrays and all decoded returns are in
`round10_backup_selection.log:11-622`.

| Candidate | Reserve-array indices (SR/JR) | Senior / junior `valueRatio` | `secondsToMaturity` | `underlyingOpenPrice` | SR balance/value; JR balance/value |
|---|---:|---:|---:|---:|---:|
| A `0xc49e…fb93` | 1 / 1 | `0.40 / 0.60 WAD` | `1209599` | `59863525166360000000000` | `29931762583 / 400000`; `29931762583 / 600000` |
| B `0x5a83…fd50` | 2 / 2 | `0.50 / 0.50 WAD` | `1814399` | `74829406457960000000000` | `74829406457 / 1000000`; `74829406458 / 1000000` |
| C `0xe23d…e90c` | 3 / 3 | `0.625 / 0.375 WAD` | `2419199` | `93536758072450000000000` | `140305137108 / 1875000`; `140305137109 / 1125000` |

Each case selected a planner deposit of `3000000`; the selected ID and
`backupMatchesPlan=true` are logged per case. A selected-ID summary is:

| Case | Selected candidate |
|---|---|
| `base`, `price_minus_10`, `price_plus_10`, `near_tie`, `maturity_order_permuted`, all three `value_ratio_*`, all three `existing_balance_*`, `candidate_order_reversed`, `near_tie_reversed` | B |
| `price_minus_30` | A |
| `price_plus_30` | C |

These are planner allocations, not 15 executed `rollover()` transactions.
“Closest to 0.5 WAD” fits the listed Round 10 selections but is not asserted as
a universal rule; the earlier Round 5 near-tie result is a counterexample to
strict argmin reasoning. The candidate features after each perturbation and the
complete planner returns remain available in the cited raw log.

## D. Partial/revert liquidity boundaries

Each public and lazy call starts from the same stale baseline per sample, sets
JR reserved liquidity through the owner-gated `updateLiquidityThresholds`,
records free funds and stale value before/after, then restores the snapshot.
The scan steps down from the maximum available amount and uses binary search
for observed full/partial/revert transitions. `upkeep()` is scanned at the
first maturity timestamp; a boundary is reported only if it actually rolls.
The `-vvvvv` traces are used to distinguish returned zero plan amounts from
actual zero-amount external deposit/transfer calls.

| Entry point | Result |
|---|---|
| Public `rollover()` | With maximum JR free funds `271549615`, full reduction required `6423504`; at `6423503`, status was partial. One-unit success/revert edge: `1999999` reverted `InsufficientRollover()` (`0xbbb27b39`), while `2000000` succeeded partially. |
| SR-only `flashMint2` lazy rollover | Full reduction required `8423504`; at `8423503`, status was partial. First non-reverting sample boundary: `3999999` reverted `InsufficientRollover()` (`0xbbb27b39`), `4000000` succeeded with no stale-value reduction (status 4). |
| `upkeep()` at default maturity/issue boundary | At `1795114800`, maturity coincided with the next issue window. It removed stale value `41875890` even at requested free liquidity `0`; all sampled amounts returned status 2. Trace shows maturity/redeem and issue calls, not the rollover planner, so there is no `upkeep()` rollover liquidity boundary in this snapshot. |
| Zero-amount external calls | Yes. Successful public and lazy traces include BondsManager `deposit(bondID, 0)` and Perp tranche `transfer(perp, 0)` calls: public trace lines `1925-1926,2038-2039`; lazy trace lines `1190-1191,1303-1304`. |

Boundary records are in `round10_probe_results.log:661-704`. The public and lazy
successful call trees are `round10_public_rollover_trace.log:1814-2062` and
`round10_lazy_flashmint_trace.log:1066-1304`; upkeep's maturity trace is
`round10_upkeep_maturity_trace.log:5064-5348,8763-9047`.

## Unknowns and limits

- Findings apply only to the pinned fork and the listed input states.
- The Round 4 test-deployed `Round4MockTranche` runtime codehashes were not
  emitted in that round's raw evidence; it is not an oracle or a runtime
  replacement. Round 9's oracle-stub address, exact tuples, decimals,
  `anvil_setCode` method, and runtime codehash are archived in
  `ROUND9_PROBES.md`.
- No universal backup-selection rule is inferred from this finite case set.
- The exact lazy transition from partial stale-value reduction to success with
  no stale-value reduction was not bisected; the successful/no-reduction
  threshold and one-unit revert edge are recorded.
- Planner-selected C allocations were not followed by a separate
  `rollover()` execution for each of the 15 parameter cases.
- Maturity-order variation in C was applied to planner calldata only; no
  scenario reordered actual on-chain maturity through a different issuance
  schedule.
- The default cadence ties maturity and issue-window start; the separated
  matured-before-issue observation requires the documented local owner change
  to the issuer timing configuration.
- `round10_maturity_diag.log` and
  `round10_probe_results_pre_correction.log` preserve an intermediate
  14-day-interval attempt. It did not separate issuance from the live
  28-day bond maturity, so the harness was changed to a 56-day interval; these
  diagnostic failures are not counted as target behavior results.
