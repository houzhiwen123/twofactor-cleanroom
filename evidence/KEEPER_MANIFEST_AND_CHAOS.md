# Keeper deployment manifest and chaos gate

## Classification and scope

This phase is **LOCAL-CLEANROOM/BNB-DESIGN**. It adds two release controls for this repository's
off-chain Keeper:

1. a read-only deployment-manifest generator pinned to one explicit block and block hash;
2. a deterministic long-sequence failure-injection harness for the existing Keeper engine.

It is not evidence about 2Factor's private Keeper service, public-chain RPC reliability or any
managed signer's authorization policy. No wallet, private key, signing operation, public broadcast,
production Solidity or proxy storage change was used.

## Fixed-block manifest

`python3 -m keeper.manifest` accepts a strict address-only input schema and an explicit block. It:

- verifies the configured chain ID;
- reads and rechecks the pinned block hash;
- observes proxy runtime size and `eth_getProof` codehash;
- reads the EIP-1967 implementation slot;
- observes implementation runtime size and codehash;
- emits a human-review-required config fragment to an atomic mode-`0600` file.

It rejects unknown input fields, including signing material, zero/duplicate addresses, a changed
block hash and invalid or missing runtime identity. It does not edit a Keeper config or automatically
accept a new implementation after an upgrade.

The same shared attestation observer is now used by manifest generation, Keeper preflight and the
local Anvil fixture. Keeper verification still short-circuits in the order proxy codehash,
implementation address, implementation codehash before any task simulation.

## Deterministic chaos/soak observation

Command:

```sh
python3 -m keeper.soak \
  --cycles 1000 \
  --seed 20261116 \
  --output .keeper/soak-result.json
```

Observed result:

| Item | Result |
|---|---:|
| Requested cycles | 1,000 |
| Submission attempts / unique hashes | 88 / 88 |
| Confirmed / reverted receipts | 76 / 12 |
| Receipt-pending observations | 176 |
| Injected read-RPC failovers observed | 464 |
| Engine restarts | 11 |
| Concurrent-send violations | 0 |
| Unreconciled submitted transactions | 0 |
| Final normal-path single-flight records | 0 |

All 15 invariants passed. The independent ambiguous-send scenario made exactly one send attempt,
persisted status `ambiguous`, and remained blocked through 20 reconstructed engines. The independent
attestation-drift scenario rejected the proxy mismatch before both `eth_call` simulation and send.

The harness uses deterministic in-memory transports and the real `KeeperEngine`, `RpcPool`,
`KeeperState`, observer and external-signer transaction-shape adapter. It intentionally does not
model mempool replacement, chain reorganization, provider-specific rate limits or actual managed
signer authorization.

## Verification

- Offline Keeper suite: **37 passed, 0 failed, 1 opt-in integration skipped**.
- Manifest-focused tests cover exact output, mode `0600`, strict schema and block-hash drift.
- Soak regression runs the same fixed seed twice and requires byte-for-byte equal result objects.
- The explicit 1,000-cycle result is stored under ignored `.keeper/` operational output.
- Explicit loopback Anvil lifecycle rerun: **1 passed, 0 failed** after the shared-attestation
  refactor.

Repository-wide size, storage, format and local-Anvil results are recorded at phase completion.

## Remaining external prerequisite

The Keeper still cannot prove through read-only calls that a selected production managed signer
will authorize the configured sender and selector allowlist. That requires an audited signer
control plane and one controlled non-production canary; this phase does not weaken that boundary.
