# Controller probes 2

Black-box observations from the local Base Anvil fork at block `54990962`
(initial timestamp `1794188568`). All calls and state writes were confined to
the fork. No target source/frontend bundle was read and no clean-room repo
files were changed.

Full raw traces and the Foundry harness are in `evidence/raw-logs.tar.xz`:

- `controller_probe2_traces.log` — Controller/perp call traces for flash mint,
  flash redeem, mint, redeem, rebalance, rollover, and upkeep.
- `controller_probe2_fee_lifecycle.log` — fee configuration, operations,
  maintenance, fee pulls, and subsequent user operation.
- `controller_probe2_aum.log` — nonzero AUM-rate cases.
- `controller_probe2_followup_final.log` — fee, liquidity, cap, and rollover
  control cases.
- `controller_probe2_sr_payer.log` — SR-payer rebalance with tranche reserves.
- `test/ControllerProbe.t.sol` — probe harness.

The `OBS:` lines in the logs are decoded raw records. Full reserve arrays,
token balances, inputs/calldata, return data, and emitted logs are retained
there; selected records and formula checks follow.

## Perp token interface and event

The proxies delegate to implementations SR
`0x96fc14b136300f9136c0d589ed7a787b66571574` and JR
`0x8e9ed1138060434e56a5f7965017391c93631529`. `cast selectors` against each
implementation runtime produced the selectors below. Shared selectors are
listed once; JR-only selectors are marked.

| Selector | Resolved signature |
|---|---|
| `0x06cb5b66` | `updateController(address)` |
| `0x06fdde03` | `name()` |
| `0x095ea7b3` | `approve(address,uint256)` |
| `0x0e07f854` | `init(string,string,address,address)` |
| `0x18160ddd` | `totalSupply()` |
| `0x23b872dd` | `transferFrom(address,address,uint256)` |
| `0x289cc9c8` | `reserveData()` |
| `0x29e81bd0` | `transferReservesTo(address,(uint256,(address,uint256)[]))` |
| `0x313ce567` | `decimals()` |
| `0x4230cc0d` | `registerTranche(address)` |
| `0x449a52f8` | `mintTo(address,uint256)` |
| `0x4bb279fb` | `handleTransferReservesIn((uint256,(address,uint256)[]))` |
| `0x650c699a` | `maxTrancheCount()` |
| `0x6f307dc3` | `underlying()` |
| `0x70a08231` | `balanceOf(address)` |
| `0x715018a6` | `renounceOwnership()` |
| `0x75172a8b` | `reserves()` |
| `0x79ba5097` | `acceptOwnership()` |
| `0x79cc6790` | `burnFrom(address,uint256)` |
| `0x8da5cb5b` | `owner()` |
| `0x95d89b41` | `symbol()` |
| `0xa9059cbb` | `transfer(address,uint256)` |
| `0xce746024` | `recover()` |
| `0xdb067b1b` | `logBalance(address)` |
| `0xdd62ed3e` | `allowance(address,address)` |
| `0xe30c3978` | `pendingOwner()` |
| `0xf77c4791` | `controller()` |
| `0x397e327f` | JR only: `primeApproval(address)` |
| `0x484685b0` | JR only: `revokeApproval(address)` |
| `0xb57b3436` | JR only: `bondDepositsForRollover(address,(bytes32,uint256)[])` |

`0xf2fde38b` resolves as `transferOwnership(address)` but is selector-ambiguous
in the 4byte lookup; the runtime selector alone does not disambiguate it.

Topic
`0xd1fbbd81a5fd46d869b5cd6883d99108cd295072be1b09d36381bbc78b686939`
resolves to **`ReserveSynced(address,uint256)`**. Its data is exactly two ABI
words `(token,balance)`. For example, `flashMint2` emitted
`ReserveSynced(cbBTC,1000000)` from SR and `ReserveSynced(cbBTC,2000000)` from
JR. The same topic is emitted when perp reserve balances are changed by
reserve transfers, tranche registration/recovery, and rollover. The `-vvvv`
trace correlates these events to calls on the emitting perp; the topic is not
an ERC-20 event.

## Controller-to-perp call inventory

These are the calls observed in `controller_probe2_traces.log`; proxy calls
delegate to the implementation above.

| Controller operation | Observed perp calls and representative decoded arguments |
|---|---|
| `flashMint2(1000000,2000000,0,0)` | `logBalance(cbBTC)` on both perps; `mintTo(Controller,74102043524)` on SR and `mintTo(Controller,175181463709)` on JR; then transfers of net `74094350215` SR and `175163276286` JR to the user. `OpFees` were `7693309` SR and `18187423` JR. |
| `flashRedeem2(74094350215,175163276286,0)` | SR `transferReservesTo(JR,(999896,[]))`; JR `handleTransferReservesIn((999896,[]))`; both sides `burnFrom(user,redeemed)`; JR `transferReservesTo(Controller,(2999688,[]))`. Controller then pays `2997699` cbBTC net and retains `1989` cbBTC fee. |
| `mint2` with deposited latest-bond tranches | Per side: `registerTranche(tranche)`, `logBalance(tranche)`, mint net perp to user and fee perp to Controller. Example trace: SR mints `37507090992` to user and `94583055` to Controller; JR mints `43035866540` to user and `108525179` to Controller. |
| `redeem2` | Both sides `burnFrom(user,amount)` and `transferReservesTo(user,reserve basket)`; zero-value mint/log calls also occur. Example returned SR basket: `[(0x2b9704…,12427697636),(0x7C82fD…,12218662440),(0x15a5Ff…,13228887052)]`, no SR underlying. JR returned `344792` underlying and `[(0x0BC266…,4046798160),(0xF012e0…,3978730585),(0x73D500…,4307687341)]`. |
| `rebalance` (baseline JR payer) | JR `transferReservesTo(SR,(28296,[]))`; SR `handleTransferReservesIn((28296,[]))`; `Rebalance(28296,false)`. |
| `rollover` | Transfers stale tranche reserves between perps, calls `recover`/`registerTranche`, redeems stale bond tranches through BondsManager, and calls JR `bondDepositsForRollover`. First captured rollover deposits: bond A `6411258`, new latest `77245228`; next rollover: prior latest `13431048`, new latest `77245228`. Detailed decoded calls are in the trace and rollover probe reports. |
| `upkeep` | Calls `recover()` on both perps and registers tranche tokens for the newly issued bond. The baseline-time upkeep reverted `NoOp()` (`0x00219cf1`); the issue-window upkeep succeeded. |

## Fee lifecycle and AUM observations

The protocol fee configuration probe set max protocol fee percentage to
`100000000000000000` and collector to the owner/keeper Safe. With this cap,
the operation fee percentages were fully protocol fees:

| Point in sequence | cbBTC Controller balance / collected / protocol | SR Controller balance / collected / protocol | JR Controller balance / collected / protocol |
|---|---:|---:|---:|
| Before user ops | `0 / 0 / 0` | `0 / 0 / 0` | `0 / 0 / 0` |
| After flash mint | `0 / 0 / 0` | `7693309 / 0 / 7693309` | `18187423 / 0 / 18187423` |
| After flash redeem | `1989 / 0 / 1989` | `7693309 / 0 / 7693309` | `18187423 / 0 / 18187423` |
| After baseline upkeep, rebalance, issue upkeep, and rollover | unchanged | unchanged | unchanged |
| After `pullProtocolFees` | `0 / 0 / 0` | `0 / 0 / 0` | `0 / 0 / 0` |

The three owner calls to `pullProtocolFees(token,0x…bEEF,amount)` succeeded.
They emitted ERC-20 `Transfer` events from Controller to `0x…bEEF` for
`1989` cbBTC, `7693309` SR, and `18187423` JR. The withdrawals are transfers,
not burns: per-token total supply did not fall on pull. Subsequent maintenance
did not move the recorded fees. The next SR-only user operation succeeded
with zero `OpFees`; its `collectedFeeBal` and `protocolFeeBals` remained zero.

### AUM fee trigger

Live AUM percentages were zero. On a local fork, `updateAumFeePerc(1000000000,
1000000000)` was used, then the cache was refreshed and a successful
`rebalance()` was used as the trigger. `AumFees(address indexed token,uint256
amount)` was emitted by Controller:

| Elapsed from rate update | Trigger result | SR `AumFees` | JR `AumFees` |
|---:|---|---:|---:|
| 3600 s | rebalance reverted `LastRebalanceTooRecent()` (`0xa3b3f090`); flash mint afterward emitted no AUM event | none | none |
| 86400 s | rebalance succeeded | `9581` | `33850` |
| 604800 s | rebalance succeeded | `9581` | `33850` |

Trace evidence shows each AUM amount is minted to FeePolicy's
`protocolFeeCollector` (the Safe) with `perp*.mintTo(Safe,amount)`; it is not
held as a Controller fee balance. At both 1d and 7d the event amounts are
identical. The 1h case is not a valid successful rebalance because of the
frequency guard, so it cannot establish what a permitted 1h trigger would do.

## JR liquidity, fee rounding, and value cap

The sampled JR liquidity getter values and candidate formula are:

| Absolute floor | Percentage floor | JR reserve value | `max(floor(value*perc/1e18),abs)` | JR idle underlying | Observed available |
|---:|---:|---:|---:|---:|---:|
| `1000000` | `10000000000000000` | `386465740` | `3864657` | `271549615` | `267684958` |
| `50000000` | `100000000000000000` | `386465740` | `50000000` | `271549615` | `221549615` |
| `0` | `500000000000000000` | `386465740` | `193232870` | `271549615` | `78316745` |
| `500000000` | `500000000000000000` | `386465740` | `500000000` | `271549615` | `0` |

For the last three settings, the reserved result is exact; available is exactly
`max(idleUnderlying-reserved,0)`. JR redemption at the computed boundary was
tested separately: `floor(supply*available/reserveValue)=23446721377764`,
whose underlying floor is `267684957`, one sat below available. The just-below
redemption succeeds; one above the boundary reverted `OpDisabled()`
(`0x07380a2e`).

For the traced both-sided flash mint, the Controller's actual FeePolicy inputs
were `(subDRpre,subDRpost,vmDRpre,vmDRpost) =
(1049678448816785329,1047013024833078884,1000925651512358813,
999633771042668700)`. `computeOpFees(isFlashOp=true,...)` returned
`103820479010835`, matching the `flashMint2` returned total percentages for
both sides. The reverse-direction flash-redeem inputs returned
`663118837574245`, also matching both returned percentages.

The fee amount rounding matches floor, not ceil:

| Operation/token | Gross basis | Percentage | Floor | Ceil | Observed `OpFees` |
|---|---:|---:|---:|---:|---:|
| flash mint SR | `74102043524` | `103820479010835` | `7693309` | `7693310` | `7693309` |
| flash mint JR | `175181463709` | `103820479010835` | `18187423` | `18187424` | `18187423` |
| flash redeem SR fee component | `1000000` | `663118837574245` | `663` | `664` | `663` |
| flash redeem JR fee component | `2000000` | `663118837574245` | `1326` | `1327` | `1326` |

Value-cap cases used current TVL `515764630` and set cap to that value for the
operation probes. A both-sided `1000000/1000000` flash mint reverted
`ValueCapExceeded()` (`0x8f61fa9a`). An SR-only `1000000` succeeded and moved
`subDR` from `1049678448816785329` toward `1e18` to
`1041622521027862605`; a JR-only `1000000` reverted with the value-cap error.
These observations agree with the previously recorded state-machine cases for
above-cap minting and improving/worsening single-sided operations. A large
SR-only `1000000000` attempt reverted `InsufficientRollover()`
(`0xbbb27b39`) both with cap `515764631` and with cap raised to `10000000000`;
therefore the crossing of `1e18` was not reached or established by that
probe.

## Rollover eligibility and SR-payer rebalance

The decoded Controller setters are
`updateRolloverEligibility(uint32)` and
`updateLiquidityThresholds(uint256,uint64)`. Initial values were
`minMaturitySec=604800`, JR reserve absolute floor `1000000`, and percentage
floor `10000000000000000`.

- With default eligibility and default liquidity, `rollover()` reverted
  `InsufficientRollover()` (`0xbbb27b39`).
- Setting min maturity to `1000000` but raising liquidity thresholds to
  absolute `500000000`, percentage `500000000000000000` left JR available
  liquidity zero; rollover reverted with the same error.
- Restoring liquidity thresholds and keeping min maturity `1000000` made
  rollover succeed. JR available liquidity changed from `267684958` to
  `264651618`. This isolates both controls: greater eligibility alone is not
  sufficient if reserved liquidity removes the available balance.

An SR-payer case was engineered by depositing `1000000000` cbBTC units into
the latest bond, then calling SR-only `mint2` with the resulting senior
tranche. Deposit minted `37970820186500` SR and the same amount JR tranche
tokens; `mint2` succeeded and minted `36460177180082` SR perp to the user plus
`1141556217855` fee SR to Controller. Before rebalance the SR reserve value
was `636730687`, JR `386465739`, and `subDR=213154887472454779`.

At timestamp `1794247200`, `rebalance()` succeeded with
`Rebalance(1020657,true)`. The Controller's
`Balancer.computeSystemRebalancePlan(reserves,1020657)` returned a reserve
plan whose nonzero tranche amount was
`(0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B,76375148955)`. The Controller
then called SR
`transferReservesTo(JR,(0,[(0x7C82fD…,76375148955)]))`, followed by JR
`handleTransferReservesIn` with the same tuple. The actual transfer exactly
matches the Balancer plan. Post-rebalance, SR reserve value was `620304838`,
JR `402891588`, and SR total supply fell from `47183045372416` to
`46041489154561` as recovery/rebalance burned SR; JR total supply remained
`33850817003440`.

## Derived formulas (hypotheses)

| Candidate | Result against observations |
|---|---|
| `ReserveSynced` data is `(address token,uint256 balance)` | **Exact match.** Decoded addresses and balances match the raw two-word event data, including flash-mint cbBTC balances and reserve-transfer updates. |
| `reservedJR=max(floor(JR.reserveValue*perc/1e18),abs)` | **Exact match** for all four threshold rows above. |
| `availableJR=max(JR.idleUnderlying-reservedJR,0)` | **Exact match** for all four rows (`267684958`, `221549615`, `78316745`, `0`). |
| Junior redemption is bounded by available underlying | **Exact at sampled boundary.** Calculated `23446721377764` perp units map to `267684957`; one sat below available succeeds, above boundary fails `OpDisabled()`. |
| Flash operation fee amount is floor of gross amount times fee percentage | **Exact match** for the two flash-mint fees and the two redeem components; ceil is one greater in each case. |
| Trace `FeePolicy.computeOpFees` percentage equals Controller return | **Exact match** for both sides of the tested flash mint and flash redeem using the trace's pre/post deviation inputs. |
| Operation fees are burned or converted during system operations | **Mismatch for burn/convert hypothesis.** Controller token balances and fee fields remain unchanged across upkeep, rebalance, and rollover; no burn was observed. `pullProtocolFees` is a transfer, and total supply is unchanged by the pull. |
| AUM accrues proportionally to elapsed seconds | **Mismatch at 1d vs 7d.** Equal successful-rebalance amounts (`9581`,`33850`) are observed at both intervals. The 1h call was blocked by `LastRebalanceTooRecent()`. |
| AUM amount is `floor(perp.totalSupply * AumFeePerc / 1e18)` | **Exact match** for both sides at both successful elapsed-time cases: `floor(9581311974479*1e9/1e18)=9581`; `floor(33850817003440*1e9/1e18)=33850`. |
| Cap allows corrective single-sided mint, rejects worsening and above-cap double-sided mint | **Exact match** for tested SR/JR and both-sided cases. |
| Crossing `subDR` through `1e18` is governed only by value cap | **Unresolved.** The large SR-only attempt fails earlier/otherwise with `InsufficientRollover()` even with a raised cap; no crossing observation is available. |
| `updateRolloverEligibility` admits bonds below the new maturity threshold, subject to liquidity | **Consistent with tested outcomes.** Default rollover fails; raising the threshold to `1000000` succeeds when liquidity is restored, and fails with zero available liquidity. |
| SR-payer `computeSystemRebalancePlan` equals executed reserve transfer | **Exact match** in the engineered case: plan and SR→JR transfer both specify `76375148955` of tranche `0x7C82fD…`; event reports `rebalanceValue=1020657`, payer SR. |

## Remaining limits

- The AUM behavior for a successful operation exactly one hour after the
  previous successful rebalance is not observable here: the rebalance
  frequency guard rejects that attempt.
- The large value-cap candidate does not establish crossing of `1e18`; it
  reverts with `InsufficientRollover()` under both tested cap settings.
- The logs retain the full decoded trace and raw record arrays for each
  operation; the tables above focus on the values needed to assess the
  requested formulas.

## Verification

- `forge test --fork-url http://127.0.0.1:8545 --match-test testFollowup
  -vvvv`: **8 passed, 0 failed**. This covered fee lifecycle, the 1h/1d/7d
  AUM cases, liquidity/eligibility controls, and large-cap candidates.
- After correcting the SR-only `mint2` input to use the matching JR tranche
  token with amount zero, the focused SR-payer run passed:
  `forge test --fork-url http://127.0.0.1:8545 --match-test
  testFollowupSrPayerRebalance -vvvv`: **1 passed, 0 failed**.
- The prior operation-trace run in `controller_probe2_traces.log` passed
  **5/5** tests.
