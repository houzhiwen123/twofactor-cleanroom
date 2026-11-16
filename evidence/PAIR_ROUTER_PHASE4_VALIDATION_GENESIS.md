# PairRouter Phase 4 — dependency validation, zero inputs and local deployment

## Scope and labels

- `TARGET-CONFIRMED`: fixed Base fork, target PairRouter bytecode connected only to fresh local recording dependencies.
- `LOCAL-CLEANROOM`: behavior of the independently written contracts in this repository.
- No wallet, private key, signature or broadcast transaction was used.
- No target storage or natural account balance was changed with `deal`/`store`.

Target lock:

| Item | Value |
|---|---|
| Chain | Base (`8453`) |
| Block | `57,015,384` |
| PairRouter | `0x97c521D21468022E205d8A57b2fcaeE33d6714d6` |
| Runtime codehash | `0x487610478a620be27092ff42bf2dea6bfc08275af635abdc27245329f9801218` |
| Deposit selector | `0x0176cb45` |
| Redeem selector | `0xb2a72016` |

## TARGET-CONFIRMED dependency matrix

Both target entry points enforce the same four canonical relationships before moving assets:

| Mutation | Deposit | Redeem | Selector |
|---|---:|---:|---|
| Different Controller on the underlying Vault | revert | revert | `InvalidParamDefn()` / `0xd126d255` |
| Underlying Vault reports the Senior side | revert | revert | `0xd126d255` |
| Underlying Vault Perp differs from `Controller.perpJr()` | revert | revert | `0xd126d255` |
| USD Vault Perp differs from `Controller.perpSr()` | revert | revert | `0xd126d255` |
| Underlying Vault `underlying()` getter differs | success | success | — |
| USD Vault `underlying()` getter differs | success | success | — |
| USD Vault `usd()` getter changes | success | success | — |
| Strategy token getters differ | success | success | — |

The successful rows are zero-input observations. They establish which identities are not rejected
by the target's pre-operation dependency guard; they do not prove arbitrary non-zero token pairs are
safe or economically usable.

## TARGET-CONFIRMED zero-input behavior

- Canonical all-zero deposit succeeds and returns six zero words (`192` bytes).
- Canonical all-zero redeem succeeds and returns two zero words (`64` bytes).
- Neither path invokes Vault deposit/redeem, Controller mint/redeem or Strategy trade.
- With `healthCheck=false`, a zero Strategy address is accepted for both all-zero calls.
- Dependency and post-DR reads still run; zero inputs are a checked no-op, not a Genesis initializer.

Reproduction:

```sh
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL="$BASE_RPC_URL" \
forge test --offline --threads 1 \
  --match-path evidence/probe-tests/PairRouterPhase4ValidationGenesisProbe.t.sol -vv
```

Result: `4 passed, 0 failed`.

## LOCAL-CLEANROOM zero-Genesis matrix

Using actual fresh `UsdVault` and `UnderlyingPerpVault` proxies with zero note supply:

| Input | Result | Asset effect |
|---|---|---|
| Deposit all zeros | six-word zero success | none |
| Redeem all zeros | two-word zero success | none |
| Zero deposit with `minUsdNotes=1` | `SlippageTooHigh()` | full rollback |
| Zero redeem with `minUnderlyingOut=1` | `SlippageTooHigh()` | full rollback |
| Positive SR-only allocation before USD Vault Genesis | arithmetic division panic | full rollback |
| Positive JR-only allocation before JR Vault Genesis | `VaultNotInitialized()` | full rollback |

The arithmetic panic is recorded as current local behavior, not as target-confirmed policy. This
phase deliberately does not invent a new target-visible Genesis error or let PairRouter initialize
either Vault.

## Minimal clean-room correction

`PairRouter` now:

1. validates the shared Controller, JR side, JR Perp and SR Perp;
2. obtains the canonical underlying token from the shared Controller;
3. does not reject a zero Strategy address before knowing whether Strategy use/health checking is
   required;
4. preserves the existing exact-output, DR-bound, partial-fill and zero-dust behavior.

Local focused results:

- `PairRouter.t.sol`: `20 passed, 0 failed`;
- `PairRouterGenesisMatrix.t.sol`: `4 passed, 0 failed`.

## LOCAL-CLEANROOM full deployment integration

`PairRouterRealIntegration.t.sol` deploys actual local Bond, BondsManager, BondIssuer, FeePolicy,
Balancer, Controller, SR/JR Perps, USD Vault, JR Vault, Uniswap-style Strategy/pool and PairRouter.
It runs:

```text
core Genesis
  → Vault Genesis
  → JR Vault real Controller rebalance into Perp JR
  → one PairRouter deposit creating both USD and JR notes
  → one PairRouter redeem burning both note positions
  → exact user settlement and zero Router dust
```

Result: `1 passed, 0 failed`. This is local integration evidence; it is not a claim that all target
rollover/upkeep/deployment parameters are already production-equivalent.

Repository gates:

- full offline suite: `289 passed, 0 failed, 0 skipped`;
- PairRouter runtime: `7,129` bytes;
- Controller runtime unchanged: `22,497 / 22,500` bytes;
- Controller, USD Vault and Underlying Vault frozen storage checks passed;
- Underlying Vault frozen ABI, `forge fmt --check`, `git diff --check` and JSON validation passed.

## Remaining boundary

The next local integration increment should add multiple Bond epochs and a Controller rollover
between PairRouter deposit and redeem, then repeat the asset-conservation and atomic-failure checks.
