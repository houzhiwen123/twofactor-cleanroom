# Security hardening phase 1

This phase contains BNB-DESIGN / CLEANROOM SAFETY changes. It does not claim that the target 2Factor deployment has
the same defects or implements these additional protections.

## Closed items

1. `UsdVault` uses DEX spot only as an oracle-divergence health signal. Direct settlement minimums are anchored to
   the independent underlying Oracle.
2. `UniswapV3DexStrategy` refunds the exact-input amount not consumed by a partial pool execution and preserves
   unrelated pre-existing token balances.
3. Lazy rollover returning an amount below `minCleanupVal` no longer reverts the surrounding user `flashMint2`.
   Explicit `rollover()` remains strict and returns `InsufficientRollover` below the threshold.
4. `FeePolicy` rejects endpoint slopes that can underflow during unbounded left/right extrapolation.
5. `BondsManager.deposit` rejects inputs that round to zero total tranche units before moving underlying.
6. Repeated USD Vault upkeep, Router dust sweeping and failure atomicity have dedicated regression coverage.
7. `ProtocolTimelock` adds a minimum one-day delay, multisig-only proposal/cancellation, permissionless delayed
   execution and self-administered roles. The production ownership handover is documented but cannot be executed
   until final deployment addresses and the multisig are selected.

## Verification

- `forge test --offline`: 264 passed, 0 failed, 0 skipped.
- Stateful invariant suite: 6 properties, 64 runs and 2,048 calls per property.
- `PerpController`: 22,497 runtime bytes, below the repository's 22,500-byte guard.
- `ProtocolTimelock`: 5,291 runtime bytes.
- Controller, USD Vault and Underlying Vault storage-layout checks passed.
- Underlying Vault frozen ABI check passed.
- `forge fmt --check` and `git diff --check` passed.

No wallet, private key, signature, RPC broadcast or mainnet mutation was used in this phase.
