# External-review hypothesis probes

## Scope and status

This work used only local Base fork endpoints (`127.0.0.1:8545` at block
`54990962`, `127.0.0.1:8546` at block `53494912`). Chain ID was `8453`.
No real transaction was broadcast. No verified-source or frontend bundle was
read; no clean-room repo file was changed.

The consolidated probe suite passed 24/24 tests. Focused follow-up runs were
used where the consolidated terminal capture omitted individual test traces.
Several requested discriminators remain unresolved, particularly an
oracle-price-moved backup-plan case, a positive-protocol-fee owner withdrawal,
and exact/near-target value-cap crossings.

| H# | Claim | Verdict | Key raw numbers / discrimination |
|---|---|---|---|
| H1 | User ops lazily issue/roll over; SR flash mint does so but JR flash mint does not | **MISMATCH (composite)** | At `1794510001`, after the issue time and with `minMaturitySec=1`, SR-only `flashMint2(2000000,0,0,0)` succeeded, called `computePerpSrRolloverPlan`, and issued a new latest bond (`0xff7319…41b1`); SR supply rose `9581311974479→9729516061528`, with `849599618` fee perps at Controller. In the same timestamp/state, tranche-funded `mint2` called the issue path but reverted `UnexpectedAsset()` (`0x59102332`), so no registration persisted—H1(a) fails as stated. In fresh stale-bond forks at `1795114801`, SR flash mint succeeded and latest changed `0x93dc…77ca8→0x5a83…fd50`; JR-only flash mint also succeeded but latest remained `0x93dc…77ca8`. This supports H1(b,c). |
| H2 | Fees are computed per side, with independent SR/JR parameters | **EXACT** | Owner set distinct fee bases (SR ordinary/flash `10000000000000/100000000000000`, JR `20000000000000/200000000000000`). Both-sided flash mint called `computeOpFees` exactly twice with identical DR args `(subPre=1049678448816785329, subPost=1047013024833078884, vmPre=1000925651512358813, vmPost=999633771042668700)`, flags `(SR=true, flash=true)` and `(SR=false, flash=true)`; returned total percents `203820479010835` and `303820479010835` (difference exactly the configured `100000000000000`). `mint2` likewise made two calls with common DR args `(1047013022137826981,1044273831697564257,999633770473866938,1000296084682855953)`, flags `(true,false)/(false,false)`, and returned `142363368069254/152363368069254` (difference exactly `10000000000000`). |
| H3 | Collected fee settlement burns/moves SR/JR tokens and sends cbBTC fees to JR | **MISMATCH (composite)** | Successful rebalance with protocol max `0`: collected SR/JR `7693309/18187423` were cleared by burns; supplies fell exactly `9655414018003→9655406324694` and `34025998467149→34025980279726`. The SR-fee-to-JR-reserve hypothesis is false for this case; both perp fee balances were burned. A `1989` cbBTC fee was transferred Controller→perpJR (`ReserveSynced`); cbBTC Controller/collected balances then fell `1989→0`, matching the JR-routing claim. Separate JR-input `flashMint2` and `mint2` did not settle the existing fee balances: the former left SR fee `7693309` and increased JR fee `18187423→138486510`; the latter ended with SR/JR fees `12670393/23898160`. |
| H3b | Protocol-fee balances accrue only the protocol share; pull authorization and amount are restricted | **UNRESOLVED (partial match)** | `updateProtocolFeeConfig(50000000000000,0x…bEEF)` set a nonzero maximum and collector. SR Controller balance `153673769438 = collected 153488514330 + protocol 185255108`; JR balance `363293569023 = collected 362855615364 + protocol 437953659`. The configured collector successfully pulled exactly `185255108` SR; collected fees remained. Random caller failed on JR with raw selector `0x7bf6a16f`. The owner call was only attempted for cbBTC with amount `0` and failed with the same selector, so owner authorization for a positive protocol balance and attempts to over-withdraw remain unresolved. |
| H4 | AUM fee uses gross-up rather than `floor(S*p/WAD)`; compare 10% and 5% and 1d/7d | **EXACT: gross-up, no elapsed-time scaling observed** | For `S_SR=9581311974479`, `S_JR=33850817003440`: at `p=1e17`, emitted `1064590219386/3761201889271`; at `p=5e16`, emitted `504279577604/1781621947549`. Each equals `floor(S*p/(1e18-p))`, not `floor(S*p/1e18)`. Both 1d and 7d tests emitted the same amounts at each rate. |
| H5 | JR redemption just above available liquidity reports `InsufficientLiquidity`; fee>=1e18 is a distinct cause | **EXACT** | Low-availability case: `available=1000`, `reserveValue=386465740`, `supply=33850817003440`, `perpIn=87678323`, gross floor `1001`, and fee `1851952958726162 < 1e18`; reverted `InsufficientLiquidity()` (`0xbb55fd27`, from `cast sig`). Separate within-liquidity case had gross floor `1`, configured fee `1001851303674000670 >= 1e18`, and reverted `OpDisabled()` (`0x07380a2e`). |
| H6 | `rebalance()` accepts exact window edges according to `windowStart/windowEnd` | **EXACT for observed calls; strict endpoint rule unresolved** | With `freq=86400`, `offset=64800`, `length=86400`, all five fresh-snapshot calls succeeded: `1794333599` (window `[1794247200,1794333600]`), `1794333600` (`[1794333600,1794420000]`), `1794419999` (same), `1794420000` (`[1794420000,1794506400]`), and `1794420001` (same). Since window length equals frequency, the exact end timestamp begins the next window; these calls do not distinguish a strict from inclusive endpoint predicate. |
| H7 | Public/lazy rollover shortfall rules differ by entry point | **UNRESOLVED (one lazy-SR claim mismatched)** | With `minCleanupVal=100000000`, public `rollover()` at the baseline snapshot reverted `InsufficientRollover()` (`0xbbb27b39`); that snapshot had no stale row, so it does not establish a cleanup-value boundary. At `1795114801`, an SR-input lazy flash mint of `2000000` succeeded with that threshold and left exactly `2000000` SR idle rather than reverting; thus the “must cover input or revert” claim is a **MISMATCH**. Partial public rollover above threshold and JR→SR rebalance lazy shortfall behavior remain untested. |
| H8 | Backup plan cap is `min(free,2*S)` vs a senior-value-ratio-derived cap | **UNRESOLVED** | Alternative A, `min(free,2*totalStaleVal)`, matched 23/23 earlier policy cases. In the JR-limited case, standard needed `83656486` while available was `83368325`; plan selected backup latest deposit `6135343`. No oracle price move was made in this pass, so the ratio-based alternative and its rounding were not discriminated from A. |
| H9 | `redeem2` burns full perp input and returns each reserve asset pro rata to net perp supply | **EXACT in two fee-bearing cases** | Case 1 inputs SR/JR `18753357487/21517501826`, fee percents `10000000000000/20000000000000`; fees `187533/430350`, net `18753169954/21517071476`. Supply reductions exactly equaled net inputs. Returned SR tranches `6213724385,6109208880,6614311071`; JR underlying/tranches `172389,2023318042,1989285618,2153757409`, each equal to `floor(reserveBalance*netPerp/preSupply)`. Case 2 inputs were each `+1`; same fee integers, net inputs each `+1`, and all basket floors matched, including the JR first-tranche one-unit increase to `2023318043`. Controller fee balances increased by the fee amounts. |
| H10 | Above-cap corrective mint crossing `subDR=1` reverts, while corrective non-crossing mint can pass | **EXACT for tested crossing distinction; exact-boundary unresolved** | `TwoFactorValueCap.t.sol` uses `ONE=1e18`, `SMALL_MINT=100000`, and `OVERSHOOT_MINT=4000000`. With cap disabled, the 4,000,000-unit corrective control crosses the target; restoring capped state and repeating it reverts `ValueCapExceeded()` (`0x8f61fa9a`). The 100,000-unit corrective senior mint succeeds. Exact/near-target crossing and post-control DR integers were not captured. |
| H11 | Proxy implementations/code hashes differ between blocks 54990962 and 53494912 | **MISMATCH: no differences observed** | Chain ID `8453`; all proxy implementation slots and proxy/implementation extcodehashes were identical at both blocks for Controller, FeePolicy, BondIssuer, BondsManager, perpSR, perpJR, and JuniorVault. Balancer is direct code (zero EIP-1967 slot). Full values are in `reviewer_fork_versions.log`. |

## Derived formulas and hypotheses

1. Junior reserve floor / availability matched the prior threshold samples:
   `reserved=max(floor(reserveValue*perc/1e18),absFloor)`,
   `available=max(idle-reserved,0)`.
2. Redemption fee tokens are floored:
   `feePerp=floor(perpIn*feePerc/1e18)`, `netPerp=perpIn-feePerp`;
   each basket element matched `floor(reserveBalance*netPerp/preSupply)` in
   both H9 cases. Supply deltas equal `-netPerp`, and Controller fee balances
   increase by `feePerp`.
3. AUM minting matched
   `floor(totalSupply*aumFeePerc/(1e18-aumFeePerc))` for both sides at 10%
   and 5%; tested 1d/7d amounts were identical. The simpler
   `floor(totalSupply*aumFeePerc/1e18)` mismatches each captured amount.
4. For JR redemption, gross underlying `1001 > available 1000` with fee
   `1851952958726162 < 1e18` reverted `InsufficientLiquidity()`; fee
   `1001851303674000670 >= 1e18` with gross output `1` reverted
   `OpDisabled()`.
5. The prior rollover backup cases matched `min(free,2*totalStaleVal)`,
   including the JR-limited case; the oracle-price/ratio alternative remains
   undistinguished.
6. The value-cap tests distinguish a corrective mint that stays on the
   permitted side of `subDR=1` from a tested amount that crosses it. Exact
   and near-target boundaries remain open.

## Selected raw OBS records and calculations

These are compact field selections from the full JSON `OBS:` records in the
listed logs; omitted fields (including complete reserve arrays and decoded
events) remain in those files.

```text
OBS:{"kind":"flashMint2_input","label":"review_lazy_sr_issue_only_flash_mint","timestamp":1794510001,"srUnderlying":2000000,"jrUnderlying":0}
OBS:{"kind":"latest_bond","label":"review_lazy_sr_issue_only_flash_mint_after","bondID":"0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b","underlyingBal":0}
OBS:{"kind":"metrics","label":"review_lazy_sr_issue_only_flash_mint_after","minMaturitySec":1,"minCleanupVal":1000000}
OBS:{"kind":"token_balances","label":"review_lazy_sr_issue_only_flash_mint_after","perpSrSupply":9729516061528,"perpSrControllerBalance":849599618,"perpSrCollectedFeeBal":849599618}
OBS:{"kind":"flashMint2_input","label":"review_lazy_sr_stale_flash_mint","timestamp":1795114801,"srUnderlying":2000000,"jrUnderlying":0}
OBS:{"kind":"latest_bond","label":"review_lazy_sr_stale_flash_mint_after","bondID":"0x5a83ee1f5b5b29d9c5adfc39fbd15a9b3d5aec0d793fc824a97b3bed97d9fd50"}
OBS:{"kind":"flashMint2_input","label":"review_lazy_jr_stale_flash_mint","timestamp":1795114801,"srUnderlying":0,"jrUnderlying":2000000}
OBS:{"kind":"latest_bond","label":"review_lazy_jr_stale_flash_mint_after","bondID":"0x93dcba573477147233c33c344a994ff99eedbe3ac9c31c2c5198f72add177ca8"}

OBS:{"kind":"token_balances","label":"review_cbbtc_fee_seed_redeem_after","cbBtcControllerBalance":1989,"cbBtcCollectedFeeBal":1989,"perpSrControllerBalance":7693309,"perpSrCollectedFeeBal":7693309,"perpJrControllerBalance":18187423,"perpJrCollectedFeeBal":18187423}
OBS:{"kind":"event","name":"Transfer","from":"0x682F3a053B0260daD4EbEee3924B1618B330A200","to":"0x8cd04668292dC32F519972495C179E4f02C0e8AB","value":1989}
OBS:{"kind":"system_state","label":"review_cbbtc_fee_after_rebalance","perpSrSupply":9581311974479,"perpJrSupply":33850817003440}
OBS:{"kind":"token_balances","label":"review_cbbtc_fee_after_rebalance","cbBtcControllerBalance":0,"cbBtcCollectedFeeBal":0,"perpSrControllerBalance":0,"perpSrCollectedFeeBal":0,"perpJrControllerBalance":0,"perpJrCollectedFeeBal":0}

OBS:{"kind":"token_balances","label":"review_protocol_split_seed_after","perpSrControllerBalance":153673769438,"perpSrCollectedFeeBal":153488514330,"perpSrProtocolFeeBals":185255108,"perpJrControllerBalance":363293569023,"perpJrCollectedFeeBal":362855615364,"perpJrProtocolFeeBals":437953659}
CALC: 153673769438-185255108=153488514330; 363293569023-437953659=362855615364
CALC: collector pull of SR 185255108 succeeded; random JR pull and owner cbBTC-zero pull reverted 0x7bf6a16f

OBS:{"kind":"review_jr_liquidity_case","available":1000,"reserveValue":386465740,"supply":33850817003440,"perpIn":87678323,"grossUnderlyingFloor":1001}
CALC: trace feePerc=1851952958726162 (<1e18); failed call selector=0xbb55fd27
OBS:{"kind":"review_jr_high_fee_case","perpIn":100000,"grossUnderlyingFloor":1,"available":267684958}
CALC: trace feePerc=1001851303674000670 (>=1e18); failed call selector=0x07380a2e
OBS:{"kind":"review_aum_grossup_case","elapsedSec":86400,"rateSr":100000000000000000,"rateJr":100000000000000000}
OBS:{"kind":"event","name":"AumFees","token":"0x4be28E7597A928835245a10E9161E0c44687b70b","amount":1064590219386}
OBS:{"kind":"event","name":"AumFees","token":"0x8cd04668292dC32F519972495C179E4f02C0e8AB","amount":3761201889271}
OBS:{"kind":"review_aum_grossup_case","elapsedSec":604800,"rateSr":50000000000000000,"rateJr":50000000000000000}
OBS:{"kind":"event","name":"AumFees","token":"0x4be28E7597A928835245a10E9161E0c44687b70b","amount":504279577604}
OBS:{"kind":"event","name":"AumFees","token":"0x8cd04668292dC32F519972495C179E4f02C0e8AB","amount":1781621947549}

OBS:{"kind":"review_rebalance_edge","label":"window_start_minus_1","timestamp":1794333599,"windowStart":1794247200,"windowEnd":1794333600}
OBS:{"kind":"call","label":"review_rebalance_window_start_minus_1","success":true}
OBS:{"kind":"review_rebalance_edge","label":"window_start","timestamp":1794333600,"windowStart":1794333600,"windowEnd":1794420000}
OBS:{"kind":"call","label":"review_rebalance_window_start","success":true}
OBS:{"kind":"review_rebalance_edge","label":"window_end_minus_1","timestamp":1794419999,"windowStart":1794333600,"windowEnd":1794420000}
OBS:{"kind":"call","label":"review_rebalance_window_end_minus_1","success":true}
OBS:{"kind":"review_rebalance_edge","label":"window_end","timestamp":1794420000,"windowStart":1794420000,"windowEnd":1794506400}
OBS:{"kind":"call","label":"review_rebalance_window_end","success":true}
OBS:{"kind":"review_rebalance_edge","label":"window_end_plus_1","timestamp":1794420001,"windowStart":1794420000,"windowEnd":1794506400}
OBS:{"kind":"call","label":"review_rebalance_window_end_plus_1","success":true}

OBS:{"kind":"call","label":"review_rollover_raise_min_cleanup","success":true,"minCleanupVal":100000000}
OBS:{"kind":"call","label":"review_rollover_high_cleanup","timestamp":1794188568,"success":false,"selector":"0xbbb27b39"}
OBS:{"kind":"flashMint2_input","label":"review_sr_lazy_high_cleanup_flash_mint","timestamp":1795114801,"srUnderlying":2000000,"minCleanupVal":100000000}
OBS:{"kind":"reserve_data","label":"review_sr_lazy_high_cleanup_after","side":"perpSr","underlyingBal":2000000}
```

H9 raw inputs/outputs and full supply snapshots are in
`review_controller_claims_followup_full.log`. The two `redeem2_return`
records were:

```text
OBS:{"kind":"redeem2_return","srUnderlying":0,"srTranches":[{"token":"0x2b97045571Ec78aE1010Df47b3e275eCdAE53300","amount":6213724385},{"token":"0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B","amount":6109208880},{"token":"0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68","amount":6614311071}],"jrUnderlying":172389,"jrTranches":[{"token":"0x0BC26651B2Fbc4230F5C34a9eD186c28aEA48414","amount":2023318042},{"token":"0xF012e0Fc76306aE1374B577483Cf6b79dE8cf9b1","amount":1989285618},{"token":"0x73D500c3fE50c320b6E0db0DB3c34Ff9A2aF3582","amount":2153757409}],"perpSrFeePerc":{"total":10000000000000,"protocol":0},"perpJrFeePerc":{"total":20000000000000,"protocol":0}}
OBS:{"kind":"redeem2_return","srUnderlying":0,"srTranches":[{"token":"0x2b97045571Ec78aE1010Df47b3e275eCdAE53300","amount":6213724385},{"token":"0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B","amount":6109208880},{"token":"0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68","amount":6614311071}],"jrUnderlying":172389,"jrTranches":[{"token":"0x0BC26651B2Fbc4230F5C34a9eD186c28aEA48414","amount":2023318043},{"token":"0xF012e0Fc76306aE1374B577483Cf6b79dE8cf9b1","amount":1989285618},{"token":"0x73D500c3fE50c320b6E0db0DB3c34Ff9A2aF3582","amount":2153757409}],"perpSrFeePerc":{"total":10000000000000,"protocol":0},"perpJrFeePerc":{"total":20000000000000,"protocol":0}}
```

For case 1,
`18753357487*10000000000000/1e18` floors to `187533`, and
`21517501826*20000000000000/1e18` floors to `430350`; net amounts are
`18753169954/21517071476`. Case 2 inputs were each one larger and yielded the
same fee integers, with net amounts `18753169955/21517071477`. All six tranche
outputs and the junior idle-underlying output matched their independent
pre-supply floors exactly.

## Raw evidence and test results

- Prior Controller raw traces: `controller_probe2_traces.log`,
  `controller_probe2_fee_lifecycle.log`, `controller_probe2_followup_final.log`,
  `controller_probe2_controls.log`, `controller_probe2_aum.log`,
  `controller_probe2_sr_payer.log`, `lazy_flashmint.log`,
  `floor_boundary.log`.
- New positive-collected-fee rebalance snapshots: `review_collected_rebalance.log`.
- Follow-up lazy-issue trace: `review_lazy_issue_only_threshold1.log`.
- Tranche-funded `mint2` after issue-window attempt:
  `review_mint2_after_issue_full.log`.
- SR-vs-JR stale-bond lazy-operation comparison:
  `review_lazy_stale_comparison.log`.
- Follow-up fee settlement traces, including JR-input flash mint/mint2 and
  cbBTC fee rebalance: `review_fee_settlement_observations.log`.
- Protocol fee split and caller probes: `review_protocol_permissions_observations.log`.
- AUM 5% / 7d trace: `review_aum_5pct_7d_observations.log`.
- JR redemption boundary/error traces: `review_jr_liquidity_followup.log`.
- Consolidated 24-test output: `review_controller_claims_followup_full.log`.
- Prior rollover policy cases and traces: `ROLLOVER_PROBES.md`,
  `rollover_allocation_cases.log`, `rollover_direct_functions.log`,
  `rollover_first_actual_trace.log`, `rollover_second_actual_trace.log`.
- Fork metadata values and hashes: `reviewer_fork_versions.log`.
- Specified regression suite summaries: `reviewer_regression_tests.log`.
- Requested test results against local Anvil (`BASE_RPC_URL=http://127.0.0.1:8545`):
  - `TwoFactorValueCap.t.sol`: **17 passed, 0 failed, 0 skipped**.
  - `TwoFactorDirectBasket.t.sol`: **4 passed, 0 failed, 0 skipped**.
- New H3 positive-collected-fee rebalance test:
  `testReviewCollectedFeesAcrossSuccessfulRebalance`: **1 passed, 0 failed,
  0 skipped**; raw before/after integers are in `review_collected_rebalance.log`.
- Consolidated `testReview*` probe run: **24 passed, 0 failed, 0 skipped**.
- Focused follow-up captures: H1 issue-only **1 passed** and stale SR/JR
  comparison **2 passed**; H3 settlement **3 passed**; H3b **1 passed**; H4
  5%/7d **1 passed**; H5 liquidity cases **2 passed**. All had 0 failures;
  raw output paths are listed above.

## Important test setup note

The first test invocation omitted `BASE_RPC_URL` and both suites failed during
`setUp()` with `vm.envString: environment variable "BASE_RPC_URL" not found`.
Rerunning with that variable explicitly pointed at local Anvil yielded the
passing results above. No direct public RPC transaction was used.

## Round 2

All new stateful calls below used the already-running local Base Anvil fork at
`http://127.0.0.1:8545` (`BASE_RPC_URL` set to that URL). No clean-room
repository files were changed, and no real transaction was broadcast.

| ID | Claim tested | Verdict | Key result |
|---|---|---|---|
| R1 | `mint2` lazily issues/registers a bond after the issue window; accepted tranche scope | **PARTIAL / MISMATCH** | Latest registered pair was accepted; tested registered non-latest pair reverted `UnexpectedAsset()` (`0x59102332`). Across the issue window, `mint2` entered `BondIssuer.issue()` / `BondsManager.createBond`, created tranche contracts and attempted both `registerTranche` calls, then reverted `UnexpectedAsset()`. The transaction rollback left no durable new bond registration. |
| R2 | Rebalance fee settlement equals a reserve transfer, with distinctive SR fee; protocol fees and zero-transfer behavior | **EXACT for tested paths** | A distinctive SR fee of `3,705,102,176` perp tokens was accumulated (`3,701,397,074` collected + `3,705,102` protocol). `Rebalance(24,188,false)` and `computeSystemRebalancePlan` both specified `24,188` underlying JR→SR, no tranche transfers. Afterward SR supply fell exactly by collected fees; `protocolFeeBals=3,705,102` and Controller balance remained `3,705,102`. A mocked zero-value rebalance succeeded with `Rebalance(0,false)`, zero plan, and still settled/burned the collected SR fees. |
| R3 | Owner / collector `pullProtocolFees` authorization and withdrawal bounds | **EXACT for tested callers** | Signature: `pullProtocolFees(address,address,uint256)`. Owner attempting to pull positive SR protocol balance `185,255,108` reverted `0x7bf6a16f`. Collector over-withdrawal of JR balance `437,953,659 + 1` reverted Solidity panic `0x4e487b71` (code `0x11`). Collector pulled exactly `437,953,659`; JR `protocolFeeBals` decreased to zero. |
| R4 | Public and lazy rollover shortfalls, and JR-payer rebalance with insufficient free liquidity | **PARTIAL / UNRESOLVED** | Public `rollover()` with `minCleanupVal=100,000,000`, JR free liquidity `0`, reverted `InsufficientRollover()` (`0xbbb27b39`). With `minCleanupVal=10,000,000` and free liquidity `20,000,000`, rollover succeeded and removed the stale row; it was not a partial-cleanup discriminator because additional unlocked liquidity may have let it complete. SR `flashMint2(2,000,000,0)` with cleanup threshold `100,000,000` left the input idle and stale rows unchanged; with threshold `1,000,000`, it triggered lazy rollover and the stale row was removed. JR-payer rebalance with reserved JR idle `271,549,615`, available liquidity `0`, and `minCleanupVal=1,000,000` succeeded with `Rebalance(28,296,false)` and an underlying-only `28,296` plan; no `computePerpSrRolloverPlan` or `BondDeposit` call/event appeared in that rebalance trace. A public partial rollover with completable value between cleanup threshold and full stale value, and SR input larger than actual completable rollover liquidity, remain untested. |
| R5 | Backup cap discrimination at shifted oracle prices and allocation re-check | **UNRESOLVED** | No −30%/+30% fresh Chainlink mock was run in this round, so `min(free,2*S)` remains indistinguishable from the senior-ratio alternative under the requested price shift. Existing 23-case evidence in `ROLLOVER_PROBES.md` is not a substitute for this discriminator. |
| R6 | Exact value-cap crossing boundary by binary search, including opposite-side construction | **UNRESOLVED** | No max-success/min-fail binary search or mirrored JR-only boundary was run in this round. Existing crossing probes do not establish the exact post-`subDR=1e18` boundary. |

### Round 2 raw evidence

- R1 registered-tranche and issue-window traces: `review_round2_r1_mint2_registered.log`.
- R2 distinctive-fee settlement / plan / protocol split: `review_round2_r2_rebalance_protocol.log`.
- R2 zero-value rebalance settlement: `review_round2_r2_rebalance.log`.
- R3 owner, collector over-withdrawal and exact withdrawal: `review_round2_r3_protocol_fees.log`.
- R4 public rollover shortfall (including the 20m-free follow-up): `review_round2_r4_public_shortfall.log`.
- R4 SR lazy cleanup-threshold cases: `review_round2_r4_rollover_shortfall.log`.
- R4 JR-payer rebalance with no free JR liquidity: `review_round2_r4_jr_payer.log`.

Focused Foundry results: R2 settlement, protocol preservation, and zero-value
tests **3/3 passed**; R3 protocol-fee withdrawal test **1/1 passed**; R4 public
shortfall, SR lazy-threshold and JR-payer rebalance tests **4/4 passed**. These
are test pass counts; revert selectors and successful state transitions are
separately recorded above and in the raw logs.

## Round 3

All new stateful calls used the already-running local Base Anvil fork at
`http://127.0.0.1:8545` (`BASE_RPC_URL` set to that URL). The probes reused
fork block `54990962` and rollover timestamp `1794510001`. No clean-room
repository files were changed, and no real transaction was broadcast.

| ID | Claim tested | Verdict | Key result |
|---|---|---|---|
| R4 | Public rollover shortfalls and partial cleanup; SR lazy-rollover threshold and insufficient-liquidity behavior | **EXACT for tested trigger cases; PARTIAL for the below-cleanup public case** | With `minCleanupVal=10,000,000`, a public rollover succeeded but left stale SR value `14,656,562` from `41,875,890` (partial removal `27,219,328`). With `minCleanupVal=20,000,000` and nonzero JR free liquidity `10,000,000`, rollover reverted `InsufficientRollover()` (`0xbbb27b39`); exact plan-completable value was not independently recorded. SR lazy rollover follows post-input idle: at a `1,000,000` threshold, idle `999,999` and `1,000,000` did not clear the stale row, while `1,000,001` did; preexisting idle `500,000` plus input `500,001` also triggered. An SR input of `2,000,000` with zero JR liquidity and zero stale-JR balance reverted `InsufficientRollover()`. |
| R5 | Shifted-price backup cap alternatives, actual backup execution, and standard allocation | **EXACT for the tested pure backup policy, actual backup cases, and standard allocations** | At −30% price, fresh latest SR `valueRatio=714285714285741559`, stale value `S=59,822,700`; at +30%, ratio `384615384615416246`, `S=32,212,223`. Pure backup output follows `min(free, floor(S*1e18/selectedBackupBond.valueRatio))`, not `min(free,2*S)` or the latest-row-ratio formula: at +30% it was `77,626,947` using selected bond ratio `414961863727109880` (floor; ceil is `77,626,948`), versus A `64,424,446` and latest-ratio B/B′ `83,751,779` / `83,751,780`. Low-free executions (`free=3,000,000`) selected the backup plan and succeeded at both prices; top-level plan and executed deposits matched `computeBackupRolloverPolicy(state,free)`. Standard allocations and actual standard rollovers matched the average-target / per-bond rule at both prices. |
| R6 | Largest successful / smallest failing corrective SR and mirrored JR `flashMint2` amounts above the value cap | **EXACT for adjacent input boundary; equality semantics UNRESOLVED** | SR correction: largest success `6,423,365`, post-`subDR=1000000004321734011`; smallest fail `6,423,366`, `ValueCapExceeded()` (`0x8f61fa9a`), with cap-disabled would-be post `999999996953745745`. Mirrored JR correction: largest success `10,184,377`, post `999999999636004270`; smallest fail `10,184,378`, same selector, with cap-disabled would-be post `1000000002157117871`. Neither boundary produced exactly `1e18`, so whether exact equality is accepted remains open. |

### R4 details

- For the partial public rollover, the stale JR tranche balance was set to 65%
  (`2,036,806,008,592` units; marked value `22,982,109`) and JR idle was
  `30,000,000`. `rollover()` redeemed `2,036,806,008,587` SR and
  `2,036,806,008,591` JR tranche units for `50,201,438` underlying. It
  deposited `4,167,317` into the earlier fresh bond and `50,209,397` into the
  latest bond. The stale SR row remained, falling from value `41,875,890` to
  `14,656,562`. JR idle ended at `25,824,724`.
- In the nonzero-free below-cleanup case, `minCleanupVal=20,000,000`, JR free
  liquidity was `10,000,000`, and the stale JR balance was reduced to 10%
  (marked value `3,535,709`); `rollover()` reverted `InsufficientRollover()`
  (`0xbbb27b39`). This establishes the observed revert with nonzero free
  liquidity but not an independently measured exact completable-plan value.
- Lazy threshold probes used `minCleanupVal=1,000,000`. Inputs
  `999,999` and `1,000,000` left the stale row present; `1,000,001` cleared it.
  With `500,000` SR idle before input, an input of `500,001` (below threshold)
  also cleared the row because post-input idle was `1,000,001`. This
  discriminates post-input idle from input amount and supports a strict
  `postInputIdle > minCleanupVal` trigger.
- With `minCleanupVal=1,000,000`, JR idle/free liquidity zero, stale JR
  tranche balance zero, and SR input `2,000,000`, `flashMint2` reverted
  `InsufficientRollover()` (`0xbbb27b39`) and reserve state remained unchanged.
- The earlier JR-payer rebalance case remains in
  `review_round2_r4_jr_payer.log`: available JR liquidity was zero; rebalance
  succeeded with an underlying-only `28,296` plan and no rollover-plan or
  `BondDeposit` call in its trace.

### R5 price-shift evidence and formulas

The cbBTC/USD feed was mocked with fresh `updatedAt=block.timestamp` values;
the sequencer feed was up and beyond its grace period, and the cached oracle
was refreshed. The feed answers were `5,238,058,452,057` (−30%) and
`9,727,822,839,534` (+30%). The fresh latest senior ratios moved from the
unshifted `0.5` to `0.714285714285741559` and `0.384615384615416246`,
respectively.

| Price case | `S` | Free | A = `min(free,2*S)` | Latest-ratio B floor / ceil | Selected backup bond ratio | Balancer backup deploy |
|---|---:|---:|---:|---:|---:|---:|
| −30% | 59,822,700 | 268,239,096 | 119,645,400 | 83,751,779 / 83,751,780 | latest bond `0xff731929…`, `714285714285741559` | 83,751,779 |
| +30% | 32,212,223 | 267,386,576 | 64,424,446 | 83,751,779 / 83,751,780 | bond `0x342b85e9…`, `414961863727109880` | 77,626,947 |

At −30%, the selected backup row is the latest row, so the latest-ratio floor
matches while ceil is one unit higher. At +30%, the selected row is the
previous fresh bond, not the latest: its-ratio floor `77,626,947` exactly
matches Balancer, and its-ratio ceil is `77,626,948`. The latest-ratio floor
is `6,124,832` higher than Balancer; A is `13,202,501` lower. This
discriminates both the `2*S` alternative and use of the latest ratio.

For actual backup execution, JR free liquidity was set to `3,000,000` while
the stale JR pair remained intact. Combined free plus unlocked liquidity was
`80,232,982`, below standard deploy (`83,656,487` at −30%;
`83,656,486` at +30%). `computePerpSrRolloverPlan` matched
`computeBackupRolloverPolicy(state,free)` exactly (and differed from the
standard plan). At −30%, it deposited `3,000,000` to the latest bond and
reported `underlyingValRolled=2,142,857`; `rollover()` succeeded, redeeming
`112,244,091,884` of each stale tranche and returning `2,766,495` underlying.
At +30%, it deposited `3,000,000` to bond `0x342b85e9…` and reported
`underlyingValRolled=1,244,885`; `rollover()` succeeded, redeeming
`121,100,196,511` of each stale tranche and returning `2,984,773` underlying.
The cap alternatives are all free-limited at this `3,000,000` budget; the
high-free pure-function rows above provide the discrimination.

The standard-policy allocations also matched the average-target rule and
`ceil(topUp*1e18/valueRatio)` at both prices:

- At −30%, average target `61,570,900`, selected target `64,768,768`;
  the earlier fresh bond top-up `4,647,536` mapped to `6,411,257`, and the
  latest top-up `55,175,164` mapped to `77,245,230`. Both matched the plan
  and executed `BondDeposit` events.
- At +30%, average target `33,153,562`, selected target `34,875,491`;
  the earlier fresh bond top-up `2,502,520` mapped to `6,411,258`, and the
  latest top-up `29,709,703` mapped to `77,245,228`. Both matched the plan
  and executed events.

### R6 boundary evidence

In the SR-correction search, `6,423,365` was the largest successful input and
left `subDR=1,000,000,004,321,734,011`; `6,423,366` failed with
`ValueCapExceeded()` (`0x8f61fa9a`). Re-running that adjacent input with the
cap disabled yielded would-be `subDR=999,999,996,953,745,745`.

For the mirrored JR-only correction, the constructed below-one state started
at `subDR=974,324,028,266,897,443`. Input `10,184,377` succeeded with
`subDR=999,999,999,636,004,270`; `10,184,378` failed with
`ValueCapExceeded()`, while the cap-disabled would-be post was
`1,000,000,002,157,117,871`. The adjacent boundaries support a no-crossing
rule in both directions, but no attempted amount produced exactly `1e18`;
strict versus inclusive equality remains unresolved.

### Round 3 raw evidence and test results

- R4 public partial / nonzero-free cases and lazy threshold / insufficient
  liquidity probes: `review_round3_r4_final.log`,
  `review_round3_public_partial_65pct.log`.
- R5 final shifted-price, cap, standard-allocation and successful actual
  backup rollover traces: `review_round3_price_shift_actual_backup.log`.
- R5 earlier price-shift attempts are retained for completeness:
  `review_round3_price_shift_discriminating.log` and
  `review_round3_price_shift_backup_final.log`.
- R6 SR and mirrored JR binary searches: `review_round3_valuecap_mirror.log`.
- Prior JR-payer no-rollover rebalance evidence:
  `review_round2_r4_jr_payer.log`.

Focused Foundry tests passed: R4 public/lazy cases **3/3** in
`review_round3_r4_final.log`, the R4 65%-JR partial case **1/1** in
`review_round3_public_partial_65pct.log`, R5 shifted-price and actual backup
cases **1/1** in `review_round3_price_shift_actual_backup.log`, and R6
value-cap boundary searches **1/1** in `review_round3_valuecap_mirror.log`.
