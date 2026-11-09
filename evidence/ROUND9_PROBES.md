# Round 9 — rollover and upkeep call traces

## Version lock

Chain ID `8453`; fork blocks `53,494,912` and `54,990,962`; Round 9 fork block
hash `0x1dff8df5543b16d844a672968579d9d341675728a9a3f3203f1e05bee332bc67`.
The EIP-1967 implementation slot is
`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.

| Contract | Proxy / direct address | Implementation | Proxy codehash | Implementation codehash |
|---|---|---|---|---|
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` | `0x16e324bae2098317477129a5e71f770bff51f02a` | `0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e` | `0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31` |
| FeePolicy | `0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8` | `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900` | `0x2a16f92d0d60ffb240c4be576111b0e8a195a4c5b0f98856380c8943b9bbaa44` | `0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755` |
| PerpBalancer | direct `0x30333a6B8744a1203D060E108dDC8C155059aCbf` | — | `0x540e400d7517059a0d44fe7ed777c00c5b667c5a118cb98b322f24e713dbb1f8` | — |
| BondIssuer | `0xc56CCbF6219B780c879544FEe0404bD3B49fEBB0` | `0xe024bd4967185456df3de7d2365919b5fb89763b` | `0x2f45f7c8aecc0c1bcc29b357b888ab106dde9ae1c078cb4fa39c3a93a41d0080` | `0x2a5e0beeb8cdfd88b98395e5e11dccdb915a7be3f8e5e9502819aaa67864cbe8` |
| BondsManager | `0xe8c13955caED9c009fd2b335A10986407958fde3` | `0x427758ed7ba97d3602125f957cd9e6716fddaac2` | `0xb14a5bc7f2c4d16ee0e0948b9c6976d4349cdc2ab01f8d86fae83ae79650dd46` | `0xb2318665f51d6ea433c3f7ac358765d48a4dace3da3e708bdaa94f54ef6a16c6` |
| PerpSR | `0x4be28E7597A928835245a10E9161E0c44687b70b` | `0x96fc14b136300f9136c0d589ed7a787b66571574` | `0x8e01b75f6fea2f350c20251d68f1da319eb892dc96fcacdcc9c7700af40e82a0` | `0x1d57fb7d55c334bb60b1a6cf666790a5e3e95d24ea6044a1a70a5e5762ce1a53` |
| PerpJR | `0x8cd04668292dC32F519972495C179E4f02C0e8AB` | `0x8e9ed1138060434e56a5f7965017391c93631529` | `0x3c1c15d9fd1529b7c8045877a581eb564b0797bb1d2e21453c140b0338f023b0` | `0xa34e6fcb0bf4e6b4ad9978a870df69fd9adb607f572e2cfad291c12c093d0ebb` |

The addresses and codehashes are the Round 8 version lock; the Round 9 tests
forked the same pinned block. All calls and state changes described below were
made on local Anvil forks. No verified source, frontend bundle, wallet key, or
non-local transaction was used.

## Reproduction

From the repository root, run the evidence-only probe file against the local
Base fork on port `8545`:

```sh
FOUNDRY_TEST=evidence/probe-tests forge test --offline --via-ir \
  --fork-url http://127.0.0.1:8545 --fork-block-number 54990962 \
  --match-path Round9TraceProbe.t.sol -vvvvv
```

The five individual scenarios each passed one test. The `-vvvvv` logs preserve
the ordered nested call traces and emitted events:
`round9_t1_rollover.log`, `round9_t2a_upkeep.log`,
`round9_t2b_upkeep_rebalance.log`, `round9_t2c_upkeep_noop.log`, and
`round9_t3_lazy_flashmint.log`.

The supplementary RPC transactions were sent only to a local Anvil fork with
account impersonation. The step-tracing node was started as follows:

```sh
anvil --fork-url http://127.0.0.1:8545 --fork-block-number 54990962 \
  --port 8547 --steps-tracing
```

To obtain the default struct logger and the call tree/output bytes for a saved
transaction:

```sh
cast rpc debug_traceTransaction <TX_HASH> '{}' \
  --rpc-url http://127.0.0.1:8547
cast rpc debug_traceTransaction <TX_HASH> '{"tracer":"callTracer"}' \
  --rpc-url http://127.0.0.1:8547
```

For the direct Anvil T1 rollover, the local price-feed and sequencer-feed code
was replaced with the test-only `Round9FreshFeedStub` runtime to satisfy the
fresh-price prerequisite after warping time. This was a local-only Anvil
override; it was not the public feed code. Its setup and the impersonated
transactions are recorded in `round9_anvil_feed_setup.log`,
`round9_t1_upkeep_anvil.log`, and `round9_t1_rollover_anvil.log`. The raw
default-struct traces and callTracer outputs are in the correspondingly named
`round9_*_debug_trace.log` and `round9_*_calltrace.log` files.

## Oracle and test-stub archive

At the pinned fork block `54990962`, the oracle's Chainlink price feed is
`0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D` (`decimals() = 8`) and the
sequencer feed is `0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`
(`decimals() = 0`). Before overrides, their `latestRoundData()` values were:

| Feed | Exact pinned-block return `(roundId, answer, startedAt, updatedAt, answeredInRound)` |
|---|---|
| Price | `(36893488147419122458, 7482940645796, 1794187614, 1794187627, 36893488147419122458)` |
| Sequencer | `(18446744073709551636, 0, 1782491507, 1794158703, 18446744073709551636)` |

For Round 9's Foundry tests, `_warpAndRefresh` uses selector-level
`vm.mockCall` for `latestRoundData()` only (`Round9TraceProbe.t.sol:156-169`).
At timestamp `t`, the exact mocked tuples are:

```text
price:     (36893488147419122458, 7482940645796, t,       t, 36893488147419122458)
sequencer: (18446744073709551636, 0,             t - 3601, t, 18446744073709551636)
```

Thus T1, T2a, and T3 use `t=1794510001`; T2b uses `t=1794160801`; and T2c
uses `t=1794160799`. These selector mocks do not replace runtime code, so
`decimals()` remained the fork values above.

For the separate direct Anvil trace, `anvil_setCode` installed the compiled
`Round9FreshFeedStub` runtime at both feed addresses (not `vm.etch`). Its
runtime codehash is
`0xaa3851d307ce61f618d0e96760865ea9fc1f8e76d5b4e58619e9c53a48539de9`.
The exact stub return uses `t=block.timestamp`:

```text
price:     (36893488147419122458, 7482940645796, t,       t, 36893488147419122458)
sequencer: (18446744073709551636, 0,             t - 3601, t, 18446744073709551636)
```

The local transactions ran at blocks/timestamps `54990963/1794510001`
(oracle refresh), `54990964/1794510002` (`upkeep()`), and
`54990965/1794510003` (`rollover()`). The code-replacement stub does not
implement `decimals()`; the recorded `8` / `0` values are the original fork
feed values before `anvil_setCode`.

### Cross-round mock inventory

The earlier oracle-mock rounds are **2, 3, 4, 5, 6, and 7**. Round 8 used no
oracle or code stub. The feed address and decimals are common across these
forks: price feed `0x07DA0E54543a844a80ABE69c8A12F22B3aA59f9D`
(`decimals() = 8`) and sequencer feed
`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433` (`decimals() = 0`). The pinned
Round 9 pre-override feed codehashes were not captured. Selector-level mocks
leave the fork feed runtimes and decimals unchanged; a separate stub runtime
codehash is not applicable for these mocks.

| Round | Exact `latestRoundData()` override | Method and runtime | Other local stubs |
|---|---|---|---|
| 2 | Price `(36893488147419122458, 7482940645796, t, t, 36893488147419122458)`; sequencer `(18446744073709551636, 0, t-3601, t, 18446744073709551636)`. `t` is the warped timestamp in each `local_oracle_refresh` record. | `vm.mockCall` on `latestRoundData()` only; no runtime replacement or stub codehash. | FeePolicy `computeRebalanceVal(uint256,uint256,uint256)` returned `(0,false)` at the configured FeePolicy. |
| 3 | Same base tuple as Round 2; the price answer also varied to `5238058452057` (−30%) and `9727822839534` (+30%), with the same round IDs and timestamp fields. | Selector `vm.mockCall`; no runtime replacement or stub codehash. | None identified in the archived Round 3 oracle cases. |
| 4 | Price `(36893488147419122458, priceAnswer, t, t, 36893488147419122458)`; sequencer `(18446744073709551636, 0, t-3601, t, 18446744073709551636)`. `priceAnswer` and `t` are the values read/emitted by that case. | Selector `vm.mockCall` in `Round4Probe.t.sol:94-116`; no runtime replacement or stub codehash. | BondsManager `isValidBond(bytes32)` returned `true`; `srTranche(bytes32)` / `jrTranche(bytes32)` returned test-deployed `Round4MockTranche` addresses. Their per-instance runtime codehashes were not captured in the Round 4 logs and remain unknown. |
| 5 | Price answers `5986352516636`, `7482940645796`, and `9353675807245`; each tuple uses the test's live `roundId` and `answeredInRound`, `(t,t)` timestamps. Sequencer `(roundId, 0, t-3601, t, answeredInRound)`. | Selector `vm.mockCall` in `Round5Probe.t.sol:468-485`; no runtime replacement or stub codehash. | A tranche's `isMature()` returned `true` in `_tryMockedMaturityUpkeep` at `Round5Probe.t.sol:335-336`. |
| 6 | Price `(36893488147419122458, 7482940645796, t, t, 36893488147419122458)`; sequencer `(18446744073709551636, 0, t-3601, t, 18446744073709551636)`. Each `t` and answer is recorded by label in `round6_controller_probes.log` / `round6_lazy_issue_probes.log`. | Selector `vm.mockCall` in `Round6ControllerProbe.t.sol:490-505`; no runtime replacement or stub codehash. | No non-oracle stub identified in Round 6. |
| 7 | Price `(1, 7482940645796, t, t, 1)`; sequencer `(1, 0, t-3601, t, 1)`. | Selector `vm.mockCall` in `Round7ReviewProbe.t.sol:517-529`; no runtime replacement or stub codehash. | FeePolicy `computeOpFees` returned `(1e15,0)`, `computeRebalanceVal` returned `(100,false)`, and `perpSrAUMFeePerc` / `perpJrAUMFeePerc` returned `1e17` / `5e16`. |
| 9 Foundry probes | Price `(36893488147419122458, 7482940645796, t, t, 36893488147419122458)`; sequencer `(18446744073709551636, 0, t-3601, t, 18446744073709551636)`. | Selector `vm.mockCall` at `Round9TraceProbe.t.sol:156-169`; no runtime replacement in Foundry tests. | None beyond the oracle refresh. |
| 9 direct Anvil trace | Same tuples, with `t=block.timestamp`, at both feed addresses. | Local `anvil_setCode` installed `Round9FreshFeedStub` (not `vm.etch`); runtime codehash `0xaa3851d307ce61f618d0e96760865ea9fc1f8e76d5b4e58619e9c53a48539de9`. The stub does not implement `decimals()`; `8` / `0` above are the original fork values. | None beyond the feed code replacement. |
| 10 | Price `(pinnedRoundId, answer, t, t, pinnedAnsweredInRound)`; sequencer `(pinnedRoundId, 0, t-3601, t, pinnedAnsweredInRound)`. The per-case answer and `t` are emitted in the Round 10 logs. | Selector `vm.mockCall` on `latestRoundData()` only; no runtime replacement or stub codehash. | No non-oracle runtime stub. |

### Other local selector/code stubs

Selector-level `vm.mockCall` entries do not install runtime bytecode, so there
is no separate stub runtime codehash for those entries; the called contracts'
fork code remains in place.

| Round | Target and mocked method | Exact mocked return | Address / runtime notes |
|---|---|---|---|
| 2 | FeePolicy `computeRebalanceVal(uint256,uint256,uint256)` | `(0, false)` | FeePolicy proxy `0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8`; `vm.mockCall` in `ControllerProbe.t.sol:1145-1149`; no runtime replacement. |
| 4 | BondsManager `isValidBond(bytes32)`, then `srTranche(bytes32)` or `jrTranche(bytes32)` | `true`, then the test-deployed `Round4MockTranche` address | BondsManager proxy `0xe8c13955caED9c009fd2b335A10986407958fde3`; `vm.mockCall` in `Round4PerpProbe.t.sol:469-475,485-492`. The mocked bond IDs are `bytes32(100000 + p*1000 + i)` and `bytes32(999999 + p)` (`p=0` SR, `p=1` JR). The generated tranche addresses and per-instance runtime codehashes were not captured in the archived Round 4 raw logs, so remain unknown. |
| 5 | Selected tranche `isMature()` | `true` | The target is the `tranche` argument to `_tryMockedMaturityUpkeep`; `vm.mockCall` in `Round5Probe.t.sol:335-336`. The exact selected tranche addresses were not preserved in the archived raw logs; this selector mock does not replace runtime code. |
| 7 | FeePolicy `computeOpFees`, `computeRebalanceVal`, `perpSrAUMFeePerc`, `perpJrAUMFeePerc` | `(1e15, 0)`, `(100, false)`, `1e17`, `5e16`, respectively | FeePolicy proxy `0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8`; `vm.mockCall` in `Round7ReviewProbe.t.sol:365-372`; no runtime replacement. |

No probe used `vm.etch`. `vm.mockCall` overrides selector responses without
replacing code; the Round 9 direct Anvil trace is the only listed runtime
replacement. All exact tuple formulas above are tied to the values logged for
each call, rather than implying that a single timestamp was used throughout a
round.

## Ordered observations

The full Foundry traces list every nested call, call kind, target, selector or
decoded function name where available, and emitted event in execution order.
The supplementary Anvil callTracer logs additionally preserve raw input
selectors and output bytes for every traced call. Foundry's printed trace does
not show raw output-byte lengths for every nested call; direct callTracer output
sizes are therefore reported where available, and planner output sizes are
measured from the raw return payloads.

| Scenario | Caller | Observed calls and events, in order |
|---|---|---|
| **T1 — `upkeep()` then public `rollover()`** | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`, the configured keeper and owner Safe at the pinned block, calls both operations via `vm.prank(controller.keeper())`. | The setup `upkeep()` calls issuer `issue()` (trace lines 454–455), then registers the newly issued SR and JR tranches on the Perps (531–540). Public `rollover()` starts at line 695; it obtains reserve data, calls the Balancer planner at 1227, transfers the stale tranche, redeems the bond pair, then calls BondsManager deposits (1338, 1352, 1394) and transfers the newly minted SR tranche back. The trace interleaves `BondMature`, the issuer's bond-created event, Perp `ReserveSynced`, ERC-20 `Transfer`, `TranchesRedeemed`, and BondsManager `BondDeposit` events in that order. See `round9_t1_rollover.log:227-1394` and `round9_t1_rollover_anvil.log:7`. |
| **T2a — issuance due, rollover otherwise needed** | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`, configured keeper and owner Safe, calls `upkeep()` via `vm.prank(controller.keeper())`. | `upkeep()` calls issuer `issue()` at 453–454, emits the new-bond event at 512, and calls `registerTranche` on SR/JR at 530–539. No `computePerpSrRolloverPlan` or rollover deposits follow in this `upkeep()` call. See `round9_t2a_upkeep.log:453-539`. |
| **T2b — rebalance window open** | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`, owner Safe and configured keeper, sets the test window and calls `upkeep()`; both roles map to the same address at the pinned block. | At timestamp `1,794,160,801` with window `(frequency, offset, length)=(1,0,1)`, this snapshot's `upkeep()` attempts the maturity/issuance substeps, then reverts `NoOp()` at lines 599–600. In this snapshot upkeep() did not trigger rebalance; does not establish that upkeep never rebalances. Its reverted logs are rolled back. See `round9_t2b_upkeep_rebalance.log:583-600`. A separate successful direct `rebalance()` transaction is used only for the timestamp-opcode comparison below. |
| **T2c — nothing due** | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`, configured keeper and owner Safe, calls `upkeep()` via `vm.prank(controller.keeper())`. | At timestamp `1,794,160,799`, `upkeep()` likewise ends in `NoOp()` at lines 460–461; no rollover planner or successful rebalance runs in this snapshot. See `round9_t2c_upkeep_noop.log:444-461`. |
| **T3 — SR-only `flashMint2` after issue time** | Random EOA `0x000000000000000000000000000000000000bEEF` calls `flashMint2` via `vm.prank(USER)`. | The input transfer and SR `ReserveSynced` occur at 406–419; issuance runs at 438–439, and SR/JR `registerTranche` calls follow at 515–524. The Controller then calls the planner at 559, transfers the planned reserves and performs rollover deposits beginning at 565 and 681–740. The trace records the ordered `Transfer`, `ReserveSynced`, bond-created, redemption, and `BondDeposit` events. See `round9_t3_lazy_flashmint.log:406-740`. |

## Answers to the requested questions

1. **Direct PerpBalancer selectors.** In the rollover/lazy-rollover paths,
   `computePerpSrRolloverPlan` is the only direct Controller-to-PerpBalancer
   selector observed (T1 line 1227; T3 line 559). No direct calls to
   `computeRolloverPolicy`, `computeBackupRolloverPolicy`,
   `computePerpJrLiquidity`, or `computePerpSrRolloverState` appear in the
   traces. The separate successful direct-rebalance call tree has a Balancer
   `STATICCALL` with selector `0x0ec27e16`, 128 return bytes, and decoded name
   `computeSystemRebalancePlan`. `computeRebalanceVal` is a FeePolicy call,
   not a PerpBalancer call; the Round 8 trace shows it at
   `round8_rebalance_trace.log:1288`, followed by the Balancer plan at line
   1291. These are rebalance planners, not calls to the four rollover helper
   selectors. This establishes the external call graph for the captured
   transactions, not PerpBalancer's internal implementation.

2. **Registration relative to planning and deposits.** In T1's same-test
   issuance, issuer `issue()` is at lines 454–455, `registerTranche` on SR/JR
   at 531–540, planner at 1227, and BondsManager deposits at 1338, 1352, and
   1394. Thus registration occurs after issue, before the planner, and before
   deposits. T3 independently shows issue at 438–439, registration at 515–524,
   planner at 559, and rollover deposits at 683 onward. The fresh bond is
   already present in both reserve-data arrays passed to the planner, with
   zero held tranche balance/value at that point.

3. **Planner inputs and decoded output.** Both calls pass
   `bondsManager=0xe8c13955caED9c009fd2b335A10986407958fde3`,
   `minMaturitySec=604800`, and
   `reservedPerpJrLiquidity=3864657`. T1 passes SR underlying `0`; T3 passes
   SR underlying `3000001` after the flash-mint input. Both SR and JR reserve
   arrays contain the freshly registered bond
   `0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b`
   with zero held reserve amount/value. The complete tuple inputs are printed
   at `round9_t1_rollover.log:1227` and
   `round9_t3_lazy_flashmint.log:559`.

   The `RolloverExecution` return is 768 bytes in both traces. Decoding the raw
   return at T1 line 1228 gives:
   - `stale = (underlyingAmt: 0, trancheAmts: [(0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B, 3133547705520)])`;
   - `freshBondDepositAmts = [(0x342b85e9d38918a8718c6ea642ea0df75e75c938bc45a6efde8c1dbaa3ef108d, 0), (0x93dcba573477147233c33c344a994ff99eedbe3ac9c31c2c5198f72add177ca8, 6411258), (0xff73192993e9aaaf7db24d86d5156c9c9eac5bfeadff2a6ffc2fd3bd8e74181b, 77245228)]`;
   - `freshSrTrAmts = [(0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68, 0), (0x2b97045571Ec78aE1010Df47b3e275eCdAE53300, 243440724687), (0x1b33Fea0a5f8685Cba207A2aC06426427FE2d2B1, 2890107281474)]`;
   - `underlyingValRolled = 41875890`.

   Decoding T3's return at line 560 gives the same stale tranche, with
   `stale.underlyingAmt=3000001`; fresh deposits
   `(0x342b…108d,0)`, `(0x93dc…77ca8,6411258)`, and
   `(0xff731…74181b,83245230)`; fresh SR tranches
   `(0x15a5…4A68,0)`, `(0x2b97…3300,243440724687)`, and
   `(0x1b33…d2B1,3114595575678)`; and
   `underlyingValRolled=44875891`. The full raw return payloads are in the
   respective trace logs.

4. **Timestamp slot and event ordering.** For T1, the before/after Controller
   storage snapshots at blocks `54990964` and `54990965` show no changed slot
   in the scanned range 0–127; the default struct trace has no Controller-depth
   `SSTORE` or `LOG` opcode. The public rollover transaction's receipt emits
   Perp/BondsManager events, but no Controller event. The Controller getter
   remains `lastRebalanceTimestampSec=1794160800` at both blocks.

   T2b `upkeep()` itself reverts `NoOp()`, so there is no rebalance timestamp
   write in that call. For the separate direct `rebalance()` transaction at
   block `54990967` / timestamp `1794510005`, the
   before/after diff identifies Controller slot `9` as the slot containing the
   timestamp: it changes from
   `0x000000000000000000000000000000006af0b8a0000000010000000000000001` to
   `0x000000000000000000000000000000006af60cb5000000010000000000000001`.
   The public getter changes to `1794510005`. In the default struct logger, the
   Controller `Rebalance` `LOG1` is opcode index `27153` and the slot-9
   `SSTORE` is index `32723`; therefore the event is logged before the
   timestamp storage update. The slot diff and indexes are recorded in
   `round9_opcode_analysis.log:1-11`; traces/snapshots are
   `round9_t2b_rebalance_debug_trace.log` and
   `round9_t2b_storage_block_54990966.log` /
   `round9_t2b_storage_block_54990967.log`.

## Evidence files

| File | Contents |
|---|---|
| `probe-tests/Round9TraceProbe.t.sol` | Evidence-only Foundry fork probe for T1, T2a–c, and T3 |
| `round9_t1_rollover.log`, `round9_t2a_upkeep.log`, `round9_t2b_upkeep_rebalance.log`, `round9_t2c_upkeep_noop.log`, `round9_t3_lazy_flashmint.log` | Ordered `forge test -vvvvv` call/event traces |
| `round9_t1_*_calltrace.log`, `round9_t1_*_debug_trace.log`, `round9_t2b_rebalance_calltrace.log`, `round9_t2b_rebalance_debug_trace.log` | Local Anvil raw callTracer and default struct-logger traces |
| `round9_*_anvil.log`, `round9_*_storage*.log`, `round9_opcode_analysis.log` | Local transaction receipts, storage snapshots, and opcode comparison |

No files under `src/` or `test/` were changed for this round.
