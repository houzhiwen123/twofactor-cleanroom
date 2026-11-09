# Round 4 Black-Box Probes

## Scope and verdicts

All new calls used the local Base Anvil fork at `http://127.0.0.1:8545` with Foundry `--offline`; the Perp permission suite selected block `54_990_962`. No real-chain transactions were sent. No verified source or frontend bundle was accessed, and no clean-room repository files were changed. The report and test harnesses are under `/home/ubuntu/work/probes`.

“Exact” below means the observed values distinguish the named alternatives for the tested cases. “Partial” means the data supports a rule for the tested cases but does not resolve the full requested matrix or establish a universal rule.

## Summary table

| Probe | Verdict | Raw result / discriminating alternatives |
|---|---|---|
| **P1 — backup selection and amount** | **PARTIAL** | A ratio closest to `0.5e18` rule, ties favoring `valueRatio >= 0.5e18`, selects the observed bond in all 6 synthetic direct-plan cases. The listed candidates match only `1/6` to `4/6`. Backup amount matches `min(free, floor(S*1e18/selectedRatio))` in all 6; actual shifted-price plans also distinguish this from `min(free,2*S)`. Universal selection behavior remains unresolved: no fresh bonds were issued at independently varied open prices in this round. |
| **P2 — public/lazy rollover thresholds** | **PARTIAL** | A public rollover with `S=41,875,890`, `minCleanupVal=10,000,000`, and `JR idle=30,000,000` partially completed `27,219,328`, leaving `14,656,562`. At lazy threshold `1,000,000`, post-input idle `999,999` / `1,000,000` did not trigger cleanup, while `1,000,001` did. The full liquidity × threshold × branch matrix and exact public completable-value boundary remain unresolved. |
| **P3 — Perp permissions and behavior** | **PARTIAL** | Both tokens report `maxTrancheCount=50`, `decimals=8`. Controller-only methods reject owner/random with `0x7bf6a16f`; owner-only `updateController` rejects controller/random with `0x118cdaa7`. Filling from `3` to `50` succeeds; entry `51` reverts `ReserveOverflow()` (`0x446c8cc9`). Recovery and reserve-removal semantics remain unresolved. |
| **P4 — fresh proxy/genesis paths** | **PARTIAL** | Fresh FeePolicy, Controller, PerpSR, and PerpJR proxies initialized successfully. `updateAumFeePerc(999999999999999999,999999999999999999)` succeeds; at `1e18` and `1e18+1` it returns `InvalidPerc()` (`0xcdc62692`). First SR-only `flashMint2(1000000,0,0,0)` at supply `0` returns panic selector `0x4e487b71`; the fresh BondIssuer/BondsManager proxies could not be fully wired from the available ABI information. |
| **P5 — rebalance windows** | **EXACT for observed calls** | All five edge calls succeeded with isolated last-rebalance state; a second call at timestamp `1,794,506,401` failed with `LastRebalanceTooRecent()` (`0xa3b3f090`). The standalone regression is `test/Round4Probe.t.sol`. |

## P1 — Backup rollover selection and amount

### Synthetic direct-plan cases

The six direct Balancer cases each used `S=100,000,000` and `free=300,000,000`. `v` is the current SR value; `vr` is the WAD-scaled senior value ratio; maturity values are seconds to maturity. Candidate columns are the user's alternatives: latest row, minimum `v`, minimum `v/vr`, maximum `vr`, standard-plan first top-up, and nearest maturity. `A/B/C` identify the synthetic rows.

| Case | `v(A,B,C)` | `vr(A,B,C)` | maturity `(A,B,C)` | Selected | Candidate predictions `(latest,min v,min v/vr,max vr,std-first,near)` | Backup output; `2*S`; ratio floor / ceil |
|---|---:|---:|---:|---|---|---:|
| base | `(10,000,000; 11,000,000; 30,000,000)` | `(300000000000000000; 700000000000000000; 900000000000000000)` | `(432000;172800;259200)` | B | `(C,A,B,C,A,B)` | `142,857,142`; `200,000,000`; `142,857,142 / 142,857,143` |
| maturity reordered | `(10,000,000; 11,000,000; 30,000,000)` | `(300000000000000000; 700000000000000000; 900000000000000000)` | `(86400;259200;432000)` | B | `(C,A,B,C,A,A)` | `142,857,142`; `200,000,000`; `142,857,142 / 142,857,143` |
| ratios reordered | `(10,000,000; 11,000,000; 30,000,000)` | `(700000000000000000; 300000000000000000; 900000000000000000)` | `(432000;172800;259200)` | A | `(C,A,A,C,A,B)` | `142,857,142`; `200,000,000`; `142,857,142 / 142,857,143` |
| values reordered | `(30,000,000; 10,000,000; 11,000,000)` | `(300000000000000000; 700000000000000000; 900000000000000000)` | `(432000;172800;259200)` | B | `(C,B,C,C,A,B)` | `142,857,142`; `200,000,000`; `142,857,142 / 142,857,143` |
| price down 30% | `(10,000,000; 11,000,000; 30,000,000)` | `(770600000000000000; 724900000000000000; 714300000000000000)` | `(432000;172800;259200)` | C | `(C,A,A,A,A,B)` | `139,997,200`; `200,000,000`; `139,997,200 / 139,997,201` |
| price up 30% | `(10,000,000; 11,000,000; 30,000,000)` | `(414900000000000000; 390300000000000000; 384600000000000000)` | `(432000;172800;259200)` | A | `(C,A,A,A,A,B)` | `241,021,932`; `200,000,000`; `241,021,932 / 241,021,933` |

Across these six cases, candidate match counts are: latest `1/6`, minimum value `3/6`, minimum `v/vr` `4/6`, maximum `vr` `1/6`, standard-first `2/6`, nearest maturity `2/6`. The best fit among the tested candidates is **minimize `abs(vr - 500000000000000000)`; in the four cases with an equidistant `0.3e18` / `0.7e18` pair, choose the `>=0.5e18` row**. That rule predicts all six synthetic selections (`6/6`). It is an observed fit, not a confirmed universal rule.

The backup amount was exactly:

```text
min(free, floor(S * 1e18 / selectedBond.valueRatio))
```

for all six synthetic cases. The down-price output is one unit below the ceil alternative (`139,997,200` vs `139,997,201`); the up-price output is also one unit below ceil (`241,021,932` vs `241,021,933`). In the up-price case, the observed `241,021,932` is also greater than `2*S = 200,000,000`, which discriminates against the `min(free,2*S)` alternative.

### Shifted-price actual observations

The following high-free direct backup-policy comparisons distinguish the amount alternatives. The same-round forced-backup actual calls used only `free=3,000,000`, so those executed calls verify successful execution and selected-bond deposits but are liquidity-capped and do not independently distinguish the cap formulas.

| Price case | `S` | `free` | latest `vr` | selected bond / selected `vr` | `min(free,2*S)` | selected-ratio floor / ceil | Balancer / execution |
|---|---:|---:|---:|---|---:|---:|---:|
| −30%, direct backup comparison | `59,822,700` | `268,239,096` | `714285714285741559` | `0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b` / `714285714285741559` | `119,645,400` | `83,751,779 / 83,751,780` | `83,751,779` |
| +30%, direct backup comparison | `32,212,223` | `267,386,576` | `384615384615416246` | `0x342b85e9d38918a8718c6ea642ea0df75e75c938bc45a6efde8c1dbaa3ef108d` / `414961863727109880` | `64,424,446` | `77,626,947 / 77,626,948` | `77,626,947` |

The +30% row is discriminating in three ways: output `77,626,947` exceeds `2*S=64,424,446`; it equals floor using the **selected bond's** ratio; and it differs from the latest-bond-ratio candidate (`floor(32,212,223*1e18/384615384615416246)=83,751,779`). The forced-backup actual rollovers at both shifted prices succeeded and deposited `3,000,000` into the selected bond because `free=3,000,000`; this amount is consistent with all caps once the `free` minimum binds.

### Standard-path allocation recheck

For the six synthetic direct-plan cases, `S=100,000,000`, `sum(v)=51,000,000`, and `N=3`, so:

```text
averageTarget = ceil((S + sum(v)) / N) = 50,333,334
target = max(averageTarget, max(v_i for rows except the last))
topUp_i = min(max(target - v_i, 0), remaining S)   // rows in returned order except last
topUp_last = remaining S
underlying_i = ceil(topUp_i * 1e18 / vr_i)
```

The computed top-ups are `(40,333,334;39,333,334;20,333,332)` for base, maturity-reordered, ratio-reordered, and the two price-shift rows; the values-reordered case is `(20,333,334;40,333,334;39,333,332)`. The calculated per-row underlying outputs match all six direct outputs exactly (`6/6`):

| Case | Direct `standardDeploy` | Direct row deposits `(A,B,C)` |
|---|---:|---:|
| base / maturity reordered | `213,227,517` | `(134,444,447;56,190,478;22,592,592)` |
| ratios reordered | `211,322,755` | `(57,619,049;131,111,114;22,592,592)` |
| values reordered | `169,100,532` | `(67,777,780;57,619,049;43,703,703)` |
| price down 30% | `135,066,624` | `(52,340,169;54,260,359;28,466,096)` |
| price up 30% | `250,858,142` | `(97,212,182;100,777,182;52,868,778)` |

**P1 limitation:** The new selection test assigns synthetic per-bond ratios; it does not issue live fresh bonds at independently mocked open prices. The actual shifted-price rollovers changed the oracle price globally, not each bond's open price independently. Therefore the `0.5e18` selection fit still needs actual independent-open-price states to distinguish it from other rules that happen to select the same bonds in these cases.

## P2 — Public and lazy rollover state machine

| Entry/state | Raw inputs | Result |
|---|---|---|
| Public partial cleanup | `minCleanupVal=10,000,000`; stale SR value `41,875,890`; JR idle/free `30,000,000` | Succeeded partially: stale SR value became `14,656,562`; completed value `27,219,328`; JR idle after was `25,824,724`. Thus completed value was below full stale value (`27,219,328 < 41,875,890`) but above cleanup threshold. |
| Public nonzero-free shortfall | `minCleanupVal=20,000,000`; stale SR value `41,875,890`; JR idle/free `10,000,000`; stale JR balance `3,133,547,705,527` reduced to `313,354,770,552` in the control state | `rollover()` reverted `InsufficientRollover()` (`0xbbb27b39`). The exact plan-completable value was not emitted, so the test does not establish a numerical `completedValue < minCleanupVal` boundary. |
| Lazy SR threshold −1 | `minCleanupVal=1,000,000`; pre-input SR idle `0`; input `999,999`; post-input idle candidate `999,999` | No cleanup. |
| Lazy SR threshold | `minCleanupVal=1,000,000`; pre-input SR idle `0`; input `1,000,000`; post-input idle candidate `1,000,000` | No cleanup. |
| Lazy SR threshold +1 | `minCleanupVal=1,000,000`; pre-input SR idle `0`; input `1,000,001`; post-input idle candidate `1,000,001` | Cleanup triggered. |
| Lazy distinguishes idle from input | `minCleanupVal=1,000,000`; pre-input SR idle `500,000`; input `500,001`; post-input idle candidate `1,000,001` | Cleanup triggered even though the input by itself was below threshold; behavior fits a strict post-input-idle `> minCleanupVal` check, not an input-only check. |
| Lazy insufficient liquidity | `minCleanupVal=1,000,000`; JR idle `0`; available JR liquidity `0`; SR input `2,000,000` | Reverted `InsufficientRollover()` (`0xbbb27b39`). |

These observations support a **strictly greater-than** lazy trigger on post-input SR idle: `999,999` and `1,000,000` do not trigger; `1,000,001` does. Public partial cleanup above the threshold is observed, and a nonzero-free shortfall reverts. The exact public completed-value gate, `threshold−1/threshold/threshold+1` on the public path, and the full free-liquidity × cleanup-threshold × standard/backup matrix were not run. No general rule for empty-plan versus partial-plan outcomes is claimed.

## P3 — Perp permission and behavior matrix

The matrix below summarizes low-level calls on both live Perp proxies with `owner`, configured `controller`, and a random caller. “Controller-only set” is `recover`, `registerTranche`, `transferReservesTo`, `handleTransferReservesIn`, `mintTo`, `burnFrom`, and `logBalance`.

| Method | SR: owner / controller / random | JR: owner / controller / random |
|---|---|---|
| `updateController(address)` | success / `0x118cdaa7` / `0x118cdaa7` | success / `0x118cdaa7` / `0x118cdaa7` |
| Controller-only set | `0x7bf6a16f` / success / `0x7bf6a16f` | `0x7bf6a16f` / success / `0x7bf6a16f` |
| `primeApproval(address)`, `revokeApproval(address)` | empty-return failure for all three callers; no allowance change | `0x7bf6a16f` / success / `0x7bf6a16f` |
| `init(...)` | `InvalidInitialization()` (`0xf92ee8a9`) for all callers | `InvalidInitialization()` (`0xf92ee8a9`) for all callers |
| `maxTrancheCount()` | succeeds for all callers | succeeds for all callers |

The selector-empty SR approval calls do not establish an authorization failure: the calls returned `success=false`, `returnLength=0`, and left `cbBTC -> BondsManager` allowance at `0`. JR `primeApproval` set that allowance to `115792089237316195423570985008687907853269984665640564039457584007913129639935` (`2^256−1`); JR `revokeApproval` reset it to `0`.

Additional observations:

- Both proxies report `maxTrancheCount=50`. Starting with `3` registered tranche tokens, registering fake valid tranches grew the count to `50`; the next registration failed with `ReserveOverflow()` (`0x446c8cc9`), and count stayed `50`.
- Re-registering the current latest tranche as controller succeeded; `reserves().trancheTokens.length` remained `3` and the three-address array was unchanged for both SR and JR. Owner/random duplicate calls failed authorization before changing the array.
- An owner update changed the configured controller from `0x682F3a053B0260daD4EbEee3924B1618B330A200` to `0x0000000000000000000000000000000000000B0b`. The old controller's `mintTo` then failed with `0x7bf6a16f`; the new controller's succeeded.
- Metadata: SR `name="cbBTC Senior"`, `symbol="cbBTC-SR"`, `decimals=8`; JR `name="cbBTC Junior"`, `symbol="cbBTC-JR"`, `decimals=8`.
- `recover()` called by controller succeeded, but did not move `1,234` cbBTC from either Perp to owner/controller; both Perp balances remained `1,234`, and owner/controller deltas were `0`. A separate SR test seeded `777` USDC; after `recover()` the Perp still held `777`, with owner/controller deltas `0`. The tested token/recipient behavior is therefore unresolved beyond “these calls moved none of the seeded balances.”
- Topic `0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939` is `ReserveSynced(address,uint256)`. In a recorded transfer probe the event order was `ReserveSynced(cbBTC,0)` followed by `ReserveSynced(tranche,0)`. Full-tranche transfer probes moved `3,149,185,188,264` SR tranche units and `3,149,185,188,266` JR tranche units. The reported reserve arrays changed from three entries to two entries, but the surviving addresses were unexpected (`0x15a5...` / `0x...315e...` for SR and `0x73D5...` / `0x...315E...` for JR). No precise deregistration, ordering, or maturity-removal rule is inferred from that result.

## P4 — Fresh proxies and zero/genesis behavior

`test/Round4GenesisProbe.t.sol` deployed six fresh ERC-1967 proxies with implementation slots set to:

| Component | Implementation |
|---|---|
| Controller | `0x16e324bae2098317477129a5e71f770bff51f02a` |
| FeePolicy | `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900` |
| PerpSR | `0x96fc14b136300f9136c0d589ed7a787b66571574` |
| PerpJR | `0x8e9ed1138060434e56a5f7965017391c93631529` |
| BondIssuer | `0xe024bd4967185456df3de7d2365919b5fb89763b` |
| BondsManager | `0x427758ed7ba97d3602125f957cd9e6716fddaaC2` |

FeePolicy `init()`, PerpSR/PerpJR `init(string,string,address,address)`, and Controller `init(address,address,address)` all succeeded (empty return data). BondIssuer exposes init selector `0xf09a4016` (`init(address,address)`), but the available ABI does not provide parameter names/wiring; that initializer was not guessed. No BondsManager `init` selector was found in the available ABI investigation. Thus the two bond-layer proxies were deployed but not initialized.

`updateAumFeePerc(uint64,uint64)` on the fresh FeePolicy proxy:

| Both-side rate | Result |
|---:|---|
| `999999999999999999` | success |
| `1000000000000000000` | `InvalidPerc()` (`0xcdc62692`) |
| `1000000000000000001` | `InvalidPerc()` (`0xcdc62692`) |

This establishes the observed AUM-fee bound as strictly below `1e18`; it does not establish bounds on every other FeePolicy parameter.

With fresh PerpSR `totalSupply=0`, an approved `flashMint2(1000000,0,0,0)` returned panic selector `0x4e487b71`; supply remained `0`, reserve idle remained `0`, and registered tranche count remained `0`. No first-share amount or scaling formula was observed.

A zero-reserve/nonzero-supply state was constructible by controller-minting `100` SR units to `0xBEEF`: supply `100`, idle `0`, tranche count `0`. Calling `redeem2(100,0,0)` as `0xBEEF` failed with empty revert data; supply stayed `100`. The trace identifies a call to non-contract address `0x0000000000000000000000000000000000000000`, consistent with the fresh Controller/bond-layer wiring being incomplete. This does not establish the live Controller's fully wired zero-reserve redemption behavior. Tranche supply/claim zero paths and redemption to zero supply remain untested.

## P5 — Rebalance-window regression

Standalone Foundry regression: `/home/ubuntu/work/probes/test/Round4Probe.t.sol`. Each edge was run with an isolated timestamp and a sufficiently old `lastRebalanceTimestamp`. In the first row, the tested `windowStart` boundary is `1,794,506,400`; its preceding timestamp is the prior interval's `windowEnd−1`.

| Case | Timestamp | Getter `windowStart` / `windowEnd` before | `lastRebalanceTimestampSec` before | Result | Last timestamp after |
|---|---:|---:|---:|---|---:|
| boundary `windowStart−1` | `1,794,506,399` | `1,794,420,000 / 1,794,506,400` | `1,794,333,599` | success | `1,794,420,000` |
| `windowStart` | `1,794,506,400` | `1,794,506,400 / 1,794,592,800` | `1,794,333,600` | success | `1,794,506,400` |
| `windowEnd−1` | `1,794,592,799` | `1,794,506,400 / 1,794,592,800` | `1,794,419,999` | success | `1,794,506,400` |
| `windowEnd` | `1,794,592,800` | `1,794,592,800 / 1,794,679,200` | `1,794,420,000` | success | `1,794,592,800` |
| `windowEnd+1` | `1,794,592,801` | `1,794,592,800 / 1,794,679,200` | `1,794,420,001` | success | `1,794,592,800` |
| consecutive same-window call | `1,794,506,401` | `1,794,506,400 / 1,794,592,800` | first call set it to `1,794,506,400` | second call failed `LastRebalanceTooRecent()` (`0xa3b3f090`) | unchanged at `1,794,506,400` |

The observed getter interval rolls at the exact end: at `1,794,592,799`, the interval is `[1,794,506,400,1,794,592,800)`; at `1,794,592,800`, it is `[1,794,592,800,1,794,679,200)`. All tested boundary calls succeeded; only the repeat in the same interval was rejected.

## Verification and raw logs

| Probe | Verification result | Raw evidence |
|---|---|---|
| P1 synthetic selection and standard allocations | `testRound4BackupBondSelectionCandidates`: 1 passed, 0 failed. An arithmetic checker independently matched the standard deposit formula on all 6 direct cases. | `/home/ubuntu/work/probes/round4_backup_selection_final.log` |
| P1 shifted-price actual/policy comparisons | Existing forced-backup actual tests succeeded at both price directions; the direct comparisons and raw transfer logs are in the report's source log. | `/home/ubuntu/work/probes/review_round3_price_shift_actual_backup.log` |
| P2 public/lazy observations | Prior Round 3 logs; no new full-matrix test was run. | `/home/ubuntu/work/probes/review_round3_public_partial_65pct.log`; `/home/ubuntu/work/probes/review_round3_r4_final.log` |
| P3 Perp matrix | 6 passed, 0 failed. | `/home/ubuntu/work/probes/round4_perp_isolated.log` |
| P4 fresh proxies/genesis | 1 passed, 0 failed. | `/home/ubuntu/work/probes/round4_genesis_verified.log` |
| P5 rebalance edges | 1 passed, 0 failed. | `/home/ubuntu/work/probes/round4_rebalance_window_edges.log`; test file `/home/ubuntu/work/probes/test/Round4Probe.t.sol` |
