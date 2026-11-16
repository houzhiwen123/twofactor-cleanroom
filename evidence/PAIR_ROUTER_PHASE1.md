# PairRouter Phase 1 — two-sided deposit entry point

## Scope and evidence boundary

This phase adds only the two-sided deposit path that is supported by the locked historical
transaction evidence. It does not claim that redeem, zero-genesis, or every unsupported-pair
branch has been reconstructed. The work uses public Base calldata/receipts, existing local fork
probe records, and clean-room mocks. No target source or frontend bundle was read; no wallet,
private key, signature, `deal`, `store`, or broadcast transaction was used.

Evidence labels:

- **TARGET-CONFIRMED** — observed in the fixed historical transaction and existing fork probe.
- **LOCAL-CLEANROOM** — independently implemented and tested against local mocks.
- **UNKNOWN** — not established and intentionally not guessed.

## Version lock

| Field | Value |
|---|---|
| Chain | Base (`8453`) |
| Historical transaction | `0x9332e8818524e3e791f77877df8e1bfca3017483af3aaeaf017ca12c641456f7` |
| Block / transaction index | `52,951,098` / `93` |
| Target router | `0x97c521D21468022E205d8A57b2fcaeE33d6714d6` |
| Target selector | `0x0176cb45` |
| Target USD Vault | `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3` |
| Target JR Vault | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Target Strategy | `0xE0fC0566ADCD6b83149874619A1FAFdF3345144f` |
| Target Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |

The public selector database did not provide a signature for `0x0176cb45`; therefore the clean-room
router preserves the selector in a compatibility fallback while exposing a typed local interface.
The exact Solidity function name and parameter types remain **UNKNOWN**.

## Target-confirmed observations

The calldata contains four addresses, eleven `uint256` values and one boolean. The observed logical
inputs are:

```text
usdVault, underlyingVault, strategy, recipient,
underlyingIn, minUsdFromTrade, underlyingToTrade,
srUnderlyingIn, jrUnderlyingIn,
minUsdNotes, minUnderlyingNotes,
minSubDr, maxSubDr, minVmDr, maxVmDr,
healthCheck
```

The historical vector used `underlyingIn=60,000`, traded `6` units, flash-minted `13,194` SR and
`46,799` JR underlying units, and supplied broad minimum/maximum bounds. The call returned six
words in this order:

```text
usdNotes, jrNotes, underlyingRefund, usdRefund, srRefund, jrRefund
```

Observed values were:

| Output | Value |
|---|---:|
| USD notes | `10,672,407,599,351,449,815` |
| JR notes | `474,271,839,185,754` |
| underlying refund | `1` |
| USD refund | `388` |
| SR refund | `0` |
| JR refund | `0` |

The existing `evidence/probe-tests/PairRouterTargetProbe.t.sol` records the following target
boundaries: exact minimum outputs succeed; minimum output plus one reverts atomically; DR bounds
are inclusive; a bound shifted by one wei reverts atomically; `recipient=0` means the caller;
an explicit recipient receives notes and refunds; `healthCheck=false` bypasses the health call;
and a health-call failure propagates. These records are target-fork evidence, not local mock
results.

## Local clean-room implementation

`src/router/PairRouter.sol` implements only the proven deposit flow:

1. Pull the caller's underlying amount and snapshot all four router token balances before the pull.
2. Optionally check `strategy.isHealthy()` and trade `underlyingToTrade` for USD.
3. Flash-mint SR/JR from the controller for the two requested underlying amounts.
4. Deposit USD + SR into the USD Vault and JR into the underlying/JR Vault.
5. Enforce minimum note outputs and inclusive post-operation `subDR`/`vmDR` bounds.
6. Transfer notes and every positive token delta to the recipient, leaving no router dust.
7. Revert the whole transaction on any failed check, so inputs, notes, vault balances and refunds
   roll back together.

The typed entry point is local API convenience. Calls using the locked target selector are handled
by the fallback and ABI-decoded using the observed static layout. The implementation deliberately
does not add a redeem route, an admin role, a persistent session, or a new storage layout.

## Regression coverage

`test/PairRouter.t.sol` is a local-clean-room suite with recording mocks. It covers:

- six-word selector return and zero router dust;
- inclusive minimum output and DR-bound success;
- minimum-output plus one atomic rollback;
- `healthCheck=false` bypass and target health selector propagation; and
- invalid allocation rollback.

Run:

```sh
forge test --match-path test/PairRouter.t.sol -vv
```

The local suite passes **6/6**. The target probe remains separately reproducible only with an
archive-capable Base endpoint; the public endpoint used during this turn did not complete the
fork replay. That is an execution-environment limitation, not a new compatibility claim.

## Explicit unknowns and next probe

- exact target Solidity signature behind `0x0176cb45`;
- target call order inside the router (public trace filters did not expose it);
- target redeem path and its return tuple;
- zero-supply/zero-reserve behavior;
- unsupported vault/strategy/token combinations;
- exact fee and session accounting outside the observed deposit vector.

The next PairRouter phase should first obtain one additional natural target deposit vector with a
nonzero minimum output and a partial strategy fill, then implement/compare redeem. No production
behavior should be inferred from the local mocks alone.
