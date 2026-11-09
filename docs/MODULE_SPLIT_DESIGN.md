# Rollover/upkeep module split design

This is a future design only. No rollover or upkeep implementation is included.

## Goal

Keep `PerpController` under the EIP-170 runtime limit as rollover and upkeep planning are
eventually added. The current pre-split runtime baseline is Controller `20,384` bytes and
PerpToken `8,055` bytes (`evidence/phase1b_sizes.log`); regenerate these figures after each
implementation change.

## Preferred boundary

Keep authorization, pause checks, reentrancy protection, user-facing errors, and durable state
updates in `PerpController`. Move pure planning and bounded execution orchestration into a
separate `RolloverExecutor` contract called externally by the Controller (no `delegatecall`).
The executor should receive an explicit, immutable-per-call context containing the issuer,
BondsManager, Perps, underlying token, thresholds, candidate tranche IDs, and the operation
limits. It returns a structured plan/result; Controller validates the result, performs any
Controller-only Perp calls, emits Controller events, and records timestamps only after success.

The target Perps currently authorize one Controller address. Before moving stateful Perp calls
into an executor, a future evidence round must establish a safe authorization model. Options are:

1. Keep all Perp calls in Controller and let the executor only calculate/validate plans.
2. Add an explicitly authorized executor role to PerpToken, with separate permission tests and
   target evidence.
3. Have the executor call back into Controller for each privileged action, preserving Controller
   as the Perp caller but increasing interface and reentrancy complexity.

Option 1 is the default unless bytecode measurements prove it insufficient. Do not silently change
the Perp controller address or rely on delegatecall/library storage semantics.

## Atomicity and validation

- One external Controller transaction must remain atomic across issue, reserve movement, mint/burn,
  settlement, events, and timestamp updates.
- Separate read-only plan construction from execution results, but validate totals and token
  identities at the Controller boundary.
- Keep all unverified threshold, partial-completion, candidate-order, and rollback behavior pending
  until black-box probes establish it.
- Add recording mocks for executor call order and fork evidence for any target call order before
  marking behavior verified.
- Re-run `forge build --sizes`, `script/check_runtime_sizes.py`, and the full offline suite after a
  later implementation is proposed.

## Alternatives

An external Solidity library is not selected because ordinary external library calls may compile
to `DELEGATECALL`; the desired boundary is explicitly delegatecall-free. A staticcall-only planner
can be considered if it reduces code while leaving all state transitions in Controller.
