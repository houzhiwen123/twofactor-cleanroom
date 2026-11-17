# Release-candidate hardening Phase 3

Status: **LOCAL-CLEANROOM PASS; Router production hardening applied**

Baseline entering the phase: `7ea56112b8a1ff91f62600badcde9aadbdb11188`.

## Scope and classification

This phase tests and changes only the repository's clean-room Router contracts and local mocks.
It is a defensive, generic callback-hardening measure, **not TARGET-CONFIRMED 2Factor behavior**.
No wallet, private key, signature, public RPC, target storage edit, `deal`, `store`, deployment to a
public chain, or broadcast transaction was used.

The previous full-stack campaign deliberately identified reentrant and arbitrary caller-supplied
Router dependencies as an open threat-model gap. This phase closes the reentrant-callback portion
only. It does not change the target-compatibility decision to accept the existing caller-supplied
dependency shapes, nor does it change the established successful-route refund semantics.

## Fix

`PairRouter`, `SingleAssetRouter`, and `UnderlyingSingleAssetRouter` now inherit OpenZeppelin
`ReentrancyGuard`. Every user entry point that can transfer/hold user assets and call an external
dependency is guarded:

| Router | Guarded entry points |
|---|---|
| `PairRouter` | `deposit`, `redeem`, `fallback` |
| `SingleAssetRouter` | `depositUsd`, `redeemUsd` |
| `UnderlyingSingleAssetRouter` | `depositUnderlying`, `redeemUnderlying` |

This is a direct-contract guard: the Routers have no proxy storage layout to preserve. The
Controller and Vault storage layouts, and the frozen Underlying Vault ABI, are unchanged.

## Local callback regression matrix

`test/RouterReentrancyHardening.t.sol` uses deliberately malicious local dependencies. Each nested
call tries to enter a second public Router route while the outer route is holding user assets. The
expected custom error is OpenZeppelin `ReentrancyGuardReentrantCall()`; because it bubbles through
the outer call, the EVM rolls back all transfers and approvals from that attempt.

| Outer route | Malicious dependency callback | Expected / observed result | Atomicity checked |
|---|---|---|---|
| `PairRouter.deposit` | Strategy calls `PairRouter.redeem` | `ReentrancyGuardReentrantCall()` | user underlying, Router balance, Strategy balance |
| `SingleAssetRouter.depositUsd` | Strategy calls `SingleAssetRouter.redeemUsd` | `ReentrancyGuardReentrantCall()` | user USD, Router balance, Strategy balance |
| `UnderlyingSingleAssetRouter.depositUnderlying` | Vault calls `UnderlyingSingleAssetRouter.redeemUnderlying` | `ReentrancyGuardReentrantCall()` | user underlying, Router balance, Vault balance |

All three regressions passed. A nested call cannot reach the existing balance-settlement/refund
logic, and no input is stranded or transferred to the malicious local dependency.

## Release gates

- focused callback suite: `3 passed, 0 failed`;
- full offline suite: `301 passed, 0 failed`;
- runtime sizes: PairRouter `7,194`, SingleAssetRouter `5,837`, UnderlyingSingleAssetRouter
  `4,045`, and PerpController `22,497` bytes (under its `22,500`-byte policy ceiling);
- Controller, Underlying Vault and USD Vault frozen storage-layout gates passed;
- frozen Underlying Vault ABI: `83` entries, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`;
- `forge fmt --check` and `git diff --check` passed;
- high-severity `forge lint` reported no production `src/` finding. Its output contains existing
  unchecked-transfer warnings in test mocks/harnesses and an OpenZeppelin unreachable-code compiler
  warning caused by the revert-only adversarial regression path.

## Deliberately not claimed

- This is not evidence that target 2Factor has the same reentrancy guard, dependency validation,
  or revert selector.
- This does not whitelist Strategy/Vault/Controller dependencies. Such a change would alter the
  externally observable Router interface and needs separate compatibility evidence and a product
  decision.
- It is not a proof against all malicious ERC-20, fee-on-transfer, hook, Oracle, or DEX behavior.
- A version-locked Base-fork deployment/interface rehearsal and independent professional audit
  remain open release requirements.

