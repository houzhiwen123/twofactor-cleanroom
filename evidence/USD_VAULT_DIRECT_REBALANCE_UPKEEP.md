# USD Vault direct `rebalance()` / `upkeep()` probe

Version lock:

- chain: Base `8453`
- target implementation: `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`
- mint prestate: block `53,526,143`
- redeem prestate: transaction `0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e`
- probe: `evidence/probe-tests/UsdVaultDirectUpkeepProbe.t.sol`
- local commit before this phase: `45d790e`

All rows below are **SYNTHETIC FORK / TARGET-IMPLEMENTATION-BEHAVIOR**. The proxy uses the
target implementation, but its ERC20s, Controller, oracle and DEX are local mocks. No target
state was changed, and no natural USD Vault direct-success transaction was found in the reused
Phase 5A material. The rows are therefore not `TARGET-CONFIRMED` production-state evidence.

## Direct rebalance

The target implementation asks the DEX for a fill using a computed full-size `(maxSell,minBuy)`
pair, then trades the returned sell amount. The synthetic traces show the trade call receives the
sell amount returned by `maxFillable`, not the original full capacity.

| Direction | `maxFillable` request `(maxSell,minBuy)` | returned sell used by `trade` | observed trade result | outcome |
|---|---:|---:|---:|---|
| mint | `(1,000,000,009,580, 1,244,266,201)` | `500,000,004,790` | `622,133,101` | success |
| mint | same request | `500,000,004,790` | `0` | `SlippageTooHigh()` `0x850c6f76` |
| redeem | `(2,001,421,796,385, 1,546,143,235,063,888)` | `1,000,710,898,192` (quote probe) | `773,071,617,531,945` | success |
| redeem | same request | `1,000,710,898,192` (quote probe) | `0` | `SlippageTooHigh()` `0x850c6f76` |

The mint boundary also tested `maxFillable` returning a buy quote one wei below the requested
full-size `minBuy`. With an actual trade result of `622,133,100` the call still reverted, while
`622,133,101` succeeded. In this vector `ceil(fullMinBuy * returnedSell / requestedMaxSell)` is
`622,133,101`; this is evidence of a conservative, upward-rounded partial-fill check. It does
not establish the complete formula for every token decimal or every DEX implementation.

The redeem trace exposes a different call order: the DEX quote is requested, then the target
Controller flash-redeem call is made, and the subsequent DEX trade uses the underlying actually
returned by that Controller call. The probe fixes that returned amount at `711,398,192` units.
The exact redeem-side rounding formula remains **UNKNOWN**; only the success/failure vectors above
are closed.

## `upkeep()`

| State | Timestamp / setup | Result | Evidence level |
|---|---|---|---|
| mint-direction capacity | `openedAt-1`, `openedAt`, `openedAt+1` around `1793833200` | `NoOp()` `0x00219cf1`; fingerprint unchanged | synthetic target implementation |
| redeem-direction capacity, forced DEX quote failure | fixed redeem prestate; `maxFillable` reverts | DEX error `ObservedMaxFillable()` `0xe453baa5` bubbles; this is not `NoOp` | synthetic target implementation |
| redeem-direction executable upkeep | local DEX sells `1,000,000,000,000` underlying | success; USD `1,000,000,010,001 → 1,547,143,235,073,889`, underlying `2,000,000,000,000 → 1,000,000,000,000`; session direction/timestamp unchanged | synthetic target implementation |

The successful synthetic upkeep path does not call the mocked Controller flash-redeem in this
setup; it performs the bounded underlying-to-USD DEX settlement and changes the Vault balances.
This closes the existence of a state-changing upkeep branch in the target implementation under a
constructed redeem state, but does not prove that the real deployed USD Vault reaches that branch
under any particular historical state.

## What remains open

- No natural USD Vault direct-success or state-changing-upkeep transaction was added in this
  phase; production-state reachability is still UNKNOWN.
- The exact redeem-side partial-fill rounding expression needs one more discriminator where the
  actual Controller return and DEX quote differ by exactly one unit.
- Issue-only, maturity-only, and issue-plus-maturity upkeep branches belong to the Controller's
  separate upkeep state machine; they are not inferred from this USD Vault synthetic probe.

The probe suite ran **5/5 passed** with the fixed public Base fork RPC. It is evidence only; no
production Solidity was changed in this phase.
