# USD Vault phase 3: session capacity

## Scope and corrected boundary

This phase implements the target-observed `sessionCapacity()` state machine and its public raw-state/config views. It does **not** implement `rebalance()`, DEX execution, oracle health checks, keeper/admin/pause or production initialization.

The target probes falsified the original assumption that session capacity limits `deposit()`. The target accepts positive deposits:

- below `minOpUsdVal`;
- while the active session direction conflicts with the current rebalance direction; and
- whose lower-bound USD value exceeds the inactive-session preview budget.

Two strict historical deposit replays also leave the stored session direction, budget and timestamp unchanged. Therefore Phase 3 deliberately adds **no deposit minimum, direction or budget guard**. The `OpUnavailable("min size")`, `OpUnavailable("direction")` and `NoOp()` evidence remains specific to the separately deferred `rebalance()` path.

No target source or frontend bundle was read. Evidence uses public Base state, two natural historical transactions, local fork calls and one locally deployed proxy pointing at the public target implementation. No target balance/storage was changed with `deal` or `store`, and no transaction was signed or broadcast.

Baseline commit: `e55ab491fe5f1dafa321612337b478d964e32433`.

## Version lock

- Chain: Base (`8453`).
- Vault proxy: `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`.
- Implementation: `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`.
- Implementation codehash: `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4`.
- Primary snapshot: block `53,526,143`, timestamp `1,793,841,633`.
- Controller: `0x682F3a053B0260daD4EbEee3924B1618B330A200`.

Target configuration at the primary snapshot:

| Getter | Value |
|---|---:|
| `rebalanceFreqSec()` | `28,800` |
| `rebalanceOffsetSec()` | `21,600` |
| `maxDeploymentVelocityPerc()` | `330000000000000000` |
| `targetDR()` | `1027500000000000000` |
| `minOpUsdVal()` | `50000000000000000000` |

## Target-confirmed state machine

The current window start is:

```text
windowOpenedAt = floor((timestamp - offset) / frequency) * frequency + offset
```

The session is active only when the stored `sessionOpenedAtSec` equals `windowOpenedAt`.

When active, `sessionCapacity()` returns the three stored fields unchanged. When inactive, it previews:

```text
sessionIsMintingPerp = controller.subDR > targetDR
sessionBudgetUsdVal  = floor(getTVL() * maxDeploymentVelocityPerc / 1e18)
sessionOpenedAtSec   = windowOpenedAt
```

The strict comparison was closed with a fresh local proxy pointing at the version-locked public implementation: `subDR == targetDR` returns `isMintingPerp = false`.

### Historical vectors

| Block | Active | Minting Perp | Budget | Opened at |
|---:|:---:|:---:|---:|---:|
| `53,526,143` | no | yes | `33024675527237586477021` | `1793829600` |
| `53,495,000` | yes | yes | `29251188032403425541687` | `1793772000` |

At block `53,505,726`, timestamp `1,793,800,799`, the stored session is active one second before expiry. A synthetic-time call at exact expiry `1,793,800,800` returns inactive and previews the new window. Equality therefore belongs to the new, inactive window.

## Deposit evidence

### Natural historical replay

Both transactions were replayed from exact transaction prestate with their original natural balances and calldata:

| Block / index | Transaction | Observation |
|---|---|---|
| `53,236,495 / 132` | `0x31dca6ff3b7fdec83add824930a85f0bb713dd7659633303a7b135f4ef2f5254` | Deposit succeeds; stored session fields unchanged |
| `52,951,098 / 93` | `0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7` | Deposit succeeds; stored session fields unchanged |

The second receipt deposits about ten USD of value while the configured `minOpUsdVal` is fifty USD, independently corroborating that the minimum is not a deposit guard.

### Focused synthetic-fork discrimination

These calls use only the Vault's natural balances. The test impersonates the Vault solely to approve its own existing tokens; it does not mint assets or modify target storage.

| Case | Target inputs/quote | Result |
|---|---|---|
| Below minimum | `usdMax=1`; accepted `(usd=1, perp=2655861)`; notes `26317272012924662`; value upper bound `53623010404983847` | succeeds; `< 50e18` |
| Above inactive preview budget | full natural balances; notes `99400116760033059318061`; deposit-value lower bound `100025592670752701457999` versus budget `33024675527237586477021` | succeeds |
| Active direction conflict | stored direction `false`, current required direction `true`; accepted `(usd=1, perp=2559)`; notes `993981473715` | succeeds |

Because no target deposit capacity boundary exists, “budget exactly” and “budget + 1” deposit reverts are **N/A**, not missing tests. Those boundaries belong to future rebalance evidence.

## Local clean-room implementation

- Phase 1/2 storage slots `0`–`3` remain unchanged.
- Phase 3 appends packed session state/config in slots `4` and `5`.
- `sessionCapacity()` matches active reuse, inactive preview, strict direction comparison and exact time equality behavior.
- Target snapshot defaults are initialized by the explicitly local scaffolding initializer.
- The production contract exposes no external session mutator; the internal hook is reserved for the future evidence-backed rebalance phase.
- `deposit()` is unchanged because target probes show it neither checks nor consumes the session budget.

## Reproduction

Target fork probes:

```sh
FOUNDRY_TEST=evidence/probe-tests/UsdVaultPhase3SessionCapacityProbe.t.sol \
BASE_RPC_URL="$BASE_RPC_URL" forge test \
  --match-path evidence/probe-tests/UsdVaultPhase3SessionCapacityProbe.t.sol -vv
```

Local regression suite:

```sh
forge test --match-path test/UsdVaultSessionCapacity.t.sol -vv
```

Machine-readable values are in `evidence/usd-vault-phase3-session-capacity.json`.
