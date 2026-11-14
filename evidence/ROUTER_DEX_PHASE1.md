# Router / DEX Strategy Phase 1

## Scope and evidence labels

This phase used public Base history, local Foundry transaction-prestate forks, local mocks and this
repository's clean-room source only. It did not read target verified source or frontend bundles, use
private keys, sign or broadcast transactions, or use `deal` / `store` to manufacture target balances.

- **TARGET-CONFIRMED**: observed against the target bytecode at a fixed transaction prestate.
- **LOCAL-CLEANROOM**: independently implemented here and compared against target behavior.
- **UNKNOWN**: not established by the Phase-1 vectors and not claimed as compatible.

## Version lock

| Component | Address / transaction | Lock |
|---|---|---|
| Current SingleAsset Router | `0x8e868c1f8f82b84a6b0d19d235d50c47b253559f` | codehash `0x33f265f8c51da59240326566d89a19548bf6ebeb9bb225cb1ab8079d701d71bf` |
| DEX Strategy | `0xe0fc0566adcd6b83149874619a1fafdf3345144f` | codehash `0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302` |
| USD Vault | `0xe356d1ed9ad82ccc79e70f50abce08057e8d75f3` | target proxy |
| Natural deposit prestate | tx `0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254` | block `53,236,495`, tx index `132` |
| Natural redeem prestate | tx `0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab` | block `53,243,583`, tx index `77` |

The historical deposit was sent to the preceding Router address, but the current Router code was
already deployed at the same prestate and has the locked current codehash. The Phase-1 deposit
matrix calls the current six-argument ABI directly using the depositor's natural USDC balance.

## TARGET-CONFIRMED Router behavior

### Deposit

Current ABI:

```solidity
depositUsd(address vault, address strategy, uint256 usdMax, uint256 minNotes, uint256 maxIters, bool healthCheck)
```

Natural input state:

| Field | Exact value |
|---|---:|
| User USDC max | `110126511` |
| Vault USDC | `27506914` |
| Vault Perp SR | `7970529505535` |
| Perp reserve value | `100702952` |
| Perp total supply | `7978609218527` |
| DEX reference price | `79993776390420401944700` |

Observed successful path with `maxIters = 0`:

1. Pull `110126511` USDC.
2. Keep a maximum of `37630` USDC for the Vault and sell `110088881` USDC.
3. DEX returns `137552` cbBTC.
4. `Controller.flashMint2(137552, 0, 0, 0)` produces the Perp SR held by the Router.
5. Call `Vault.deposit(37630, 10800619432)`; the Vault consumes `37273` USDC.
6. Return `108320498554343292777` notes and refund `357` USDC.
7. Router ends with zero USDC, cbBTC and Perp SR.

The independently derived initial allocation is:

```text
vaultPerpUnderlying = floor(vaultPerp * perpReserveValue / perpSupply)
vaultPerpUsd        = floor(vaultPerpUnderlying * referencePrice / 1e18)
vaultPerpUsd        = floor(vaultPerpUsd * usdUnit / underlyingUnit)
usdForVaultMax      = ceil(usdAvailable * vaultUsd / (vaultUsd + vaultPerpUsd))
usdToSell           = usdAvailable - usdForVaultMax
```

This produces `usdForVaultMax = 37630` and `usdToSell = 110088881` exactly.

`maxIters` counts additional dust-convergence passes after the first pass. On this real state:

| maxIters | Result | Exact output / error |
|---:|---|---|
| `0` | success | `108320498554343292777` notes |
| `1` | revert, atomic | `UnexpectedAmount()` / `0x312f6ffa` |
| `2` | revert, atomic | `UnexpectedAmount()` / `0x312f6ffa` |

The extra pass sells dust for zero cbBTC and still calls `flashMint2(0, 0, 0, 0)`, which bubbles the
Controller error. This is target behavior, not an optimization recommendation.

`minNotes` is inclusive. The exact output succeeds; exact output plus one reverts atomically with
`SlippageTooHigh()` / `0x850c6f76`.

### Redeem

Current ABI:

```solidity
redeemUsd(address vault, address strategy, uint256 notesIn, uint256 minUsdOut, bool runUpkeep, bool healthCheck)
```

For natural holder `0x11649a794f918508027765f6280c1b396ee59f8f` and
`3762930374354620392` notes:

- `runUpkeep = false` succeeds and returns `3780194` USDC.
- The Vault returns `1294` USDC and `375200394` Perp SR.
- Controller flash redeem returns `4723` cbBTC.
- DEX trade returns `3778900` USDC.
- `minUsdOut = 3780194` succeeds; `3780195` reverts atomically with `0x850c6f76`.
- `runUpkeep = true` first calls `Vault.upkeep()`; this snapshot has no work, so `NoOp()` /
  `0x00219cf1` bubbles before notes move.

The final boolean is the health-check toggle. With an unhealthy local probe strategy,
`healthCheck = true` reverts with target selector `0xc9f488c6`; `false` permits a zero-input no-op.

## TARGET-CONFIRMED DEX Strategy behavior

| Field | Value |
|---|---|
| Pool | `0xfbb6eed8e7aa03b138556eedaf5d271a5e1e43ef` |
| Fee | `500` |
| Minimum liquidity | `200000000000` |
| token0 / token1 | USDC / cbBTC |
| Unauthorized callback | `UnauthorizedCall()` / `0x7bf6a16f` |

At the redeem transaction prestate:

- `referencePrice(cbBTC, USDC) = 80061462195552451024100`.
- `referencePrice(USDC, cbBTC) = 12490403904408`.
- `quote(cbBTC, USDC, 4723) = 3778900`.
- `quote(USDC, cbBTC, 1000000) = 1248`.
- A real target trade of `1000000` USDC returns `1248` cbBTC; trading that amount back returns
  `998366` USDC.

The exact two-stage reference-price rounding is:

```text
token0 -> token1:
  sqrtWad = floor(sqrtPriceX96 * 1e18 / 2^96)
  rawWad  = floor(sqrtWad * sqrtPriceX96 / 2^96)

token1 -> token0:
  inverseSqrtWad = floor(2^96 * 1e18 / sqrtPriceX96)
  rawWad         = floor(inverseSqrtWad * 2^96 / sqrtPriceX96)

referencePrice = floor(rawWad * sellTokenUnit / buyTokenUnit)
```

This model matches four independently observed historical reference prices exactly. The
single-active-liquidity-range Uniswap V3 quote math also matches both golden quotes exactly.

## LOCAL-CLEANROOM implementation and differential

Implemented:

- `src/router/SingleAssetRouter.sol`
- `src/strategy/UniswapV3DexStrategy.sol`
- minimal interfaces in `src/interfaces/`
- five additive, target-observed read-only getters on `UsdVault`; no storage slot changed

The fork differential deploys the local contracts and compares them against the target from the
same snapshot and natural balances:

| Differential | Result |
|---|---|
| Router natural deposit return, user spend and notes | exact match |
| Router natural redeem return and user USDC | exact match |
| Strategy forward real-pool trade | target/local `1248` cbBTC |
| Strategy reverse real-pool trade | target/local `998366` USDC |
| Reference prices and golden quotes | exact match |
| Callback authorization selector | exact match |

## UNKNOWN / Phase-2 work

- Target `quote()` behavior when a simulated trade crosses an initialized Uniswap V3 tick.
- Target `maxFillable()` partial-fill search when the full amount cannot satisfy its constraint.
- Invalid token-pair error selectors and zero-liquidity behavior.
- Router behavior against a zero-supply / zero-reserve Vault genesis state.

The local Strategy's state-changing `trade()` always delegates execution to the actual pool and is
not limited by the current-tick quote model. Until the first two unknowns are closed, the local
`quote()` / `maxFillable()` should only be treated as compatible for target-confirmed, non-crossing
vectors.

## Reproduction and gates

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-path evidence/probe-tests/RouterDexPhase1Probe.t.sol -vv

forge test --match-path test/SingleAssetRouter.t.sol -vv
forge test
python3 script/check_runtime_sizes.py
python3 script/check_controller_storage_layout.py
python3 script/check_underlying_perp_vault_storage_layout.py
python3 script/check_usd_vault_storage_layout.py
python3 script/check_underlying_perp_vault_abi.py
forge fmt --check
git diff --check
```

Results:

- target fork probe: `6 passed, 0 failed`
- local Router / Strategy tests: `4 passed, 0 failed`
- full offline suite: `211 passed, 0 failed`
- runtime: Router `5753`, Strategy `4388`, Controller unchanged at `22475`, USD Vault `15996` bytes
- all frozen storage and UnderlyingPerpVault ABI checks passed
- formatting and diff checks passed
