# Phase 1b status

Only behavior backed by the cited specifications, probes, or public ABIs is implemented. A
pending row is deliberately not filled in by inference.

| feature | status ✅/pending | evidence file+section | test name |
|---|---|---|---|
| PerpToken ERC20 metadata, 8 decimals, owner/controller permissions, 50-entry cap, duplicate registration, JR-only approvals | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 4 P3; Controller/Balancer public ABIs | `testPerpPermissionsCapDuplicateAndJuniorApproval` |
| Perp reserve data, tranche valuation, and reserve sync events | ✅ | `docs/SPEC_CONTROLLER_ZH.md` §7b; Balancer public ABI; `src/policy/PerpBalancer.sol` reserve structs | `testReserveDataTrancheValueFloors` |
| `flashMint2` share floors, returned net shares, protocol/collected split | ✅ | `docs/SPEC_CONTROLLER_ZH.md` §§2, 3; `evidence/CODEX_REVIEW_PROBES.md` Round 1 H2/H3b | `testFlashMint2GoldenNetShares`, `testFlashMint2ProtocolSplitGoldenVector` |
| Protocol amount `floor(gross * protocolFeePerc / 1e18)` and fee balance split | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H3b; `review_protocol_permissions_observations.log` OBS values | `testFlashMint2ProtocolSplitGoldenVector` |
| `redeem2` net-perp basket floors and fee-token retention | ✅ | `docs/RECON_FINDINGS.md` redemption notes; `evidence/CODEX_REVIEW_PROBES.md` Round 1 H9 | `testRedeem2FloorsAndRetainsFeePerps`, `testRedeem2SecondFeeBearingGoldenVector` |
| JR liquidity and `OpDisabled` precedence | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H5 | `testJrLiquidityAndFeePriority` |
| Value-cap corrective-side crossing; exact equality interpretation | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 3 R6; exact equality was not observed | `testValueCapCorrectiveBoundaries` (chosen strict-crossing fixture; equality remains pending evidence) |
| Fee settlement on zero-plan rebalance, protocol preservation, AUM gross-up | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R2/R3 and AUM; `review_round2_r2_rebalance_protocol.log`, `review_aum_5pct_7d_observations.log` | `testRebalanceSettlesCollectedFeesAndMintsAumOnZeroPlan` |
| Rebalance trace ordering: settle fees, compute value/plan, transfer, then AUM mint | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R2 and AUM trace; see code-order note in `PerpController.rebalance` | `testRebalanceSettlesCollectedFeesAndMintsAumOnZeroPlan` |
| Pause selectors, `UserOpsPaused()` / `SystemOpsPaused()` errors, and same-window recent-rebalance guard | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 4 P5; Controller public ABI (errors are present; no pause events are in the ABI) | `testPauseSelectorsAndRebalanceWindowEdges` |
| `pullProtocolFees` only by collector; arithmetic underflow on over-withdraw | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R3 | `testFlashMint2ProtocolSplitGoldenVector` |
| `mint2` latest-bond acceptance and issuer `issue()` call | ✅ | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1, Round 2 R1; latest tranche pair | `testMint2PerSideFloorGoldenVector` |
| Unit regression for `mint2` issue-before-check and non-latest rejection | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 2 R1; transaction-revert call ordering not asserted offline | — |
| `flashRedeem2` gross-floor vectors, per-side fees, SR-to-JR settlement, and output event order | ✅ | `evidence/CONTROLLER_PROBES_2.md` §Controller operation trace; `evidence/CODEX_REVIEW_PROBES.md` Round 1 H2 | `testFlashRedeem2Gross999999GoldenCases`, `testFlashRedeem2TwoSidedGoldenSettlement`, `testFlashMint2PerSideFeeDivergence` |
| `mint2` per-side tranche-value floors, share floors, and fee-perp minting | ✅ | `evidence/CONTROLLER_PROBES.md` §mint2 tranche valuation and perps; latest-bond `OBS` record | `testMint2PerSideFloorGoldenVector` |
| Rebalance window endpoint semantics beyond the tested calls | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 4 P5; timestamps did not distinguish endpoint inclusivity | `testPauseSelectorsAndRebalanceWindowEdges` |
| `upkeep`, public/lazy rollover, backup bond selection, `InsufficientRollover` paths | pending | `docs/SPEC_CONTROLLER_ZH.md` §§5, 7b; `evidence/CODEX_REVIEW_PROBES.md` Rounds 1–5 | — |
| SR lazy issue in `flashMint2` and `mint2` | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1 and Round 2 R1; offline unit fixture not included | — |
| `recover()`, tranche removal/array reordering, rollover deposit bookkeeping | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 5 Q3/Q4; removal behavior unresolved | — |
| Genesis/zero-supply seeding and exact zero-claim valuation | pending | `evidence/CODEX_REVIEW_PROBES.md` Round 4 P4; zero-supply call panicked; seed path unresolved | — |
| Slippage equality and extreme VM behavior | pending | `docs/SPEC_CONTROLLER_ZH.md` pending-evidence notes; Round 5 Q7/Q8 not run | — |
| Oracle setter/reset semantics, remaining ABI admin behavior and setter validation | pending | Controller public ABI; behavior not established by cited evidence | — |

## Behavior intentionally left pending

- `upkeep()`, `rollover()`, lazy rollover, backup-bond selection, and their shortfall/partial-plan
  state machine.
- `PerpToken.recover()` and tranche deregistration or reserve-array reordering.
- First-mint/genesis seeding and zero-supply valuation.
- Exact `post subDR == 1e18` value-cap behavior. The implementation rejects only a strict crossing,
  as directed; that equality choice is not represented as observed chain behavior.
- Slippage equality, extreme VM/zero tranche-supply edges, and unverified oracle-reset/admin details.
- Issue-order/non-latest `mint2` rejection tests and rollover/genesis golden vectors requiring live
  deployment state are not represented by the current offline fixture.
