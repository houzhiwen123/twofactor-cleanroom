# Rollover plan safety hardening

Status: **BNB-DESIGN / CLEANROOM SAFETY**
Baseline: `bccfb72`
Scope: local clean-room contracts and local tests only

This phase does not claim that the target 2Factor deployment exposes the same checks or the same
errors. It adds defense-in-depth around the clean-room planner trust boundary without changing the
Controller storage layout or placing more code in `PerpController`.

## Threat boundary

`PerpController` consumes an externally configured planner result and then asks the SR/JR Perp
contracts to move reserves. The planner cannot choose the final recipient, which remains fixed by
Controller, and it cannot be changed by an unprivileged caller. A malformed result could still
previously introduce an unknown tranche, select an invalid Bond, overstate a deposit result, pollute
the reserve list, trigger an unsafe external token/manager call, or permanently block rollover.

The hardening protects against planner bugs, malformed configuration and unexpected output. It does
not protect against a compromised owner that deliberately replaces the Guard or Controller. That
separate governance risk requires multisig, timelock, upgrade delay and monitoring.

## PerpToken asset-boundary checks

`PerpToken` now verifies canonical tranche identity before registration, incoming reserve handling,
recovery and positive reserve outflow:

- tranche `manager()` must equal immutable `bondsManager`;
- `bondID` must be nonzero;
- `bondsManager.tranches(bondID)` must return two distinct deployed token contracts;
- the token must be exactly the recorded senior or junior tranche;
- `isSenior()` and `data()` identity fields must agree with the Manager pair;
- a positive reserve outflow must refer to an already registered tranche;
- target-observed canonical zero-value transfers remain allowed;
- nonempty rollover deposits must use immutable `bondsManager`;
- deposit return tokens must equal the Manager pair;
- reported tranche amounts must equal actual balance increases;
- actual underlying spent must equal the requested deposit amount.

Any failure reverts the complete top-level transaction, including earlier token transfers, Manager
state changes and reserve registration.

## External planning Guard

`RolloverPlanGuard` is a stateless wrapper with immutable canonical Planner and BondsManager
addresses. The local Genesis deployment configures Controller to call the Guard instead of calling
`PerpBalancer` directly. It exposes both planning selectors used by Controller:

- `computeSystemRebalancePlan`;
- `computePerpSrRolloverPlan`.

The Guard checks:

- reserve and plan array limits;
- underlying and tranche outflows against actual input reserves;
- duplicate or zero token identities;
- stale tranche manager, side, maturity and balance;
- fresh Bond/tranche pairing and exact senior mint arithmetic;
- total rollover deposits against JR free plus unlocked liquidity;
- `underlyingValRolled` against total stale value;
- the Manager argument against the immutable canonical Manager.

The Guard intentionally has no setter and uses no `delegatecall`. An upgrade deploys a new Guard and
requires an explicit Controller governance action.

## Regression coverage

New regressions cover:

- duplicate stale tokens;
- stale reserve overdraw;
- incorrect fresh senior amount;
- deposit above JR free plus unlocked liquidity;
- system-rebalance underlying overdraw;
- noncanonical Manager;
- unregistered positive tranche outflow;
- foreign tranche registration/recovery;
- Manager deposit amount misreporting and atomic rollback;
- canonical Planner output passing exactly;
- canonical zero-deposit and zero-transfer behavior remaining available.

Legacy Phase 1B mocks were upgraded from arbitrary addresses to canonical Manager/Bond/SR/JR pairs.
No production validation was weakened to make old mocks pass.

## Verification

- Full Foundry suite: **254 passed, 0 failed**.
- Guard-focused suite: **7 passed, 0 failed**.
- PerpToken reserve/deposit suites: **15 passed, 0 failed**.
- Controller Phase 1B suite: **41 passed, 0 failed**.
- Stateful invariants: **6 passed**, 64 runs × 2,048 calls per invariant.
- Secret-free local Genesis deployment: success, including canonical Planner + Guard deployment.
- `PerpController`: **22,475 runtime bytes**, unchanged and below the 22,500-byte project limit.
- `PerpToken`: **11,424 runtime bytes**.
- `RolloverPlanGuard`: **4,752 runtime bytes**.
- Controller, Underlying Vault and USD Vault storage-layout checks: pass.
- Underlying Vault frozen ABI check: pass.
- `forge fmt --check` and `git diff --check`: pass after final formatting.

## Remaining governance work

- require a production multisig and timelock for `updatePerpBalancer`;
- add deployment monitoring for Guard, Planner and Controller-address changes;
- define a delayed Guard replacement/runbook;
- independently audit the Guard invariants and gas cost before real-fund deployment.
