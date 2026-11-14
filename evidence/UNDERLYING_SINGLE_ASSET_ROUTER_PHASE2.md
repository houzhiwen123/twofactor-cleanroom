# Underlying Single-Asset Router Phase 2

Status: **TARGET-CONFIRMED shared Junior/Senior Router + LOCAL-CLEANROOM full-stack integration**

This phase closes the Phase-1 Senior uncertainty. The target does not need a separate Senior Router:
the same deployed Router at `0xbf0f2aa8784a1a459C7E2eB87CF25E5cABF4d296` accepts either target
UnderlyingPerpVault and selects the Controller side from `isPerpSrVault()`.

## Safety and provenance

- Public Base state and local Foundry forks only.
- No wallet, private key, signature, broadcast, target storage edit, `deal`, or `store`.
- No target verified source or frontend bundle was read.
- Senior vectors use the natural holder `0xf582fc610600836534f59e641c808ab1810866eb` at Base block
  `54,990,962`.
- Version locks for the shared Router and both Vaults remain those recorded in Phase 1 and
  `UNDERLYING_PERP_VAULT_PHASE4A_REAL_CONFIG.md`.

## Target-confirmed Senior vectors

At the fixed block the holder naturally owned `249,954,791,674,916,592` Senior notes and
`56,630,950` cbBTC units.

| Path | Input | Exact target result | Boundary |
|---|---:|---:|---|
| Senior deposit | `100,000` cbBTC, `maxIters=2` | spends `99,999`, refunds `1`, mints `486,011,106,243,695` notes | exact `minNotesOut` succeeds; `+1` reverts `SlippageTooHigh()` |
| Senior redeem | `1,000,000,000,000,000` notes | `102,637` direct cbBTC + `7,640,893,873` Perp SR converted to `103,113` cbBTC; total `205,750` cbBTC | exact `minUnderlyingOut` succeeds; `+1` reverts `SlippageTooHigh()` |

Both paths leave zero cbBTC and zero Perp SR dust in the target Router. The local Router matches
the target return values, user balance changes, spend/refund amounts and failure atomicity exactly.

The historical Senior redeem pre-state at block `51,777,358` cannot test this Router because the
Router had not yet been deployed. The fixed-block natural-balance vector avoids modifying balances
and makes that deployment-order limitation explicit.

## Local full-stack lifecycle

`test/UnderlyingRouterRealIntegration.t.sol` runs the independently written Router against newly
deployed real local components rather than Router mocks:

```text
deploy Bond/Issuer/Controller/Perps
        -> deploy SR and JR UnderlyingPerpVaults
        -> single-cbBTC Router deposits into both Vaults
        -> both Vaults rebalance through Controller
        -> issue three later Bond epochs
        -> Controller rollover
        -> Router redeems both note balances to cbBTC
```

The lifecycle verifies both side selections, zero Router dust and total underlying conservation.
A second test obtains the exact real-component Senior redemption output, restores the same snapshot,
then proves `minOut = exact + 1` reverts atomically without changing Vault, Controller, Perp, user or
Router balances and supplies.

The SR-side local fixture adds explicit cbBTC liquidity to the SR Perp before flash redemption. This
is test funding for the clean-room lifecycle, not a claim about a target transaction.

## Reproduction

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=<public-archive-rpc> \
  forge test --match-path evidence/probe-tests/UnderlyingSingleAssetRouterPhase1Probe.t.sol -vv

forge test --match-path test/UnderlyingRouterRealIntegration.t.sol -vv
```

## Verification

- Target fork probe: `9 passed, 0 failed`.
- Focused local Router suites: `6 passed, 0 failed`.
- Full offline suite: `217 passed, 0 failed`.
- Runtime sizes: Controller `22,475` bytes, UnderlyingPerpVault `11,806` bytes,
  UnderlyingSingleAssetRouter `3,994` bytes.
- Frozen Controller, UnderlyingPerpVault and UsdVault storage-layout checks passed.
- Frozen UnderlyingPerpVault ABI check passed: 83 entries, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`.
- `forge fmt --check`, JSON parsing and `git diff --check` passed.

## Evidence classification

- Shared target Router supporting both JR and SR: **TARGET-CONFIRMED**.
- Exact Senior deposit/redeem vectors above: **TARGET-CONFIRMED synthetic fork with natural balances**.
- New local multi-epoch Router lifecycle and explicit SR liquidity top-up: **LOCAL-CLEANROOM**.
- A natural historical Senior transaction sent through the Router remains **UNKNOWN**; it is no
  longer required to establish that the deployed Router accepts the Senior Vault.
