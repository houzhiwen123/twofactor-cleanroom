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

## Ordered observations

The full Foundry traces list every nested call, call kind, target, selector or
decoded function name where available, and emitted event in execution order.
The supplementary Anvil callTracer logs additionally preserve raw input
selectors and output bytes for every traced call. Foundry's printed trace does
not show raw output-byte lengths for every nested call; direct callTracer output
sizes are therefore reported where available, and planner output sizes are
measured from the raw return payloads.

| Scenario | Observed calls and events, in order |
|---|---|
| **T1 — `upkeep()` then public `rollover()`** | The setup `upkeep()` calls issuer `issue()` (trace lines 454–455), then registers the newly issued SR and JR tranches on the Perps (531–540). Public `rollover()` starts at line 695; it obtains reserve data, calls the Balancer planner at 1227, transfers the stale tranche, redeems the bond pair, then calls BondsManager deposits (1338, 1352, 1394) and transfers the newly minted SR tranche back. The trace interleaves `BondMature`, the issuer's bond-created event, Perp `ReserveSynced`, ERC-20 `Transfer`, `TranchesRedeemed`, and BondsManager `BondDeposit` events in that order. See `round9_t1_rollover.log:227-1394`. |
| **T2a — issuance due, rollover otherwise needed** | `upkeep()` calls issuer `issue()` at 453–454, emits the new-bond event at 512, and calls `registerTranche` on SR/JR at 530–539. No `computePerpSrRolloverPlan` or rollover deposits follow in this `upkeep()` call. See `round9_t2a_upkeep.log:453-539`. |
| **T2b — rebalance window open** | At timestamp `1,794,160,801` with window `(frequency, offset, length)=(1,0,1)`, `upkeep()` attempts the maturity/issuance substeps, then reverts `NoOp()` at lines 599–600. No planner or successful rebalance is part of this `upkeep()` call, and its logs are rolled back. See `round9_t2b_upkeep_rebalance.log:583-600`. A separate successful direct `rebalance()` transaction is used only for the timestamp-opcode comparison below. |
| **T2c — nothing due** | At timestamp `1,794,160,799`, `upkeep()` likewise ends in `NoOp()` at lines 460–461; no rollover planner or successful rebalance runs. See `round9_t2c_upkeep_noop.log:444-461`. |
| **T3 — SR-only `flashMint2` after issue time** | The input transfer and SR `ReserveSynced` occur at 406–419; issuance runs at 438–439, and SR/JR `registerTranche` calls follow at 515–524. The Controller then calls the planner at 559, transfers the planned reserves and performs rollover deposits beginning at 565 and 681–740. The trace records the ordered `Transfer`, `ReserveSynced`, bond-created, redemption, and `BondDeposit` events. See `round9_t3_lazy_flashmint.log:406-740`. |

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
