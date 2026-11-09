# PerpBalancer rollover probes

## Scope and method

Investigation-only; no repo files were changed. All stateful executions were run in Foundry against the local Anvil Base fork at `http://127.0.0.1:8545`. The probe warped locally, refreshed the local Oracle using test-only feed mocks, called `upkeep()`, then either directly `staticcall`ed the public Balancer functions or impersonated the configured keeper for `rollover()`. No transaction was broadcast to Base.

The harness is `evidence/raw-logs.tar.xz::test/RolloverProbe.t.sol`. Raw decoded `OBS` input/output records for direct Balancer calls are in `evidence/raw-logs.tar.xz::rollover_direct_functions.log`. Full `forge test -vvvv` call traces are in:

- `evidence/raw-logs.tar.xz::rollover_first_actual_trace.log`
- `evidence/raw-logs.tar.xz::rollover_second_actual_trace.log`

The older, full-field Controller snapshots are in `evidence/raw-logs.tar.xz::controller_probe_v2.log` and `evidence/raw-logs.tar.xz::CONTROLLER_PROBES.md`.

The public ABI signatures used were:

- `computePerpSrRolloverState(ReserveData,uint32,address) → PerpSrRolloverState`
- `computePerpJrLiquidity(ReserveData,PerpSrRolloverState,uint256) → (uint256 free,uint256 unlocked,uint256[] unpairedStaleSrTrAmts)`
- `computeRolloverPolicy(PerpSrRolloverState,uint256[],uint256) → (uint256 underlyingAmtToDeploy,RolloverExecution)`
- `computeBackupRolloverPolicy(PerpSrRolloverState,uint256) → RolloverExecution`
- `computePerpSrRolloverPlan(ReserveData,ReserveData,address,uint32,uint256) → RolloverExecution`

The Controller trace contains one external Balancer call, `computePerpSrRolloverPlan`. It does **not** contain separate external calls from Controller to the four component functions above. Those four public pure functions were called directly by the probe with the Controller-derived inputs; their direct results are shown below. The internal implementation/call graph inside PerpBalancer is not exposed by this external call trace, so the selection logic derived later is an observable behavioral fit, not a claim about unobservable internal dispatch.

## Controller inputs at the two rollovers

| Getter/input | First rollover, `1794510001` after `upkeep()` | Second rollover, `1795436234` after first rollover and `upkeep()` |
|---|---:|---:|
| `minMaturitySec` | 604800 | 604800 |
| `reservedPerpJrLiquidity` | 3864657 | 3864657 |
| `perpJrReservedUnderlyingAmt` | 1000000 | 1000000 |
| `perpJrReservedUnderlyingPerc` | 10000000000000000 (1%) | 10000000000000000 (1%) |
| `minCleanupVal` | 1000000 | 1000000 |
| SR reserve idle underlying | 0 | 0 |
| JR reserve idle underlying | 271549615 | 265126111 |
| SR/JR reserve tranche rows | 4 / 4 | 4 / 4 |
| Latest bond ID | `0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b` | `0x5a83ee1f5b5b29d9c5adfc39fbd15a9b3d5aec0d793fc824a97b3bed97d9fd50` |
| BondsManager | `0xe8c13955caED9c009fd2b335A10986407958fde3` | same |

The first state has four senior tranches in `perpSr` and four junior tranches in `perpJr`; the soon-to-mature bond B is `0x845535d5c774b4204fe67ddcdd33292c39defdaa7092f1d562bdb50a3b102963`, with `secondsToMaturity=604799`. Its SR/JR reserve balances are `3133547705520` / `3133547705527`, reserve values `41875890` / `35357092`, and `totalClaim=77232982`. The other nonzero positions are bond A (`0x93dcba…177ca8`) and bond C (`0x342b85…ef108d`); the latest bond has zero tranche balances before rollover.

At the second state, bond C (`0x342b85…ef108d`) is the stale tranche at `283366` seconds. The full Controller-derived structs, including `TrancheData` fields and all tranche tokens, are visible in the decoded Balancer call arguments at trace lines 1311 and 2370 respectively. The direct-call log contains the same reserve inputs in compact rows of `[bondID,tranche,balance,value,secondsToMaturity,isMature,isSenior,trancheSupply,trancheClaim,totalClaim,trancheRatio,valueRatio]`; the verbose trace contains the additional `volatilityMultiplier`, `underlyingOpenPrice`, `counterpart`, and `manager` fields.

## Actual `rollover()` traces

Both actual calls were `forge test -vvvv` local-fork traces, with the configured keeper impersonated. The line numbers below refer to the trace files above. The Balancer plan arguments in the trace are the full decoded reserve structs and the controller’s manager, maturity, and reserved-liquidity values.

### First rollover

Call sequence inside the actual `Controller.rollover()` at trace line 795:

1. `PerpBalancer.computePerpSrRolloverPlan(srReserve,jrReserve,BondsManager,604800,3864657)` — line 1311.
2. `perpSr.transferReservesTo(perpJr, (underlying=0, [(bond-B-SR,3133547705520)]))` — line 1313.
3. `BondsManager.redeem(bond-B,3133547705520,3133547705527)` — line 1349. The decoded `TranchesRedeemed` event at line 1374 reports `underlyingAmtReturned=77232982`.
4. `perpJr.bondDepositsForRollover(BondsManager, [(bond-C,0),(bond-A,6411258),(latest-bond,77245228)])` — line 1394. The zero deposit for bond C is present in the call vector.
5. `BondsManager.deposit(bond-A,6411258)` — line 1410; `BondDeposit` at line 1427 reports SR/JR mints `243440724687` / `243440724687`.
6. `BondsManager.deposit(latest-bond,77245228)` — line 1440; `BondDeposit` at line 1457 reports SR/JR mints `2890107281474` / `2890107281475`.
7. `perpJr.transferReservesTo(perpSr, (underlying=0, [(bond-C-SR,0),(bond-A-SR,243440724687),(latest-SR,2890107281474)]))` — line 1477.

The plan therefore reproduces both reported deposits exactly: `77245228` to the latest bond and `6411258` to bond A. It also asks for a full paired redemption of bond B, whose event reports `77232982` returned.

### Second rollover

The test prepares the first rollover and then the second timestamp; the target second `Controller.rollover()` begins at trace line 1854:

1. `PerpBalancer.computePerpSrRolloverPlan(srReserve,jrReserve,BondsManager,604800,3864657)` — line 2370.
2. `perpSr.transferReservesTo(perpJr, (underlying=0, [(bond-C-SR,3392625737181)]))` — line 2372.
3. `BondsManager.redeem(bond-C,3392625737181,3392625737183)` — line 2408. `TranchesRedeemed` at line 2433 reports `underlyingAmtReturned=84045051`.
4. `perpJr.bondDepositsForRollover(BondsManager, [(bond-A,0),(previous-latest,13431048),(new-latest,77245228)])` — line 2453.
5. `BondsManager.deposit(previous-latest,13431048)` — line 2469; `BondDeposit` at line 2486 reports SR/JR mints `502518674974` / `502518674974`.
6. `BondsManager.deposit(new-latest,77245228)` — line 2499; `BondDeposit` at line 2516 reports SR/JR mints `2890107281474` / `2890107281475`.
7. `perpJr.transferReservesTo(perpSr, (underlying=0, [(bond-A-SR,0),(previous-latest-SR,502518674974),(new-latest-SR,2890107281474)]))` — line 2536.

As in the first trace, the earlier `BondsManager.redeem` lines before the Balancer plan are reserve-snapshot/valuation work from the test’s pre-call `systemReserveState()` logging. The state-changing rollover redemption is the nested, nonzero paired redeem listed above and is accompanied by the `TranchesRedeemed` event.

## Direct Balancer outputs for the two baseline states

For the first state, direct `computePerpSrRolloverState(sr,604800,BondsManager)` returned one stale senior tranche (bond B), `staleUnderlyingBal=0`, and `totalStaleVal=41875890`. The fresh senior rows were C, A, and the current latest bond. Calling `computePerpSrRolloverState` on the JR reserve separately was also recorded in the raw JSON log.

`computePerpJrLiquidity(jr,state,3864657)` returned:

| State | `freePerpJrLiquidity` | `unlockedPerpJrLiquidity` | `unpairedStaleSrTrAmts` |
|---|---:|---:|---|
| First | 267684958 | 77232982 | `[0]` |
| Second | 261261454 | 84045051 | `[0]` |

For the first state, the combined candidate availability is `267684958 + 77232982 = 344917940`. `computeRolloverPolicy(state,[0],344917940)` returns `underlyingAmtToDeploy=83656486` and the execution in the actual trace: deposits `6411258` to bond A and `77245228` to the latest bond, with the zero entry for C. Its `underlyingValRolled` is `41875890`. `computeBackupRolloverPolicy(state,267684958)` instead returns a latest-bond deposit of `83751780` (twice `41875890`); this is not the plan selected for the actual first rollover.

For the second state, the standard policy returns `underlyingAmtToDeploy=90676276`, with deposits `13431048` to the previous latest bond and `77245228` to the new latest bond; `underlyingValRolled=45338138`. The backup policy with free JR liquidity also totals `90676276` in this state. The directly called `computePerpSrRolloverPlan` matches the actual second rollover trace.

## Raw case table

The following 22 first-state variations plus the second-state baseline are 23 separate case records. “Standard deploy” is the `computeRolloverPolicy` return using `free + unlocked`; “backup total” is the sum of `freshBondDepositAmts` from `computeBackupRolloverPolicy(state,free)`; “selected deposits” are the nonzero deposits returned by `computePerpSrRolloverPlan`. All values are raw integer base units. Full JSON inputs/decoded returns for each row are in `rollover_direct_functions.log`.

| Case | Input delta; SR/JR idle | Stale SR bond(s): seconds | `totalStaleVal` | JR free / unlocked / unpaired | Standard deploy | Backup total | Selected deposits (bond suffix:amount) | `underlyingValRolled` |
|---|---|---|---:|---|---:|---:|---|---:|
| 01 baseline first rollover | baseline; 0 / 271549615 | `102963:604799` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 02 JR idle zero | 0 / 0 | `102963:604799` | 41875890 | 0 / 77232982 / `[0]` | 83656486 | 0 | none | 0 |
| 03 JR idle one below absolute floor | 0 / 999999 | `102963:604799` | 41875890 | 0 / 77232982 / `[0]` | 83656486 | 0 | none | 0 |
| 04 JR idle at absolute floor | 0 / 1000000 | `102963:604799` | 41875890 | 0 / 77232982 / `[0]` | 83656486 | 0 | none | 0 |
| 05 JR idle one above absolute floor | 0 / 1000001 | `102963:604799` | 41875890 | 0 / 77232982 / `[0]` | 83656486 | 0 | none | 0 |
| 06 JR idle 10m | 0 / 10000000 | `102963:604799` | 41875890 | 6135343 / 77232982 / `[0]` | 83656486 | 6135343 | `74181b:6135343` | 3067671 |
| 07 JR idle 1b | 0 / 1000000000 | `102963:604799` | 41875890 | 996135343 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 08 SR idle 1m | 1000000 / 271549615 | `102963:604799` | 42875890 | 267684958 / 78232982 / `[0]` | 85656486 | 85751780 | `177ca8:6411258`, `74181b:79245228` | 42875890 |
| 09 SR idle 100m | 100000000 / 271549615 | `102963:604799` | 141875890 | 267684958 / 177232982 / `[0]` | 278197686 | 267684958 | `ef108d:57641676`, `177ca8:67690086`, `74181b:152865924` | 141875890 |
| 10 remove bond B from both reserve arrays | 0 / 271549615 | none | 0 | 267684958 / 0 / `[]` | 0 | 0 | none | 0 |
| 11 bond B seconds = 604798 | 0 / 271549615 | `102963:604798` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 12 bond B seconds = 604800 exactly | 0 / 271549615 | `102963:604800` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 13 bond B seconds = 604801 | 0 / 271549615 | none | 0 | 267684958 / 0 / `[]` | 0 | 0 | none | 0 |
| 14 bond B `isMature=true`, seconds still 604799 | 0 / 271549615 | `102963:604799` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 15 add paired synthetic stale bond (`seconds=600000`, balance 1000000 each side) | 0 / 271549615 | `0401aa:600000`, `102963:604799` | 41876890 | 267684958 / 77234982 / `[0,0]` | 83658486 | 83753780 | `177ca8:6411258`, `74181b:77247228` | 41876890 |
| 16 append paired synthetic fresh zero-balance bond (`seconds=2000000`) | 0 / 271549615 | `102963:604799` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `a6977b:77245228` | 41875890 |
| 17 set bond A SR/JR balances equal to bond C balances | 0 / 271549615 | `102963:604799` | 41875890 | 267684958 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 18 set bond B balances and reserve values to zero | 0 / 271549615 | `102963:604799` | 0 | 267684958 / 0 / `[0]` | 0 | 0 | none | 0 |
| 19 halve only the JR bond B balance | 0 / 271549615 | `102963:604799` | 41875890 | 267684958 / 38616490 / `[1566773852761]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 20 set `reservedPerpJrLiquidity=0` | 0 / 271549615 | `102963:604799` | 41875890 | 271549615 / 77232982 / `[0]` | 83656486 | 83751780 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 21 JR idle exactly covers standard budget when combined with unlocked liquidity | 0 / 10288161 | `102963:604799` | 41875890 | 6423504 / 77232982 / `[0]` | 83656486 | 6423504 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| 22 JR idle one unit above that boundary | 0 / 10288162 | `102963:604799` | 41875890 | 6423505 / 77232982 / `[0]` | 83656486 | 6423505 | `177ca8:6411258`, `74181b:77245228` | 41875890 |
| Second rollover baseline | 0 / 265126111 | `ef108d:283366` | 45338138 | 261261454 / 84045051 / `[0]` | 90676276 | 90676276 | `74181b:13431048`, `d9fd50:77245228` | 45338138 |

The appended synthetic fresh-bond case is an ordering probe, not a live-state shape: the synthetic row was appended last to the reserve arrays and the plan directed the latest-bond deposit to that row (`a6977b`) even though its maturity timestamp is less than the original last row’s. The controller’s live reserve arrays and `latestBondInfo()` agree on the latest row. The synthetic stale/fresh rows are otherwise explicitly recorded in the raw log.

## Derived formulas (hypotheses)

The checks below were evaluated against all 23 records (22 first-state variants plus the second-state baseline). “Exact” refers to the raw integer outputs; the plan-selection comparison normalizes away zero-valued placeholder array entries only.

1. **Stale SR selection:** include SR reserve rows with `secondsToMaturity <= minMaturitySec`. Exact membership in 23/23 cases. The exact-boundary case (`604800`) is stale; `604801` is not. Setting `isMature=true` while keeping `secondsToMaturity=604799` did not change selection. This is evidence that the observed partition follows seconds-to-maturity, not the `isMature` flag.
2. **Stale value:** `totalStaleVal = srReserve.underlyingBal + Σ(value of selected stale SR rows)`. Exact in 23/23.
3. **Free JR liquidity:** `free = max(jrReserve.underlyingBal - reservedPerpJrLiquidity, 0)`. Exact in 23/23, including idle values below, at, and above the 1000000 absolute getter and the zero-reserve case.
4. **Unlocked JR liquidity:** `unlocked = staleUnderlyingBal + Σ floor(jrBalance × jrTranche.totalClaim / jrTranche.trancheSupply)` over stale SR bond IDs with a corresponding JR row (skip zero supply). Exact in 23/23. For the first baseline this is `0 + 77232982`; with SR idle 1000000 it is `1000000 + 77232982 = 78232982`; with half of the odd-sized JR bond-B supply it floors to `38616490`.
5. **Unpaired stale SR amount:** for each stale bond, `max(srBalance - floor(jrBalance × srTrancheSupply / jrTrancheSupply),0)`. Exact per-element array in 23/23. Case 19 gives `floor(1566773852763 × 3133547705520 / 3133547705527)=1566773852759`, so unpaired SR is `3133547705520 - 1566773852759 = 1566773852761`.
6. **Standard-versus-backup selection:** let `available = free + unlocked`; call the standard policy with that availability. If its returned `underlyingAmtToDeploy <= available`, the observable plan equals its execution. Otherwise, the observable plan equals `computeBackupRolloverPolicy(state,free)`. Economic plan fields match in 23/23. This includes the exact budget test: at JR idle `10288161`, `free + unlocked = 83656486`, exactly the standard amount, and the standard plan is selected. At idle `10000000`, combined availability is `83368325`, short by `288161`, and the backup plan uses `6135343` free units. The three no-stale/zero-value cases (10, 13, 18) return only zero-valued work; their zero placeholder arrays differ structurally, but their token movements, deposits, and rolled value are all zero.
7. **Backup deposit cap:** the sum of backup `freshBondDepositAmts` is `min(free, 2 × totalStaleVal)`. Exact in 23/23. The per-bond allocation is included in each raw decoded execution; the table shows the resulting total.
8. **Observed first-rollover split:** the standard execution totals `83656486`, while redeeming bond B returns `77232982`, leaving `6423504` to be funded from pre-existing JR idle. The policy allocates `6411258` to bond A and `77245228` to the new latest bond; the latter is `77232982 + 12246`. The output is an exact match to the Controller trace. The second standard execution totals `90676276` against `84045051` redeemed, allocating `13431048` to the previous latest bond and `77245228` to the new latest. These exact per-bond allocations are returned by `computeRolloverPolicy` and confirmed by the traces; these probes do not reduce the A-bond top-up and the `12246` latest-bond increment to a simpler general closed-form independent of the Balancer output.

The actual external Controller path is verified as `rollover() → computePerpSrRolloverPlan → transfer stale SR tranche to JR → paired BondsManager.redeem → bondDepositsForRollover → per-bond BondsManager.deposit calls → transfer newly minted SR tranches from JR back to SR`. The helper formulas above reproduce the observed public function outputs, but the helper functions’ internal invocation from within `computePerpSrRolloverPlan` cannot be confirmed from the external call trace alone.

## Allocation rule

This section tests the per-bond allocation hypothesis against the 23 saved standard-policy cases, the two actual rollover traces, and ten new direct calls. The additional harness calls and full decoded inputs/outputs are in `evidence/raw-logs.tar.xz::rollover_allocation_cases.log`; the harness is `evidence/raw-logs.tar.xz::test/RolloverProbe.t.sol`. The compact reserve rows in the new log append `underlyingOpenPrice` after the earlier fields. `evidence/raw-logs.tar.xz::analyze_rollover_allocation.py` reproduces the per-case match counts from both logs.

### Refined target and allocation

The initial hypothesis is right about sequentially topping up non-latest fresh rows toward a target, but `target = max(non-latest values)` is too low when the stale value budget is large. The target that matches the black-box outputs is:

```text
S = totalStaleVal
N = len(freshSrTrs)
v[i] = freshSrTrs[i].value
averageTarget = ceil((S + sum(v[i] for i in 0..N-1)) / N)
target = max(averageTarget, max(v[i] for i in 0..N-2))

remaining = S
for i in freshSrTrs order, excluding the last row:
    topUp[i] = min(max(target - v[i], 0), remaining)
    remaining -= topUp[i]
topUp[last] = remaining
```

For the tested live states, `freshSrTrs` is ordered by `secondsToMaturity` ascending, with the current latest bond last. If there is insufficient `S` to reach the target, earlier rows in that returned order consume the available amount first. The last row receives the residual after all preceding rows have been processed. This exactly refines H: when `averageTarget` is below the maximum non-latest value, the target remains that maximum; when `S` is large, the average raises the target above it.

The underlying deposit corresponding to a positive SR-value top-up is:

```text
underlyingAmt[i] = ceil(topUp[i] * 1e18 / valueRatio[i])
                  = (topUp[i] * 1e18 + valueRatio[i] - 1) / valueRatio[i]
```

`valueRatio` is the WAD-scaled ratio supplied in the reserve row; the policy’s observed inversion uses that rounded field. A new latest row has `valueRatio = 0.5e18` in these states, so an SR-value top-up of `38,622,614` requires `77,245,228` underlying. For bond A, a top-up of `3,253,276` at `valueRatio=507431799242465803` gives `6,411,258`; flooring the inverse instead gives `6,411,257`. The odd-ratio probe below distinguishes the stored ratio from recomputing `totalClaim / srClaim`: with `valueRatio=428571428571428571` and top-up `3`, the observed deposit is `8`, while `ceil(3 × 7 / 3)` would be `7`.

Across all 33 direct cases, the predicted per-bond deposits match the standard `computeRolloverPolicy` outputs exactly, and the returned `underlyingAmtToDeploy` equals the sum of those deposits in 33/33. The tested ratio inversion uses the value already present in the public reserve struct; these probes do not independently vary open price and current price while holding `valueRatio` fixed, so they do not establish how upstream reserve construction derives that field.

### Original H against the saved cases

The “H” column below means the original target `max SR value among non-stale, non-latest rows`, with sequential top-ups in the returned fresh-row order and the latest row receiving the remainder. The observed amounts are the direct standard-policy outputs, not necessarily the plan selected when JR liquidity forces the backup policy.

| Saved case | H | Observed standard-policy deposits (`bond suffix:underlying`) |
|---|---|---|
| 01 baseline first rollover | Exact | `177ca8:6411258`, `74181b:77245228` |
| 02 JR idle zero | Exact | `177ca8:6411258`, `74181b:77245228` |
| 03 JR idle one below absolute floor | Exact | `177ca8:6411258`, `74181b:77245228` |
| 04 JR idle at absolute floor | Exact | `177ca8:6411258`, `74181b:77245228` |
| 05 JR idle one above absolute floor | Exact | `177ca8:6411258`, `74181b:77245228` |
| 06 JR idle 10m | Exact | `177ca8:6411258`, `74181b:77245228` |
| 07 JR idle 1b | Exact | `177ca8:6411258`, `74181b:77245228` |
| 08 SR idle 1m | Exact | `177ca8:6411258`, `74181b:79245228` |
| 09 SR idle 100m | **Mismatch** | H predicts `177ca8:6411258`, `74181b:277245228`; observed `ef108d:57641676`, `177ca8:67690086`, `74181b:152865924` |
| 10 remove bond B | Exact | no deposits |
| 11 bond B seconds 604798 | Exact | `177ca8:6411258`, `74181b:77245228` |
| 12 bond B seconds 604800 | Exact | `177ca8:6411258`, `74181b:77245228` |
| 13 bond B seconds 604801 | Exact | no deposits |
| 14 mark bond B mature | Exact | `177ca8:6411258`, `74181b:77245228` |
| 15 add synthetic stale bond | Exact | `177ca8:6411258`, `74181b:77247228` |
| 16 add synthetic fresh bond | Exact | `177ca8:6411258`, `a6977b:77245228` |
| 17 equalize A balances to C | Exact | `177ca8:6411258`, `74181b:77245228` |
| 18 zero bond B balances | Exact | no deposits |
| 19 unequal JR bond B balance | Exact | `177ca8:6411258`, `74181b:77245228` |
| 20 reserved JR liquidity zero | Exact | `177ca8:6411258`, `74181b:77245228` |
| 21 JR idle exactly covers standard budget | Exact | `177ca8:6411258`, `74181b:77245228` |
| 22 JR idle one above boundary | Exact | `177ca8:6411258`, `74181b:77245228` |
| Second rollover baseline | Exact | `74181b:13431048`, `d9fd50:77245228` |

Thus original H matches **22/23** saved cases. Case 09 has `S=141,875,890`; its original target is `45,338,138`, but the average target is `ceil((141,875,890 + 87,423,000)/3)=76,432,964`. The refined rule tops C to `76,432,964` (`57,641,676` underlying), tops A to the same target (`67,690,086` underlying), then assigns the residual SR value `76,432,962` to the latest bond (`152,865,924` underlying).

### Ten discriminating direct calls

All amounts are raw integer base units. Row values are shown as `bond:value@secondsToMaturity`; IDs are suffixes of the full IDs in the raw log. “Standard deposits” are from direct `computeRolloverPolicy`; “selected plan” is `computePerpSrRolloverPlan`.

| Case | Input change and fresh SR rows | `S` / target | Standard deposits | Selected plan / H |
|---|---|---:|---|---|
| A above C | A set to 60,000,000; C remains 45,338,138; latest 0 | 41,875,890 / 60,000,000 | `ef108d:27179258`, `74181b:54428056` | Same; H exact |
| A below C | A set to 30,000,000; C 45,338,138; latest 0 | 41,875,890 / 45,338,138 | `177ca8:30226995`, `74181b:53075504` | Same; H exact |
| Partial small S | Baseline C 45,338,138, A 42,084,862, latest 0 | 1,000,000 / 45,338,138 | `177ca8:1970709` | Same; H exact, latest gets 0 |
| S exactly covers A’s gap | Baseline values | 3,253,276 / 45,338,138 | `177ca8:6411258` | Same; H exact, latest gets 0 |
| Much larger S | SR idle set to 300,000,000; C 45,338,138, A 42,084,862, latest 0 | 341,875,890 / 143,099,630 | `ef108d:181224240`, `177ca8:199070631`, `74181b:286199260` | Same; original H mismatches, refined rule exact |
| Four fresh, ascending maturities | C 20m@1,209,599; synthetic 30m@1,500,000; A 40m@1,814,399; latest 0@2,419,199 | 15,000,000 / 40,000,000 | `ef108d:27806078` | Same; H exact, earliest C receives the partial top-up |
| Four fresh, reversed non-latest maturities | A 40m@1,100,000; synthetic 30m@1,500,000; C 20m@1,800,000; latest 0@2,419,199 | 15,000,000 / 40,000,000 | `cec75c:20000000`, `ef108d:9268693` | Same; H with ascending maturity is exact; descending-order alternative is not |
| Zero-value non-latest | Synthetic 0@1,000,000 before C 45,338,138 and A 42,084,862 | 1,000,000 / 45,338,138 | `f9cd1e:2000000` | Same; H exact, zero-value row consumes the partial budget first |
| JR idle limits plan | Baseline SR; JR idle set to 10,000,000 | 41,875,890 / 45,338,138 | Standard candidate: `177ca8:6411258`, `74181b:77245228` | Available `83,368,325` is `288,161` below standard deploy `83,656,486`; plan selects backup deposit `74181b:6135343`. H exactly predicts the standard candidate, not the selected backup |
| Odd claim-ratio rounding | A `value=3`, `trancheClaim=3`, `totalClaim=7`, `valueRatio=428571428571428571`; C value 6; stale S=3 | 3 / 6 | `177ca8:8` | Same; H exact under `ceil(topUp×1e18/valueRatio)`; `ceil(topUp×totalClaim/trancheClaim)` would give 7 |

Original H matches **9/10** of these calls; its only miss is the large-S case. The refined target and allocation match **10/10**. Together with the saved cases, this is **33/33 exact direct policy outputs**. The two actual rollovers also match:

| Actual rollover | `S`; fresh SR values before rollover | Target | SR-value top-ups; resulting underlying deposits | Result |
|---|---|---:|---|---|
| First, `1794510001` | 41,875,890; C 45,338,138, A 42,084,862, latest 0 | 45,338,138 | A `3,253,276` → `6,411,258`; latest `38,622,614` → `77,245,228` | Exact; B redeemed for 77,232,982 |
| Second, `1795436234` | 45,338,138; A 45,338,138, previous latest 38,622,614, new latest 0 | 45,338,138 | previous latest `6,715,524` → `13,431,048`; new latest `38,622,614` → `77,245,228` | Exact; C redeemed for 84,045,051 |

Original H also matches both actual rollovers, so its aggregate is **33/35** across the saved cases, new probes, and real executions; its only misses are the two large-S cases. The refined rule matches **35/35**. The old case 16 is also clarified by its returned state order: `[C,A,synthetic,D]`. The synthetic row’s deposit (`77,245,228`) is its non-latest sequential top-up; D remains the final row and gets zero. The earlier shorthand calling that deposit the “latest-bond deposit” was imprecise.
