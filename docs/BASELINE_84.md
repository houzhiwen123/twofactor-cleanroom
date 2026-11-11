# Frozen 84/84 baseline

This document identifies the pre-split clean-room baseline. The Git commit containing this file is
the authoritative source snapshot. Do not compare later Controller refactors against an uncommitted
working tree.

## Verification

- `forge test --offline -vv`: **84 passed, 0 failed, 0 skipped** across 8 suites.
- `forge fmt --check`: passed.
- `python3 script/check_runtime_sizes.py`: passed.
- `python3 script/check_controller_storage_layout.py`: passed.
- `cd evidence && shasum -a 256 -c LOG_SHA256SUMS.txt`: all entries passed.

## Runtime sizes

| Contract | Runtime bytes |
|---|---:|
| PerpController | 23,981 |
| PerpToken | 10,846 |
| PerpBalancer | 8,652 |
| BondsManager | 13,771 |

The Controller refactor target is at most **22,500 bytes**. The existing 24,000-byte project guard
remains an absolute ceiling during intermediate steps.

## Frozen dependency revisions

| Dependency | Revision |
|---|---|
| forge-std | `77041d2ce690e692d6e03cc812b57d1ddaa4d505` |
| OpenZeppelin Contracts | `c64a1edb67b6e3f4a15cca8909c9482ad33a02b0` |
| OpenZeppelin Contracts Upgradeable | `e725abddf1e01cf05ace496e950fc8e243cc7cab` |

These revisions match both `foundry.lock` and the committed submodule links. The earlier local
archive worktrees were deliberately replaced before freezing the baseline because they did not
match the lock file and could not reproduce a fresh checkout.

## Frozen Controller storage layout

The machine-enforced layout is in `script/check_controller_storage_layout.py`. It fixes:

- top-level slots 0 through 17;
- the packed fields in slots 13 and 14;
- the two mappings at slots 15 and 16;
- the four-slot `_latestBondInfo` struct beginning at slot 17.

Refactoring may change code, interfaces and external planner contracts, but it must not reorder,
remove, repack or insert Controller storage ahead of the frozen layout.

## Refactor acceptance gate

Every extraction step must preserve:

1. the full offline regression result;
2. the frozen storage layout;
3. return values and revert selectors;
4. balances, supplies, reserve arrays and Bond state;
5. event contents and order;
6. one-unit rounding behavior;
7. evidence hashes and documentation consistency.

Any safety-only validation that changes a user-visible target result must be documented as an
intentional clean-room design difference rather than silently added during bytecode reduction.
