# Rollover/upkeep module split design

Design only; this document does not implement rollover or upkeep.

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
cbBTC and tranche transfers, settlement, all Controller/Perp event emission, and timestamp updates.
The rollover/rebalance timestamp is committed only after every external asset operation has
succeeded, so no external call can observe a timestamp for an operation that has not completed.
The exact position of the timestamp write relative to events is fixed from the target trace, not
assumed. Any revert reverts the whole transaction.

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

**TODO before implementation:** capture fork traces of target `rollover()`, `upkeep()` and the
SR flash-mint lazy rollover path, and record every Balancer selector each one calls. Do not infer
internal planner call order beyond what those traces show.

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

The plan therefore carries tranche addresses and bond IDs, not indices. Because every planner
function is `pure`, it can only return addresses/IDs derived from the Controller-built input. The
Controller validates by membership: each `token` must appear in the reserve data it passed in, and
each `bondID` must belong to a tranche in that input. Index-based plans were considered and rejected
because they would change the public Balancer ABI.

## Controller plan-validation checklist

Before executing a returned plan, Controller-side checks should cover:

- Every token is a registered tranche, and every bond belongs to BondsManager.
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

Current runtime sizes are Controller **20,384 bytes**, PerpToken **8,055 bytes**, and PerpBalancer
**2,467 bytes** (`evidence/phase1b_sizes.log`). Keep planning in the existing Balancer. Only if a
measured Balancer runtime would exceed EIP-170's 24,576-byte limit should a separate stateless
`RolloverPlanner` be considered; it would still return a plan for Controller-only execution.

An executor role or callback boundary is rejected because it expands the attack surface, requires a
Perp permission change, and adds reentrancy and call-order complexity.

## Pending evidence

- Backup selection behavior.
- Partial-completion versus revert boundary.
- Tranche removal and reserve-array reordering.
- `recover()` behavior.
- Genesis/first-mint behavior.
- Exact `subDR == 1e18` value-cap behavior.
- `updateIssuer` validation.
