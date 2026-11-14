# Stateful and economic hardening Phase 1

Status: **LOCAL-CLEANROOM PASS; no production-code change**

Baseline: `f57da64`.

## Scope and safety

This phase exercises only the locally deployed core + Junior/Senior Underlying Vault +
UnderlyingSingleAssetRouter system. It uses Foundry mocks and local state only. No wallet, private
key, signature, broadcast, target storage edit, `deal`, `store`, verified source or frontend bundle
was used. USD Vault first-notes issuance remains outside this phase and remains UNKNOWN.

## Stateful action model

`OperationalStatefulHandler` is the sole invariant fuzz target. It exposes 13 bounded actions:

- Router and direct deposits/redemptions;
- underlying and Perp donations to Vault/Perp destinations;
- oracle price changes from `40,000` to `160,000` USD per BTC;
- one-week epoch advances with `upkeep`;
- fresh Bond deposits and Controller mint;
- permissionless Controller rollover;
- SR/JR rebalance direction changes;
- keeper pause/unpause;
- failed `minOut` deposits for atomicity.

The invariant configuration is `32` runs at depth `16`, with expected action failures caught inside
the handler. The first run exposed a harness-only issue: Foundry fuzzed every deployed contract and
called `MockERC20.mint` directly, creating an untracked balance. The handler is now explicitly set
as the only target; no production logic was changed.

## Invariants

All six invariants passed:

1. Every underlying unit remains in the tracked actor, system, Vault, Perp, Router or Bond
   addresses.
2. Each Perp total supply equals all tracked Perp balances, including permanently locked shares.
3. Vault note supplies remain fully accounted and each Vault retains exactly
   `MINIMUM_LIQUIDITY` locked notes.
4. Router never retains underlying, Perp or Vault notes after a completed or reverted action.
5. Perp reserve arrays contain unique tranche addresses and their calculated value matches the
   Controller state.
6. A failed `minOut` operation leaves the complete tracked fingerprint unchanged.

Each invariant executed `32` sequences with `16` calls per sequence (`512` calls per invariant),
including price changes, donations, epoch advances, rollovers, rebalances and failed operations.

## Economic attack vectors

Three deterministic local attacks passed:

- A Junior Vault donation round trip cannot return more underlying than the attacker's starting
  capital.
- Thirty-two repeated tiny Router deposit/redeem round trips cannot create underlying or leave
  Router dust.
- A `50%` price shock still permits pro-rata SR/JR basket exits while retaining the locked minimum
  liquidity.

These are local safety observations, not claims about target economic policy or production capital
adequacy. The severe multi-epoch exit-fee behavior documented elsewhere remains a separate economic
calibration concern.

## Verification

- Focused stateful/economic suite: `9 passed, 0 failed`.
- Full offline suite: `228 passed, 0 failed`.
- Existing production contracts were not changed by this phase.
- `forge fmt --check` and `git diff --check` pass after the final test harness change.
- Controller, UnderlyingPerpVault and UsdVault storage checks plus the frozen UnderlyingPerpVault
  ABI gate remain required before commit.

## Remaining limits

- This is bounded fuzzing, not formal verification.
- The local DEX mock is non-executing; USD Vault remains activation-blocked.
- No target-fork stateful trace is claimed by these local tests.
- Further phases should add longer sequences, adversarial fee/price schedules and an independent
  review of the economic model before any real deployment.
