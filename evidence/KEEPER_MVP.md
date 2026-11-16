# Clean-room Keeper MVP

## Scope

This phase implements our off-chain operational service around the maintenance entries catalogued
in `TARGET_KEEPER_OPERATIONS_RECON.md`. No Solidity production contract, proxy storage slot, wallet,
private key, target private service, or mainnet state was changed.

## Evidence classification

| Item | Classification |
|---|---|
| Maintenance function selectors and observed permissionless caller boundary | TARGET-CONFIRMED |
| Known no-work/window/cooldown error selectors | TARGET-CONFIRMED for the cited probes |
| USD Vault `swap()` exclusion from the public task list | TARGET-CONFIRMED authorization boundary |
| Priority order, polling, retry/backoff, failover and confirmation depth | BNB-DESIGN |
| Dry-run default, double broadcast opt-in and global single-flight | BNB-DESIGN safety policy |
| Private 2Factor Keeper queue, gas bidding and alerting rules | UNKNOWN |

## Implemented flow

1. Read and verify chain ID, one explicit block, block metadata, sender balance and target bytecode.
2. Simulate every configured maintenance task with `eth_call` at that same block.
3. Classify exact known business reverts as `not_needed`; preserve unknown reverts as errors.
4. In live mode, estimate gas and submit at most the highest-priority executable task.
5. Persist the single-flight record before sending. Any ambiguous send remains locked and is never
   retried automatically.
6. Poll the receipt, require the configured confirmations, clear the lock and rescan fresh state.

Read calls use bounded exponential retry and endpoint rotation. Deterministic EVM reverts never
rotate providers. Submission deliberately uses one separate managed-signing RPC and has no retry.
Private signing material is rejected anywhere in the JSON configuration.

## BNB-DESIGN priority

`Controller upkeep → Controller rollover → Controller rebalance → JR Vault rebalance → SR Vault
rebalance → USD Vault upkeep → USD Vault rebalance`

The service submits at most one task and rescans only after its confirmed result. This priority is
a conservative operational design, not a reconstructed claim about the target's private scheduler.

## Verification

- Keeper offline tests: **15 passed, 0 failed**.
- Python compile check: passed with bytecode cache redirected to `/tmp` because the sandbox blocks
  the default macOS user cache directory.
- Example JSON parse: passed.
- `git diff --check`: passed.
- Runtime-size artifact check: passed; Controller remains **22,497 bytes**.
- Frozen Controller storage layout: passed.
- `forge fmt --check`: passed.
- Full `forge test --offline`: attempted twice; Solc remained in the 127-file compilation phase
  without an error for 10 and 15 minutes respectively, then was stopped. This is **not recorded as
  a passing full-suite run**. No Solidity file changed in this phase.

## Operational boundary

The current version is ready for local Anvil dry-runs after real deployment addresses are placed in
a copied config. Live broadcasting remains intentionally disabled until a dedicated managed signer,
monitoring, operator runbook and deployment-specific dry-run have been reviewed.
