# Release-candidate hardening Phase 2

Status: **LOCAL-CLEANROOM PASS; no production-contract change**

Baseline entering the phase: `f3f4d5ff73868b6a030e212b183981e49153586f`.

## Scope and classification

This phase exercises only this repository's clean-room contracts and local mocks. It is not target
2Factor evidence, a formal proof, an external audit, or approval to use real funds. No wallet,
private key, signature, public RPC, target storage edit, `deal`, or `store` was used.

The new stateful test deploys the exact local 24-component graph through
`DeployGenesisLocal.run()`. Only the handler is registered as a Foundry fuzz target, so Foundry
cannot bypass protocol entry points by calling the public mock surfaces directly.

## Full-stack state machine

`test/FullProtocolStatefulInvariant.t.sol` adds an 18-action handler spanning:

1. PairRouter deposit and redeem;
2. Senior and Junior single-underlying Router deposit and redeem;
3. direct USD Vault note deposit and redeem;
4. DEX execution/unlock changes, zero fills and bounded partial fills;
5. time and underlying-price changes;
6. weekly issue/upkeep, balanced Bond mint and rollover;
7. Senior/Junior Vault rebalance, USD Vault direct rebalance and state-changing upkeep;
8. bounded donations into Vault, Pool, Inventory and Perp reserve surfaces;
9. deliberately impossible PairRouter deposit and redeem minimums with before/after state
   fingerprints.

Expected operational failures are caught inside the handler so a reverted action does not discard
the rest of a generated sequence. The two forced-failure actions separately declare a defect if an
impossible minimum succeeds or if any tracked state changes across the revert.

## Enforced properties

Every generated sequence checks five properties:

1. underlying, USD, both Perps and all three Vault-note supplies equal the balances of all known
   holders in the deployed address graph;
2. the locked minimum liquidity of the USD, Junior and Senior Vaults remains present and total
   supply never falls below it;
3. PairRouter, USD SingleAssetRouter and UnderlyingSingleAssetRouter retain no user assets or
   notes;
4. both Perp reserve arrays remain unique, within the tranche cap, balance-synchronized and equal
   to the Controller's reported reserve values;
5. deliberately failed PairRouter operations remain atomic, including Pool price, Vault session,
   Controller fee and Perp reserve state.

## Results

Default campaign:

```sh
forge test --offline --match-contract FullProtocolStatefulInvariantTest -vv
```

- `5/5` properties passed;
- `64` runs and `2,048` handler calls per property;
- `10,240` aggregate generated calls.

Deep campaign:

```sh
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 \
  forge test --offline --match-contract FullProtocolStatefulInvariantTest -q
```

- `5/5` properties passed;
- `256` runs and `16,384` handler calls per property;
- `81,920` aggregate generated calls.

Repository regression and release gates:

- full offline suite: `298 passed`, `0 failed`, across `35` test contracts;
- `PerpController`: `22,497` runtime bytes under the `22,500`-byte repository ceiling;
- Controller, Underlying Vault and USD Vault frozen storage-layout checks passed;
- frozen Underlying Vault ABI passed: `83` entries, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`;
- `forge fmt --check` and `git diff --check` passed.

## Limits and remaining work

- The DEX, USD inventory, ERC-20s and Oracles in this campaign are local mocks. Passing this test
  does not establish compatibility with an arbitrary production dependency.
- Malicious caller-supplied Router dependencies and reentrant token/strategy callbacks still need
  a dedicated threat-model matrix.
- A version-locked Base-fork deployment/interface rehearsal remains outstanding.
- The Controller ceiling has only three bytes of repository-policy headroom. Any future production
  behavior must first extract code or change the measured module boundary; this test adds no
  production bytecode.

No limitation above is represented as closed.
