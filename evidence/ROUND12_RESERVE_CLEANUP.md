# Round 12 — Perp reserve cleanup and recovery

## Scope

These observations came from a local Base Anvil fork at block `54,990,962`, chain ID `8453`.
Only public ABI calls, local state construction, events, return data, and reserve snapshots were
used. No target source or frontend bundle was read, and no real transaction was broadcast.

Reproduce:

```sh
NO_PROXY=127.0.0.1,localhost \
no_proxy=127.0.0.1,localhost \
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL=http://127.0.0.1:8545 \
forge test --match-path evidence/probe-tests/Round12ReserveCleanupProbe.t.sol -vv
```

Result: **8 passed, 0 failed**.

## Target observations

| Question | Observation | Evidence level |
|---|---|---|
| Removing a fully transferred tranche | Transferring the full balance of the middle SR reserve entry reduced the array from 3 to 2 and moved the old last entry into the removed slot. This is swap-pop ordering, not stable-order deletion. | target fork, exact before/after arrays |
| Transferring a registered zero balance | `transferReservesTo` accepted amount `0`, performed the zero-value transfer, and removed the registered zero-balance tranche. | target fork |
| Paired input to `handleTransferReservesIn` | Sending one bond's SR tranche into JR, where JR already held the matching JR tranche, redeemed the pair. JR underlying increased by exactly `1,000`; both tranche balances became zero and both registrations were removed. | target fork |
| One-sided input to `handleTransferReservesIn` | Incoming nonzero SR was registered and retained. Its registered zero-balance JR counterpart was removed, so the array length stayed constant while the token identity changed. | target fork |
| `recover()` with no recoverable position | Controller call succeeded and returned ABI `bool(false)`. | target fork, exact returndata |
| `recover()` with a matured middle tranche | Controller call returned `bool(true)`, increased SR underlying by `41,875,890`, removed the recovered tranche, and preserved swap-pop ordering. | target fork, exact returndata and balances |
| Public `rollover()` reserve mutation | The observed stale rows disappeared, new deposits were registered, and both SR/JR arrays followed swap-pop effects. | target fork, exact before/after arrays |
| Mature `upkeep()` reserve mutation | Mature balances were converted to underlying. A zero-balance latest tranche remained because the Controller issued/re-registered it after recovery; this is not evidence that `recover()` retains zero rows. | target fork, exact before/after arrays plus call trace |

## Trace corroboration

The earlier Round 9 public-rollover trace independently shows:

- swap-pop storage writes in `evidence/round9_t1_rollover.log:1229-1250`;
- `handleTransferReservesIn` resolving the bond pair and calling the manager redemption path at
  `evidence/round9_t1_rollover.log:1252-1334`;
- Controller calls to the public Perp selectors for `recover`, `registerTranche`,
  `transferReservesTo`, and `handleTransferReservesIn`.

These traces corroborate call order only. Internal rules not distinguished by the fork vectors are
still treated as unknown.

## Implemented scope

`PerpToken` now implements the target-backed behavior above:

- 1-based registration indexes and exact swap-pop removal;
- zero-balance cleanup after transfer or recovery;
- paired recovery through `BondsManager.redeem`;
- `recover()` returning whether any tranche produced a recovery;
- safe zero contribution when a registered tranche has zero total supply.

Offline regressions are in `test/PerpTokenReserveCleanup.t.sol`. Invalid tranche identities,
manager failures, and every possible mixed-manager batch remain outside the verified target scope.
