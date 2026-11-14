# Underlying Single-Asset Router Phase 1

Status: **TARGET-CONFIRMED Junior behavior + LOCAL-CLEANROOM shared implementation**

> Superseded for Senior classification by `UNDERLYING_SINGLE_ASSET_ROUTER_PHASE2.md`, which later
> confirmed that this same deployed target Router accepts the Senior Vault.

This phase covers the single-cbBTC entry and exit path for `UnderlyingPerpVault`. Target claims are
limited to the deployed Junior Router. Applying the same side-selecting implementation to the
Senior cbBTC + Perp SR vault is a clean-room product extension because no equivalent target Senior
Underlying Router was found in the bounded evidence set.

## Safety and provenance

- Public Base chain data and local Foundry forks only.
- No wallet, private key, signature, broadcast, target storage edit, `deal`, or target balance edit.
- The target verified source and frontend bundle were not read.
- The natural account `0x5A42…cdCa` supplied its historical cbBTC and Vault-note balances. Local
  `approve` calls were used only inside the fork.

## Version lock

| Item | Value |
|---|---|
| Chain | Base (`8453`) |
| Target Junior Router | `0xbf0f2aa8784a1a459C7E2eB87CF25E5cABF4d296` |
| Router runtime codehash | `0xefe9f9c0563e83464998417f8bf820d3f7b9e47205cb836bee3679cb8f02ac59` |
| Junior Vault proxy | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Vault proxy runtime codehash | `0x0a16141b955fdc3548daeab3d02a4f007fcd407b6f88758a94caae8e8f4a4ab7` |
| Shared Vault implementation | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |
| Perp JR | `0x8cd04668292dC32F519972495C179E4f02C0e8AB` |

## Target surface

```solidity
depositUnderlying(vault, underlyingAmtIn, minNotesOut, maxIters)
redeemUnderlying(vault, notesAmtIn, minUnderlyingOut)
```

Both minimum-output checks are inclusive. An exact minimum succeeds; actual output plus one reverts
with `SlippageTooHigh()` (`0x850c6f76`) and rolls back notes, token balances, Vault supply and Router
dust atomically.

## Deposit state machine

For each pass, let:

```text
A = cbBTC currently held by Router
U = Vault idle cbBTC
P = Vault Perp balance
S = selected Perp total supply
R = selected Perp reserve value
V = U + floor(P × R / S)
```

The target split is:

```text
directUnderlying = ceil(A × U / V)
flashUnderlying  = A - directUnderlying
```

`flashUnderlying` is sent to the selected Controller side (`JR` for the target deployment), then
the Router calls `vault.deposit(directUnderlying, perpMinted)`. `maxIters` counts additional passes
after the first. Processing stops early when a pass mints no notes. Any cbBTC or Perp dust is
refunded to the caller.

### Exact vectors

| Classification | State / transaction | Input | Controller call | Vault call/result | User result |
|---|---|---:|---|---|---|
| TARGET-CONFIRMED historical | `0x14d7…61fa`, block `53,372,806`, index `52` | `166,464` cbBTC, `maxIters=2` | JR-only flash mint | `Deposit(0, 14,411,197,784, 1,711,753,692,854,663)` | `1,711,753,692,854,663` notes |
| TARGET-CONFIRMED synthetic fork after real rebalance | replay `0x3562…9259b`, block `52,543,960`, index `64` | `100,000` cbBTC | `flashMint2(0,98,021,0,0)` | quoted `(1,979, 8,259,918,892)`; Vault accepts `1,978` cbBTC | `1,001,004,523,584,842` notes; spends `99,999`; refunds `1` |

The nonzero-basket model inputs were `U=2,896,806`, `P=12,092,542,915,318`,
`S=12,092,542,915,318`, and `R=143,503,001`. The formula gives `ceil(100,000 × 2,896,806 /
146,399,807) = 1,979` direct units exactly. `maxIters` values `0`, `1`, and `2` returned the same
notes. For `maxIters >= 1`, the target attempted `vault.deposit(1,0)` once, received zero notes and
stopped.

## Redemption state machine

The target Router:

1. reads `underlying`, `perp`, `perpController`, and `isPerpSrVault` from the Vault;
2. transfers the user's notes to itself;
3. calls `vault.redeem(notes)`;
4. sends the returned Perp balance through the selected side of `flashRedeem2`;
5. adds direct Vault cbBTC and flash-redeemed cbBTC;
6. enforces `minUnderlyingOut`, transfers cbBTC, and leaves no cbBTC or Perp dust.

At block `54,990,962`, the natural holder owned `2,724,303,154,369,610` notes. Redeeming
`1,000,000,000,000,000` notes produced `8,418,966,960` Perp JR from the Vault and exactly `95,934`
cbBTC after the Controller fee. `minUnderlyingOut=95,934` succeeded; `95,935` reverted atomically.
This is a **SYNTHETIC FORK** call using a natural balance and a local approval, not a historical user
transaction.

## Clean-room implementation and differential

`src/router/UnderlyingSingleAssetRouter.sol` is stateless and uses only the already-frozen Vault
getters. It does not alter Controller or Vault code, ABI, or storage.

The local Router matched the target exactly on three Junior paths:

| Differential | Result |
|---|---|
| Historical all-Perp deposit | return value, notes and cbBTC spend exact |
| Post-rebalance split deposit | return value, notes, `99,999` spend and `1` refund exact |
| Natural-note redemption | return value and `95,934` cbBTC output exact |

The shared implementation selects SR or JR Controller arguments from `isPerpSrVault()`. The SR path
has local tests for deposit, redemption, dust, side selection and atomic slippage failure, but is
classified **LOCAL-CLEANROOM**, not target-confirmed.

## Tests

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=<public-archive-rpc> \
  forge test --match-path evidence/probe-tests/UnderlyingSingleAssetRouterPhase1Probe.t.sol -vv

forge test --match-path test/UnderlyingSingleAssetRouter.t.sol -vv
```

- Target fork probe: `7 passed, 0 failed`.
- Local Router unit/integration tests: `4 passed, 0 failed`.
- Router runtime: `3,994` bytes.

## Remaining unknowns

- No target-equivalent single-cbBTC Router for the Senior Underlying Vault was observed.
- No natural historical `redeemUnderlying` transaction was found in the bounded component history;
  the redemption vector is therefore explicitly synthetic-fork evidence.
- Target behavior for malicious or unrelated caller-supplied Vault contracts was not expanded in
  this phase.
