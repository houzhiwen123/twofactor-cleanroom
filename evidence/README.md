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
| probe-tests/*.sol | Foundry fork probes that produced the records, including Round6ControllerProbe.t.sol and Round7ReviewProbe.t.sol (not compiled by this repo) |
| LOG_SHA256SUMS.txt | SHA-256 manifest for all archived probe `.log` files |
| raw-logs.tar.xz | Archive of probe `.log` files, including Round 6, Round 7, and Round 8 logs |

Spec items in docs/SPEC_CONTROLLER_ZH.md reference these reports.
