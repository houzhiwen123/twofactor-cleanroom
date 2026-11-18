# Genesis exit fee curve audit — LOCAL CLEANROOM / BNB-DESIGN

**Evidence classification: `LOCAL CLEANROOM / BNB-DESIGN`. This report is not `TARGET-CONFIRMED`.**

**Compatibility status: `FEE MODULE TARGET-MATCHED`. The local system state remains synthetic and is not target Controller-confirmed, but the FeePolicy arithmetic used here passed the fixed-block target differential.**

This report is generated from the local clean-room Foundry regression after the independently derived FeePolicy compatibility correction.

- Test: `test/GenesisDeployment.t.sol:testGenesisExitFeeCurveAudit`
- State: every row starts from the same multi-epoch Genesis snapshot; failed calls are also reverted to that snapshot.
- Modes: A = user's owned SR/JR shares in the same proportion; B = each side's total supply in the same proportion; C = SR-only or JR-only.
- Regression event hash: `0x375c8a2d791fd2e03ff300d838d9af9c5c93e930ae0671cb05a53648e07b3258`
- Values are underlying smallest units unless explicitly marked as DR (WAD) or fee percentage (WAD).

## Findings from this tested state

- Common pre-exit state: `subDR=847534510909630408` (0.847535x), `vmDR=1060773479096730879` (1.060773x).
- Mode A (user-owned proportional): fee is 2.466878% at 1% and 3.209733% at 100%; the tested size effect is only 0.742855 percentage points. Because the smallest tested exit is 1%, this sweep does not prove a zero-size base fee; it only establishes the fee at and above that tested size.
- Mode B (total-supply proportional): 95% and 99% revert with `0xe450d38c` (the caller does not own all total-supply shares, including retained/locked shares); 100% returns a fee signal at or above the Controller disable threshold and reverts with `0x07380a2e`. These are not liquidity failures.
- Mode C SR-only: 0.000000% at 1% to 23.439141% at 100%; Mode C JR-only: 2.478783% to 3.701895%. These rows show how one-sided exits alter the corrected fee curve in this local state.
- All 40 rows conserved the underlying balance (`True`); successful rows leave the fee as Controller-held Perp shares, while reverted rows leave state unchanged.

## Thresholds

`first_exit_percent_exceeding` means the first tested proportion strictly above the threshold; `null` means no tested point exceeded it.

| mode | in-scope rows | N/A rows | success | failure selectors | >1% (either) | >5% (either) | >10% (either) | >25% (either) | >50% (either) |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| A_user_owned_proportional | 10 | 0 | 10/10 | `none` | 1% | - | - | - | - |
| B_total_supply_proportional | 8 | 2 | 7/8 | `0x07380a2e` | 1% | 100% | 100% | 100% | 100% |
| C_sr_only | 10 | 0 | 10/10 | `none` | 50% | 90% | 95% | - | - |
| C_jr_only | 10 | 0 | 10/10 | `none` | 1% | - | - | - | - |

## Observations

| mode | exit | analysis | SR input | JR input | pre subDR | pre vmDR | SR fee | JR fee | theoretical | actual | retained fee value | result | selector | conserved |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| A_user_owned_proportional | 1% | in scope | 52884625920 | 132563553309 | 847534510909630408 | 1060773479096730879 | 24668775771025119 | 24668775771025119 | 2315979 | 2258844 | 57131 | success | - | True |
| A_user_owned_proportional | 5% | in scope | 264423129604 | 662817766545 | 847534510909630408 | 1060773479096730879 | 24687618625131755 | 24687618625131755 | 11579900 | 11294018 | 285879 | success | - | True |
| A_user_owned_proportional | 10% | in scope | 528846259208 | 1325635533090 | 847534510909630408 | 1060773479096730879 | 24713372268088016 | 24713372268088016 | 23159801 | 22587441 | 572356 | success | - | True |
| A_user_owned_proportional | 25% | in scope | 1322115648020 | 3314088832726 | 847534510909630408 | 1060773479096730879 | 24809624714242815 | 24809624714242815 | 57899504 | 56463037 | 1436464 | success | - | True |
| A_user_owned_proportional | 50% | in scope | 2644231296040 | 6628177665453 | 847534510909630408 | 1060773479096730879 | 25083892143429165 | 25083892143429165 | 115799010 | 112894318 | 2904689 | success | - | True |
| A_user_owned_proportional | 75% | in scope | 3966346944060 | 9942266498179 | 847534510909630408 | 1060773479096730879 | 25795398369839018 | 25795398369839018 | 173698515 | 169217891 | 4480621 | success | - | True |
| A_user_owned_proportional | 90% | in scope | 4759616332872 | 11930719797815 | 847534510909630408 | 1060773479096730879 | 27265844841999266 | 27265844841999266 | 208438219 | 202754972 | 5683244 | success | - | True |
| A_user_owned_proportional | 95% | in scope | 5024039462476 | 12593537564360 | 847534510909630408 | 1060773479096730879 | 28618657653400985 | 28618657653400985 | 220018120 | 213721495 | 6296622 | success | - | True |
| A_user_owned_proportional | 99% | in scope | 5235577966159 | 13123791777596 | 847534510909630408 | 1060773479096730879 | 31023661475279726 | 31023661475279726 | 229282040 | 222168868 | 7113167 | success | - | True |
| A_user_owned_proportional | 100% | in scope | 5288462592080 | 13256355330906 | 847534510909630408 | 1060773479096730879 | 32097325967636589 | 32097325967636589 | 231598021 | 224164339 | 7433676 | success | - | True |
| B_total_supply_proportional | 1% | in scope | 56249999797 | 135924066302 | 847534510909630408 | 1060773479096730879 | 24664286521125921 | 24664286521125921 | 2399999 | 2340803 | 59194 | success | - | True |
| B_total_supply_proportional | 5% | in scope | 281249998988 | 679620331513 | 847534510909630408 | 1060773479096730879 | 24664286525613365 | 24664286525613365 | 11999999 | 11704025 | 295971 | success | - | True |
| B_total_supply_proportional | 10% | in scope | 562499997976 | 1359240663027 | 847534510909630408 | 1060773479096730879 | 24664286531783601 | 24664286531783601 | 23999999 | 23408055 | 591942 | success | - | True |
| B_total_supply_proportional | 25% | in scope | 1406249994942 | 3398101657568 | 847534510909630408 | 1060773479096730879 | 24664286555230497 | 24664286555230497 | 59999999 | 58520139 | 1479856 | success | - | True |
| B_total_supply_proportional | 50% | in scope | 2812499989884 | 6796203315136 | 847534510909630408 | 1060773479096730879 | 24664286625571186 | 24664286625571186 | 119999999 | 117040283 | 2959713 | success | - | True |
| B_total_supply_proportional | 75% | in scope | 4218749984826 | 10194304972704 | 847534510909630408 | 1060773479096730879 | 24664286836593243 | 24664286836593243 | 179999999 | 175560427 | 4439570 | success | - | True |
| B_total_supply_proportional | 90% | in scope | 5062499981792 | 12233165967244 | 847534510909630408 | 1060773479096730879 | 24664287469659344 | 24664287469659344 | 215999999 | 210672510 | 5327485 | success | - | True |
| B_total_supply_proportional | 95% | N/A | 5343749980780 | 12912786298758 | 847534510909630408 | 1060773479096730879 | 24664288524769271 | 24664288524769271 | 227999999 | 0 | 0 | revert | `0xe450d38c` | True |
| B_total_supply_proportional | 99% | N/A | 5568749979971 | 13456482563969 | 847534510909630408 | 1060773479096730879 | 24664296965637883 | 24664296965637883 | 237599999 | 0 | 0 | revert | `0xe450d38c` | True |
| B_total_supply_proportional | 100% | in scope | 5624999979769 | 13592406630272 | 847534510909630408 | 1060773479096730879 | 2000000000000000000 | 2000000000000000000 | 240000001 | 0 | 0 | revert | `0x07380a2e` | True |
| C_sr_only | 1% | in scope | 52884625920 | 0 | 847534510909630408 | 1060773479096730879 | 0 | 0 | 661057 | 661056 | 0 | success | - | True |
| C_sr_only | 5% | in scope | 264423129604 | 0 | 847534510909630408 | 1060773479096730879 | 0 | 0 | 3305289 | 3305289 | 0 | success | - | True |
| C_sr_only | 10% | in scope | 528846259208 | 0 | 847534510909630408 | 1060773479096730879 | 0 | 0 | 6610578 | 6610578 | 0 | success | - | True |
| C_sr_only | 25% | in scope | 1322115648020 | 0 | 847534510909630408 | 1060773479096730879 | 1225194015584969 | 1225194015584969 | 16526445 | 16506195 | 20248 | success | - | True |
| C_sr_only | 50% | in scope | 2644231296040 | 0 | 847534510909630408 | 1060773479096730879 | 18938140216145137 | 18938140216145137 | 33052891 | 32426931 | 625960 | success | - | True |
| C_sr_only | 75% | in scope | 3966346944060 | 0 | 847534510909630408 | 1060773479096730879 | 43472713274660411 | 43472713274660411 | 49579336 | 47423988 | 2155348 | success | - | True |
| C_sr_only | 90% | in scope | 4759616332872 | 0 | 847534510909630408 | 1060773479096730879 | 88704460207472165 | 88704460207472165 | 59495204 | 54217713 | 5277489 | success | - | True |
| C_sr_only | 95% | in scope | 5024039462476 | 0 | 847534510909630408 | 1060773479096730879 | 129626374880431972 | 129626374880431972 | 62800493 | 54659892 | 8140600 | success | - | True |
| C_sr_only | 99% | in scope | 5235577966159 | 0 | 847534510909630408 | 1060773479096730879 | 202085580192241475 | 202085580192241475 | 65444724 | 52219287 | 13225435 | success | - | True |
| C_sr_only | 100% | in scope | 5288462592080 | 0 | 847534510909630408 | 1060773479096730879 | 234391411079961027 | 234391411079961027 | 66105782 | 50611152 | 15494627 | success | - | True |
| C_jr_only | 1% | in scope | 0 | 132563553309 | 847534510909630408 | 1060773479096730879 | 24787832946671404 | 24787832946671404 | 1654922 | 1613898 | 41021 | success | - | True |
| C_jr_only | 5% | in scope | 0 | 662817766545 | 847534510909630408 | 1060773479096730879 | 25282019448430736 | 25282019448430736 | 8274611 | 8065411 | 209198 | success | - | True |
| C_jr_only | 10% | in scope | 0 | 1325635533090 | 847534510909630408 | 1060773479096730879 | 25899752631620428 | 25899752631620428 | 16549223 | 16120602 | 428620 | success | - | True |
| C_jr_only | 25% | in scope | 0 | 3314088832726 | 847534510909630408 | 1060773479096730879 | 27752952181189504 | 27752952181189504 | 41373059 | 40224834 | 1148224 | success | - | True |
| C_jr_only | 50% | in scope | 0 | 6628177665453 | 847534510909630408 | 1060773479096730879 | 30841618097137964 | 30841618097137964 | 82746119 | 80194094 | 2552024 | success | - | True |
| C_jr_only | 75% | in scope | 0 | 9942266498179 | 847534510909630408 | 1060773479096730879 | 33930284013086424 | 33930284013086424 | 124119179 | 119907779 | 4211399 | success | - | True |
| C_jr_only | 90% | in scope | 0 | 11930719797815 | 847534510909630408 | 1060773479096730879 | 35783483562655500 | 35783483562655500 | 148943015 | 143613314 | 5329699 | success | - | True |
| C_jr_only | 95% | in scope | 0 | 12593537564360 | 847534510909630408 | 1060773479096730879 | 36401216745845192 | 36401216745845192 | 157217627 | 151494713 | 5722912 | success | - | True |
| C_jr_only | 99% | in scope | 0 | 13123791777596 | 847534510909630408 | 1060773479096730879 | 36895403247604524 | 36895403247604524 | 163837316 | 157792471 | 6044843 | success | - | True |
| C_jr_only | 100% | in scope | 0 | 13256355330906 | 847534510909630408 | 1060773479096730879 | 37018949929034885 | 37018949929034885 | 165492239 | 159365889 | 6126348 | success | - | True |

## Interpretation boundaries

- This is a synthetic local Genesis/multi-epoch state, not a claim that the target Controller can reach or execute every row.
- The fee arithmetic is target-matched by the separate fixed-block differential; the local state vectors themselves remain LOCAL CLEANROOM / BNB-DESIGN.
- There is no zero-input execution row in this sweep; the 1% row is the smallest tested exit and must not be treated as a zero-size base fee.
- Mode B at 95% and 99% is `N/A`: both calls exceeded the caller's real local share balance, so those quotes are preserved as raw records but excluded from fee-trend conclusions.
- A high fee can arise from exit size, SR/JR mismatch, or both; the four modes are kept separate so the report does not attribute causality without evidence.
- A successful operation with a large retained fee means the user received the net basket and the fee remained as Perp shares in the Controller; it is not an underlying-token loss.
- A reverted operation leaves DR, balances, supplies, and underlying conservation unchanged because each row is isolated by snapshot/revert.

## Candidate mitigations (not implemented)

1. Pro-rata withdrawal from the SR/JR reserve baskets.
2. Staged exit with a user-supplied max-fee limit.
3. Exit queue, followed by Keeper/rebalance, then continued withdrawal.
