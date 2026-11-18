# Governance deployment drill

Date: 2026-11-17

Classification: **LOCAL-CLEANROOM / BNB-DESIGN**. This is a local deployment and operating-policy test. It is not a claim about the target 2Factor governance deployment. No wallet, private key, signature, RPC broadcast, or public-chain state change was used.

## Result

The local full-stack governance drill passed. It deployed the clean-room protocol, separated the emergency Keeper from governance, transferred nine contract owners and seven `ProxyAdmin` owners to a two-day `ProtocolTimelock`, accepted all two-step ownership transfers through delayed execution, and exercised configuration, upgrade, cancellation, emergency-pause, and delay-change boundaries.

Tests:

- `GovernanceDeploymentDrillTest`: **5 passed / 0 failed**.
- Existing `GovernanceTimelockTest`: **3 passed / 0 failed**.
- Total focused governance regression: **8 passed / 0 failed**.

## Ownership and role wiring

After the drill:

- Timelock owns `BondsManager`, `BondIssuer`, `PerpController`, `FeePolicy`, `PerpSr`, `PerpJr`, `JuniorKeeperVault`, `SeniorKeeperVault`, and `UsdVault`.
- Timelock owns the seven proxy administrators for Manager, Issuer, Controller, FeePolicy, Junior Vault, Senior Vault, and USD Vault.
- The governance Safe has proposer and canceller roles but no Timelock administrator role.
- Execution is permissionless only after the scheduled delay.
- A separate Keeper controls immediate Controller and SR/JR Vault pause/unpause operations.

## Defect found and fixed

The first drill exposed that constructor validation alone did not preserve the one-day delay floor. OpenZeppelin's standard Timelock permits a correctly scheduled self-call to `updateDelay(0)`. Before the fix, the local regression reached that path successfully.

`ProtocolTimelock` now validates every self-call to `updateDelay()` at the internal execution boundary. The guard therefore applies to both single and batch operations. Regression coverage proves:

- a single scheduled `updateDelay(0)` reverts with `InvalidGovernanceConfig`;
- a batch containing `updateDelay(0)` also reverts;
- a scheduled increase from two days to three days remains valid.

This is a clean-room safety rule, not target-confirmed 2Factor behavior.

## Emergency authority clarified

The first test also contained an incorrect assumption that the Keeper could not pause immediately. Source and execution results show the opposite:

- the governance Safe cannot directly pause Controller or the SR/JR Vaults;
- the designated Keeper can immediately pause all three;
- the same Keeper can immediately unpause all three.

This provides a fast emergency response path, but it also makes Keeper key security a production-critical trust boundary. Governance can replace the Keeper only through the Timelock delay.

## Release gates

- `forge fmt --check`: pass.
- `git diff --check`: pass.
- Runtime-size gate: pass. `ProtocolTimelock` is 5,436 bytes; `PerpController` remains 22,497 bytes.
- Controller frozen storage layout: pass, 84/84 entries.
- USD Vault storage-layout gate: pass.
- Underlying Vault storage-layout and 83-entry ABI gates: pass.

## What this does not prove

This drill does not deploy to Base Sepolia or Base mainnet, does not test a real Safe, does not sign transactions, and does not provide a production ownership-wiring/broadcast script. Before any public testnet deployment, the project still needs explicit Safe/Keeper addresses, a funded non-production deployer, deterministic address and chain checks, post-deployment attestation, and an operator runbook for Keeper compromise and Timelock recovery.

Machine-readable summary: `evidence/governance-deployment-drill.json`.
