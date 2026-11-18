# Controller Quote Engine Refactor

## Result

The redemption quote and state-simulation path was extracted from `PerpController` into the existing
immutable, stateless `PerpMath` contract.

| Contract | Baseline runtime | Final runtime | Change |
| --- | ---: | ---: | ---: |
| `PerpController` | 22,497 bytes | 21,061 bytes | -1,436 bytes |
| `PerpMath` | n/a for this baseline | 6,739 bytes | quote engine added |

The Controller now has 1,439 bytes of headroom under the repository's 22,500-byte soft limit and
3,515 bytes under the EIP-170 runtime limit of 24,576 bytes.

## Extracted behavior

`PerpMath` now owns the read-only calculation path for:

- DR construction and operation-fee quoting;
- flash-redemption gross/net values and simulated post-operation state;
- basket-redemption amounts, basket values, fees, and simulated post-operation state;
- proportional reserve-basket construction.

`PerpController` continues to own:

- pause, access, value-cap, and minimum-output checks;
- all durable state and fee accounting;
- token minting, burning, and transfers;
- reserve movement, rollover, rebalance, and external asset execution;
- protocol events and oracle-dependent state acquisition.

No asset custody or state mutation was moved into `PerpMath`.

## Compatibility boundaries

- The public `PerpController.computeDRs()` entry point remains `pure` and keeps its existing ABI.
- No Controller storage variable was added, removed, or reordered.
- The frozen Controller storage layout still matches all 84 expected entries.
- The extraction is a clean-room engineering refactor; it does not claim that the target 2Factor
  implementation uses the same internal module boundary.
- The current `FeePolicy` is caller-agnostic. Because fee quoting now originates from `PerpMath`, any
  future replacement FeePolicy must either remain caller-agnostic or explicitly authorize
  `PerpMath` as the quote caller.

## Verification

- PerpMath focused tests: 6/6 passed.
- Controller Phase 1B compatibility tests: 42/42 passed.
- Full local test suite: 306/306 passed across 37 suites.
- Controller runtime-size guard: passed at 21,061 bytes.
- Frozen Controller storage-layout check: passed, 84/84 entries.
- `forge fmt --check`: passed.
- `git diff --check`: passed.

The full suite covers Controller mint/redeem and flash paths, rollover, routers, vaults, genesis,
governance, real-integration fixtures, fuzz cases, and stateful invariants.

## Operational scope

This work used local compilation and tests only. It did not use a wallet or private key, sign or
broadcast a transaction, alter a public deployment, or push a remote Git branch.
