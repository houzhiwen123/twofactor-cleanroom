# Rollover/upkeep module split design

Design only; this document does not implement rollover or upkeep.

## Boundary

Adopt only option 1: `PerpController` remains the sole coordinator and performs **all asset
operations**. Planning stays in the existing `PerpBalancer` as pure functions invoked by the
Controller with `STATICCALL`:

| Planning function | Responsibility |
|---|---|
| `computePerpSrRolloverState` | Derive SR stale-tranche and rollover state |
| `computePerpJrRolloverPlan` | Plan JR-side rollover amounts |
| `computeRolloverPolicy` | Plan standard rollover deposits |
| `computeBackupRolloverPolicy` | Plan backup-branch deposits |
| `computePerpJrLiquidity` | Derive JR free/reserved liquidity |
| `computeSystemRebalancePlan` | Existing system rebalance plan |

The planning context is built by `PerpController` from its own storage: issuer, SR/JR Perps,
BondsManager, underlying token, and the relevant thresholds and current reserve state. Users never
pass dependency addresses. `PerpBalancer` returns plans only; it does not move tokens or mutate
protocol state.

`PerpController` retains issuer calls, every SR/JR Perp call, BondsManager deposits and redeems,
cbBTC and tranche transfers, settlement, all Controller/Perp event emission, and timestamp updates.
The last state-changing step is the timestamp update after all planned execution succeeds. A
revert anywhere before that point reverts the whole transaction.

## Target call-graph evidence

An existing target fork trace records `Controller.rollover()` calling the Balancer address with a
selector rendered as `computePerpSrRolloverPlan` at
`evidence/raw-logs.tar.xz::rollover_controller_trace_initial.log:5037-5038,5553`; the path is also
summarized in `evidence/ROLLOVER_PROBES.md:135`. That name is **not** in the supplied public
Balancer ABI. The trace confirms the observed call in that snapshot, but it does not establish
that the public planner functions listed above are called separately: their internal invocation
inside that Balancer call is not visible in the external call trace.

**TODO before implementation:** reconcile the observed selector with the supplied public ABI and
capture a fork trace of target `rollover()` that establishes which Balancer selectors are invoked.
Do not implement a `computePerpSrRolloverPlan` dependency or infer internal planner call order from
the current trace.

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
