# Full Protocol Three-Vault Lifecycle

## Result

The local clean-room deployment now has one deterministic acceptance test that exercises the core protocol and all
three user Vault products in the same deployed system:

- USD Senior Vault (`USDC + Perp SR`);
- cbBTC Senior Vault (`cbBTC + Perp SR`);
- cbBTC Junior Vault (`cbBTC + Perp JR`).

The acceptance test passes and the complete repository suite passes with **307/307 tests** across 38 suites.

## Lifecycle covered

1. Deploy the complete local system from `DeployGenesisLocal`.
2. Verify Controller, guarded rollover planner, Vault, Inventory, and DEX wiring.
3. Rebalance the SR and JR cbBTC Vaults into mixed underlying/Perp inventories.
4. Deposit into the SR Vault through `UnderlyingSingleAssetRouter`.
5. Deposit into the USD and JR Vaults through `PairRouter` and the executable local DEX.
6. Execute the USD Vault direct DEX rebalance into Perp SR after the active-session delay.
7. Execute the Controller system rebalance (the periodic SR/JR funding transfer) and verify aggregate reserve value.
8. Advance through three additional Bond epochs with real Bond deposits and balanced Perp minting.
9. Execute rollover and verify that the stale reserve row is removed from both Perp reserve sets.
10. Force an SR single-asset exit to fail on `minOut` and verify exact state rollback.
11. Redeem the USD/JR pair and SR single-asset positions successfully.
12. Verify that all user notes are burned, routers retain no user assets, and tracked supplies remain conserved.

Supply accounting covers cbBTC, USDC, Perp SR, Perp JR, USD Vault notes, SR Vault notes, and JR Vault notes.

## Boundary findings

### USD minimum operation size

The first test vector reached `OpUnavailable("min size")`. The initial USD position was below the Vault's configured
`50e18` minimum operation value after applying the 33% session deployment limit. The acceptance fixture was raised to
an approximately USD 800 deposit so the resulting session capacity crosses the real configured minimum. No production
parameter was changed.

### SR exit liquidity is supplied through JR reserve absorption

This gap is now closed with target source plus a strict historical-state Base fork trace. Perp SR does not need idle
cbBTC. The Controller selects an equal-value portion of SR's tranche reserves, transfers it to Perp JR, and JR pairs or
recovers those reserves before paying the complete cbBTC redemption through the Controller.

The artificial `1,000,000`-unit SR cbBTC fixture has been removed. This acceptance test passes with the real deployment
model and no dedicated SR exit cash buffer. Exact evidence and accounting are in
`TARGET_SR_EXIT_LIQUIDITY_SOURCE.md`.

## Verification

- Three-Vault acceptance test: 1/1 passed.
- Controller regression: 42/42 passed.
- Router regression group: passed.
- Genesis deployment regression: 20/20 passed.
- Full Foundry suite: 307/307 passed across 38 suites.
- Stateful invariants: passed at the repository-configured 64 runs and 32-call depth.
- `PerpController` runtime: 21,519 bytes, below the 22,500-byte repository limit.
- Controller storage layout: frozen 84/84 entries matched.
- USD Vault and Underlying Perp Vault storage-layout guards: passed.
- `forge fmt --check`: passed.
- `git diff --check`: passed.

## Scope

This was a local simulation only. It did not connect a wallet, use a private key, broadcast a transaction, alter a
public deployment, or push a remote Git branch.
