# UnderlyingPerpVault Phase 2 — rebalance evidence

## Scope and evidence labels

This report covers the target cbBTC/Perp JR and cbBTC/Perp SR Vault rebalance surface. It uses only
public Base chain data and local Foundry forks. No verified source, frontend bundle, wallet, private
key, signature, or broadcast transaction was used.

- **TARGET-CONFIRMED** — observed in an unmodified public-chain state or an exact historical
  transaction-prestate replay.
- **SYNTHETIC FORK** — observed by changing a target parameter on a local fork, then reverting the
  snapshot.
- **LOCAL-CLEANROOM** — behavior of this repository's independent implementation, kept separate
  from the target-fork observations.
- **UNKNOWN** — not established by the current probes.

Primary evidence:

- `evidence/probe-tests/UnderlyingPerpVaultPhase2Probe.t.sol`
- `evidence/underlying-perp-vault-rebalance-history.json`
- repository baseline `656a4d4a9c496255180b093106454c7de4ca0e03`

The target probe passes **18/18** tests. The independent target probe is run with:

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-contract UnderlyingPerpVaultPhase2ProbeTest -vv
```

This command tests the target-fork evidence only; it is not a local implementation differential.

The independent local implementation passes **14/14** focused Phase 2 unit tests and **3/3**
real-component integration tests using the repository's `PerpController`, `PerpToken`, `FeePolicy`,
`BondsManager`, and `BondIssuer`. The complete repository passes **199/199** tests. Its runtime is
`11,799` bytes; `PerpController` remains `22,475` bytes. The frozen UnderlyingPerpVault Phase 1
prefix remains in slots `0..4`, and the Phase 2 state is appended in slots `5..7`. Runtime-size,
Controller storage, UnderlyingPerpVault storage, formatting, JSON, and diff checks all pass.

## Version lock

**TARGET-CONFIRMED** at Base block `53,526,143`:

| Item | Value |
|---|---|
| chain ID | `8453` |
| Junior Vault proxy | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Senior Vault proxy | `0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB` |
| shared implementation | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` |
| implementation codehash | `0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645` |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |
| Controller target system ratio | `2,847,475,019,000,000,000` |
| Controller `subDR` | `1,052,430,305,854,682,822` |
| Controller `vmDR` | `1,000,210,729,013,702,352` |
| Rebalance event topic | `0xd2412c662f48f974143bb2428ce115c948201145d7b96f0eded33ccc43db383d` |

Both proxies resolved to the implementation above through the EIP-1967 implementation slot and the
runtime codehash matched.

## Public surface used by this phase

| Function | Selector |
|---|---|
| `computeRebalanceAmount()` | `0x409304db` |
| `rebalance()` | `0x7d7c2a1c` |
| `updateTargetDR(uint96,(uint96,uint96))` | `0x45c57816` |
| `updateRebalanceTimingParams(uint32,uint32)` | `0xfe4ddddf` |
| `updateMinRebalanceAmt(uint128)` | `0x6ae695b7` |
| `updateMaxFlashFeePerc(uint64)` | `0xf6de79c6` |

The event is `Rebalance(uint256 drBefore,uint256 underlyingAmt,bool isMintingPerp)`.

## Historical event inventory

**TARGET-CONFIRMED** within the explicit scan range `51,695,016..53,526,143`:

- `70` successful `Rebalance` events were found.
- Senior: `63` events — `26` mint and `37` redeem.
- Junior: `7` events — `5` mint and `2` redeem.
- `68` transactions were sent by `0xba887c8e396f24e0817be13839850de454ac7e45` to
  `0xca11bde05977b3631167028862be2a173976ca11` with top-level selector `0x82ad56cb`.
- `2` transactions were sent by `0xd7daaa0648d72afd2470e5b68b3cf1c9fd88c92b` directly to a Vault
  with selector `rebalance()` (`0x7d7c2a1c`).
- First recorded event: block `51,753,826`, transaction index `26`.
- Last recorded event: block `53,507,860`, transaction index `163`.

This inventory proves only successful event-producing calls within the stated range. It does not
enumerate reverted calls or calls that returned without emitting the event.

## Deployment defaults and fixed-block configuration

### Deployment defaults

**TARGET-CONFIRMED** at the first post-deployment snapshots probed — Junior block `51,749,808`,
Senior block `51,749,809`:

| Parameter | Junior | Senior |
|---|---:|---:|
| `targetDR` | `1e18` | `1e18` |
| `eqDRRange.lower` | `1e18` | `1e18` |
| `eqDRRange.upper` | `1e18` | `1e18` |
| `lastRebalanceTimestampSec` | `0` | `0` |
| `rebalanceFreqSec` | `86,400` | `86,400` |
| `rebalanceOffsetSec` | `0` | `0` |
| `minRebalanceVal` | `0` | `0` |
| `maxFlashFeePerc` | `10,000,000,000,000,000` | `10,000,000,000,000,000` |

### Fixed block `53,526,143`

**TARGET-CONFIRMED**:

| Parameter | Junior | Senior |
|---|---:|---:|
| `isPerpSrVault` | `false` | `true` |
| `mintsAboveTarget` | `false` | `true` |
| `targetDR` | `1,053,564,994,000,000,000` | `1,053,564,994,000,000,000` |
| `eqDRRange.lower` | `1,053,564,994,000,000,000` | `1,043,029,344,100,000,000` |
| `eqDRRange.upper` | `1,230,000,000,000,000,000` | `1,064,100,643,900,000,000` |
| `lastRebalanceTimestampSec` | `1,793,318,400` | `1,793,785,200` |
| `rebalanceFreqSec` | `28,800` | `28,800` |
| `rebalanceOffsetSec` | `0` | `6,000` |
| `minRebalanceVal` | `100,000` | `100,000` |
| `maxFlashFeePerc` | `5,000,000,000,000,000` | `5,000,000,000,000,000` |

## `computeRebalanceAmount` state machine

Let:

- `W = 1e18`;
- `D` be the Controller-returned `subDR`;
- `T` be Vault `targetDR`;
- `R` be Controller `targetSystemRatio`;
- `S` and `J` be the Controller SR and JR `reserveValue` values.

### Range and direction

**SYNTHETIC FORK, target implementation**:

1. If `eqDRRange.lower <= D <= eqDRRange.upper`, the amount is `0`. Both edges are inclusive.
2. Outside the range:
   - Senior: `D > T` mints SR; `D < T` redeems SR.
   - Junior: `D < T` mints JR; `D > T` redeems JR.
3. At `D == T`, both Vaults returned `isMintingPerp == false`.

Equivalent direction predicate outside equality:

```text
isMintingPerp =
    (mintsAboveTarget && D > T) ||
    (!mintsAboveTarget && D < T)
```

### Full-precision target reserve and system capacity

The formula family below is derived from exact target observations. All four system-capacity
directions are **TARGET-CONFIRMED** by transaction-prestate states in which the system capacity was
the binding cap. For Junior mint, block `51,774,759` returned `745,119` while the Vault held
`5,157,264` underlying units; the successful next-block transaction `0xc91cf622…d554` emitted the
same amount. Range and direction boundary rules remain separately labelled **SYNTHETIC FORK**.

| Direction | System capacity in underlying units | Evidence grade |
|---|---|---|
| JR mint | `floor(S * R * T / W^2) - J` | **TARGET-CONFIRMED**, uncapped historical state |
| JR redeem | `J - ceil(S * R * T / W^2)` | **TARGET-CONFIRMED**, uncapped transaction-prestate replay |
| SR mint | `floor(J * W^2 / (R * T)) - S` | **TARGET-CONFIRMED**, uncapped transaction-prestate replay |
| SR redeem | `S - ceil(J * W^2 / (R * T))` | **TARGET-CONFIRMED**, uncapped transaction-prestate replay |

The operation increases a reserve toward a floored target and decreases a reserve toward a ceiled
target. That prevents the planned integer reserve from crossing the target.

The multiplication and division must be evaluated with full-precision `mulDiv` semantics. At the
fixed block, splitting the calculation into two rounded divisions would produce:

- JR redeem `3,613,037` instead of the observed `3,613,038`;
- SR mint `1,217,209` instead of the observed `1,217,210`.

### Asset capacity

**TARGET-CONFIRMED for mint paths and Senior redeem; derived as the shared-side rule for Junior
redeem**:

```text
mintAssetCapacity   = underlyingBalance
redeemAssetCapacity = floor(perpBalance * selectedReserveValue / selectedPerpTotalSupply)
underlyingAmt       = min(systemCapacity, assetCapacity)
```

In the capped Junior replay, system capacity is `939,251`, while its underlying balance and returned
amount are both `856,406`. The separate uncapped historical state above distinguishes the floor rule.

An additional natural Senior redeem at transaction
`0x082d21936b731dc204fc66e57d0e30c0ca218f0a400cd650178b1c8a52f10d0b`, block
`52,936,360`, index `47`, emitted `2,121,382`. Its preceding-block state gave system capacity
`2,462,744` and `floor(perpBalance * reserveValue / totalSupply) == 2,121,382`. A transaction-index
exact replay is still required before treating this extra vector as the strongest evidence grade.

## Four exact historical replays

All four are **TARGET-CONFIRMED** transaction-prestate replays. Each emitted exactly one matching
Vault `Rebalance` event, left Vault note supply unchanged, advanced the Vault timestamp, and exposed
one successful Controller flash call with the expected selector and exact calldata. The probe does
not claim the absence of unrelated calls with different calldata.

| Side/action | Transaction, block/index | Historical `T` | System cap | Asset cap | Event amount | Actual underlying delta |
|---|---|---:|---:|---:|---:|---:|
| SR mint | `0x07114c…42ff`, `51,753,826/26` | `1,053,500,000,000,000,000` | `56,584` | `5,100,000` | `56,584` | `56,584` out |
| JR mint | `0x8eda4d…778e0`, `51,777,393/141` | `1,075,000,000,000,000,000` | `939,251` | `856,406` | `856,406` | `856,406` out |
| SR redeem | `0x2c2375…d5c0`, `51,879,760/71` | `1,053,500,000,000,000,000` | `129,350` | `3,945,082` | `129,350` | `129,138` in |
| JR redeem | `0x356229…9259b`, `52,543,960/64` | `1,053,564,994,000,000,000` | `2,896,807` | `146,399,807` | `2,896,807` | `2,896,806` in |

The exact Controller calls were:

- SR mint: `flashMint2(56_584, 0, 0, 0)`;
- JR mint: `flashMint2(0, 856_406, 0, 0)`;
- SR redeem: `flashRedeem2(10_890_264_276, 0, 0)`;
- JR redeem: `flashRedeem2(0, 244_104_743_210, 0)`.

For redeem, the Vault converts the planned underlying amount to Perp units with:

```text
perpIn = floor(plannedUnderlying * selectedPerpTotalSupply / selectedReserveValue)
```

The Controller then applies its own share-to-asset rounding and fee. Consequently, the Vault
`Rebalance` event amount is the planned underlying amount, not necessarily the final Vault balance
delta:

- JR redeem: planned `2,896,807`, actual `2,896,806`; the one-unit difference is integer rounding.
- SR redeem: planned `129,350`, reserve value fell `129,349`, Vault received `129,138`. The quote-to-
  receipt difference is one unit of conversion rounding plus `211` units retained as fee.

The SR redeem target total fee was `1,637,628,506,141,442`; the other three target total fees were
zero. Protocol fee was zero in all four replays.

## Execution boundaries

### Caller authorization

**SYNTHETIC FORK**: from the same valid Senior mint prestate, `rebalance()` succeeded independently
for the owner, a configured keeper `0x000000000000000000000000000000000000CA11`, and unrelated
address `0x000000000000000000000000000000000000bEEF`. The entry point is therefore permissionless in the
tested valid state.

### Minimum amount

**SYNTHETIC FORK** using a natural Junior quote of `856,406`:

| `minRebalanceVal` | Result |
|---:|---|
| `856,405` | success |
| `856,406` | success |
| `856,407` | `OpUnavailable("no capacity")` |

The execution comparison is inclusive: `amount >= minRebalanceVal` is allowed.

### Timing bucket and cooldown

**SYNTHETIC FORK** with frequency `100` and offset `50`:

```text
alignedBucket = floor((timestamp - offset) / frequency) * frequency + offset
```

At call timestamp `1,790,296,999`, a successful rebalance stored `1,790,296,950`, the aligned bucket,
not the call timestamp. At `aligned + 99`, it reverted `LastRebalanceTooRecent()` (`0xa3b3f090`). At
`aligned + 100`, the cooldown passed and the call reached the capacity check, which reverted
`OpUnavailable("no capacity")` (`0xf0b62b3b`).

### Maximum flash fee and atomicity

**SYNTHETIC FORK** on the natural Senior redeem vector:

- target fee: `1,637,628,506,141,442`;
- max fee `target - 1`: reverted `SlippageTooHigh()` (`0x850c6f76`);
- max fee exactly equal to target: succeeded.

The failing call preserved the Vault underlying balance, Perp balance, note supply, last timestamp,
Controller `subDR`/`vmDR`, and the complete `systemReserveState()` return tuple. The tested fee
comparison is inclusive and the failure is atomic over this monitored state.

## Setter roles and validation

The following results are **SYNTHETIC FORK** observations against the target implementation.

For `updateTargetDR`, `updateRebalanceTimingParams`, `updateMinRebalanceAmt`, and
`updateMaxFlashFeePerc`:

- owner: success;
- configured keeper after separating it from owner: `OwnableUnauthorizedAccount(address)`;
- unrelated caller: `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`).

Validation matrix:

| Setter | Allowed | Rejected |
|---|---|---|
| target/range | nonzero target; `lower <= target <= upper`; equality allowed | target `0` → `InvalidParamDefn()` (`0xd126d255`); malformed or target-outside range → `InvalidRange()` (`0x561ce9bb`) |
| timing | frequency `>= 1`; `offset < frequency` | frequency `0`, `offset >= frequency` → `InvalidParamDefn()` |
| minimum | every tested `uint128`, including `0`, `1`, and max | no rejected in-range value observed |
| max flash fee | `0..1e18`, inclusive | `1e18 + 1` → `InvalidPerc()` (`0xcdc62692`) |

## Evidence classification and implementation status

- **TARGET-CONFIRMED**: version lock, deployment defaults, fixed-block state, 70-event inventory, four
  exact natural replays, Controller calldata, natural rounding, and event payloads.
- **SYNTHETIC FORK**: exact formula discriminator matrix, direction/equality, inclusive range edges,
  permissionless caller test, timing boundary, minimum boundary, maximum-fee boundary, setter roles,
  and setter validation.
- **LOCAL-CLEANROOM**: the repository now contains the Phase 2 implementation and focused local
  unit and real-component integration suites; local results are reported separately from target
  observations.
- **UNKNOWN**: items below remain intentionally unresolved.

## Remaining unknowns

1. Exact ordering of the Vault `Rebalance` event relative to every Controller, Perp, underlying, and
   reserve-sync event. The current replay checks payload and uniqueness, not full ordering.
2. Pause behavior and precedence among pause, cooldown, no-capacity, minimum, and flash-fee errors.
3. `updateKeeper` authorization, zero-address validation, and event behavior; only an owner update was
   used to prepare the permissionless caller probe.
4. Junior redeem when its Perp asset capacity, rather than system capacity, is the binding cap.
5. The cap's final one-unit rule in a constructed case where `floor(perpBalance * value / supply)` and
   the largest amount whose floored Perp conversion is spendable differ by one.
6. Zero `reserveValue`, zero Perp `totalSupply`, and other degenerate arithmetic states.
7. Whether every historical configuration change followed the same setter event ordering.
8. Full history before block `51,695,016`, after block `53,526,143`, and reverted rebalance attempts.

Do not fill these gaps with inferred behavior in the production implementation. Add focused target
fork probes or mark the corresponding local behavior as an explicit clean-room safety design.
