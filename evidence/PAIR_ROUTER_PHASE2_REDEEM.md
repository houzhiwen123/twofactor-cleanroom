# PairRouter Phase 2 — natural redeem replay and clean-room differential

## Scope and evidence boundary

This phase reconstructs the PairRouter redeem path from one natural successful Base transaction,
bounded public-log discovery, transaction-index prestate replay, and local clean-room differential
tests. It does not claim that every vault pairing, successful `upkeep()` state, or partial DEX fill
has been reconstructed.

No target source or frontend bundle was read. No wallet, private key, signature, `deal`, `store`,
or broadcast transaction was used.

Evidence labels:

- **TARGET-CONFIRMED** — observed on the target at a fixed historical prestate.
- **SYNTHETIC-FORK** — a target call made from natural balances with mutated calldata only.
- **LOCAL-CLEANROOM** — independently implemented in this repository.
- **TARGET-DIFFERENTIAL** — target and local implementations executed from the same historical
  prestate and compared without tolerance.
- **UNKNOWN** — not established and intentionally not guessed.

## Version lock and bounded discovery

| Field | Value |
|---|---|
| Chain | Base (`8453`) |
| Natural transaction | `0xcb92c779fd030f2524da58822354ddbc755818da877a0774baea1da70eaf6634` |
| Block / transaction index | `57,015,384` / `6` |
| Natural caller | `0x5d13C850F3E8eB925B8aB73155b8d8b610e16e5a` |
| Target Router | `0x97c521D21468022E205d8A57b2fcaeE33d6714d6` |
| Target selector | `0xb2a72016` |
| Router codehash | `0x487610478a620be27092ff42bf2dea6bfc08275af635abdc27245329f9801218` |
| EIP-1967 implementation slot | zero; the observed Router is direct, not an EIP-1967 proxy |
| USD Vault | `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3` |
| JR Vault | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Strategy | `0xE0fC0566ADCD6b83149874619A1FAFdF3345144f` |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |

`script/scan_pair_router_transfers.py` scanned only the bounded ranges
`52,900,000..58,230,811`. The earlier range produced deposits only. The later range produced one
additional deposit and the natural redeem above. This is a bounded evidence search, not a claim
that every historical Router transaction was enumerated.

## TARGET-CONFIRMED natural vector

The calldata is a static 15-word tuple. The independently reconstructed logical fields are:

```text
usdVault, underlyingVault, strategy,
usdNotes, underlyingNotes,
maxUsdRetained, underlyingToTrade, runUpkeep,
minUsdOut, minUnderlyingOut,
minSubDr, maxSubDr, minVmDr, maxVmDr,
healthCheck
```

Natural inputs and outputs:

| Item | Value |
|---|---:|
| USD notes redeemed | `3,115,505,797,682,734,554` |
| JR notes redeemed | `173,340,040,757,196` |
| `maxUsdRetained` | `uint256.max` |
| cbBTC explicitly sold | `19,771` |
| `runUpkeep` | `false` |
| minimum USDC out | `14,164,003` |
| minimum cbBTC out | `0` |
| returned USDC | `14,245,807` |
| returned cbBTC | `0` |

The replayed asset path was:

1. Redeem USD Vault notes into `642,319` USDC and `246,764,098` Perp SR.
2. Redeem JR Vault notes into `0` cbBTC and `1,459,344,075` Perp JR.
3. Call Controller `flashRedeem2(246,764,098, 1,459,344,075, 0)` and receive `19,771` cbBTC.
4. Sell exactly `19,771` cbBTC through the selected Strategy for `13,603,488` USDC.
5. Return `642,319 + 13,603,488 = 14,245,807` USDC to the natural caller.
6. Leave no USD notes, JR notes, USDC, cbBTC, Perp SR, or Perp JR on the Router.

State deviations changed as follows:

| State | pre | post |
|---|---:|---:|
| `subDR` | `1,049,023,021,577,290,954` | `1,049,008,142,808,840,695` |
| `vmDR` | `1,001,075,227,187,767,314` | `1,001,085,976,679,671,604` |

## TARGET-CONFIRMED and SYNTHETIC-FORK boundaries

- `underlyingToTrade=19,770` succeeds and returns `14,245,119` USDC plus `1` cbBTC.
- `underlyingToTrade=19,771` succeeds with the natural output.
- `underlyingToTrade=19,772` reverts `InvalidParamDefn()` (`0xd126d255`).
- `minUsdOut=14,245,807` succeeds; `14,245,808` reverts `SlippageTooHigh()`
  (`0x850c6f76`).
- `minUnderlyingOut=1` reverts `SlippageTooHigh()` in the natural all-USDC vector.
- Exact post-operation DR minimum and maximum bounds are inclusive. Moving any bound one wei
  outside the result reverts `SlippageTooHigh()`.
- `runUpkeep=true` calls USD Vault `upkeep()` first. In this fixed state, that dependency reverts
  `NoOp()` (`0x00219cf1`) before notes move.
- A non-boolean value in the `runUpkeep` word fails ABI decoding with empty revert data.
- When `underlyingToTrade` is nonzero, that explicit cbBTC-to-USDC trade takes priority and
  `maxUsdRetained` does not cause a second opposite-direction trade.
- When `underlyingToTrade=0` and USD Vault redemption produces more USDC than
  `maxUsdRetained`, the Router sells exactly the excess USDC for cbBTC. Natural-balance one-sided
  probes returned:

| USD-only setting | USDC out | cbBTC out |
|---|---:|---:|
| cap `0` | `0` | `4,556` |
| cap `1` | `1` | `4,556` |
| cap `uint256.max` | `642,319` | `3,624` |

The one-sided and mutated-boundary calls are **SYNTHETIC-FORK** because calldata was changed, but
the caller's target balances and target storage were natural and were not manufactured.

## LOCAL-CLEANROOM implementation

`src/router/PairRouter.sol` now exposes a typed `redeem(RedeemParams)` and preserves target
selector `0xb2a72016` through its compatibility fallback. The implementation:

1. checks the selected vaults share a Controller;
2. performs the optional health check and optional USD Vault upkeep before moving notes;
3. redeems both note types;
4. flash-redeems resulting SR/JR through the Controller;
5. executes either the explicit cbBTC sale or the excess-USDC sale, never both;
6. enforces inclusive minimum-output and post-DR bounds;
7. sends both final assets to the caller and leaves no Router dust; and
8. relies on transaction atomicity so dependency failures restore notes, assets and supplies.

`test/PairRouter.t.sol` covers the selector return layout, both trade directions, explicit-trade
priority, exact and plus-one output boundaries, inclusive DR bounds, health/upkeep ordering,
atomic rollback, and zero Router dust.

## TARGET-DIFFERENTIAL result

`testCleanRoomRouterMatchesNaturalTargetReplayExactly` creates two independent forks at the
natural transaction prestate. One calls the target Router; the other deploys the clean-room
Router, grants it only the natural caller's existing note approvals, and submits identical
calldata.

The following matched exactly with no tolerance:

- two-word return data;
- caller USDC and cbBTC deltas;
- caller USD/JR note burns;
- both note total supplies;
- post-operation `subDR` and `vmDR`; and
- zero balances for all six relevant assets on the clean-room Router.

This proves compatibility for the locked natural vector and the separately asserted boundaries;
it does not prove every possible dependency combination.

## Reproduction

Local clean-room regression:

```sh
forge test --match-path test/PairRouter.t.sol -vv
```

Target fork and exact differential (requires an archive-capable public Base endpoint):

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL="$BASE_RPC_URL" \
  forge test --offline --threads 1 \
  --match-path evidence/probe-tests/PairRouterRedeemTargetProbe.t.sol -vv
```

## Verification snapshot

- target probe and same-prestate differential: **8/8 passed**;
- focused local PairRouter regression: **14/14 passed**;
- full local repository regression: **278/278 passed** across 31 suites;
- PairRouter runtime: **6,372 bytes**;
- PerpController unchanged at **22,497 bytes**, within the project `22,500`-byte guard;
- frozen Controller, UnderlyingPerpVault and USD Vault storage-layout checks: passed; and
- `forge fmt --check`, `git diff --check` and JSON validation: passed.

## Remaining UNKNOWNs

- the target's original Solidity function name/signature behind selector `0xb2a72016`;
- the successful `runUpkeep=true` state transition and its output accounting;
- partial-fill Strategy behavior on the PairRouter redeem path;
- all target validation rules for mismatched/noncanonical vault, Strategy and token sets;
- target behavior for every zero-note combination; and
- compatibility outside the locked Router codehash.

