# Governance handover

This is a BNB-DESIGN / CLEANROOM SAFETY deployment boundary, not a claim about the target protocol.

## Roles

- A tested multisig is the only proposer and canceller.
- Execution is permissionless after the configured delay.
- The timelock itself is the only role administrator.
- Keeper pause permissions remain operational roles; they do not receive upgrade or ownership authority.

`ProtocolTimelock` enforces a minimum delay of one day. Production deployment should normally use at least two days.

## Required handover order

1. Deploy `ProtocolTimelock` with the final multisig address.
2. For every `Ownable2Step` contract, call `transferOwnership(timelock)`, then have the multisig schedule
   `acceptOwnership()` through the timelock. Execute only after the delay.
3. For one-step `Ownable` contracts, transfer ownership directly to the timelock only after verifying the timelock
   deployment, roles and delay.
4. Transfer every `ProxyAdmin` owner to the timelock. A proxy implementation owner and its `ProxyAdmin` are separate
   authority surfaces and both must be covered.
5. Verify the former deployer owns no production contract, `ProxyAdmin`, proposer role or default-admin role.

## Contracts to inventory

- `BondsManager`, `BondIssuer`, `PerpController`, `FeePolicy`
- both `PerpToken` contracts
- Junior/Senior `UnderlyingPerpVault` and `UsdVault`
- every `ProxyAdmin` created for a transparent proxy
- Oracle, Inventory or strategy administration deployed outside this repository

Do not broadcast the handover until the complete address inventory, bytecode hashes and rollback plan have been
reviewed by independent signers.
