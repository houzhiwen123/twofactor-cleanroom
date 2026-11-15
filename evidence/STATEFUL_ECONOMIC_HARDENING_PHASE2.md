# Stateful and economic hardening Phase 2

Status: **LOCAL-CLEANROOM PASS; no production-code change**

Baseline: `af0d955`.

## Scope and safety

This phase extends only the locally deployed clean-room core, Junior/Senior Underlying Vaults and
UnderlyingSingleAssetRouter. It uses Foundry mocks and local state. It does not use a wallet,
private key, signature, broadcast, `deal`, `store`, target storage edit, verified source or frontend
bundle. These results are not TARGET-CONFIRMED.

USD Vault first-notes issuance, live DEX execution and target-fork stateful compatibility remain
UNKNOWN and outside this phase.

## Expanded stateful model

The invariant campaign increased from `32 x 16` to `64 x 32`: each invariant executes 2,048
handler calls. The handler remains the only fuzz target and now exposes 15 bounded actions.

Phase 2 adds:

- prices from `8,000` to `800,000` USD per BTC instead of the earlier `40,000` to `160,000` range;
- independently bounded base, flash-base and flat impact fees from zero through `1e18`;
- failed Router redemption with impossible `minOut`, in addition to failed deposit;
- a stronger failure fingerprint covering selected Perp balances and Controller fee accounting;
- the existing deposits, redemptions, donations, issue/upkeep, balanced Bond mint, rollover,
  rebalance and pause/unpause actions.

All six original invariants still pass:

1. underlying supply is fully accounted;
2. both Perp supplies equal tracked balances;
3. Vault note supplies and permanent minimum liquidity remain intact;
4. Router retains no underlying, Perp or notes;
5. reserve arrays remain unique and match Controller reserve values;
6. deliberately failed Router operations leave the tracked fingerprint unchanged.

## Deterministic Phase 2 scenarios

### High-fee failure and recovery

A Junior Vault is first rebalanced so that it holds both underlying and Perp JR. With flash base
fee set to exactly `1e18`, a Router exit that must redeem the Perp leg reverts with
`OpDisabled()` and leaves the complete tracked state unchanged. After fees are restored to zero,
the same notes can exit successfully.

A separate synthetic FeePolicy input with both flat impact components at `1e18` returns the raw
`2e18` total-fee signal. This confirms the local Controller test covers the disable signal rather
than treating it as a user charge above 100%.

The first construction used an all-underlying Vault and did not revert because no Perp leg reached
the Controller. The corrected test explicitly rebalances before the high-fee exit. This was a test
construction issue, not a production-code failure.

### Eight-epoch stress sequence

The test executes eight weekly epochs at:

`82k -> 79k -> 84k -> 8k -> 800k -> 40k -> 160k -> 80k`.

It includes three balanced Controller mints, repeated upkeep, both Vault rebalance directions and
permissionless rollover attempts. The scenario requires at least one successful upkeep, rebalance
and rollover, then restores the initial price and exits all user SR/JR notes through the
proportional basket path. Asset and supply accounting remain exact.

### Alternating single-side flows

Eight alternating Senior/Junior deposits are followed by 0.1x or 10x price shocks and partial
basket exits. After restoring the initial price, all remaining user notes exit. Both Vaults retain
their permanent minimum liquidity and global accounting remains exact.

## Verification

- Phase 1 + Phase 2 focused suite: `12 passed, 0 failed`.
- Phase 2 deterministic suite: `3 passed, 0 failed`.
- Each invariant: `64 runs`, `2,048 calls`, `0` Foundry-level handler reverts.
- Full offline suite: `231 passed, 0 failed`.
- No contract under `src/` changed in this phase.

## Interpretation and limits

The longer campaign did not expose asset creation, supply drift, reserve duplication, Router dust,
loss of locked liquidity or partial state changes on expected failures. This is bounded local
testing, not formal verification and not evidence that the economic model is safe for real funds.

Administrative fee settings can deliberately disable single-asset paths. Proportional basket
redemption remains the local escape path tested here. Production readiness still requires target
stateful differential evidence, executable DEX lifecycle tests, USD Vault genesis closure and an
independent economic/security audit.
