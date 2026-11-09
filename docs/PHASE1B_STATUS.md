# Phase 1b status

Only behavior backed by black-box evidence and a regression assertion is marked ✅. Implemented
behavior whose full on-chain semantics are not established is marked 暂定实现 (tentative);
unimplemented behavior remains pending evidence.

| feature | status | evidence file+section | test name |
|---|---|---|---|
| `PerpToken.reserves()` raw ABI shape `(uint256 underlyingBal, (address token,uint256 amount)[] trancheTokens)` and rich `reserveData()` ABI shape | ✅ | `evidence/ROUND7_PROBES.md` §R7.1; `evidence/round7_integrated_probe.log:142-210,213-283`; `evidence/round7_reserve_abi_corrected.log:26-41,97-112` | `testReserveDataTrancheValueFloors` |
| `reserveData()` tranche valuation floor formula | 暂定实现 (tentative) | Local fixture only; live Round 7 records show values but do not distinguish floor rounding | `testReserveDataTrancheValueFloors` |
| Perp ERC20 metadata (8 decimals, observed names/symbols) and holder `transfer`, `approve`, and `transferFrom` behavior | ✅ | `evidence/ROUND7_PROBES.md` §R7.2; `evidence/round7_integrated_probe.log:137-138` | `testR7PerpHolderTransfers`, `testPerpOwnable2StepAndHolderTransfers` |
| Perp ownership handoff/renunciation, controller replacement role matrix, 50-entry cap, duplicate registration, JR-only approvals | ✅ | `evidence/ROUND7_PROBES.md` §R7.2; `evidence/CODEX_REVIEW_PROBES.md` Round 4 P3 | `testPerpControllerReplacementPermissionMatrix`, `testPerpOwnable2StepAndHolderTransfers`, `testPerpPermissionsCapDuplicateAndJuniorApproval` |
| Perp `ReserveSynced` emissions during reserve movements | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R2 raw trace; `evidence/round7_integrated_probe.log:288-306` | `testRebalanceOrdersFeeSettlementPlanAndAumLogs` |
| `flashMint2` share floors, returned net shares, protocol/collected split | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H2/H3b | `testFlashMint2GoldenNetShares`, `testFlashMint2ProtocolSplitGoldenVector` |
| Protocol amount `floor(gross * protocolFeePerc / 1e18)` and fee balance split | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H3b; `evidence/review_protocol_permissions_observations.log` OBS values | `testFlashMint2ProtocolSplitGoldenVector` |
| `redeem2` net-perp basket floors and fee-token retention | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H9 | `testRedeem2FloorsAndRetainsFeePerps`, `testRedeem2SecondFeeBearingGoldenVector` |
| JR liquidity check and input-side `OpDisabled` precedence | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H5; `evidence/ROUND6_PROBES.md` R6.3 | `testJrLiquidityAndFeePriority` |
| Zero-input-side fee at or above WAD does not disable `flashMint2`, `flashRedeem2`, or `redeem2` | ✅ | `evidence/ROUND6_PROBES.md` R6.3 | `testZeroInputSideFeeDoesNotDisableOperations` |
| `mint2` zero-input-side `OpDisabled` behavior | pending | Not probed in Round 6; do not infer from other operation entry points | — |
| Value-cap pre-operation `subDR == 1e18` above-cap rejection and under-cap/post-over-cap corrective/worsening paths | ✅ | `evidence/ROUND6_PROBES.md` R6.5 | `testValueCapBalancedPreSubWadAboveCapReverts`, `testValueCapUnderCapPostOverCapAllowsOnlyCorrectiveSide` |
| Exact post-operation `subDR == 1e18` value-cap boundary | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 3 R6; Round 6 did not construct equality | `testValueCapCorrectiveBoundaries` (strict-crossing vectors only) |
| Fee settlement on zero-plan rebalance, protocol-fee preservation, and AUM gross-up | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R2/R3 and AUM evidence | `testRebalanceSettlesCollectedFeesAndMintsAumOnZeroPlan` |
| Nonzero fee-perp burns/cbBTC fee transfer, nonzero plan, `Rebalance`, reserve transfer, then nonzero AUM events | ✅ | `evidence/round7_integrated_probe.log:287-308` | `testRebalanceOrdersFeeSettlementPlanAndAumLogs` |
| `pauseUserOps` and `pauseSystemOps` are keeper-only; owner/random revert `UnauthorizedCall()` | ✅ | `evidence/ROUND7_PROBES.md` §R7.3; `evidence/round7_integrated_probe.log:7-12` | `testControllerAdminRoleAndValidationMatrix`, `testPauseSelectorsAndRebalanceWindowEdges` |
| Owner-only authorization for `updateDRTargets`, `updateFeePolicy`, `updateIssuer`, `updateKeeper`, `updateLiquidityThresholds`, `updateMinCleanupVal`, `updatePerpBalancer`, `updateRebalanceWindow`, and `updateRolloverEligibility` | ✅ | `evidence/ROUND7_PROBES.md` §R7.3; `evidence/round7_integrated_probe.log:13-39` | `testControllerAdminRoleAndValidationMatrix` |
| `updateValueCap` is keeper-only; owner/random revert `UnauthorizedCall()` | ✅ | `evidence/ROUND7_PROBES.md` §R7.3; `evidence/round7_integrated_probe.log:40-42` | `testControllerAdminRoleAndValidationMatrix` |
| `updateRebalanceWindow`: zero frequency, offset greater than frequency, zero length, or length greater than frequency revert `InvalidParamDefn`; offset equal to frequency succeeds | ✅ | `evidence/ROUND7_PROBES.md` §R7.4; `evidence/round7_integrated_probe.log:113-118` | `testControllerAdminRoleAndValidationMatrix` |
| `updateLiquidityThresholds` rejects percentage above WAD with `InvalidPerc`; WAD succeeds; `updateDRTargets` rejects either zero target | ✅ | `evidence/ROUND7_PROBES.md` §R7.4; `evidence/round7_integrated_probe.log:119-124` | `testControllerAdminRoleAndValidationMatrix` |
| `rebalance()` callable by random EOA, owner, and configured keeper | ✅ | `evidence/ROUND6_PROBES.md` R6.1 | `testRebalanceAllowsRandomCallerWhenKeeperDiffers`, `testRebalanceAllowsOwnerCallerWhenKeeperDiffers`, `testRebalanceAllowsConfiguredKeeperCaller` |
| Rebalance window is start-inclusive/end-exclusive; stored timestamp is window start; frequency-boundary behavior | ✅ | `evidence/ROUND6_PROBES.md` R6.2 | `testPauseSelectorsAndRebalanceWindowEdges`, `testRebalanceCooldownWindowStartAndFrequencyBoundaries`, `testRebalanceSecondCallInSameWindowIsTooRecent` |
| `pullProtocolFees` collector authorization and arithmetic underflow on over-withdraw | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R3 | `testFlashMint2ProtocolSplitGoldenVector` |
| `mint2` latest-bond tranche check and registered non-latest rejection | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1, Round 2 R1; `evidence/ROUND6_PROBES.md` R6.6 | `testMint2PerSideFloorGoldenVector`, `testMint2RejectsRegisteredNonLatestTranche` |
| `flashRedeem2` gross-floor vectors, per-side fees, SR-to-JR settlement, and output event order | ✅ | `evidence/CONTROLLER_PROBES_2.md` §Controller operation trace; `evidence/CODEX_REVIEW_PROBES.md` Round 1 H2 | `testFlashRedeem2Gross999999GoldenCases`, `testFlashRedeem2TwoSidedGoldenSettlement` |
| `mint2` per-side tranche-value/share floors and fee-perp minting | ✅ | `evidence/CONTROLLER_PROBES.md` §mint2 tranche valuation and perps | `testMint2PerSideFloorGoldenVector` |
| `upkeep`, public/lazy rollover, backup bond selection, and `InsufficientRollover` paths | pending | `evidence/CODEX_REVIEW_PROBES.md` Rounds 1–5; behavior remains out of scope | — |
| SR-input lazy issue in `flashMint2` after issue time; JR-only input does not issue | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1; `evidence/ROUND6_PROBES.md` R6.6 | `testFlashMint2IssuesOnlyForSeniorInput`, `testFlashMint2JuniorOnlyDoesNotIssue` |
| Positive-rate AUM fee mint/events, including zero computed amount; no AUM event at zero rate | ✅ | `evidence/ROUND6_PROBES.md` R6.4 | `testAumFeeZeroAmountMintsZeroAndEmits`, `testAumFeeZeroRateDoesNotEmit` |
| `setUnderlyingOracle()` / `resetUnderlyingOracle()` | pending | Present in the public Controller ABI; behavior not probed and intentionally unimplemented | — |
| Input validation for remaining setters beyond the observed `updateDRTargets`, `updateLiquidityThresholds`, and `updateRebalanceWindow` cases | 暫定实现 (tentative) | `evidence/ROUND7_PROBES.md` §R7.3; only current-value writes were attempted for other setters | `testControllerAdminRoleAndValidationMatrix` |
| `recover()`, tranche removal/array reordering, and rollover deposit bookkeeping | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 5 Q3/Q4; removal behavior unresolved | — |
| Genesis/zero-supply seeding and exact zero-claim valuation | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 4 P4; zero-supply call panicked and seed path remains unresolved | — |
| Slippage equality and extreme VM behavior | pending | `docs/SPEC_CONTROLLER_ZH.md` pending-evidence notes; Round 5 Q7/Q8 not run | — |

## Behavior intentionally left pending

- `upkeep()`, `rollover()`, lazy rollover, backup-bond selection, and their shortfall/partial-plan
  state machine.
- `PerpToken.recover()` and tranche deregistration or reserve-array reordering.
- First-mint/genesis seeding and zero-supply valuation.
- Exact post-operation `subDR == 1e18` value-cap behavior. The implementation permits equality and
  rejects only a strict crossing as directed; that post-operation boundary remains unobserved.
- `mint2` fee-guard behavior when the zero-input side fee is at or above WAD; only
  `flashMint2`, `flashRedeem2`, and `redeem2` were probed.
- Slippage equality, extreme VM/zero tranche-supply edges, and intentionally unimplemented
  `setUnderlyingOracle()` / `resetUnderlyingOracle()`.
- Rollover/genesis golden vectors requiring live deployment state are not represented by the current
  offline fixture.
