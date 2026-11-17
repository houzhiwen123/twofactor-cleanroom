# Release-candidate hardening Phase 1

Status: **LOCAL-CLEANROOM PASS; no production-contract change**

Baseline entering the phase: `923fba5d14251c591efbc0948e1ca242c8847d81`.

## Scope and classification

This phase validates only this repository's clean-room deployment and local mocks. It is not target
2Factor evidence, a formal verification result, or approval to use real funds. No wallet, private
key, signature, public RPC broadcast, target storage edit, `deal`, or `store` was used.

The phase deliberately reuses the full `DeployGenesisLocal.run()` address graph. It does not replace
the production DEX, Oracle, or governance assumptions with a test-only shortcut.

## Deep stateful campaign

The existing 15-action operational handler was rerun with substantially higher bounds:

```sh
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 \
  forge test --offline --match-contract OperationalStatefulInvariantTest -vv
```

Each of the six invariants completed `256` runs and `16,384` handler calls. The campaign covered
deposits, redemptions, donations, price changes from `8,000` to `800,000`, weekly issue/upkeep,
balanced Bond minting, rollover, both Vault rebalance directions, pause/unpause, dynamic fees, and
deliberately impossible min-out operations.

All six properties passed:

1. underlying supply remained fully accounted;
2. both Perp supplies equalled tracked balances;
3. Vault supplies and locked minimum liquidity remained intact;
4. Router retained no user assets;
5. reserve arrays remained unique and agreed with Controller reserve values;
6. expected failures remained atomic.

## New full-stack regressions

`test/FullProtocolDeploymentLifecycle.t.sol` now adds two adversarial tests on the exact complete
deployment entry point.

### Downstream pause and Controller failure

After a real local PairRouter deposit, the test approves both note positions and then checks two
late failures:

- USD Vault redemption executes first, while the Junior Vault is paused and reverts with
  `EnforcedPause()`;
- both Vault redemptions execute before Controller flash redemption reverts with
  `UserOpsPaused()`.

In both cases a broad fingerprint remains byte-for-byte unchanged: token supplies, user and Router
balances, Vault balances, Pool balances, Controller fee accounting, and both Perp reserve arrays.
After both pause conditions are removed, the same notes redeem successfully and all asset
conservation checks pass.

### DEX outage and partial-fill recovery

With the executable local DEX disabled, PairRouter deposit reverts with the exact
`ExecutionDisabled()` selector and the full fingerprint remains unchanged. After execution is
restored, the Pool is capped to consume only half the requested trade input. The deposit succeeds,
the unfilled half is returned exactly to the user, both notes are positive, Router dust is zero,
and all six tracked token supplies remain conserved.

## Static and release gates

- High-severity `forge lint` produced no production `src/` finding. Its unchecked-transfer warnings
  were confined to test mocks/harnesses.
- Focused full-deployment suite: `3 passed, 0 failed`.
- Full Foundry suite: `293 passed, 0 failed, 0 skipped`.
- Deep invariant campaign: `6/6` properties passed, `16,384` calls per property.
- `PerpController`: `22,497` runtime bytes, under the repository's `22,500`-byte ceiling.
- Controller, Underlying Vault, and USD Vault storage-layout gates passed.
- Frozen Underlying Vault ABI passed: `83` entries, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`.
- `forge fmt --check` and `git diff --check` passed.

## Remaining release-candidate work

- The high-bound invariant still targets the core and Underlying Vault/Router system; a new
  stateful handler must add USD Vault, PairRouter, executable DEX partial fills, and upkeep.
- Reentrancy and arbitrary caller-supplied Router dependency assumptions need an explicit local
  threat-model matrix. The current deterministic tests establish atomic late failure, not a general
  proof for malicious dependencies.
- A Base-fork deployment/interface rehearsal with version-locked public token and Oracle contracts
  remains outstanding.
- Slither/Semgrep were not installed in the environment; `forge lint` is not a substitute for an
  independent static analyzer or professional audit.

No remaining item above is silently represented as closed.
