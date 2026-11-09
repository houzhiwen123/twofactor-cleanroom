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
| probe-tests/*.sol | Foundry fork probes that produced the records (not compiled by this repo) |
| raw-logs.tar.xz | Raw forge logs and JSONL observations |

Spec items in docs/SPEC_CONTROLLER_ZH.md reference these reports.
