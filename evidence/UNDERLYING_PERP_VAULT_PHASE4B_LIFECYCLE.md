# UnderlyingPerpVault Phase 4B — JR/SR lifecycle differential

## Scope and verdict

Phase 4B connects the already verified Vault operations to the real clean-room Controller, Perps,
BondIssuer, BondsManager, FeePolicy and PerpBalancer in one local lifecycle:

`deposit → Vault rebalance → three issue/mint epochs → Controller rollover → Vault redeem`.

The local lifecycle passes for the Junior and Senior Vaults in the same transaction sequence. The
rollover removes the stale tranche pair while preserving both Vaults' notes supply, held Perp
amounts and TVL exactly. Both user positions then redeem successfully and only the permanent minimum
Vault notes remain.

The target comparison is a **composite differential**, not a claim that one target account executed
the same contiguous sequence. Target deposits/redemptions and four rebalances are version-locked
historical vectors; target rollover behavior is from the existing disposable Base-fork probes. No
natural target rollover transaction has been identified in the archived evidence. Therefore the
complete local lifecycle is **LOCAL-CLEANROOM**, while each target leg retains its original evidence
classification.

Evidence labels:

- **TARGET-CONFIRMED** — public historical state or exact historical transaction replay already
  archived by Phase 1/2.
- **TARGET-SYNTHETIC-FORK** — target bytecode executed on a disposable Base fork with explicitly
  constructed local conditions.
- **LOCAL-CLEANROOM** — this repository's independently implemented contracts.
- **UNKNOWN** — not established by current target evidence.

Repository baseline: `3108239`.

## Target leg matrix

### Deposit and redeem

The Phase 1 target probe locks the quote and state at each transaction pre-state. The corresponding
public transaction metadata is retained here; Phase 4B did not reclassify quote-only evidence as a
new full transaction replay.

| Leg | Block / tx index | Transaction | Exact target result |
|---|---:|---|---|
| JR deposit | `51,777,456 / 245` | `0x57d37a67cb7497bb613e6d1c04805586b8a48130896575a378aa732a8a18132a` | `0 cbBTC + 1,636,069,530,773 JR → 194,416,786,128,004,843 notes` |
| SR deposit | `51,777,490 / 48` | `0xfbcb1b0804631f55de0d5f2460fd4b4681be20a8a87459719d5d5391de28ec48` | accepts `1,587,122 cbBTC + 540,252,299,306 SR → 80,494,093,785,850,860 notes` |
| JR redeem | `51,777,350 / 180` | `0x21eb05f37f07bd2c08da8d3f3c32621c11b0144f3c1eb0190d75c2d9ada5334a` | burns `41,562,290,000,000,000 notes → 3,555,739 cbBTC + 50,480,992,204 JR` |
| SR redeem | `51,777,359 / 158` | `0x55f37956343d2ec453a4421de2ca98427fcd7d10fca3a8353b22062994d61ae4` | burns `49,620,700,000,000,000 notes → 4,907,016 cbBTC + 4,656,119,783 SR` |

The local Phase 1 regression fixes the same floor-rounding formulas and exact vectors. Those tests
remain the operation-level differential for deposit and redeem.

### Vault rebalance

Phase 2 replays four real target transactions from transaction pre-state and checks the Controller
calldata, pre/post DRs, balances, fee, event and unchanged notes supply:

| Side/direction | Transaction | Gross / actual cbBTC | Perp delta | Total fee |
|---|---|---:|---:|---:|
| SR mint | `0x07114c7e3baca7be676b961fe55548e688f830b0a6d99116cdc04c25b8c542ff` | `56,584 / 56,584` | `+4,785,545,326 SR` | `0` |
| JR mint | `0x8eda4df97e08f8afc1d16ac0685f0d47527ebde30fbd4bbc8b5c177c97e778e0` | `856,406 / 856,406` | `+72,081,351,896 JR` | `0` |
| SR redeem | `0x2c23758afef541c51d2e290e533ab77f9396bf99e3cb9c632e7eec5f6fccd5c0` | `129,350 / 129,138` | `-10,890,264,276 SR` | `1,637,628,506,141,442` |
| JR redeem | `0x3562298f878658f89d970f77da8bc7ae8c0e0d14fa389ee6f794c8b814e9259b` | `2,896,807 / 2,896,806` | `-244,104,743,210 JR` | `0` |

The local Vault calls the same Controller side (`flashMint2` or `flashRedeem2`), leaves notes supply
unchanged, validates the flash fee, and commits the rebalance timestamp only after successful
execution. Phase 4B reuses this coverage instead of rescanning history.

### Controller rollover

Existing target evidence is **TARGET-SYNTHETIC-FORK** at Base block `54,990,962`:

- `upkeep()` issues/registers the fresh pair before planning;
- Controller calls only `computePerpSrRolloverPlan` externally on PerpBalancer;
- the stale SR/JR tranche balances were `3,133,547,705,520 / 3,133,547,705,527`;
- the standard plan rolled `41,875,890` underlying value and deposited `0`, `6,411,258`, and
  `77,245,228` into the three fresh candidates;
- reserve transfers, paired redemption, Bond deposits and new SR transfer occurred atomically;
- stale reserve rows were removed and reserve arrays followed swap-pop behavior.

Round 17 separately proves execution of the non-`0.5` backup branch. These observations establish
the Controller/Perp/Bond rollover behavior. They do **not** directly observe the target JR/SR Vault
notes and TVL across a natural rollover transaction; that target-level Vault invariant remains
**UNKNOWN**.

## Local complete lifecycle

Executable regression:

- `test/UnderlyingPerpVaultRealIntegration.t.sol`
- `testPhase4BBothVaultsDepositRebalanceRolloverRedeemLifecycle()`

The test deploys only repository contracts and uses the target-derived JR/SR initializer flags.
Each Vault receives a `1,000,000` cbBTC user deposit and performs a mint-direction rebalance. Three
weekly issue/mint epochs at `$82k`, `$79k`, and `$84k` make the original pair stale, after which
`Controller.rollover()` executes.

Exact local observations:

| Checkpoint | Senior | Junior |
|---|---:|---:|
| stale tranche before rollover | `4,160,000,000,000` | `4,160,000,000,000` |
| stale tranche after rollover | `0` | `0` |
| Vault TVL before rollover | `1,881,184` | `2,035,909` |
| Vault TVL after rollover | `1,881,184` | `2,035,909` |
| notes supply changed by rollover | no | no |
| Vault-held Perp changed by rollover | no | no |
| TVL after all redeemable notes exit | `0` | `1` rounding unit |
| final notes supply | `10,000,000,000` | `10,000,000,000` |

The final notes are the Vault-held permanent minimum liquidity. The test also proves that all tracked
cbBTC equals total cbBTC supply before and after rollover and after full user/initializer exit.

## Differential conclusion

| Behavior | Target evidence | Local evidence | Result |
|---|---|---|---|
| JR/SR deposit math and flooring | Phase 1 historical pre-states | exact Phase 1 regressions | match |
| JR/SR redeem math and flooring | Phase 1 historical pre-states | exact Phase 1 regressions | match |
| mint/redeem rebalance direction, Controller calldata, fees and rounding | four exact historical replays | Phase 2 regressions + real-component tests | match at the proven operation boundary |
| rollover call order and reserve mutation | target synthetic fork | Controller/Perp regressions + Phase 4B lifecycle | compatible for the proven Controller/Perp behavior |
| Vault notes/Perp/TVL invariant across rollover | **UNKNOWN** on target | exact local assertion | local safety property only |
| one contiguous deposit→rebalance→rollover→redeem target sequence | not present in archived evidence | passes locally | not target-confirmed |

No production compatibility defect was found in this phase, and no production contract was changed.

## RPC replay boundary

Phase 4B attempted to upgrade the Phase 1 quote vectors to full `vm.transact` replays. The free
public RPCs either returned HTTP `429`, returned TLS `525`, or did not complete one transaction in a
five-minute bound. These attempts are not counted as passing evidence. The probe was not retained in
the repository; the existing Phase 1 classification remains unchanged. A future archive RPC can
close this evidence-quality gap without changing the implementation.

## Verification

The focused local real-component suite passes **6/6**, including the new complete lifecycle. The
complete local suite passes **207/207**. Runtime checks report Controller **22,475 bytes** and
UnderlyingPerpVault **11,806 bytes**. Controller, USD Vault and UnderlyingPerpVault frozen storage
checks pass; the UnderlyingPerpVault ABI remains the frozen 83-entry interface with SHA-256
`c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`. `forge fmt --check`,
`git diff --check`, and JSON parsing all pass.
