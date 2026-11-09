# Round 5 Black-Box Probes

Repro command: `cd /home/ubuntu/work/probes && BASE_RPC_URL=http://127.0.0.1:8545 forge test --offline --via-ir --fork-url http://127.0.0.1:8545 --match-path test/Round5Probe.t.sol -vvvv`

All Round 5 Foundry cases used the local Base Anvil fork at `http://127.0.0.1:8545`, chain ID `8453`, fork block `54,990,962`. No verified source or frontend bundle was accessed, no real-chain transaction was sent, and no clean-room repository file was changed. Raw logs are listed below; the SHA-256 manifest is `/home/ubuntu/work/probes/LOG_SHA256SUMS.txt`.

## Summary

| ID | Claim / area | Verdict | Key result | Evidence |
|---|---|---|---|---|
| Q1 | Backup bond selection with independently issued open prices | **PARTIAL / MISMATCH on near-tie** | Three open prices yielded fresh SR ratios `0.4e18`, `0.5e18`, `0.625e18`. Backup policy and actual rollover selected the exact-`0.5e18` bond. The winner survived candidate reversal, maturity permutation, and existing-value permutation (`4/4` direct cases; actual execution `1/1`). A near-equidistant pair contradicted strict integer `argmin(abs(vr−0.5e18))`; an exact synthetic `0.4e18`/`0.6e18` tie chose the upper ratio in both orders (`2/2`). | `round5_q1_independent_prices_exact_tie.log` |
| Q2 | Public and lazy rollover partial/revert boundary | **PARTIAL (prior evidence only)** | Earlier probes observed public partial completion `27,219,328` from stale value `41,875,890`; the lazy SR threshold was strictly above `1,000,000` post-input idle (`999,999` and `1,000,000` did not trigger; `1,000,001` did). Round 5 did not binary-search both standard and backup branches. | `review_round3_public_partial_65pct.log`; `review_round3_r4_final.log` |
| Q3 | Perp `recover()` asset behavior | **PARTIAL** | `recover()` selector `0xce746024` succeeded on both Perps, but underlying `101`, registered tranche `202`, unregistered USDC `303`, and own Perp token `404` remained unchanged. Six emitted events per call were `ReserveSynced` events. No complete overload list was available from the supplied ABI metadata. | `round5_q3_recover.log` |
| Q4 | Tranche removal and reserve-array order | **UNRESOLVED** | `reserves()` contained two contract-backed tranche addresses plus a no-code sentinel per Perp. Zero/partial/full transfer calls succeeded, but the observed arrays changed in ways that do not distinguish stable-remove from swap-pop; the selected “B” was already absent from the array before the full-transfer call. A mocked maturity upkeep failed, and a newly issued tranche did not appear in the array. | `round5_q4_reserve_order_partial_live.log` |
| Q5 | Genesis initialization and first-supply replay | **NOT RUN** | No deployment/init transaction metadata was collected and no pre-init fork/replay was performed. | — |
| Q6 | `upkeep()` issuance, maturity, multiple maturity, and cleanup matrix | **PARTIAL (prior evidence only)** | Earlier logs contain upkeep after an issue window and maturity, including a `BondMature` event, but the requested full before/at/after and idle-threshold matrix was not run in Round 5. | `review_round3_r4_final.log` |
| Q7 | Extreme valuation and zero claims/supply | **NOT RUN** | No extreme-oracle or zero-supply valuation case was constructed in Round 5. | — |
| Q8 | Slippage minima for flash and non-flash mint/redeem | **NOT RUN** | No actual−1 / actual / actual+1 matrix or two-sided single-leg failure case was run. | — |
| Q9 | Exact `valueCap` equality | **NOT RUN** | No state with post-op `subDR == 1e18` was created. Earlier adjacent-boundary work did not hit exact equality. | `review_round3_valuecap_mirror.log` (prior context only) |
| Q10 | Error priority: `totalFee >= 1e18` plus JR liquidity shortfall | **NOT RUN** | The combined state was not constructed. | — |

The consolidated Round 5 Foundry run passed **3/3** tests: independent-price backup selection, recovery asset matrix, and the limited reserve-array probe. Passing tests establish the recorded calls and outputs; they do not resolve the explicitly inconclusive Q4 array interpretation or the unrun items.

## Q1 — Independent open prices and backup selection

Three issue windows were crossed in sequence. The Chainlink answer was mocked to `5,986,352,516,636`, `7,482,940,645,796`, and `9,353,675,807,245`; each issuance was followed by a deposit of `1,000,000`, `2,000,000`, and `3,000,000`, respectively. The resulting open prices were distinct:

| Row | Open price | Current SR value | `valueRatio` | Seconds to maturity |
|---|---:|---:|---:|---:|
| A | `59,863,525,166,360,000,000,000` | `400,000` | `400,000,000,000,000,000` | `1,209,599` |
| B | `74,829,406,457,960,000,000,000` | `1,000,000` | `500,000,000,000,000,000` | `1,814,399` |
| C | `93,536,758,072,450,000,000,000` | `1,875,000` | `625,000,000,000,000,000` | `2,419,199` |

The policy input had `staleUnderlyingBal=78,146,401`, `totalStaleVal=120,231,263`, and JR availability `10,000,000`. The direct backup plan selected B and deposited `10,000,000`; the full rollover plan reported `underlyingValRolled=5,000,000`. Actual `rollover()` succeeded, emitted `29` raw logs (`24` relevant bond/reserve events after filtering), and recorded the same selected bond; post-state SR/JR idle balances were `73,146,401` and `5,000,000`.

**Selection discrimination and match counts**

The observed `value/valueRatio` values are A `1,000,000`, B `2,000,000`, and C `3,000,000`; therefore the minimum-`value/valueRatio` alternative predicts A. Minimum value and nearest maturity also predict A, while latest row and maximum ratio predict C.

| Candidate rule / variation | Prediction or observation | Match |
|---|---|---:|
| `argmin |valueRatio − 0.5e18|`, base state | B, the exact-`0.5e18` row | `1/1` direct policy; `1/1` actual rollover |
| Candidate array reversed | B | `1/1` |
| Maturity fields permuted while ratios stay fixed | B | `1/1` |
| Existing SR values for A/C permuted while ratios stay fixed | B | `1/1` |
| Latest row / maximum `valueRatio` | C | `0/1` against base policy and actual execution |
| Minimum SR value, minimum `value/valueRatio`, nearest maturity | A | `0/1` each against base policy and actual execution |
| Standard-plan first top-up candidate in this state | A | `0/1` against backup winner |

The independent open-price case supports ratio-centered selection for the base state and the three direct perturbations, but it is not a universal confirmation. With a mocked current price of `basePrice * 41 / 40`, the competing ratios were `390,244,000,000,000,000` and `609,756,333,333,333,333`. Their distances from `0.5e18` were `109,756,000,000,000,000` and `109,756,333,333,333,333`. The policy selected the higher-ratio candidate even though its distance was larger by `333,333,333,333`; thus strict integer argmin matched **`0/1`** in that near-tie probe. The result survives reversing those two candidates.

An additional **synthetic direct-policy** test set the two ratios to exactly `400,000,000,000,000,000` and `600,000,000,000,000,000`. Both distances were exactly `100,000,000,000,000,000`; the `0.6e18` candidate won with both candidate orders (`2/2`). This exact tie was constructed in the Balancer input and was not produced by an independently opened pair of live bonds. The actual open-price series did produce an exact `0.5e18` row, selected in the actual rollover.

The backup amount alternatives were not distinguished in the base execution: with availability capped at `10,000,000` and selected ratio exactly `0.5e18`, both `min(free, 2*S)` and ratio-based alternatives cap at the same available amount. No general amount formula is claimed from this case.

## Q2 — Rollover boundary evidence carried forward

The Round 5 threshold matrix was not run. Relevant earlier local-fork records:

- Public partial case: `minCleanupVal=10,000,000`, JR idle/availability `30,000,000`, stale SR value `41,875,890`; completed value was `27,219,328`, leaving `14,656,562`.
- Lazy SR flash-mint: with `minCleanupVal=1,000,000`, post-input idle of `999,999` and `1,000,000` did not trigger rollover, while `1,000,001` did.

These observations are consistent with partial public cleanup and a strict `post-input SR idle > minCleanupVal` lazy trigger. They do **not** provide the requested Round 5 binary search around `threshold−1 / threshold / threshold+1` for both public and lazy entry points, nor do they distinguish standard from backup branch boundaries. They also do not establish the SR-input behavior when the full completable value is below the threshold.

## Q3 — `recover()` balances and events

The available Perp address JSON under `/home/ubuntu/work/abis` is selector-match metadata and contains no `abi` field. The exercised signature was the no-argument `recover()` (`cast sig` selector `0xce746024`); the supplied ABI material did not establish whether overloads exist. No arguments were available to vary.

For each Perp, the test dealt `101` cbBTC, `202` of its latest registered tranche, `303` USDC, and `404` of the Perp token to the Perp, then called `recover()` as Controller. Both calls succeeded with empty return data. Before/after balances were unchanged in every category; Controller and owner cbBTC deltas were `0`. Each call emitted six `ReserveSynced(address,uint256)` events (topic `0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939`) for the three SR/JR tranche pairs; no tested token was transferred out.

## Q4 — Reserve-array limits

The final test passed but did not establish an ordering/removal algorithm:

- SR initial array: `[0x2b97045571Ec78aE1010Df47b3e275eCdAE53300, 0x000000000000000000000000000002DD3a1081A8, 0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B]`.
- JR initial array: `[0x0BC26651B2Fbc4230F5C34a9eD186c28aEA48414, 0x000000000000000000000000000002dD3a1081aa, 0xF012e0Fc76306aE1374B577483Cf6b79dE8cf9b1]`.
- Each array contained only two entries with deployed code; the third was a no-code sentinel. A/B zero, B partial (`100` after dealing `300`), and B full (`300`) `transferReservesTo` calls returned success and emitted two events each.
- For both Perps, the array changed after the zero transfer, and the candidate used as B was absent from the array snapshot before the full-transfer call (`presentBefore=false`). After the full call, one code-backed entry remained. These observations cannot be used to classify stable-remove, swap-pop, sorted, or other.
- Mocking `isMature()` and calling `upkeep()` did not settle the row: SR reverted with raw selector `0x00219cf1`; JR reverted with panic selector `0x4e487b71`; both had zero logs.
- A later issue/upkeep succeeded (`14` logs) and produced bond ID `0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b`, but its SR token `0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1` and JR token `0xe027B0A154347546cfFDa5cbcb71A61038738538` were not present in the `reserves()` array returned in that probe.

The attempted three-live-tranche construction therefore did not supply a valid A/B/C array for a conclusive ordering test. The raw log preserves the arrays and call results; no removal rule is inferred.

## Q5–Q10 status

No Round 5 execution was performed for Q5, Q7, Q8, or Q10. Q6 only has the earlier partial upkeep evidence cited above. For Q9, the prior `review_round3_valuecap_mirror.log` contains adjacent corrective-mint boundaries, but exact `post subDR == 1e18` equality was not reached and the Round 5 equality test was not performed. These items remain open rather than inferred from unrelated cases.

## Raw logs and manifest

Primary Round 5 logs:

- `/home/ubuntu/work/probes/round5_all_tests.log`
- `/home/ubuntu/work/probes/round5_q1_independent_prices_exact_tie.log`
- `/home/ubuntu/work/probes/round5_q3_recover.log`
- `/home/ubuntu/work/probes/round5_q4_reserve_order_partial_live.log`

Earlier/inconclusive Q4 harness attempts are also retained and included in the manifest:

- `/home/ubuntu/work/probes/round5_q1_independent_prices.log`
- `/home/ubuntu/work/probes/round5_q4_reserve_order.log`
- `/home/ubuntu/work/probes/round5_q4_reserve_order_live_tokens.log`
- `/home/ubuntu/work/probes/round5_q4_reserve_order_after_prefill.log`
- `/home/ubuntu/work/probes/round5_q4_reserve_order_deposit.log`

`/home/ubuntu/work/probes/LOG_SHA256SUMS.txt` contains SHA-256 hashes for all `.log` files in the probes directory.
