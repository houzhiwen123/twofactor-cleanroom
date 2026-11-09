# Phase 1b status

“Black-box verified” refers only to target observations from local Base forks. “Implemented” is
separate: yes means the cited scope has an offline regression; provisional means some semantics
remain unverified. All paths below are repository-relative.

| feature | 黑盒已验证 (yes/no/partial + evidence file:lines, repo-relative) | 已实现 (yes/no/provisional) | 离线回归测试 (test names) |
|---|---|---|---|
| `reserves()` tuple ABI, underlying amount, tranche count/order/amounts | yes — `evidence/ROUND7_PROBES.md:30`; `evidence/ROUND8_PROBES.md:29`; `evidence/raw-logs.tar.xz::round8_review_probe.log:68-75` | yes | `testReservesRawTupleOrderAmountsAndDuplicateRegistration` |
| Duplicate tranche registration is a no-op | partial — target duplicate result was not independently exercised; Round 5 Q4 decode is invalid: `evidence/ROUND5_PROBES.md:9-20` | provisional | `testReservesRawTupleOrderAmountsAndDuplicateRegistration`, `testPerpPermissionsCapDuplicateAndJuniorApproval` |
| `reserveData()` valuation floor and live structure | partial — `evidence/ROUND7_PROBES.md:30` records rich return values, not the rounding boundary; Round 5 Q4 reserve-array data must be rerun using the corrected tuple ABI | provisional | `testReserveDataTrancheValueFloors` |
| `ReserveSynced` emissions | partial — observed around rebalance settlement/transfers, not verified at every operation: `evidence/ROUND7_PROBES.md:34`; `evidence/raw-logs.tar.xz::round7_integrated_probe.log:288-306` | provisional | `testRebalanceOrdersFeeSettlementPlanAndAumLogs` |
| Perp controller permission matrix | partial — exact target cells and gaps are enumerated in `evidence/ROUND7_PROBES.md:31`; SR selectors `0x397e327f`/`0x484685b0` from Controller empty-reverted in `evidence/ROUND8_PROBES.md:30`. No other SR selector caller cells were probed. | yes for this matrix | `testPerpControllerReplacementPermissionMatrix`, `testPerpPermissionsCapDuplicateAndJuniorApproval` |
| Perp Ownable2Step handoff and holder ERC20 transfers | yes — `evidence/ROUND7_PROBES.md` §R7.2 | yes | `testPerpOwnable2StepAndHolderTransfers` |
| Flash mint floors, net shares, per-side fees, protocol split | yes — `evidence/CONTROLLER_PROBES_2.md` and `evidence/CODEX_REVIEW_PROBES.md` Round 1 H2/H3b | yes | `testFlashMint2GoldenNetShares`, `testFlashMint2PerSideFeeDivergence`, `testFlashMint2ProtocolSplitGoldenVector` |
| `redeem2` basket floors and fee-perp retention | yes — `evidence/CODEX_REVIEW_PROBES.md` Round 1 H9 | yes | `testRedeem2FloorsAndRetainsFeePerps`, `testRedeem2SecondFeeBearingGoldenVector` |
| Flash redeem golden vectors and two-sided settlement | yes — `evidence/CONTROLLER_PROBES_2.md` operation trace | yes | `testFlashRedeem2Gross999999GoldenCases`, `testFlashRedeem2TwoSidedGoldenSettlement` |
| JR liquidity error and zero-input-side fee guard for flash mint/redeem and redeem | yes — `evidence/CODEX_REVIEW_PROBES.md:1-80`; `evidence/ROUND6_PROBES.md:33-36` | yes | `testJrLiquidityAndFeePriority`, `testZeroInputSideFeeDoesNotDisableOperations` |
| `mint2` latest-tranche check and per-side floors | yes — `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1; `evidence/ROUND6_PROBES.md` R6.6 | yes | `testMint2PerSideFloorGoldenVector`, `testMint2RejectsRegisteredNonLatestTranche` |
| `mint2` zero-input-side `OpDisabled` behavior | no — not probed; do not infer from other operation entry points | no | — |
| Value-cap corrective boundaries and pre-operation equality | yes — `evidence/ROUND6_PROBES.md:35`; exact fork vectors retained in the test | yes for asserted vectors | `testValueCapBalancedPreSubWadAboveCapReverts`, `testValueCapUnderCapPostOverCapAllowsOnlyCorrectiveSide`, `testValueCapCorrectiveBoundaries` |
| Exact post-operation `subDR == 1e18` value-cap outcome | no — equality remains unproven: `evidence/ROUND5_PROBES.md` Q9; `evidence/ROUND6_PROBES.md` R6.5 | provisional; strict crossing only | `testValueCapCorrectiveBoundaries` |
| Rebalance window, cooldown, and permissionless caller | yes — `evidence/ROUND6_PROBES.md:29-32` | yes | `testRebalanceAllowsRandomCallerWhenKeeperDiffers`, `testRebalanceAllowsOwnerCallerWhenKeeperDiffers`, `testRebalanceAllowsConfiguredKeeperCaller`, `testRebalanceCooldownWindowStartAndFrequencyBoundaries`, `testRebalanceSecondCallInSameWindowIsTooRecent` |
| Rebalance settlement/plan/AUM order | partial — target trace: `evidence/round8_rebalance_trace.log:1132-1143,1288-1293,1307-1334`; event order `evidence/round7_integrated_probe.log:287-308`; report `evidence/ROUND8_PROBES.md:34` | yes for observed call/event order | `testRebalanceOrdersFeeSettlementPlanAndAumLogs` |
| AUM zero-mint events and zero-rate omission | yes — `evidence/ROUND6_PROBES.md:34` | yes | `testAumFeeZeroAmountMintsZeroAndEmits`, `testAumFeeZeroRateDoesNotEmit` |
| Controller setter authorization | yes — `evidence/ROUND7_PROBES.md:32`; raw `round7_integrated_probe.log:7-42` | yes for the listed owner/keeper cells | `testControllerAdminRoleAndValidationMatrix`, `testControllerSetterValuesFromRound8Probe` |
| `updateDRTargets`, liquidity threshold, rebalance window and rollover eligibility validations | yes — `evidence/ROUND7_PROBES.md:33`; `evidence/ROUND8_PROBES.md:31-32` | yes for probed values | `testDRTargetBoundaryMatchesRound8Probe`, `testControllerSetterValuesFromRound8Probe`, `testControllerAdminRoleAndValidationMatrix` |
| Other tested setter values (fee policy, keeper, balancer, min cleanup, value cap, pause flags) | yes for tested values — `evidence/ROUND8_PROBES.md:32` and archived setter log | yes for tested values | `testControllerSetterValuesFromRound8Probe` |
| `updateIssuer` validation | partial — current issuer accepted; zero, EOA, BondsManager and PerpSR empty-reverted: `evidence/ROUND8_PROBES.md:33`; archived setter log lines 26-30 | provisional; implementation intentionally unchanged | `testControllerSetterValuesFromRound8Probe` (current issuer only) |
| `pullProtocolFees` collector access and over-withdraw behavior | yes — `evidence/CODEX_REVIEW_PROBES.md` Round 2 fee observations | yes for tested path | `testFlashMint2ProtocolSplitGoldenVector` |
| Lazy issue on SR-input `flashMint2`; no issue on JR-only | yes — `evidence/ROUND6_PROBES.md:36`; `evidence/CODEX_REVIEW_PROBES.md:1-80` | yes | `testFlashMint2IssuesOnlyForSeniorInput`, `testFlashMint2JuniorOnlyDoesNotIssue` |
| `recover()` asset behavior | partial — tested assets remained in place; overloads unknown: `evidence/ROUND5_PROBES.md` Q3 | no | — |
| Tranche removal/array reordering and rollover deposit bookkeeping | no — Round 5 Q4 is invalid due to the earlier `address[]` ABI misdecode and must be rerun: `evidence/ROUND5_PROBES.md` Q4 | no | — |
| `upkeep`, rollover, backup selection and shortfall paths | partial/unresolved — `evidence/ROUND5_PROBES.md` Q1-Q2,Q6; see earlier-round reports | no | — |
| Genesis/zero-supply seeding, extreme VM, slippage equality | no/partial — `evidence/ROUND5_PROBES.md` Q5,Q7-Q8; `evidence/CODEX_REVIEW_PROBES.md` pending notes | no | — |
| `setUnderlyingOracle()` / `resetUnderlyingOracle()` | no — public ABI only; behavior not probed | no | — |

## Pending evidence

- `mint2` zero-input fee behavior; exact post-operation value-cap equality.
- `updateIssuer` validation beyond accepting its current value.
- Per-operation `ReserveSynced` coverage, reserve valuation rounding, and duplicate-registration target behavior.
- Rerun Round 5 Q4 with `(uint256,(address,uint256)[])`; establish removal/reordering only from valid live data.
- `recover()` overloads, upkeep/rollover, genesis/zero-supply valuation, extreme VM, and slippage equality.
- `setUnderlyingOracle()` / `resetUnderlyingOracle()`.
