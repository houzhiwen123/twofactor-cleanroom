# Rollover/upkeep module split design

The public standard/backup rollover branches, SR lazy rollover, and upkeep now follow this
boundary. Planning remains in `PerpBalancer`; all asset operations remain in `PerpController`.

## Boundary

Adopt only option 1: `PerpController` remains the sole coordinator and performs **all asset
operations**. Planning stays in the existing `PerpBalancer` as pure functions invoked by the
Controller with `STATICCALL`:

Controller calls **one** planner entry point for rollover: `computePerpSrRolloverPlan` (the only
Balancer rollover selector observed in the target trace below). The other public pure functions are
used inside `PerpBalancer`:

```text
PerpController
    -> PerpBalancer.computePerpSrRolloverPlan(srReserveData, jrReserveData, bondsManager,
                                              minMaturitySec, reservedPerpJrLiquidity)   // STATICCALL, pure
PerpBalancer (internal)
    |- computePerpSrRolloverState
    |- computePerpJrLiquidity
    |- computeRolloverPolicy
    `- computeBackupRolloverPolicy
```

Whether target Controller also calls any of the inner functions directly is unproven; until a trace
shows it, the clean room calls only the single entry point. `computeSystemRebalancePlan` remains the
separate rebalance entry point.

The planning context is built by `PerpController` from its own storage: issuer, SR/JR Perps,
BondsManager, underlying token, and the relevant thresholds and current reserve state. Users never
pass dependency addresses. `PerpBalancer` returns plans only; it does not move tokens or mutate
protocol state.

`PerpController` retains issuer calls, every SR/JR Perp call, BondsManager deposits and redeems,
cbBTC and tranche transfers, settlement, Controller event emission, and timestamp updates.
`PerpToken` emits its own events (`Transfer`, `ReserveSynced`, ...) when the Controller calls it.
The rollover/rebalance timestamp is committed only after every external asset operation has
succeeded, so no external call can observe a timestamp for an operation that has not completed.
A normal call trace does not show the order of internal `SSTORE`s relative to events; proving the
target's timestamp-vs-event order requires an opcode/storage trace (e.g. `debug_traceTransaction`
with the struct logger on the fork). Until that is captured, "timestamp after all external asset
operations" is a clean-room safety design, not verified target behavior. Any revert reverts the
whole transaction.

## Target call-graph evidence

An existing target fork trace records `Controller.rollover()` calling
`PerpBalancer.computePerpSrRolloverPlan` (public Balancer ABI selector) at
`evidence/raw-logs.tar.xz::rollover_controller_trace_initial.log:5037-5038,5553`; the path is also
summarized in `evidence/ROLLOVER_PROBES.md:135`. The public Balancer ABI contains
`computeBackupRolloverPolicy`, `computePerpJrLiquidity`, `computePerpSrRolloverPlan`,
`computePerpSrRolloverState`, `computeRolloverPolicy` and `computeSystemRebalancePlan`.
Whether the other planner functions are reached only internally (inside
`computePerpSrRolloverPlan`) or also called directly by the Controller is not visible in the
external call trace of that snapshot.

Round 9 captured target fork traces for public `rollover()`, `upkeep()`, and the SR flash-mint lazy
rollover path. Only `computePerpSrRolloverPlan` was observed as the Controller's rollover planner
entry point. Do not infer internal planner call order beyond those traces.

## Plan format

The return type is fixed by the public Balancer ABI and is kept bit-compatible:

```text
RolloverPlan {
    (uint256 underlyingAmt, (address token, uint256 amount)[] trancheAmts) stale;
    (bytes32 bondID, uint256 underlyingAmt)[] freshBondDepositAmts;
    (address token, uint256 amount)[] freshSrTrAmts;
    uint256 underlyingValRolled;
}
```

The plan therefore carries tranche addresses and bond IDs, not indices. Index-based plans were
considered and rejected because they would change the public Balancer ABI.

`STATICCALL` forbids, at runtime, any state modification by the Balancer and its whole call chain;
it does not forbid reading chain state. `pure` is a compile-time constraint of the current
`PerpBalancer` implementation, not a runtime guarantee about an arbitrary replacement contract set
by governance. The Balancer address is therefore a governed, trusted planning module, and nothing
guarantees that returned addresses/IDs come from the input (a planner can return hard-coded or
arbitrarily computed values). The following membership checks are future hardening candidates,
not current target-compatible behavior:

- every stale tranche `token` must come from the SR/JR reserve data the Controller passed to the
  Balancer;
- every fresh `bondID` must come from the candidate bond set the Controller builds from
  Issuer/BondsManager state (a freshly issued bond need not already appear in pre-operation reserve
  data);
- every `freshSrTrAmts` token must be the senior tranche that BondsManager maps to one of those fresh
  `bondID`s.

How the candidate set is built (including a bond issued in the same transaction) follows the
Round 9 issue→register→planner trace.

## Future Controller plan-validation checklist

If target evidence supports extra validation before executing a returned plan, checks should cover:

- Every stale tranche token is an already-registered reserve tranche; every bond belongs to
  BondsManager. Fresh SR tranches may be issued in the same transaction: whether and when they must
  be registered is decided by the pending issue→rollover trace, so the "already registered" check
  is not applied to fresh tranches unconditionally.
- Array lengths do not exceed the configured tranche cap; no tranche is duplicated.
- Total outflow is no greater than actual reserves.
- SR/JR tranche amounts are correctly paired.
- Total deposited equals the funds available to the plan.
- Direction, maturity, and `minMaturitySec` are consistent with current state.
- Partial completion cannot breach the JR liquidity floor.

These are clean-room safety checks, not established target behavior. Before adding a check that
could cause an extra user-visible revert, fork evidence must show it does not diverge from the
target. If that cannot be established, retain it only as an internal assertion that cannot trigger
for a valid target planner output; do not turn it into a new observable validation rule.

## Size contingency and rejected boundaries

Current runtime sizes are Controller **23,981 bytes**, PerpToken **10,846 bytes**, and PerpBalancer
**8,652 bytes** (`evidence/phase1b_current_sizes.log`). Keep planning in the existing Balancer. Only if a
measured Balancer runtime would exceed EIP-170's 24,576-byte limit should a separate stateless
`RolloverPlanner` be considered; it would still return a plan for Controller-only execution.

After backup, upkeep, oracle entries, lazy rollover and the Round 15 issuer behavior, Controller has
**595 bytes** of EIP-170 headroom and only **19 bytes** under the project's stricter 24,000-byte
guard. Any further Controller feature must be measured immediately; additional pure planning
belongs in Balancer.

An executor role or callback boundary is rejected because it expands the attack surface, requires a
Perp permission change, and adds reentrancy and call-order complexity.

## Pending evidence

- Deployment-time genesis seeding (the empty-system first-mint failure is known).
- Invalid tranche identities, manager failures and mixed-manager reserve-cleanup batches.
- Exact slippage-equality boundaries for all user operation entry points.
