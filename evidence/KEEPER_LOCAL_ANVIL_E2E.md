# Keeper local Anvil end-to-end

## Scope and classification

This is a **LOCAL-CLEANROOM/BNB-DESIGN** integration result. It deploys only this repository's
contracts to an ephemeral Anvil chain and exercises the off-chain Keeper against those deployed
addresses. It is not target 2Factor evidence and no transaction was sent to Base or any public
network.

The harness uses Anvil auto-impersonation for the fixed local development address
`0x00000000000000000000000000000000000A11cE`. It never reads, accepts or writes a private key.
Every RPC URL is required to use a literal loopback IP. Generated configurations, state and result
files are written atomically with mode `0600`; Anvil's generated key banner is suppressed.

## Reproduction

```sh
python3 -m keeper.local_anvil --repo-root . --output-dir .keeper/anvil-e2e
```

The command starts an ephemeral chain with chain ID `31337`, deploys the complete clean-room
Genesis system through `DeployGenesisLocal`, generates Keeper configuration from the emitted
addresses, runs the lifecycle below, writes structured evidence, and then terminates Anvil.

## Observed deployment

The final reproducible run deployed these proxy addresses:

| Component | Address |
|---|---|
| Controller | `0x00490D1AE862AAa4a202AB920d709905738eA519` |
| Junior Underlying Vault | `0x6335066390B13fF33463010d95651F091FA6f6eE` |
| Senior Underlying Vault | `0x5F57CB43D1506A17f3A1164da94aA11D8D04F503` |
| USD Vault | `0x3720ca0F90CB03eBC7EfC61A0435cEE97eB52B92` |

Keeper preflight observed deployed bytecode at all four addresses before simulation. The proxy
runtime measured `787` bytes at each address; implementation runtime-size checks remain a separate
repository gate.

## Lifecycle result

| Stage | Fixed chain state | Result |
|---|---|---|
| Dry-run discovery | block 8, timestamp `1800000005` | Selected `controller_rebalance`; no transaction sent |
| Real read failover | first loopback endpoint deliberately closed | One bounded failover to the live local endpoint |
| Submit and confirm | same Genesis state | `controller_rebalance` submitted and confirmed once |
| Fresh controller rescan | block 9 | No Controller task executable; cooldown/no-work state observed |
| Issue boundary | timestamp `1800558000` | `controller_upkeep` submitted and confirmed once |
| First stale boundary | timestamp `1801767600` | `controller_upkeep` submitted and confirmed once |
| Post-upkeep rescan | same timestamp, fresh block | `controller_rollover` submitted and confirmed once |

The four final local transaction hashes are machine-recorded in
`.keeper/anvil-e2e/result.json`. Each receipt reached the configured one-confirmation threshold,
cleared the single-flight record and forced a fresh simulation before another submission.

At the issue and stale boundaries more than one Controller task was executable. The observed
selection followed the declared BNB-DESIGN priority: `upkeep` before `rollover`, and `rollover`
before `rebalance` after upkeep completed.

## Failure and safety boundaries

- The dry-run configuration contained a closed loopback endpoint before the valid endpoint. The
  first transport call failed once, rotated providers, and completed without operator input.
- The local USD Vault `upkeep()` simulation reverted with an unknown local DEX `min size` error.
  Keeper preserved it as a hard error. Because it ranked below the selected Controller task, it did
  not block that higher-priority task; it was never submitted.
- Submission was never retried. Every submitted hash came from one `eth_sendTransaction` call and
  was reconciled through the persisted single-flight record.
- Immediately after Controller rebalance, the controller-only rescan returned no executable task,
  proving the confirmed transaction was not duplicated.
- The runner rejects public RPC URLs and suppresses Anvil's generated mnemonic/private-key banner.

## Generated local artifacts

The ignored `.keeper/anvil-e2e/` directory contains:

- `deployment.json`: local addresses and chain metadata;
- `keeper.dry.json`, `keeper.live.json`, `keeper.controller-only.json`: generated mode-`0600`
  configs;
- `keeper-events.jsonl`: snapshots, every simulation, failover, submission and receipt;
- `live-state.json`: final single-flight state;
- `result.json`: compact machine-readable outcome;
- `forge-deployment.log`, `anvil.log`: local deployment/RPC diagnostics without key material.

The opt-in regression form is:

```sh
RUN_KEEPER_ANVIL_E2E=1 python3 -m unittest keeper_tests.test_local_anvil -v
```

## Verification gates

- Keeper test discovery: **18 passed, 0 failed, 1 opt-in integration skipped**.
- Explicit opt-in Anvil integration: **1 passed, 0 failed**.
- Python compile check: passed with its cache redirected to `/tmp`.
- Runtime-size gate: passed; `PerpController` remains **22,497 bytes**.
- Frozen Controller, Underlying Vault and USD Vault storage-layout gates: passed.
- Frozen Underlying Vault ABI gate: passed (`83` entries).
- `forge fmt --check` and `git diff --check`: passed.
- `forge test --offline`: attempted after the successful deployment, but Solc remained in the
  40-file compilation phase without an error for 10 minutes and was stopped. This is **not**
  represented as a passing full-suite run. This phase changes no Solidity production logic.

