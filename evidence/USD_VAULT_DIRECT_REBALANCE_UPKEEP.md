# USD Vault direct `rebalance()` / `upkeep()` compatibility closure

Version lock:

- chain: Base `8453`
- target implementation: `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`
- mint prestate: block `53,526,143`
- redeem prestate: transaction `0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e`
- target probe: `evidence/probe-tests/UsdVaultDirectUpkeepProbe.t.sol`
- evidence-only baseline: `aa8b722`

The target rows are **SYNTHETIC FORK / TARGET-IMPLEMENTATION-BEHAVIOR**. A fresh proxy runs the
locked target implementation while ERC20s, Controller, oracle and DEX are local recording mocks.
No live transaction was broadcast and no target account or target storage was modified. Natural
production-state reachability is not claimed.

## Direct rebalance rules

The target uses a `9,985 / 10,000` minimum-buy factor. For a partial fill, the final minimum is:

```text
partialMinBuy = ceil(fullMinBuy * actualSell / requestedMaxSell)
```

The DEX's returned buy quote is not used as the final slippage result; the amount returned by the
state-changing `trade()` call is checked.

| Path | Full request | Target-implementation-observed rule |
|---|---:|---|
| mint | `maxSell=1,000,000,009,580`, `minBuy=1,244,266,201` | full `minBuy` is floored; partial threshold is rounded up |
| redeem | `maxSell=2,001,421,796,385`, `minBuy=1,546,143,235,063,888` | full `minBuy` is floored; actual Controller output is checked proportionally |

Mint discriminators:

- half fill: `622,133,100` fails and `622,133,101` succeeds;
- one-third fill: `414,755,400` fails and `414,755,401` succeeds;
- `maxSell - 1`: the threshold remains `1,244,266,201`;
- one-unit sell: zero fails and one succeeds.

Redeem call order and amount semantics are closed:

```text
DEX.maxFillable(max underlying capacity, full minimum USD)
        -> Controller.flashRedeem2(perp amount corresponding to quoted sell)
        -> DEX.trade(actual underlying returned by Controller)
        -> proportional upward-rounded slippage check
```

The quote-before-Controller ordering was verified by making both calls fail: the DEX quote error
won. With a returned DEX sell of `1,000,710,898,192`, the target passed that exact amount to the
mocked one-to-one Controller state. With an actual Controller return of `711,398,192`, the exact
USD threshold was `549,571,061,925`; one unit less failed.

## State-changing `upkeep()`

In a constructed redeem-direction state, `upkeep()` performs only the idle-underlying DEX
settlement:

```text
validate health/oracles/rebalance state
        -> maxSell = Vault idle underlying balance
        -> DEX.maxFillable(underlying, USD, maxSell, fullMinBuy)
        -> DEX.trade(returned sell amount)
        -> proportional upward-rounded slippage check
```

Observed request and boundary:

- `maxSell=2,000,000,000,000`, exactly the Vault's idle-underlying balance;
- `minBuy=1,545,044,865,461,701`, using the same `9,985 / 10,000` factor but rounding the full
  upkeep minimum upward;
- one-third partial fill threshold `515,014,955,153,386`; one unit less fails.

A successful half fill changed USD and underlying balances but did not call Controller, change the
stored session budget/direction/timestamp, reset the session, or emit the Vault `Rebalance` event.
Mint-direction upkeep still returns `NoOp()`.

## Local compatibility changes

`src/vault/UsdVault.sol` now independently implements the black-box-observed behavior:

- proportional upward-rounded partial-fill checks for direct mint and redeem;
- DEX quote before Controller redeem and quoted-sell sizing of the Controller input;
- DEX trading of the Controller's actual underlying return;
- redeem-side idle-underlying settlement in `upkeep()` without session commit or `Rebalance` event.

`test/UsdVaultRebalanceExecution.t.sol` replaces the superseded nonzero-capacity-NoOp assumption
with success, one-unit slippage, ordering and atomic rollback regressions.

## Verification

- target implementation probe: **10 passed, 0 failed**;
- local USD Vault execution suite: **22 passed, 0 failed**;
- full local suite: **243 passed, 0 failed**;
- `UsdVault` runtime: **17,542 bytes**;
- Controller runtime: **22,475 bytes**;
- USD Vault and Controller frozen storage checks: passed;
- formatting and whitespace checks: passed.

## Remaining evidence boundary

- No natural production-state direct-success or state-changing-upkeep transaction was added in
  this phase; natural reachability remains **UNKNOWN**.
- Issue/maturity upkeep belongs to the separate Controller state machine and is not inferred here.
