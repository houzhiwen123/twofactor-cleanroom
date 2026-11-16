# Keeper production hardening

## Classification and scope

This phase is **LOCAL-CLEANROOM/BNB-DESIGN**. It hardens the repository's off-chain Keeper; it does
not reconstruct 2Factor's private scheduling, alerting, signer or retry infrastructure. No public
network transaction, real signer, wallet or private key was used.

No production Solidity, proxy storage or task priority changed.

## Implemented controls

### Deployment identity

Each active maintenance proxy can be pinned to three fixed-block values:

1. proxy `codeHash` from `eth_getProof`;
2. the EIP-1967 implementation address;
3. implementation `codeHash` from `eth_getProof`.

Live configuration requires all three values for every configured Controller/Vault. Any mismatch
fails before task simulation or transaction submission.

### External signer boundary

`ExternalSignerClient` accepts no signing material and exposes only `eth_sendTransaction`. It
rejects a wrong sender, invalid target, calldata other than one four-byte maintenance selector,
non-canonical/zero gas, and every additional transaction field (including `value`, nonce and fee
overrides). It checks the submit chain ID and pending sender nonce before operation.

`managed-rpc` requires a separate HTTPS endpoint. `local-unlocked` requires a literal loopback IP
and is forbidden on Base mainnet/testnet chain IDs. A read-only preflight cannot prove that an
external signer will authorize a future send; that remains an operator/control-plane check.

### Observability

The event observer writes:

- atomic mode-`0600` health JSON;
- atomic mode-`0600` Prometheus textfile metrics;
- append-only mode-`0600` actionable alert JSONL.

Unknown deterministic simulation errors produce `degraded` health even when a higher-priority task
successfully executes. Ambiguous submissions, blocked operation, reverted receipts and cycle
errors produce `critical` health. Alert cooldown suppresses repeated pages without suppressing raw
events or metrics.

RPC logs remove URL userinfo, query, fragment and the entire provider path so path-embedded API
tokens cannot appear in events.

## Local staged-drill observation

The opt-in Anvil test generated and verified attestations for Controller, Junior Vault, Senior
Vault and USD Vault, then retained the proven lifecycle:

`Controller rebalance → issue upkeep → stale-boundary upkeep → rollover`

All four sends were individually confirmed and followed by a fresh rescan. The final health state
was correctly `degraded`, not healthy, because the local USD Vault upkeep simulation still returns
the known local DEX `min size` hard error. A `SIMULATION_ERROR` warning was persisted while the
higher-priority Controller maintenance continued.

## Verification

- Keeper discovery suite: **31 passed, 0 failed, 1 opt-in integration skipped**.
- Explicit hardened Anvil staged drill: **1 passed, 0 failed**.
- The drill asserts four deployment attestations, four submissions/confirmations, no pending final
  transaction, degraded health, Prometheus counters and an alert file.
- No public RPC, real signer or signing material was used.

Repository-wide size/storage/format gates are recorded separately at phase completion. The full
Foundry suite's prior slow-compilation limitation remains unless a later run completes; no passing
claim is inferred from this Python/integration result.

## Remaining external prerequisites

- Select and audit a managed signer product/control plane.
- Configure target/selector/value allowlists, rate limits and independent operator approval there.
- Connect the Prometheus textfile and alert JSONL to reviewed monitoring/alert delivery.
- Perform a non-production deployment drill with the actual signer and RPC topology.
- Establish a reviewed manual reconciliation tool before clearing any ambiguous single-flight lock.

