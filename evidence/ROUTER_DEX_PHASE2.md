# Router / DEX Strategy Phase 2

## Scope and evidence labels

This phase closes the two high-priority DEX Strategy unknowns left by Phase 1: large quotes around
initialized Uniswap V3 ticks and partial results from `maxFillable`. It used only public Base state,
local transaction-prestate forks, local tests and this repository's clean-room implementation. It
did not read target verified source or frontend bundles, use private keys, sign or broadcast
transactions, or modify target balances/storage with `deal` or `store`.

- **TARGET-CONFIRMED**: observed against the locked target bytecode at a fixed transaction prestate.
- **LOCAL-CLEANROOM**: independently derived and implemented here, then compared exactly.
- **UNKNOWN**: not established by this phase and not claimed as compatible.

## Version and state lock

| Field | Exact value |
|---|---|
| Strategy | `0xe0fc0566adcd6b83149874619a1fafdf3345144f` |
| Strategy codehash | `0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302` |
| Pool | `0xfbb6eed8e7aa03b138556eeDaF5D271A5E1e43ef` |
| Transaction prestate | `0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab` |
| Block / transaction index | `53,243,583` / `77` |
| `sqrtPriceX96` | `2800063142574549000000000000` |
| Current tick / spacing | `-66858` / `10` |
| Active liquidity | `2782022353822` |
| Nearest initialized ticks | down `-66860`, up `-66850` |

## Quote behavior — TARGET-CONFIRMED

The target does **not** traverse initialized ticks when calculating `quote()`. It extrapolates the
currently active liquidity over the whole simulated amount. The existing Phase-1 clean-room formula
matched all 20 geometric vectors exactly, including amounts large enough to move far beyond the
immediately adjacent initialized ticks.

Representative vectors:

| Sell direction | Sell amount | Target output | Clean-room output |
|---|---:|---:|---:|
| USDC → cbBTC | `1000000` | `1248` | `1248` |
| USDC → cbBTC | `100000000000` | `124683273` | `124683273` |
| USDC → cbBTC | `10000000000000` | `11077605053` | `11077605053` |
| USDC → cbBTC | `1000000000000000` | `91143394595` | `91143394595` |
| cbBTC → USDC | `1000` | `799813` | `799813` |
| cbBTC → USDC | `100000000` | `79940167314` | `79940167314` |
| cbBTC → USDC | `10000000000` | `7263738929080` | `7263738929080` |
| cbBTC → USDC | `1000000000000` | `71667690303320` | `71667690303320` |

This is a read-only quote rule, not a statement about real pool execution. `trade()` calls the pool,
so actual execution still follows initialized-tick transitions and can diverge from the extrapolated
large quote. The clean-room implementation deliberately preserves this target distinction.

## `maxFillable` behavior — TARGET-CONFIRMED

Phase 1 implemented `maxFillable` as full-or-zero. That was incomplete. The target uses the fourth
argument as the minimum output for the **full** `maxSell` amount, scales that minimum proportionally
for each smaller candidate, and performs exactly ten bisection rounds.

Equivalent independently derived state machine:

```text
fullBuy = quote(maxSell)

if maxSell == 0:
    return (0, 0)
if fullBuy >= minBuy:
    return (maxSell, fullBuy)

low = 0
high = maxSell
repeat exactly 10 times:
    candidate = floor((low + high) / 2)
    candidateBuy = quote(candidate)
    scaledMinimum = ceil(minBuy * candidate / maxSell)
    if candidateBuy >= scaledMinimum:
        low = candidate
    else:
        high = candidate

return (low, quote(low))
```

This explains why a partial result's absolute `buyOut` may be below `minBuy`: the applicable
threshold is the proportionally scaled, upward-rounded minimum for that partial sell amount.

The model matched 60 target combinations exactly: six maximum amounts per direction, each tested
with zero, exact quote, quote plus one, a larger positive deviation, and twice the quote.

Representative boundaries:

| Direction | `maxSell` | `minBuy` | Target/local `sellOut` | Target/local `buyOut` | Branch |
|---|---:|---:|---:|---:|---|
| USDC → cbBTC | `3390111185` | `4232086` | `3390111185` | `4232086` | full |
| USDC → cbBTC | `3390111185` | `4232087` | `3370247252` | `4207290` | partial |
| USDC → cbBTC | `3390111185` | `8464172` | `0` | `0` | zero |
| USDC → cbBTC | `100000000000` | `124683274` | `99902343750` | `124561666` | partial |
| cbBTC → USDC | `960289` | `768428818` | `959351` | `767678656` | partial |
| cbBTC → USDC | `100000000` | `79940167315` | `99902343` | `79862178685` | partial |
| USDC → cbBTC | `0` | `0` or `1` | `0` | `0` | zero-input |

The partial results expose the ten-round resolution directly: for example,
`100000000000 × 1023 / 1024 = 99902343750`.

## LOCAL-CLEANROOM implementation

`src/strategy/UniswapV3DexStrategy.sol` now:

- retains the target-confirmed current-liquidity `quote()` arithmetic;
- implements the ten-round proportional-minimum bisection in `maxFillable()`;
- uses upward rounding for the scaled minimum;
- returns `(0, 0)` for zero maximum sell, including a positive fourth argument;
- does not change `trade()`, pool callback authorization, storage, Controller or Vault behavior.

The Strategy runtime increased from `4388` to `4530` bytes and remains far below EIP-170.

## Reproduction and verification

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-path evidence/probe-tests/RouterDexPhase2Probe.t.sol -vv

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

- target/local Phase-2 fork tests: `4 passed, 0 failed`;
- formal quote differential: `20/20` exact;
- formal `maxFillable` model/differential: `60/60` exact;
- local Router/Strategy tests: `4 passed, 0 failed`;
- full offline suite: `211 passed, 0 failed`;
- Controller remains `22475` bytes; Vault storage and frozen UnderlyingPerpVault ABI are unchanged;
- all size, storage, ABI, formatting and diff checks pass.

## Remaining UNKNOWN

- Error selectors for unsupported token pairs and any target-specific behavior at zero pool
  liquidity.
- Router behavior against a zero-supply/zero-reserve Vault genesis state.
- Extreme `uint256` inputs outside reachable protocol balances; this phase covers the full observed
  operating range and much larger geometric vectors, not mathematically every possible word.
