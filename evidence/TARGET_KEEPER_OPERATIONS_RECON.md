# Target Keeper / operations reconstruction

## Outcome

The target does **not** expose a single privileged “Keeper-only” execution surface. The observed
maintenance entries are mostly permissionless, while production automation is visible as a stable
operator pattern: `68/70` historical JR/SR Vault rebalances in the bounded scan were submitted by
one address through Multicall3, and two were direct Vault calls from another address.

That distinction is important:

- **contract rule**: a valid random EOA reaches the same business path as owner/keeper in the tested
  Controller and Vault states;
- **production habit**: a small set of addresses actually performed the natural historical calls;
- **UNKNOWN**: the private service's poll interval, task queue, retry/backoff, gas bidding, alerting,
  and failover logic.

This phase is evidence/specification only. It does not add an off-chain Keeper or change a production
contract.

## Evidence labels and safety boundary

- **TARGET-CONFIRMED**: natural public Base state or exact transaction-prestate replay.
- **SYNTHETIC FORK / TARGET IMPLEMENTATION**: target bytecode on a local fork with an explicitly
  constructed state.
- **DERIVED**: computed from target-confirmed values.
- **UNKNOWN**: public evidence does not settle it.
- **BNB-DESIGN**: future clean-room design choice, never presented as target behavior.

Only public Base read-only data and local forks were used. No wallet, private key, signature,
broadcast, private Keeper API, target storage mutation on a live chain, verified source, or target
frontend bundle was used.

## Version locks

| Surface | Version lock |
|---|---|
| Controller | Base block `54,990,962`, hash `0x1dff…bc67`; proxy `0x682F…A200`; implementation `0x16e3…f02a`; implementation codehash `0xc18d…6e31` |
| JR/SR UnderlyingPerpVault | block `53,526,143`; proxies `0xebEe…139DB` / `0x805D…398cB`; shared implementation `0xA130…925ea`; codehash `0xf449…5645` |
| USD Vault | proxy `0xe356…75F3`; implementation `0xF85E…aACF`; codehash `0x8154…80a4` |

Full values are in `evidence/target-keeper-operations-recon.json` and the cited phase reports.

## On-chain task matrix

| Task | Trigger | Caller | Success / idle result | Evidence |
|---|---|---|---|---|
| Controller `rebalance()` | Inside the half-open configured window and cooldown satisfied | Permissionless in tested valid state | Success stores the aligned window start; outside window `OutOfRebalanceWindow()`; one second before cooldown `LastRebalanceTooRecent()` | Synthetic target fork, Round 6 |
| Controller `upkeep()` | Mature tranche recovery and/or Bond issuance due | Permissionless in tested work/no-work states | Four-state matrix below; no work reverts `NoOp()` | Synthetic target fork, Rounds 10/13 |
| Controller `rollover()` | Stale SR state plus a non-empty plan funded by JR free liquidity | Permissionless in tested work/no-work states | Full, partial, or `InsufficientRollover()`; thresholds are pinned-state vectors, not constants | Synthetic target fork, Round 10 |
| JR/SR Vault `rebalance()` | `subDR` outside inclusive range, capacity at least minimum, newer aligned timing bucket | Permissionless in valid tested state | Executes Controller flash mint/redeem; no capacity reverts `OpUnavailable("no capacity")` | Natural history + synthetic caller boundary |
| USD Vault `rebalance()` | Active executable session, healthy dependencies, at least `openedAt + 3600` | Permissionless before business guards | Direct path executes DEX/Controller atomically; natural production settlement commonly uses authorized inventory `swap()` instead | Natural transactions + synthetic delay/failure probes |
| USD Vault `upkeep()` | Health/state maintenance; redeem-side idle-underlying cleanup exists | Permissionless before business guards | Natural batches call it; state-changing cleanup is proven only on a synthetic target-implementation state | Natural reachability + synthetic execution |
| USD Vault `swap()` | External inventory settlement | Authorized swapper only | Random address gets `UnauthorizedCall()` | Target-confirmed |
| `flashMint2()` lazy rollover | User mint encounters issue/rollover conditions | User operation | May issue or roll as a side effect | Not a scheduled Keeper job |

### Controller `upkeep()` state machine

| Maturity due | Issuance due | Result | Durable change |
|---:|---:|---|---|
| No | No | `NoOp()` (`0x00219cf1`) | None; attempted subcalls roll back |
| No | Yes | Success | Latest Bond changes; SR/JR reserve arrays gain the new rows |
| Yes | No | Success | Mature rows are removed; underlying returns to both Perps |
| Yes | Yes | Success | Settlement and new registration happen atomically |

Observed internal order:

```text
oracle.cachePrice
  -> SR.recover
  -> JR.recover
  -> issuer.issue
  -> SR/JR registerTranche
  -> oracle.resetCache on successful work
```

No rollover planner, system rebalance planner, or `rebalance()` call appeared in those four pinned
traces. This is a version-and-state-bounded negative observation, not a universal claim about every
historical implementation.

### Timing and idempotency boundaries

- Controller rebalance window is half-open: start and `end - 1` succeed; end and `end + 1` revert.
- Controller cooldown is inclusive at `last + frequency`: one second earlier reverts, exact boundary
  succeeds.
- At block `53,526,143`, both JR and SR Vaults use an eight-hour (`28,800` second) frequency; JR
  offset is `0`, SR offset is `6,000` seconds.
- USD direct rebalance delay is inclusive at `openedAt + 3,600` seconds.
- No-work paths revert atomically and do not consume timestamps or budgets. This supports a
  state-based idempotent polling model, but the target's private retry policy remains **UNKNOWN**.

## Natural operator evidence

Bounded scan: blocks `51,695,016..53,526,143`.

| Observation | Count |
|---|---:|
| Successful JR/SR Vault `Rebalance` events | `70` |
| Senior / Junior | `63 / 7` |
| Mint / redeem direction | `31 / 39` |
| Operator `0xba88…7e45` -> Multicall3 `0xca11…ca11`, `aggregate3` selector `0x82ad56cb` | `68` |
| Operator `0xd7da…c92b` -> Vault direct `rebalance()` selector `0x7d7c2a1c` | `2` |

This proves a concentrated operational pattern, not an access-control requirement.

## Selected replay vectors

| Vector | Block / index | Result in this phase |
|---|---:|---|
| SR mint, batched: `0x07114c…42ff` | `51,753,826 / 26` | PASS, exact Controller calldata and balances |
| JR mint, direct: `0x8eda4d…778e0` | `51,777,393 / 141` | PASS, exact Controller calldata and balances |
| SR redeem, batched: `0x2c2375…d5c0` | `51,879,760 / 71` | PASS, exact fee/calldata/balances |
| USD redeem settlement: `0xf49ebf…7568e` | `53,480,534 / 64` | PASS, asset flow/event/session debit |
| USD mint settlement: `0x4adb05…0276` | `53,491,335 / 117` | PASS, asset flow/event/session debit |

Two additional natural JR/SR directions were also rerun, so the selected UnderlyingPerpVault suite
finished `5 passed, 0 failed`; the selected USD suite finished `3 passed, 0 failed`.

## What can be implemented next

The target-aligned on-chain interface for a first clean-room operations service is now bounded:

1. read task state only;
2. simulate the exact public entry before submitting;
3. treat the documented no-work selectors as normal outcomes;
4. submit permissionless Controller/Vault maintenance entries;
5. never call USD `swap()` unless the service is the explicitly authorized inventory;
6. re-read state after success; do not assume a transaction won solely because it was submitted.

The following must be explicitly **BNB-DESIGN**, because public target evidence cannot recover it:

- polling interval and cross-task priority;
- retry count, exponential backoff, RPC failover, and gas bidding;
- alert thresholds and operator escalation;
- whether to batch independent calls through Multicall3;
- signer custody, deployment topology, and secrets handling.

No off-chain service should be advertised as a 1:1 clone of the private target Keeper. We can make
its on-chain decisions and results target-compatible; its private scheduling policy is necessarily
our own design.

## Reproduction

Natural UnderlyingPerpVault replays and caller boundary:

```sh
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL=https://base-rpc.publicnode.com \
forge test --match-contract UnderlyingPerpVaultPhase2ProbeTest \
  --match-test 'testReplayNatural(Junior|Senior)(Mint|Redeem)Rebalance|testSyntheticForkRebalanceIsPermissionlessForOwnerKeeperAndRandom' -vv
```

Natural USD Vault settlement and business-guard caller boundary:

```sh
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL=https://base-rpc.publicnode.com \
forge test --match-contract UsdVaultPhase5ARealRebalanceProbe \
  --match-test 'testProbeNatural(Mint|Redeem)Rebalance|testProbeNaturalDelayBoundaryBlocks' -vv
```

Controller state-machine probes remain reproducible using the commands in `ROUND6_PROBES.md` and
`ROUND10_PROBES.md`. Their archived results are Round 6 `22/22` and Round 10 `10/10`. During this
phase, a fresh local compilation of those two heavy probe files exceeded the phase compile-time cap
and was stopped before execution, so it is not counted as a new pass.

## Source evidence

- `evidence/ROUND6_PROBES.md`
- `evidence/ROUND9_PROBES.md`
- `evidence/ROUND10_PROBES.md`
- `evidence/ROUND13_SYSTEM_GAPS.md`
- `evidence/UNDERLYING_PERP_VAULT_PHASE2_REBALANCE.md`
- `evidence/underlying-perp-vault-rebalance-history.json`
- `evidence/USD_VAULT_PHASE5A_REAL_REBALANCE.md`
- `evidence/USD_VAULT_DIRECT_REBALANCE_UPKEEP.md`
- `evidence/probe-tests/UnderlyingPerpVaultPhase2Probe.t.sol`
- `evidence/probe-tests/UsdVaultPhase5ARealRebalanceProbe.t.sol`
