# Round 11 — Perp rollover deposits

## Scope

Black-box calls used a local Anvil fork of Base at block `54,990,962` (chain ID `8453`). The probe
used only the public ABI and simulated calls. It did not read target source or a frontend bundle,
and no real-chain transaction was broadcast.

Reproduction:

```sh
NO_PROXY=127.0.0.1,localhost \
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL=http://127.0.0.1:8545 \
forge test --match-path evidence/probe-tests/Round11PerpDepositProbe.t.sol -vv
```

Probe result: **4 passed, 0 failed**. The captured observations are in
`evidence/round11_perp_deposit_results.log`.

## Observations

1. `bondDepositsForRollover(address,(bytes32,uint256)[])` exists only on the JR behavior surface.
   The configured Controller succeeded. Owner and a random EOA reverted with
   `UnauthorizedCall()` (`0x7bf6a16f`). The SR call from the Controller failed with empty return
   data.
2. An empty deposit array succeeded and emitted exactly one `ReserveSynced`, for the underlying.
   Passing a different manager with an empty array also succeeded, so the entry point does not
   reject a manager address before iterating the array.
3. A zero-amount deposit still called the manager and emitted three synchronization events in this
   order: returned SR tranche, returned JR tranche, underlying. The zero-balance SR tranche was not
   added to the reserve array.
4. A positive `1000`-unit deposit consumed `1000` units of the existing maximum cbBTC allowance,
   minted `37,970,820` units of each returned tranche in the captured bond, registered the new SR
   tranche, and emitted SR, JR, underlying synchronization events in that order.
5. Two positive deposits in one call emitted five synchronization events: SR/JR after the first
   deposit, SR/JR after the second deposit, and underlying once after the loop.
6. The function returned no data. Approval was separately primed before positive deposits and was
   not reset by this function.

## Implementation boundary

The clean-room implementation may reproduce the observed Controller-only JR entry point, per-item
manager deposit, nonzero tranche registration, per-item SR/JR synchronization, and one final
underlying synchronization. It must not add a manager-equality check based only on the empty-array
observation.

Still unverified on the target: a positive call to a different manager, a manager returning only
one nonzero tranche, capacity overflow behavior, and revert-data propagation from a failing
manager. These remain explicit evidence gaps; offline tests cover only the reconstructed
implementation's atomicity.
