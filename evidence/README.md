# Black-box evidence (clean-room)

All data here came from local Base forks (chainId 8453, blocks 53494912 and 54990962), using public ABIs, read-only calls, and simulated transactions. No target source code or frontend bundle was read. No real transaction was broadcast.

| File | Contents |
|---|---|
| reviewer_fork_versions.log | Full proxy / implementation addresses and codehashes at both blocks |
| CONTROLLER_PROBES.md, CONTROLLER_PROBES_2.md | flashMint2/flashRedeem2/mint2, fees, pause, valueCap, JR liquidity, rebalance (raw OBS records) |
| ROLLOVER_PROBES.md, analyze_rollover_allocation.py | Rollover selection, funding, standard allocation (35 cases), backup branch |
| ROUND5_PROBES.md, LOG_SHA256SUMS.txt | Independent open-price backup selection (refutes closest-to-0.5), recover(), reserve array attempts; sha256 of all logs |
| ROUND4_PROBES.md | Backup bond selection, rollover thresholds, Perp token permission matrix, fresh-proxy genesis, rebalance window regression |
| CODEX_REVIEW_PROBES.md | Rounds 1-3 verification of the external review (lazy issue/rollover, per-side fees, AUM gross-up, fee settlement, protocol fees, redeem2, valueCap boundary, backup cap at shifted prices, partial rollover) |
| ROUND6_PROBES.md | Round 6 Controller authorization, rebalance window/cooldown, fee-guard, AUM, value-cap, and lazy-issue observations; exact reproduction commands and version lock |
| ROUND7_PROBES.md, round7_integrated_probe.log | Round 7 Perp ABI/ownership/permissions, Controller admin roles/validation, reserve sync, and nonzero rebalance ordering; version lock |
| ROUND8_PROBES.md, round8_review_probe.log, round8_setter_followup.log, round8_rebalance_trace.log | Round 8 tuple ABI, SR approval selector, setter boundary results, and trace-level rebalance call order |
| ROUND9_PROBES.md, probe-tests/Round9TraceProbe.t.sol, round9_*.log | Round 9 public rollover, upkeep (issuance/rebalance/no-op), lazy SR flash-mint traces, planner inputs/returns, and Controller timestamp opcode ordering |
| ROUND10_PROBES.md, probe-tests/Round10Probe.t.sol, round10_*.log | Round 10 caller matrices, separate matured-before-issue state, 15 planner-selection cases, exact public/lazy liquidity edges, and zero-amount call traces |
| ROUND11_PERP_DEPOSITS.md, probe-tests/Round11PerpDepositProbe.t.sol, round11_perp_deposit_results.log | Round 11 JR rollover-deposit permissions, zero/positive/multiple deposits, manager pre-check boundary, reserve registration and sync order |
| ROUND12_RESERVE_CLEANUP.md, probe-tests/Round12ReserveCleanupProbe.t.sol, round12_reserve_cleanup_results.log | Round 12 `recover`, paired/one-sided reserve intake, zero/full transfer cleanup, and exact swap-pop reserve-array ordering |
| ROUND13_SYSTEM_GAPS.md, round13-probes/Round13SystemGapProbe.t.sol, round13_system_gap_results.log | Round 13 backup selector metric/tie rule, upkeep four-state coordinator, exact lazy no-progress boundary, and oracle configuration entries |
| ROUND14_BACKUP_EXECUTION.md, round14-probes/Round14BackupExecutionProbe.t.sol, round14_backup_execution_results.log | Round 14 backup underlying-first execution, ordered/partial stale consumption, deposit cap and rolled-value vectors |
| ROUND15_CONTROLLER_GAPS.md, round15-probes/Round15ControllerGapProbe.t.sol, round15_controller_gap_results.log | Round 15 `mint2` input-side-only fee guard, `updateIssuer` validation/approval rotation, empty-genesis behavior and AUM-rate boundary |
| ROUND16_EXACT_VALUE_CAP_VM.md, round16-probes/*.t.sol, round16_exact_vm_results.log | Round 16 exact `subDR == 1e18` landings from both directions and extreme tranche VM behavior |
| ROUND17_BACKUP_E2E.md, round17-probes/Round17BackupEndToEndProbe.t.sol, round17_backup_e2e_results.log | Round 17 non-0.5 backup selection and stateful execution through the target Controller |
| USD_VAULT_PHASE2_MINT_DEPOSIT.md, usd-vault-phase2-mint-deposit.json, probe-tests/UsdVaultPhase2TargetProbe.t.sol | USD Vault TVL and paired-mint arithmetic, five historical vectors, two-stage rounding counterexample, two real deposit event orders and zero-input no-op |
| USD_VAULT_PHASE3_SESSION_CAPACITY.md, usd-vault-phase3-session-capacity.json, probe-tests/UsdVaultPhase3SessionCapacityProbe.t.sol | USD Vault active/inactive session state machine, exact expiry and DR-equality behavior, two natural deposit replays, and target proof that deposit is not limited by session minimum/direction/budget |
| USD_VAULT_PHASE4_REBALANCE_CAPACITY.md, usd-vault-phase4-rebalance-capacity.json, probe-tests/UsdVaultPhase4RebalanceCapacityProbe.t.sol | USD Vault exact rebalance-capacity formula, deadband, guard ordering, budget clipping, historical session subtraction, and clean-room planning-only implementation boundary |
| USD_VAULT_PHASE5A_REAL_REBALANCE.md, usd-vault-phase5a-real-rebalance.json, probe-tests/UsdVaultPhase5ARealRebalanceProbe.t.sol | Exact transaction-index replay of natural mint/redeem rebalance flows, asset/event ordering, DEX views, caller authorization, active-delay boundary and synthetic dependency-failure atomicity; evidence only, no production implementation |
| USD_VAULT_GENESIS.md, usd-vault-genesis.json, probe-tests/UsdVaultGenesisProbe.t.sol | Fresh-proxy target fork matrix for USD Vault first notes: exact no-op threshold, one-dollar note price, fixed locked notes, authorization, replay selector, donation behavior and event order |
| TARGET_KEEPER_OPERATIONS_RECON.md, target-keeper-operations-recon.json | Consolidated target-aligned maintenance task/caller/timing/error matrix, five selected natural vectors, 70-event operator inventory, and explicit private-scheduler UNKNOWNs; evidence/specification only, no off-chain Keeper implementation |
| KEEPER_MVP.md, ../keeper/, ../keeper_tests/ | BNB-DESIGN off-chain Keeper implementation and verification: fixed-block simulation, priority, bounded read retry/failover, non-retrying submission, receipt reconciliation, private state and 15 offline regressions |
| LOCAL_DEX_LIFECYCLE.md, local-dex-lifecycle.json, test/UsdVaultLocalDexLifecycle.t.sol | LOCAL-CLEANROOM executable pool and Inventory lifecycle: Strategy callback accounting, mint/redeem settlement, user exit, asset conservation and cross-contract rollback; not target-pool evidence |
| phase1b_current_forge_test.log, phase1b_current_sizes.log, ../test/ControllerRollover.t.sol | Current 84-test regression count, runtime-size baseline, public rollover/upkeep atomicity tests, and planner-failure propagation |
| local_genesis_baseline_105_*.log, local_genesis_baseline_105_sha256.txt | Local-only clean-room Genesis baseline: 105 offline tests, runtime sizes, frozen Controller storage layout and secret-free deployment simulation; no fork or target-system claim |
| probe-tests/*.sol | Foundry fork probes that produced the records, including Round6ControllerProbe.t.sol and Round7ReviewProbe.t.sol (not compiled by this repo) |
| LOG_SHA256SUMS.txt | SHA-256 manifest for all archived probe `.log` files |
| raw-logs.tar.xz | Archive of probe `.log` files, including Round 6, Round 7, Round 8, Round 9, and Round 10 logs |

Spec items in docs/SPEC_CONTROLLER_ZH.md reference these reports.
