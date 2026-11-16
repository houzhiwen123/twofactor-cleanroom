# Clean-room Keeper MVP

This dependency-free Python service executes the conservative maintenance loop:

`read a fixed block → eth_call every task → submit at most one task → confirm receipt → rescan`

It does not hold a private key. Dry-run is the default. Live submission requires both `live: true`
in the config and the CLI flag `--allow-broadcast`; the configured submit RPC must expose a managed
or unlocked sender through `eth_sendTransaction`. Never point that option at a public RPC.

## Evidence boundary

The public function selectors, permissionless caller observations, and benign business-error
selectors are TARGET-CONFIRMED in `evidence/TARGET_KEEPER_OPERATIONS_RECON.md`. Polling, task
priority, failover, gas margin, confirmation depth, and global single-flight behavior are our
BNB-DESIGN. They are not claims about 2Factor's private Keeper service.

The catalog is, in priority order:

1. Controller `upkeep()`
2. Controller `rollover()`
3. Controller `rebalance()`
4. Junior then Senior Underlying Vault `rebalance()`
5. USD Vault `upkeep()` then `rebalance()`

USD Vault `swap()` is deliberately excluded because it is an authorized inventory callback.

## Safety rules

- All simulations share one explicit block number.
- Read RPC transport/provider failures retry with bounded exponential backoff and rotate endpoints.
- Deterministic EVM reverts never trigger provider failover.
- An unknown revert blocks submission when it outranks the selected task.
- Submission uses one endpoint and is never retried automatically.
- A dropped/ambiguous send persists a lock requiring operator reconciliation.
- At most one transaction may be outstanding; after confirmation the next cycle rescans fresh state.
- Target bytecode must exist and the chain ID must match before simulation.
- Each snapshot logs its block hash/time, sender balance, and target code sizes without secrets.
- The state file is written atomically with mode `0600`.

## Run

Copy `keeper/config.example.json`, replace every non-null contract address with the deployment
address, and keep `live` false while validating:

```sh
python3 -m keeper --config keeper/config.local.json
python3 -m keeper --config keeper/config.local.json --loop
```

Only after configuring a dedicated managed-signing RPC:

```sh
python3 -m keeper --config keeper/config.live.json --loop --allow-broadcast
```

The process writes JSON Lines to stdout. Protect the config even though the Keeper rejects and
never reads private-key fields.

## Test

```sh
python3 -m unittest discover -s keeper_tests -v
```

Tests are offline and cover fixed-block simulation, benign versus unknown reverts, read failover,
double live opt-in, task priority, ambiguous-send locking, receipt reconciliation, and chain/code
preflight.

## Local Anvil end to end

The local lifecycle runner starts an ephemeral Anvil with auto-impersonation, deploys only this
repository's clean-room contracts through `DeployGenesisLocal`, parses the real deployment
addresses, writes private generated configs under `.keeper/`, and drives the real Keeper through:

`rebalance → receipt/rescan → idle cooldown → issue upkeep → stale-boundary upkeep → rollover`

It rejects every non-loopback RPC and never reads a private key:

```sh
python3 -m keeper.local_anvil --repo-root . --output-dir .keeper/anvil-e2e
```

The output directory contains the deployment manifest, dry/live configs, structured events, Forge
deployment log and result JSON. All are `LOCAL-CLEANROOM/BNB-DESIGN`, not target evidence.

The same lifecycle is available as an opt-in integration test:

```sh
RUN_KEEPER_ANVIL_E2E=1 python3 -m unittest keeper_tests.test_local_anvil -v
```
