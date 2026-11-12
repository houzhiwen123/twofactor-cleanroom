# USD Vault phase 2: mint quote and deposit core

## Scope and evidence boundary

This phase adds only the USD Vault valuation, paired mint quote and atomic two-token deposit core:

- `getTVL()`;
- `computeMintAmt(usdMax, perpSrMax)`; and
- `deposit(usdMax, perpSrMax)` asset movement, note mint and event order.

It deliberately does **not** implement session/capacity, rebalance/keeper, pause/admin or the target
initializer. Public Base reads, receipts and local fork simulation were used; no target source or
frontend bundle was read, and no transaction was signed or broadcast.

The target's full `deposit` preflight also reaches health/oracle and operating-state checks. Those
checks are not silently guessed here because some belong to the explicitly deferred session/capacity
phase. Therefore, this phase is target-confirmed for the quote arithmetic and successful core state
transition, but it is not yet a claim that every target `deposit` revert path is implemented.

Baseline commit: `a6da59369156e187024f10c7f8d85a60e5f04077`.

## Version lock

- Chain: Base (`8453`).
- Vault proxy: `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`.
- Implementation used by the five quote vectors:
  `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`.
- Implementation codehash: `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4`.
- Controller proxy: `0x682F3a053B0260daD4EbEee3924B1618B330A200`.
- Underlying price oracle at block `53,526,143`:
  `0x636AF09C85A5B6C939a2BDa70F7f2f5ac3D1682a`.
- The implementation exists at block `52,902,098`; block `52,915,437` is used only after its proxy
  upgrade at transaction index `21`.

## Target-confirmed arithmetic

Let `usdBal`, `perpBal` and `idleUnderlying` be the Vault's actual token balances. Let
`srSupply` and `srReserveValue` be the Controller's Perp SR state, and let `underlyingPrice` be the
Controller oracle's 18-decimal USD price.

The accepted pair preserves the current raw reserve ratio:

```text
if usdMax * perpBal <= perpSrMax * usdBal:
    usdIn  = usdMax
    perpIn = floor(usdMax * perpBal / usdBal)
else:
    perpIn = perpSrMax
    usdIn  = floor(perpSrMax * usdBal / perpBal)
```

TVL and issuance use two distinct floors for Perp SR valuation:

```text
vaultPerpUnderlying = floor(perpBal * srReserveValue / srSupply)
vaultTVL = floor(usdBal * 1e18 / 1e6)
         + floor(idleUnderlying * underlyingPrice / 1e8)
         + floor(vaultPerpUnderlying * underlyingPrice / 1e8)

depositPerpUnderlying = floor(perpIn * srReserveValue / srSupply)
depositValue = floor(usdIn * 1e18 / 1e6)
             + floor(depositPerpUnderlying * underlyingPrice / 1e8)
notesMinted = floor(depositValue * vaultSupply / vaultTVL)
```

USDC is valued at face value. The target USD oracle does not enter `computeMintAmt`. Idle cbBTC
changes the TVL denominator but not the accepted USDC/Perp SR ratio.

### Five historical quote vectors

All rows use `computeMintAmt(1,000,000, 10,000,000,000)` and match exactly:

| Block | TVL | Notes | USDC in | Perp SR in |
|---:|---:|---:|---:|---:|
| 52,915,437 | 38,721,332,620,804,922,195,000 | 100,290,640,708,916,173,358 | 34,510 | 10,000,000,000 |
| 52,951,097 | 59,913,170,143,638,691,282,500 | 100,290,542,230,908,439,944 | 34,510 | 10,000,000,000 |
| 53,236,494 | 80,342,246,954,891,302,818,400 | 100,291,078,925,391,285,697 | 34,510 | 10,000,000,000 |
| 53,469,759 | 80,519,389,925,026,088,820,800 | 62,263,207,820,484,804,771 | 1,000,000 | 6,111,367,532 |
| 53,526,143 | 100,074,774,324,962,383,263,700 | 100,271,154,039,568,388,009 | 3,765 | 10,000,000,000 |

At block `53,526,143`, collapsing the two Perp SR valuation floors into one would mint
`100,271,607,373,576,495,882` notes, an over-mint of `453,334,008,107,873`. The local test fixes
this as a regression counterexample.

## Target-confirmed successful deposit order

Two independent real receipts show the same four-step order:

1. USDC `Transfer(caller, vault, usdIn)`;
2. Perp SR `Transfer(caller, vault, perpSrIn)`;
3. Vault note `Transfer(address(0), caller, notesMinted)`;
4. `Deposit(usdIn, perpSrIn, notesMinted)` with no indexed arguments.

| Route | Block / index | Transaction | Deposit event `(USDC, Perp SR, notes)` |
|---|---|---|---|
| Single-asset Router | 53,236,495 / 132 | `0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254` | `(37,273, 10,800,619,432, 108,320,498,554,343,292,777)` |
| Pair Router | 52,951,098 / 93 | `0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7` | `(3,672, 1,064,222,447, 10,672,407,599,351,449,815)` |

The corresponding public-fork probe is
`evidence/probe-tests/UsdVaultPhase2TargetProbe.t.sol`. Direct receipt reads established both event
orders. Public transaction-prestate replay timed out on the two unauthenticated RPC endpoints used
during this run, so that reproducible replay remains an execution-environment check rather than a
new compatibility claim.

At block `53,526,143`, target `deposit(0,0)` returns zero, moves no assets and emits no logs. The
focused public-fork probe passed `1/1`; the local implementation has the same no-op behavior.

## Local implementation and regression coverage

- Phase-1 slots remain unchanged: `_usdToken` slot `0`, `_perpSrToken` slot `1`.
- Phase 2 appends `_underlyingToken` slot `2` and `_perpController` slot `3`.
- The expanded initializer remains **LOCAL-CLEANROOM scaffolding**, not a target initializer claim.
- Transfers use `SafeERC20`, and the whole deposit is guarded by `nonReentrant`.
- A failure of the second transfer reverts the first transfer, note mint and every balance update.
- Actual balance donations are reflected immediately: USDC and Perp SR affect ratio/TVL, while idle
  cbBTC affects only TVL.
- Single-empty-reserve branches and the target-observed both-empty positive-input division panic are
  fixed by tests.

Run local tests:

```sh
forge test --match-path test/UsdVaultMintDeposit.t.sol -vv
```

Run the zero-input target probe with a public archive-capable Base endpoint:

```sh
FOUNDRY_TEST=evidence/probe-tests/UsdVaultPhase2TargetProbe.t.sol \
BASE_RPC_URL="$BASE_RPC_URL" forge test \
  --match-path evidence/probe-tests/UsdVaultPhase2TargetProbe.t.sol \
  --match-test testZeroInputTargetBehaviorProbe -vv
```

Machine-readable vectors are in `evidence/usd-vault-phase2-mint-deposit.json`.

## Deliberately deferred

- Session/capacity rules and their deposit reverts.
- Rebalance/keeper behavior.
- Pause, admin and target initialization semantics.
- Full health/oracle preflight call order and every external failure boundary.
- Genesis/zero-note-supply issuance.
- Extreme-input multiplication-overflow behavior.

These must be closed with their own target evidence; no local guess is presented as target behavior.

## Verification result

- Phase-2 local suite: **8 passed, 0 failed**.
- Full offline/local suite: **131 passed, 0 failed** across 12 suites.
- Target zero-input fork probe: **1 passed, 0 failed**.
- `UsdVault` runtime: **6,418 bytes** (18,158 bytes below EIP-170).
- `PerpController` runtime: **22,475 bytes**, unchanged and below the 22,500-byte project guard.
- General runtime-size guard: passed.
- Frozen Controller storage slots: unchanged.
- Frozen Vault phase-1 slots preserved; phase-2 state appended in slots `2` and `3`.
- `forge fmt --check`, `git diff --check` and JSON validation: passed.
