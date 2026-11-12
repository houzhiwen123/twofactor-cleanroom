# Genesis exit fee curve audit — LOCAL CLEANROOM / BNB-DESIGN

**Evidence classification: `LOCAL CLEANROOM / BNB-DESIGN`. This report is not `TARGET-CONFIRMED`.**

**Compatibility status: `PRE-FIX LOCAL BUG`. The 73%–74% results in this report are preserved as regression evidence, but they are not target behavior and must not be used as expected FeePolicy values.**

This report is generated from the local clean-room Foundry regression only. FeePolicy and production contracts were not modified.

- Test: `test/GenesisDeployment.t.sol:testGenesisExitFeeCurveAudit`
- State: every row starts from the same multi-epoch Genesis snapshot; failed calls are also reverted to that snapshot.
- Modes: A = user's owned SR/JR shares in the same proportion; B = each side's total supply in the same proportion; C = SR-only or JR-only.
- Regression event hash: `0x7751f2237a4ec45d495f4cd1df42ec8f6a1f74f13d4ffdebe8837bbe7496e9fb`
- Values are underlying smallest units unless explicitly marked as DR (WAD) or fee percentage (WAD).

## Findings from this tested state

- Common pre-exit state: `subDR=847534510909630408` (0.847535x), `vmDR=1060773479096730879` (1.060773x).
- Mode A (user-owned proportional): fee is 73.778692% at 1% and 74.521548% at 100%; the tested size effect is only 0.742855 percentage points. Because the smallest tested exit is already above 50%, this sweep does not prove a zero-size base fee, but it does show that the high fee is already present before a large exit.
- Mode B (total-supply proportional): 95% and 99% revert with `0xe450d38c` (the caller does not own all total-supply shares, including retained/locked shares); 100% reaches the fee cap and reverts with `0x07380a2e`. These are not liquidity failures.
- Mode C SR-only: 71.311815% at 1% to 94.750956% at 100%; Mode C JR-only: 73.790598% to 75.013710%. The mismatch changes the curve, but it is not enough in this state to explain the whole ~74% level without the pre-existing DR state.
- All 40 rows conserved the underlying balance (`True`); successful rows leave the fee as Controller-held Perp shares, while reverted rows leave state unchanged.

## Thresholds

`first_exit_percent_exceeding` means the first tested proportion strictly above the threshold; `null` means no tested point exceeded it.

| mode | in-scope rows | N/A rows | success | failure selectors | >1% (either) | >5% (either) | >10% (either) | >25% (either) | >50% (either) |
|---|---:|---:|---:|---|---:|---:|---:|---:|---:|
| A_user_owned_proportional | 10 | 0 | 10/10 | `none` | 1% | 1% | 1% | 1% | 1% |
| B_total_supply_proportional | 8 | 2 | 7/8 | `0x07380a2e` | 1% | 1% | 1% | 1% | 1% |
| C_sr_only | 10 | 0 | 10/10 | `none` | 1% | 1% | 1% | 1% | 1% |
| C_jr_only | 10 | 0 | 10/10 | `none` | 1% | 1% | 1% | 1% | 1% |

## Observations

| mode | exit | analysis | SR input | JR input | pre subDR | pre vmDR | SR fee | JR fee | theoretical | actual | retained fee value | result | selector | conserved |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|---|
| A_user_owned_proportional | 1% | in scope | 52884625920 | 132563553309 | 847534510909630408 | 1060773479096730879 | 737786924881158484 | 737786924881158484 | 2315979 | 607277 | 1708699 | success | - | True |
| A_user_owned_proportional | 5% | in scope | 264423129604 | 662817766545 | 847534510909630408 | 1060773479096730879 | 737805767735265120 | 737805767735265120 | 11579900 | 3036179 | 8543717 | success | - | True |
| A_user_owned_proportional | 10% | in scope | 528846259208 | 1325635533090 | 847534510909630408 | 1060773479096730879 | 737831521378221382 | 737831521378221382 | 23159801 | 6071767 | 17088032 | success | - | True |
| A_user_owned_proportional | 25% | in scope | 1322115648020 | 3314088832726 | 847534510909630408 | 1060773479096730879 | 737927773824376181 | 737927773824376181 | 57899504 | 15173848 | 42725652 | success | - | True |
| A_user_owned_proportional | 50% | in scope | 2644231296040 | 6628177665453 | 847534510909630408 | 1060773479096730879 | 738202041253562530 | 738202041253562530 | 115799010 | 30315942 | 85483065 | success | - | True |
| A_user_owned_proportional | 75% | in scope | 3966346944060 | 9942266498179 | 847534510909630408 | 1060773479096730879 | 738913547479972383 | 738913547479972383 | 173698515 | 45350327 | 128348186 | success | - | True |
| A_user_owned_proportional | 90% | in scope | 4759616332872 | 11930719797815 | 847534510909630408 | 1060773479096730879 | 740383993952132631 | 740383993952132631 | 208438219 | 54113893 | 154324321 | success | - | True |
| A_user_owned_proportional | 95% | in scope | 5024039462476 | 12593537564360 | 847534510909630408 | 1060773479096730879 | 741736806763534351 | 741736806763534351 | 220018120 | 56822577 | 163195537 | success | - | True |
| A_user_owned_proportional | 99% | in scope | 5235577966159 | 13123791777596 | 847534510909630408 | 1060773479096730879 | 744141810585413092 | 744141810585413092 | 229282040 | 58663683 | 170618353 | success | - | True |
| A_user_owned_proportional | 100% | in scope | 5288462592080 | 13256355330906 | 847534510909630408 | 1060773479096730879 | 745215475077769955 | 745215475077769955 | 231598021 | 59007588 | 172590429 | success | - | True |
| B_total_supply_proportional | 1% | in scope | 56249999797 | 135924066302 | 847534510909630408 | 1060773479096730879 | 737782435631259286 | 737782435631259286 | 2399999 | 629320 | 1770677 | success | - | True |
| B_total_supply_proportional | 5% | in scope | 281249998988 | 679620331513 | 847534510909630408 | 1060773479096730879 | 737782435635746731 | 737782435635746731 | 11999999 | 3146608 | 8853388 | success | - | True |
| B_total_supply_proportional | 10% | in scope | 562499997976 | 1359240663027 | 847534510909630408 | 1060773479096730879 | 737782435641916967 | 737782435641916967 | 23999999 | 6293219 | 17706777 | success | - | True |
| B_total_supply_proportional | 25% | in scope | 1406249994942 | 3398101657568 | 847534510909630408 | 1060773479096730879 | 737782435665363863 | 737782435665363863 | 59999999 | 15733052 | 44266945 | success | - | True |
| B_total_supply_proportional | 50% | in scope | 2812499989884 | 6796203315136 | 847534510909630408 | 1060773479096730879 | 737782435735704551 | 737782435735704551 | 119999999 | 31466106 | 88533891 | success | - | True |
| B_total_supply_proportional | 75% | in scope | 4218749984826 | 10194304972704 | 847534510909630408 | 1060773479096730879 | 737782435946726609 | 737782435946726609 | 179999999 | 47199159 | 132800838 | success | - | True |
| B_total_supply_proportional | 90% | in scope | 5062499981792 | 12233165967244 | 847534510909630408 | 1060773479096730879 | 737782436579792709 | 737782436579792709 | 215999999 | 56638990 | 159361006 | success | - | True |
| B_total_supply_proportional | 95% | N/A | 5343749980780 | 12912786298758 | 847534510909630408 | 1060773479096730879 | 737782437634902636 | 737782437634902636 | 227999999 | 0 | 0 | revert | `0xe450d38c` | True |
| B_total_supply_proportional | 99% | N/A | 5568749979971 | 13456482563969 | 847534510909630408 | 1060773479096730879 | 737782446075771249 | 737782446075771249 | 237599999 | 0 | 0 | revert | `0xe450d38c` | True |
| B_total_supply_proportional | 100% | in scope | 5624999979769 | 13592406630272 | 847534510909630408 | 1060773479096730879 | 1000000000000000000 | 1000000000000000000 | 240000001 | 0 | 0 | revert | `0x07380a2e` | True |
| C_sr_only | 1% | in scope | 52884625920 | 0 | 847534510909630408 | 1060773479096730879 | 713118149110133366 | 713118149110133366 | 661057 | 189645 | 471412 | success | - | True |
| C_sr_only | 5% | in scope | 264423129604 | 0 | 847534510909630408 | 1060773479096730879 | 713118149110133366 | 713118149110133366 | 3305289 | 948225 | 2357061 | success | - | True |
| C_sr_only | 10% | in scope | 528846259208 | 0 | 847534510909630408 | 1060773479096730879 | 713118149110133366 | 713118149110133366 | 6610578 | 1896453 | 4714123 | success | - | True |
| C_sr_only | 25% | in scope | 1322115648020 | 0 | 847534510909630408 | 1060773479096730879 | 714343343125718335 | 714343343125718335 | 16526445 | 4720887 | 11805556 | success | - | True |
| C_sr_only | 50% | in scope | 2644231296040 | 0 | 847534510909630408 | 1060773479096730879 | 732056289326278502 | 732056289326278502 | 33052891 | 8856312 | 24196576 | success | - | True |
| C_sr_only | 75% | in scope | 3966346944060 | 0 | 847534510909630408 | 1060773479096730879 | 756590862384793777 | 756590862384793777 | 49579336 | 12068061 | 37511273 | success | - | True |
| C_sr_only | 90% | in scope | 4759616332872 | 0 | 847534510909630408 | 1060773479096730879 | 801822609317605530 | 801822609317605530 | 59495204 | 11790603 | 47704600 | success | - | True |
| C_sr_only | 95% | in scope | 5024039462476 | 0 | 847534510909630408 | 1060773479096730879 | 842744523990565337 | 842744523990565337 | 62800493 | 9875721 | 52924772 | success | - | True |
| C_sr_only | 99% | in scope | 5235577966159 | 0 | 847534510909630408 | 1060773479096730879 | 915203729302374841 | 915203729302374841 | 65444724 | 5549466 | 59895256 | success | - | True |
| C_sr_only | 100% | in scope | 5288462592080 | 0 | 847534510909630408 | 1060773479096730879 | 947509560190094392 | 947509560190094392 | 66105782 | 3469920 | 62635861 | success | - | True |
| C_jr_only | 1% | in scope | 0 | 132563553309 | 847534510909630408 | 1060773479096730879 | 737905982056804770 | 737905982056804770 | 1654922 | 433743 | 1221177 | success | - | True |
| C_jr_only | 5% | in scope | 0 | 662817766545 | 847534510909630408 | 1060773479096730879 | 738400168558564102 | 738400168558564102 | 8274611 | 2164636 | 6109974 | success | - | True |
| C_jr_only | 10% | in scope | 0 | 1325635533090 | 847534510909630408 | 1060773479096730879 | 739017901741753794 | 739017901741753794 | 16549223 | 4319050 | 12230172 | success | - | True |
| C_jr_only | 25% | in scope | 0 | 3314088832726 | 847534510909630408 | 1060773479096730879 | 740871101291322870 | 740871101291322870 | 41373059 | 10720953 | 30652104 | success | - | True |
| C_jr_only | 50% | in scope | 0 | 6628177665453 | 847534510909630408 | 1060773479096730879 | 743959767207271330 | 743959767207271330 | 82746119 | 21186334 | 61559783 | success | - | True |
| C_jr_only | 75% | in scope | 0 | 9942266498179 | 847534510909630408 | 1060773479096730879 | 747048433123219790 | 747048433123219790 | 124119179 | 31396138 | 92723038 | success | - | True |
| C_jr_only | 90% | in scope | 0 | 11930719797815 | 847534510909630408 | 1060773479096730879 | 748901632672788866 | 748901632672788866 | 148943015 | 37399346 | 111543667 | success | - | True |
| C_jr_only | 95% | in scope | 0 | 12593537564360 | 847534510909630408 | 1060773479096730879 | 749519365855978558 | 749519365855978558 | 157217627 | 39379969 | 117837656 | success | - | True |
| C_jr_only | 99% | in scope | 0 | 13123791777596 | 847534510909630408 | 1060773479096730879 | 750013552357737890 | 750013552357737890 | 163837316 | 40957107 | 122880207 | success | - | True |
| C_jr_only | 100% | in scope | 0 | 13256355330906 | 847534510909630408 | 1060773479096730879 | 750137099039168250 | 750137099039168250 | 165492239 | 41350369 | 124141868 | success | - | True |

## Interpretation boundaries

- This is a synthetic local Genesis/multi-epoch state, not a claim about live 2Factor behavior.
- There is no zero-input execution row in this sweep; the 1% row is the smallest tested exit and must not be treated as a zero-size base fee.
- Mode B at 95% and 99% is `N/A`: both calls exceeded the caller's real local share balance, so those quotes are preserved as raw records but excluded from fee-trend conclusions.
- A high fee can arise from exit size, SR/JR mismatch, or both; the four modes are kept separate so the report does not attribute causality without evidence.
- A successful operation with a large retained fee means the user received the net basket and the fee remained as Perp shares in the Controller; it is not an underlying-token loss.
- A reverted operation leaves DR, balances, supplies, and underlying conservation unchanged because each row is isolated by snapshot/revert.

## Candidate mitigations (not implemented)

1. Pro-rata withdrawal from the SR/JR reserve baskets.
2. Staged exit with a user-supplied max-fee limit.
3. Exit queue, followed by Keeper/rebalance, then continued withdrawal.
