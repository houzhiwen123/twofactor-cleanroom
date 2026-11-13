# USD Vault phase 4: rebalance capacity planning

## Scope

This phase closes the target-observed **planning and session-accounting** part of USD Vault rebalance. It adds a clean-room `rebalanceCapacity()` implementation, internal validation of the observable `NoOp`/direction/minimum/capacity guards, and an internal session commit hook for a later atomic executor.

It deliberately does **not** add an external `rebalance()` entry point, token movement, Controller calls that change state, DEX execution, oracle health checks, keeper/admin/pause logic or production initialization. Those remain a separate phase because partial execution would create an unsafe public surface.

No target source or frontend bundle was read. Evidence comes from public Base state and bytecode, read-only local forks, natural historical transactions, and locally deployed proxies pointing at the public target implementation. No target balance or storage was changed with `deal`/`store`; no transaction was signed or broadcast.

Baseline commit: `c466a7cfa9c30e49d69b651d2cf4a06d6a024317`.

## Version lock

- Chain: Base (`8453`).
- Vault proxy: `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`.
- Implementation: `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`.
- Implementation codehash: `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4`.
- Controller: `0x682F3a053B0260daD4EbEee3924B1618B330A200`.
- DEX strategy: `0xE0fC0566ADCD6b83149874619A1FAFdF3345144f`.
- Primary snapshot: block `53,526,143`.

Target configuration:

| Field | Value |
|---|---:|
| target DR | `1027500000000000000` |
| equality range | `[1022000000000000000, 1033000000000000000]` |
| minimum operation USD value | `50000000000000000000` |
| session velocity | `330000000000000000` |
| frequency / offset / active delay | `28800 / 21600 / 3600` seconds |
| Controller target system ratio | `2847475019000000000` |

## Target-confirmed capacity formula

`rebalanceCapacity()` returns raw capacity before the session budget and minimum-size guards. The current direction is:

```text
isMintingPerp = currentSubDR > targetDR
```

The inclusive equality range is a no-rebalance deadband. If `lower <= currentSubDR <= upper`, raw capacity is zero.

Outside that range, with SR reserve value `S`, JR reserve value `J`, target system ratio `R` and target DR `D`:

```text
targetSrFloor = floor(J * 1e36 / (R * D))
targetSrCeil  = ceil (J * 1e36 / (R * D))

mint system capacity   = max(targetSrFloor - S, 0)
redeem system capacity = max(S - targetSrCeil, 0)
```

Mint capacity is the smaller of system capacity and the Vault's USD balance converted to underlying. Redeem capacity is the smaller of system capacity and the Vault's Perp-SR balance valued in underlying.

### Exact public-state vectors

| Block | Direction | Limiter | Exact capacity (underlying base units) | Current DR |
|---:|:---:|---|---:|---:|
| `53,526,143` | mint | Vault USD balance | `4,651` | `1052430305854682822` |
| `53,490,000` | mint | system correction | `3,422,518` | `1055663647561289239` |
| `53,480,533` | redeem | system/Vault Perp | `960,289` | `1019867585526484997` |
| `53,492,000` | no-op | inclusive deadband | `0` | `1026428101402202294` |

A fresh proxy using the public target implementation was configured with `lower == currentDR == upper`; capacity was exactly zero. Equality is therefore inside the deadband.

## Target-confirmed validation order and errors

| Snapshot | Observation |
|---:|---|
| `53,492,000` | raw capacity zero reverts `NoOp()` |
| `53,490,000` | active session direction differs from current direction and reverts `OpUnavailable("direction")` |
| `53,526,143` | executable value is below `50e18` and reverts `OpUnavailable("min size")` |
| fresh boundary proxy | a session budget that converts to zero underlying reverts `OpUnavailable("no capacity")` |

The clean-room planner follows that observed ordering. `OpUnavailable("capacity")` in the internal commit hook is a clean-room impossible-state assertion for `consumed > planned budget`; it is not claimed as an externally observed target branch.

## Session-budget boundary

The requested “budget + 1 must fail” hypothesis was falsified. Target behavior clips the raw underlying amount to what the remaining USD budget can fund:

```text
sessionUnderlyingCapacity = floor(sessionBudgetUsdVal * 1e8 / underlyingPrice)
executableUnderlying      = min(rawCapacity, sessionUnderlyingCapacity)
```

Using a fresh target proxy, local tokens and a marker DEX:

| Session budget | Raw capacity | Execution marker |
|---:|---:|---:|
| `9629772227653200` | `12` sat | reached DEX with `9,629` USD base units |
| `9629772227653199` | `12` sat | clipped to `11` sat; reached DEX with `8,827` USD base units |
| `0` | `12` sat | reverted `OpUnavailable("no capacity")` |

Thus the remaining budget is inclusive; one WAD wei less does not necessarily revert, but can remove one executable underlying unit because of integer conversion.

## Session state transitions

Natural historical state changes confirm that session fields are written only after successful execution:

| Path | Transaction / block | Pre budget | Actual rebalance USD value | Post budget | Direction / openedAt |
|---|---|---:|---:|---:|---|
| new redeem session | `0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e`, block `53,480,534`, index `64` | `33016915546003499111958` | `742959233254557147400` | `32273956312748941964558` | redeem / `1793743200` |
| same redeem session | blocks `53,481,733` → `53,481,734` | `32273956312748941964558` | `843614249058466123200` | `31430342063690475841358` | unchanged |
| new mint session | `0x4adb0572701aa84dabb661ad72d31617cf80a441f5696f69825b8a4ee5b80276`, block `53,491,335`, index `117` | `33016963790403425541687` | `3390111185000000000000` | `29626852605403425541687` | mint / `1793772000` |

For a new successful session, target state changes from the inactive preview to current direction/current window and then subtracts actual executed USD value. For an already active successful session, only the remaining budget decreases.

Phase 4 also corrects a Phase 3 interpretation: inactive `sessionCapacity()` preserves the **stored previous direction** while previewing a new budget and window. The current required direction comes from `rebalanceCapacity()` and is persisted only after successful execution.

## Local clean-room implementation

- Adds only view planning plus internal validation/commit hooks.
- Appends configuration storage in slots `6` and `7`; frozen slots `0`–`5` are unchanged.
- Uses exact target floor/ceiling behavior and the four public-state golden vectors.
- Caps the plan by the session budget before applying the minimum-size guard.
- Exposes no external state-changing rebalance function.

Evidence classes are intentionally separate:

- **TARGET-CONFIRMED:** formulas, exact capacities, inclusive deadband, observable errors, budget clipping, and historical session subtraction.
- **LOCAL-CLEANROOM:** `RebalancePlan`, `_validatedRebalancePlan()` and `_commitRebalanceSession()` scaffolding.
- **DEFERRED:** external atomic execution, DEX slippage/health behavior, Controller state changes, caller authorization, delay enforcement, admin/pause and production initialization.

## Reproduction

Target fork probes:

```sh
FOUNDRY_TEST=evidence/probe-tests/UsdVaultPhase4RebalanceCapacityProbe.t.sol \
BASE_RPC_URL="$BASE_RPC_URL" forge test \
  --match-path evidence/probe-tests/UsdVaultPhase4RebalanceCapacityProbe.t.sol -vv
```

Local regression suite:

```sh
forge test --match-path test/UsdVaultRebalanceCapacity.t.sol -vv
```

Machine-readable values are in `evidence/usd-vault-phase4-rebalance-capacity.json`.

## Verification

- Local suite: **151 passed, 0 failed**.
- Phase 4 target fork suite: **6 passed, 0 failed**.
- Phase 3/4 focused local suites: **20 passed, 0 failed**.
- Runtime: `PerpController` **22,475 bytes**; `UsdVault` **8,807 bytes**.
- Controller frozen storage layout: unchanged.
- USD Vault frozen slots `0`–`5`: unchanged; Phase 4 fields are appended in slots `6`–`7`.
- `forge fmt --check`, `git diff --check`, both evidence JSON validations and runtime guards: passed.
