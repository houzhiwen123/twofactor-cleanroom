# Release-blocker remediation after `3aa1117`

## Scope and evidence labels

This change set starts from local commit `3aa1117b83e621f92e4533569d10d17efce8b30d`.
It uses three distinct labels:

- **TARGET-CONFIRMED**: reproduced from the archived public-chain fork evidence.
- **LOCAL CLEANROOM / BNB-DESIGN**: a defensive rule in this repository, not a claim about 2Factor.
- **OPEN ECONOMIC BLOCKER**: reproduced locally, but intentionally not changed without an equivalent-state target differential or an explicit product-policy decision.

## Changes

| Area | Classification | Result |
|---|---|---|
| Zero-valued rollover row | TARGET-CONFIRMED | `BondsManager.deposit(bondID, 0)` returns the canonical tranche addresses and zero amounts without moving assets or minting. This matches `ROUND10_PROBES.md` and `ROUND11_PERP_DEPOSITS.md`. |
| USD-only router deposit | LOCAL CLEANROOM / BNB-DESIGN | A zero required swap now skips both DEX and Controller calls, so a standard pool cannot reject an otherwise valid USD-only deposit. |
| Router residual balances | LOCAL CLEANROOM / BNB-DESIGN | Both single-asset routers isolate each call with pre/post balance floors. Old dust is neither consumed by the current call nor refunded to the current user. |
| Inventory authorization | LOCAL CLEANROOM / BNB-DESIGN | Governance can revoke or rotate a swapper without changing storage layout. Zero and unauthorized updates revert. |
| Inventory price | LOCAL CLEANROOM / BNB-DESIGN | Inventory mint/redeem amounts must remain within the configured underlying-oracle deviation. Failure is atomic. |
| USD Vault idle underlying | LOCAL CLEANROOM / BNB-DESIGN | The two-asset redemption quote refuses to exclude nonzero idle underlying. Permissionless upkeep must settle it first, preventing silent transfer of its value to remaining note holders. |

The idle-underlying rule is a fail-closed accounting safeguard, not a complete availability solution. If upkeep cannot settle because the DEX, Oracle or liquidity check fails, redemption remains blocked instead of underpaying the exiting user. A production release still needs an explicit exit entitlement/settlement design for that state.

## Proportional exit comparison

`GenesisDeploymentTest.testGenesisProportionalBasketAndFlashExitComparison` independently starts from the same state for every row:

`82k price -> 79k -> 84k -> rollover -> 80k -> rollover`.

The user exits the same percentage of their own SR and JR balances on both paths.

| User position exited | Theoretical value | Basket received value | Basket effective fee | cbBTC received | cbBTC effective fee |
|---:|---:|---:|---:|---:|---:|
| 1% | 2,315,979 | 2,258,844 | 2.4669912810090246% | 604,916 | 73.8807648946730518% |
| 10% | 23,159,801 | 22,587,441 | 2.4713511139409185% | 5,812,282 | 74.9035753804620341% |
| 50% | 115,799,010 | 112,894,318 | 2.5083910475573150% | 18,889,374 | 83.6877931857966661% |

These figures are **LOCAL CLEANROOM / BNB-DESIGN observations**, not TARGET-confirmed fees. They reproduce the external review's central finding: the high cbBTC fee is not limited to a terminal 100% exit.

## Deliberately not changed

The FeePolicy curve and `PerpController.flashRedeem2` are unchanged. The current cbBTC result is an **OPEN ECONOMIC BLOCKER** because the local FeePolicy already matches the target fee-policy vectors, while this multi-epoch Controller state has not yet been differentially replayed against the target. A production policy change would be a protocol-design decision rather than a clean-room compatibility fix.

Before real funds, require one of:

1. equivalent-state TARGET Controller differential evidence showing this path is compatible; or
2. an explicit BNB-design exit policy with user-visible quotes, `minOut`/maximum-fee protection and liquidity limits.

## Local validation

- All 35 test files were run in six compile groups: **317 passed, 0 failed, 0 skipped**.
- This includes the two stateful invariant suites and the corrected nonzero-DEX reentrancy vector.
- Runtime sizes: Controller `21,519` bytes; USD Vault `18,023`; BondsManager `12,968`; SingleAssetRouter `6,338`; UnderlyingSingleAssetRouter `4,323`.
- Controller frozen storage layout: `84/84` match.
- USD Vault and UnderlyingPerpVault frozen storage-layout checks: pass.
- `forge fmt --check` and `git diff --check`: pass.
- The one-shot all-test compilation was stopped after making no progress for an extended period; the complete result above comes from the same source and configuration split by test-path groups, matching the repository's established resource-safe verification method.

