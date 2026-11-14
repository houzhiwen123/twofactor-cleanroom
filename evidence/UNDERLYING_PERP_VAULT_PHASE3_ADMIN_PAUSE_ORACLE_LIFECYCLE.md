# UnderlyingPerpVault Phase 3 — admin, pause, failure atomicity, and lifecycle

## Scope and evidence labels

This phase closes the administrative and pause state machines of the cbBTC/Perp SR and cbBTC/Perp
JR Vaults, then verifies failure atomicity and a complete two-Vault lifecycle in the independent
clean-room implementation.

Only public Base data, read-only calls, local Foundry forks, local mocks, and this repository's own
contracts were used. No verified source, frontend bundle, wallet, private key, signature, or
broadcast transaction was used.

- **TARGET-CONFIRMED** — observed in unmodified public-chain state or an exact historical
  transaction-prestate replay.
- **SYNTHETIC FORK** — observed after changing a target parameter or deploying a fresh proxy around
  the version-locked target implementation on a local fork, then discarding the fork.
- **LOCAL-CLEANROOM** — behavior of this repository's independent implementation.
- **UNKNOWN** — not established by the present evidence.

Primary evidence:

- `evidence/probe-tests/UnderlyingPerpVaultPhase3Probe.t.sol`
- `test/UnderlyingPerpVaultRebalance.t.sol`
- `test/UnderlyingPerpVaultRealIntegration.t.sol`
- `evidence/UNDERLYING_PERP_VAULT_PHASE2_REBALANCE.md`

The target-fork suites pass **32/32** tests in aggregate: Phase 1 **7/7**, Phase 2 **18/18**, and
Phase 3 **7/7**. The Phase 3 clean-room suites pass **19/19** focused state-machine tests and
**5/5** real-component integration tests. These counts do not turn local integration behavior into
target evidence; the classifications below remain branch-specific.

The complete local repository passes **206/206** tests. `PerpController` remains `22,475` runtime
bytes and `UnderlyingPerpVault` is `11,806` runtime bytes. The Controller, USD Vault, and
UnderlyingPerpVault frozen storage-layout checks pass. The complete UnderlyingPerpVault ABI is
frozen at **83 entries** with canonical SHA-256
`c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`.

## Version lock

**TARGET-CONFIRMED** at Base block `53,526,143`:

| Item | Value |
|---|---|
| chain ID | `8453` |
| Junior Vault proxy | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Senior Vault proxy | `0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB` |
| shared implementation | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` |
| implementation codehash | `0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645` |
| EIP-1967 implementation slot | `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |

The cooldown-precedence probe additionally replays the prestate of transaction
`0x07114c7e3baca7be676b961fe55548e688f830b0a6d99116cdc04c25b8c542ff`; the fee-precedence
probe replays the prestate of transaction
`0x2c23758afef541c51d2e290e533ab77f9396bf99e3cb9c632e7eec5f6fccd5c0`.

## Administrative state machine

The following are **SYNTHETIC FORK observations of the version-locked target implementation**.

| Operation or boundary | Observed behavior |
|---|---|
| `updateKeeper` caller | owner succeeds; configured keeper and unrelated address revert with `OwnableUnauthorizedAccount(address)` |
| zero keeper | accepted and stored |
| five parameter setters | owner-only; keeper and unrelated address get the same Ownable error |
| invalid target / timing / fee parameters | exact `InvalidParamDefn()`, `InvalidRange()`, or `InvalidPerc()` error; monitored state unchanged |
| ownership transfer | one-step and immediate; the old owner loses setter access and the new owner gains it in the same transaction |
| ownership transfer to zero | `OwnableInvalidOwner(address(0))`; monitored state unchanged |
| pause / unpause | keeper-only; after `updateKeeper`, the former keeper immediately loses unpause authority |

No `pendingOwner` step was observed. The clean-room Vault therefore retains immediate, one-step
ownership behavior for compatibility.

The failure fingerprint covers owner, keeper, pause flag, all Phase 2 parameters, Vault underlying
and Perp balances, note supply, and the rebalance timestamp. All probed administrative failures
preserved the fingerprint.

## Pause and error precedence

The following matrix is **SYNTHETIC FORK target evidence**.

| Vault state | Call | Exact result |
|---|---|---|
| initialized, paused | `initDeposit(0)` | `VaultInitialized()` |
| initialized, paused | `deposit(0,0)` | `EnforcedPause()` |
| initialized, paused | `redeem(0)` | `EnforcedPause()` |
| initialized, paused | `rebalance()` | `EnforcedPause()` |
| fresh/uninitialized, paused | `initDeposit(0)` | `EnforcedPause()` |
| fresh/uninitialized, paused | `deposit(0,0)` | `VaultNotInitialized()` |
| fresh/uninitialized, paused | `redeem(0)` | `EnforcedPause()` |
| fresh/uninitialized, paused | `rebalance()` | `EnforcedPause()` |
| paused | owner parameter setters | succeed without unpausing the Vault |

This proves that `initDeposit` checks “already initialized” before pause, while `deposit` checks
“not initialized” before pause. It does not justify replacing the other entry-point ordering with a
shared generic modifier.

For `rebalance()`, **SYNTHETIC FORK target evidence** establishes:

1. pause precedes `LastRebalanceTooRecent()`;
2. pause precedes zero-capacity `NoOp()`;
3. pause precedes `SlippageTooHigh()`;
4. after unpausing, the underlying error is returned unchanged;
5. an exact zero capacity returns `NoOp()`, while a positive amount below `minRebalanceVal`
   returns `OpUnavailable("no capacity")`.

Relevant selectors are:

| Error | Selector |
|---|---|
| `OwnableUnauthorizedAccount(address)` | `0x118cdaa7` |
| `OwnableInvalidOwner(address)` | `0x1e4fbdf7` |
| `UnauthorizedCall()` | `0x7bf6a16f` |
| `EnforcedPause()` | `0xd93c0665` |
| `VaultInitialized()` | `0x13056cf1` |
| `VaultNotInitialized()` | `0x9a09fd87` |
| `NoOp()` | `0x00219cf1` |
| `LastRebalanceTooRecent()` | `0xa3b3f090` |
| `OpUnavailable(string)` | `0xf0b62b3b` |
| `SlippageTooHigh()` | `0x850c6f76` |

## Clean-room compatibility changes

The Phase 3 production change is deliberately small and storage-neutral:

- `initDeposit` now tests `VaultInitialized()` before `_requireNotPaused()`;
- `deposit` now tests `VaultNotInitialized()` before `_requireNotPaused()`;
- `rebalance` returns `NoOp()` for an exact zero amount and reserves
  `OpUnavailable("no capacity")` for a positive amount below the configured minimum.

No Vault Oracle setter or independent Vault pricing source was added. Prices continue to flow
through the Controller interface.

## Controller and Oracle failure atomicity

These results are **LOCAL-CLEANROOM**, not target-fork claims.

The focused suite forces each Controller read used by the Vault to revert independently:

- `systemDeviations()`;
- `systemReserveState()`;
- `targetSystemRatio()`.

It also forces Controller flash execution to revert after the Vault has entered the rebalance path.
In every case, the original revert data bubbles out and the Vault balances, note supply, and
rebalance timestamp remain unchanged.

The real-component integration suite uses the repository's actual `PerpController`, `PerpToken`,
`FeePolicy`, `BondsManager`, `BondIssuer`, and `CachedOracle`. It verifies four Oracle failures:

- stale Chainlink answer: `InvalidPrice()`;
- zero answer: `ZeroPrice()`;
- negative answer: `InvalidPrice()`;
- reverting Oracle contract: the original `OracleCallFailure()` bubbles out.

The fingerprint additionally covers Controller underlying balance and SR/JR total supplies. All
four failures preserve the complete fingerprint. These tests demonstrate local failure atomicity;
the target's Oracle failure selectors and ordering remain **UNKNOWN**.

## Complete two-Vault lifecycle

`testBothVaultsCompletePriceRebalancePauseAndFullUserExitLifecycle` is **LOCAL-CLEANROOM**. It uses
the repository's real core components and independently deployed Senior and Junior
`UnderlyingPerpVault` instances to run:

```text
deploy core and both Vaults
  -> initialize both Vaults
  -> user deposits
  -> price increase
  -> SR and JR mint-direction rebalances
  -> price decrease
  -> SR and JR redeem-direction rebalances
  -> pause and resume both Vaults
  -> receiver partial exits
  -> receiver and owner exit all redeemable notes
  -> verify locked minimum liquidity and asset conservation
```

The test changes the local Oracle price and then explicitly adjusts each Vault's local `targetDR`
to select the desired mint or redeem branch. It proves the clean-room components can complete both
directions atomically; it does **not** prove that a price change alone selects that direction, and
it is not target-fork lifecycle evidence.

At the end, both user accounts hold zero notes. Each Vault's total supply equals
`MINIMUM_LIQUIDITY`, and that locked amount is held by the Vault itself. The test accounts for all
underlying minted by the fixture and confirms that the tracked system balance equals total supply.

The test mints `SR_REDEEM_LIQUIDITY_TOP_UP = 10 * VAULT_SEED` of **local mock underlying directly
to the local SR Perp reserve** before the redeem wave. This is an explicit local liquidity fixture:
it prevents the local Controller from attempting a redeem against a tranche-valued reserve with no
idle underlying. It is included in the conservation equation. It is **not target evidence**, not a
production seeding rule, and not proof that the target uses an equivalent top-up.

## Remaining UNKNOWN items

- Target Oracle stale/zero/negative/revert selectors and their precedence relative to Vault gates.
- A target-fork full lifecycle from a freshly deployed Controller, Bond system, both Perps, and both
  UnderlyingPerpVaults.
- Whether every successful administrative setter emits an event and the exact event ordering; the
  present probes lock state and revert behavior rather than claiming a complete event inventory.
- Any target-specific liquidity mechanism corresponding to the local SR idle-liquidity fixture.

These unknowns do not invalidate the tested clean-room safety properties, but they must not be
reported as target-compatible behavior without additional evidence.

## Reproduction

Target probes:

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-contract 'UnderlyingPerpVaultPhase(1|2|3)ProbeTest' --summary
```

Focused clean-room suites:

```sh
forge test --match-contract 'UnderlyingPerpVault(Rebalance|RealIntegration)Test' --summary
```

Release gates executed for this phase:

```sh
forge test --summary                                  # 206 passed, 0 failed
python3 script/check_runtime_sizes.py                 # Controller 22,475; Vault 11,806 bytes
python3 script/check_controller_storage_layout.py     # pass
python3 script/check_usd_vault_storage_layout.py      # pass
python3 script/check_underlying_perp_vault_storage_layout.py  # pass
python3 script/check_underlying_perp_vault_abi.py     # 83 entries, frozen hash matches
forge fmt --check                                     # pass
git diff --check                                      # pass
```
