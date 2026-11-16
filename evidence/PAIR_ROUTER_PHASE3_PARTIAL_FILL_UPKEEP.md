# PairRouter Phase 3 — partial fills and successful upkeep

## Scope and evidence boundary

This phase closes the two redeem-path unknowns left by Phase 2: how PairRouter accounts for a
Strategy that spends less than the requested sell amount, and what happens when `runUpkeep=true`
and the USD Vault upkeep succeeds.

The probes execute the locked target PairRouter bytecode on a fixed public Base fork while passing
fresh local recording Vault, Controller, token and Strategy contracts through the target calldata.
The rows below are therefore **SYNTHETIC-FORK / TARGET-IMPLEMENTATION-BEHAVIOR**, not claims that the
same constructed states occurred naturally in production. The earlier natural redeem replay stays
separately documented in `PAIR_ROUTER_PHASE2_REDEEM.md`.

No target source or frontend bundle was read. No target balance or storage was changed with
`deal`/`store`; no wallet, private key, signature or broadcast transaction was used.

## Version lock

| Field | Value |
|---|---|
| Chain / fixed block | Base `8453` / `57,015,384` |
| Target PairRouter | `0x97c521D21468022E205d8A57b2fcaeE33d6714d6` |
| Target selector | `0xb2a72016` |
| Target codehash | `0x487610478a620be27092ff42bf2dea6bfc08275af635abdc27245329f9801218` |
| Target probe | `evidence/probe-tests/PairRouterPhase3TargetProbe.t.sol` |

## Partial Strategy fills — target behavior

The recording Vaults first give the Router `20` USD and `120` underlying in total: `40`
underlying directly from the JR Vault and `80` underlying from Controller redemption. The Strategy
is then asked to sell `100` underlying but actually pulls only `40` and returns `400` USD.

| Item | Exact target value |
|---|---:|
| Requested underlying sell | `100` |
| Actual underlying spent | `40` |
| USD returned by Strategy | `400` |
| Final user USD | `420` |
| Final user underlying | `80` |
| Router underlying dust | `0` |

The target does not subtract the requested `100` from an internal counter. After the external
calls it reads the Router's actual USD and underlying balances, transfers those balances to the
caller and returns the same two values.

The reverse direction is identical in principle. With `20` USD initially available,
`maxUsdRetained=5` requests a `15` USD sale. A Strategy that spends only `6` and returns `9`
underlying produces exactly `14` USD and `129` underlying for the user, with zero Router dust.

Minimum outputs use those actual post-trade balances. For the first vector, `(420, 80)` succeeds;
USD minimum `421` or underlying minimum `81` reverts atomically with `SlippageTooHigh()` /
`0x850c6f76`.

## Successful `runUpkeep=true` — target behavior

With a successful recording USD Vault upkeep and a full `100`-underlying Strategy spend, the
target returns `420` USD and `20` underlying. The recorded state-changing call order is:

```text
USD Vault upkeep
    -> USD Vault redeem
    -> JR Vault redeem
    -> Controller flashRedeem2
    -> Strategy trade
```

`upkeep()` is called exactly once and before either note moves. Phase 2 already proves that a
reverting upkeep bubbles `NoOp()` before notes move. This phase proves the complementary successful
branch against the same locked target bytecode. Natural production-state reachability of a
successful upkeep inside this Router call remains **UNKNOWN**.

## Clean-room compatibility correction

The pre-fix clean-room Router subtracted the requested DEX sell amount. When the Strategy spent
only part of that amount, it under-reported the returned sell token and stranded the refund on the
Router. The pre-fix same-state target/local return-data hashes differed.

`src/router/PairRouter.sol` now derives both final outputs from its actual post-operation token
balances before applying minimums and transferring them. It changes no storage, interface,
Controller or Vault behavior.

Exact target/local differential tests now match, without tolerance, for:

- underlying-to-USD partial fill plus successful upkeep;
- USD-to-underlying partial fill;
- returned two-word data;
- user USD and underlying balances; and
- zero Router USD/underlying dust.

The offline PairRouter suite also fixes both partial directions and successful upkeep as permanent
regressions.

## Reproduction

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL="$BASE_RPC_URL" \
  forge test --offline --threads 1 \
  --match-path evidence/probe-tests/PairRouterPhase3TargetProbe.t.sol -vv

forge test --match-path test/PairRouter.t.sol -vv
forge test
python3 script/check_runtime_sizes.py
python3 script/check_controller_storage_layout.py
python3 script/check_underlying_perp_vault_storage_layout.py
python3 script/check_usd_vault_storage_layout.py
forge fmt --check
git diff --check
```

## Verification snapshot

- target-implementation and exact differential probe: **6/6 passed**;
- focused local PairRouter regression: **17/17 passed**;
- full offline suite: **281/281 passed** across 31 suites;
- PairRouter runtime: **6,613 bytes**;
- PerpController unchanged at **22,497/22,500 bytes**;
- Controller, UnderlyingPerpVault and USD Vault frozen storage checks: passed;
- frozen UnderlyingPerpVault ABI: passed; and
- `forge fmt --check`, `git diff --check` and JSON validation: passed.

## Remaining boundaries

- successful upkeep inside a naturally occurring PairRouter production transaction remains
  **UNKNOWN**;
- negative selectors for every mismatched Vault/Controller/Perp/Strategy combination are not
  closed here;
- this evidence applies to the locked Router codehash only; and
- pre-existing unrelated token dust sweeping was not separately probed.
