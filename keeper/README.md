# Clean-room Keeper

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
- Live deployments pin proxy codehash, EIP-1967 implementation and implementation codehash.
- The external signer adapter accepts only zero-value four-byte maintenance calls from the configured sender.
- Each snapshot logs its block hash/time, sender balance, and target code sizes without secrets.
- State, health, metrics and alerts are written with mode `0600`.

## Run

Generate a review-only deployment identity at one explicit historical block before writing a live
configuration. The input accepts only deployment ID, chain ID and contract addresses; it rejects
private-key fields and never changes the Keeper configuration:

```sh
cp keeper/manifest.input.example.json .keeper/manifest-input.json
python3 -m keeper.manifest \
  --input .keeper/manifest-input.json \
  --rpc-url https://reviewed-read-rpc.example \
  --block 54990962 \
  --output .keeper/deployment-manifest.json
```

Review the block hash, proxy/implementation addresses and both codehashes independently before
copying the emitted `configFragment`. The output is mode `0600`; generation never auto-accepts or
auto-refreshes an attestation.

Copy `keeper/config.example.json`, replace every non-null contract address with the deployment
address, and keep `live` false while validating:

```sh
python3 -m keeper --config keeper/config.local.json
python3 -m keeper --config keeper/config.local.json --loop
```

Validate a configured deployment and external signer without broadcasting:

```sh
chmod 600 keeper/config.preflight.json
python3 -m keeper --config keeper/config.preflight.json --preflight-only
```

Only after configuring a dedicated HTTPS managed-signing RPC and reviewing
[`OPERATIONS.md`](OPERATIONS.md):

```sh
python3 -m keeper --config keeper/config.live.json --loop --allow-broadcast
```

The process writes JSON Lines to stdout. Protect the config even though the Keeper rejects and
never reads private-key fields. Submission-enabled configs must have mode `0600`.

## Test

```sh
python3 -m unittest discover -s keeper_tests -v
```

Tests are offline and cover fixed-block simulation, benign versus unknown reverts, read failover,
double live opt-in, task priority, ambiguous-send locking, receipt reconciliation, and chain/code
preflight, proxy/implementation attestations, signer transaction-shape enforcement, health,
Prometheus metrics and alert boundaries. They also run a deterministic 300-cycle chaos regression.

Run the longer deterministic soak before a release candidate:

```sh
python3 -m keeper.soak \
  --cycles 1000 \
  --seed 20261116 \
  --output .keeper/soak-result.json
```

The soak is local-only. It injects read transport failures, pending and reverted receipts, process
restarts, one ambiguous submission, and deployment-attestation drift. A passing result requires no
concurrent or duplicate sends, complete receipt reconciliation, a persistent ambiguous lock and no
simulation/send after identity drift.

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
