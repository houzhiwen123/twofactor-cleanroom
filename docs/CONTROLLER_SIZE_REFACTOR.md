# Controller size refactor candidate

This candidate continues from the frozen pre-split baseline at Git commit `10cba49`. It changes
code organization and compiler settings; it does not add protocol behavior.

## Result

| Contract | Frozen baseline | Candidate | Change |
|---|---:|---:|---:|
| PerpController | 23,981 bytes | 22,052 bytes | -1,929 bytes |
| PerpToken | 10,846 bytes | 9,735 bytes | -1,111 bytes |
| PerpBalancer | 8,652 bytes | 6,877 bytes | -1,775 bytes |
| BondsManager | 13,771 bytes | 12,949 bytes | -822 bytes |
| PerpMath | n/a | 2,767 bytes | new stateless module |

`PerpController` is 448 bytes below the project-specific 22,500-byte guard and 2,524 bytes below
the EIP-170 runtime limit. Its initcode is 25,168 bytes, 23,984 bytes below the EIP-3860 limit.

## Boundary

`PerpController` remains the only coordinator of permissions, durable state, protocol events, token
movement, mint/burn, reserve registration, settlement, rollover execution and timestamps.

`PerpMath` is deployed once by the Controller implementation constructor and stored as an immutable
implementation-code reference. It has no storage, ownership or asset-moving functions. It contains
only deterministic calculations for:

- reserve value and reserve-weighted VM;
- post-deposit and post-withdrawal reserve state;
- proportional reserve-basket redemption and valuation;
- the evidence-backed `valueCap` direction/no-crossing check.

Tranche `data()` reads remain in `PerpController`, so the extraction does not change the caller seen
by a tranche. The Controller does not use `delegatecall`; the proxy storage layout remains unchanged.

## Compiler configuration

- Solidity `0.8.24`, Cancun EVM;
- optimizer enabled with `optimizer_runs = 1`;
- `via_ir = true`;
- `storageLayout` is an explicit compiler output so the layout guard works after a clean build.

The lower optimizer run count is intentional: deployment/runtime size is the current constraint.
Gas changes are visible in the regression output and must be reconsidered before a production
deployment decision.

## Verification

- clean `forge build --sizes`: passed;
- `forge test --offline -vv`: **88 passed, 0 failed, 0 skipped** across 9 suites;
- `test/PerpMath.t.sol`: four independent arithmetic/boundary comparisons passed;
- `python3 script/check_runtime_sizes.py`: passed with a 22,500-byte Controller guard;
- `python3 script/check_controller_storage_layout.py`: frozen slots 0–17 matched;
- `forge fmt --check`: passed.

The existing Controller tests continue to cover return values, revert selectors, balances, supplies,
reserve arrays, events, call order and one-unit boundaries for the implemented behaviors. This is a
size-refactor candidate, not a mainnet-readiness claim; the P0/P1 work in
`CODE_REVIEW_RECOMMENDATIONS_ZH.md` remains applicable where not explicitly closed.
