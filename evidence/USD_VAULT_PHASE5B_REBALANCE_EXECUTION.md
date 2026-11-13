# USD Vault phase 5B: atomic rebalance execution

## Scope and evidence boundary

This phase implements the clean-room USD Senior Vault execution layer on top of the phase-4
capacity/session state machine. The baseline is commit
`34f97f1ab1bf340b83f240c98cca5fa450415f70`.

The implementation uses only the target observations frozen in
`evidence/USD_VAULT_PHASE5A_REAL_REBALANCE.md` and local clean-room safety tests. It does **not**
move the external inventory/DEX settlement batch into the Vault. That batch remains a separate
component in the target traces.

Evidence classes used below:

- **TARGET-CONFIRMED:** directly observed in the locked Base fork vectors.
- **LOCAL-CLEANROOM:** implemented locally and tested, without claiming target equivalence beyond
  the cited observations.
- **UNKNOWN:** not implemented as target behavior because the available traces do not settle it.

## Implemented boundary

```text
authorized inventory
        |
        +-- swap(tokenIn, tokenOut, tokenInAmt, tokenOutAmt)
        |       |
        |       +-- Oracle/reference/state validation
        |       +-- Controller flashMint2 / flashRedeem2
        |       +-- provisional asset return to inventory
        |       +-- session debit + Rebalance event + cache reset
        |
permissionless caller
        |
        +-- rebalance()
                |
                +-- DEX health + Oracle/reference/state validation
                +-- inclusive active-delay gate
                +-- maxFillable + trade
                +-- Controller flashMint2 / flashRedeem2
                +-- session debit + Rebalance event + cache reset
```

`upkeep()` is permissionless and revalidates the same DEX/oracle/state boundary. The target evidence
only observes a business-level `NoOp()` result and does not prove that upkeep internally performs an
external settlement. The local implementation therefore ends in `NoOp()` after validation instead
of inventing a state-changing upkeep branch.

## Target-confirmed inventory vectors

The local tests reproduce the Vault/Controller leg of both natural transactions. External batch
settlement surplus is intentionally outside the local Vault leg.

| direction | input to Vault | Controller action | provisional output | event USD value | local result |
|---|---:|---:|---:|---:|---|
| mint Perp | `4,316,589` cbBTC | gross `332,778,700,917`, net `331,220,012,568` Perp SR | `3,390,111,185` USDC | `3,390,111,185e12` | exact balances, supply, fee retention, budget and event order |
| redeem Perp | `731,851,567` USDC | burn `73,659,360,073` Perp SR, gross `960,289` cbBTC | `955,487` cbBTC | `742,959,233,254,557,147,400` | exact balances, supply, retained `4,802` cbBTC, budget and event order |

The six phase-5A target fork tests were rerun against public Base state and passed `6/6`:

- both natural transaction replays;
- DEX quote/max-fill vectors;
- permissionless business guards and the `3,599/3,600/3,601` delay evidence;
- unauthorized `swap()`;
- Oracle, DEX and Controller dependency-failure rollback.

Three additional **SYNTHETIC FORK / TARGET-CONFIRMED** probes deploy the locked target implementation
behind a fresh local proxy and replace only its test dependencies. They establish exact inclusive
guard boundaries for both direct `rebalance()` and authorized `swap()`:

| guard | exact boundary | one unit beyond | target error |
|---|---:|---:|---|
| USD peg | `1e18 ± 5e15` succeeds | fails | `OpUnavailable("usd peg")` |
| DEX vs underlying Oracle | Oracle price `× (1 ± 5e16) / 1e18` succeeds | fails | `OpUnavailable("oracle divergence")` |
| flash mint total fee | `5e15` succeeds | `5e15 + 1` fails | `OpUnavailable("flash fee")` |
| flash redeem total fee | `5e15` succeeds | `5e15 + 1` fails | `OpUnavailable("flash fee")` |

These probes assert the target result; they do not read verified source and do not mutate a live
account or broadcast a transaction.

## Local execution tests

`test/UsdVaultRebalanceExecution.t.sol` contains eighteen local regressions:

1. exact natural mint Vault leg;
2. exact natural redeem Vault leg;
3. exact unauthorized `swap()` selector;
4. direct delay at `3,599` and `3,600` seconds;
5. direct delay at `3,601` seconds;
6. successful direct mint;
7. successful direct redeem;
8. permissionless balanced-state upkeep `NoOp`;
9. nonzero-capacity upkeep does not invent external settlement;
10. underlying-oracle cache failure rollback;
11. DEX trade failure after transfer rollback;
12. Controller state-query failure rollback;
13. Controller execution failure after DEX transfer rollback;
14. Oracle reset failure after execution/session commit rollback.
15. USD peg upper/lower exact and one-unit-outside boundaries;
16. underlying Oracle/reference upper/lower exact and one-unit-outside boundaries;
17. flash mint fee exact and one-unit-over boundaries with full rollback;
18. flash redeem fee exact and one-unit-over boundaries with full rollback.

All asset movement, Controller calls, session debit, event emission and cache reset occur in one EVM
transaction. A failure in any later step reverts earlier transfers, token supply changes and session
state.

## Compatibility table

| behavior | evidence | implementation status |
|---|---|---|
| `swap()` authorized inventory only; random caller gets `UnauthorizedCall()` | TARGET-CONFIRMED | exact selector and local regression |
| permissionless `rebalance()` / `upkeep()` before business guards | TARGET-CONFIRMED | implemented |
| direct gate rejects at `openedAt + 3,599`; passes at `+3,600` | TARGET-CONFIRMED, synthetic fork | implemented with inclusive boundary |
| mint/redeem inventory transfer and Controller order | TARGET-CONFIRMED, natural history | exact local Vault-leg regression |
| session debit equals emitted `rebalanceUsdVal` and commits last | TARGET-CONFIRMED | implemented |
| dependency marker errors bubble and all tested state rolls back | TARGET-CONFIRMED, synthetic fork | implemented and extended locally through reset failure |
| USD peg and underlying-reference deviation guards | TARGET-CONFIRMED, synthetic fork | exact inclusive boundaries and error reasons |
| mint/redeem flash-fee guards | TARGET-CONFIRMED, synthetic fork | exact inclusive `5e15` boundaries and atomic rollback |
| direct DEX mint/redeem success | no natural successful direct transaction in phase 5A | LOCAL-CLEANROOM, bounded by phase-5A DEX interfaces |
| DEX unhealthy local error text | exact target selector/text not isolated | LOCAL-CLEANROOM: `OpUnavailable("dex unhealthy")` |
| successful state-changing `upkeep()` branch | not observed | UNKNOWN; deliberately not guessed |
| external settlement surplus return | observed outside Vault | not implemented in Vault |
| target initializer/admin/pause surface | deferred to phase 6 | not implemented in phase 5B |

## Storage and size

- Frozen USD Vault slots `0`–`7` keep their existing order and offsets.
- Phase-5B dependencies append `_dexStrategy` in the unused tail of slot `7`, `_usdOracle` in slot
  `8`, and `_isSwapper` in slot `9`.
- Four `uint64` guard limits are packed into appended slot `10`; slots `0`–`9` retain their order
  and offsets.
- `PerpController` source and storage were not modified.
- Runtime sizes after phase 5B: `PerpController` **22,475 bytes** and `UsdVault` **15,763 bytes**.

## Verification

```sh
forge test --match-path test/UsdVaultRebalanceExecution.t.sol -vv
forge test
python3 script/check_controller_storage_layout.py
python3 script/check_usd_vault_storage_layout.py
python3 script/check_runtime_sizes.py
forge fmt --check
git diff --check
```

Results:

- phase-5B focused local suite: **18 passed, 0 failed**;
- full local suite: **169 passed, 0 failed** (the prior 151 remain green);
- phase-5A target fork suite: **6 passed, 0 failed**;
- phase-5B synthetic target boundary probes: **3 passed, 0 failed**;
- Controller frozen storage: unchanged;
- USD Vault frozen prefix: unchanged;
- formatting and whitespace checks: passed.
