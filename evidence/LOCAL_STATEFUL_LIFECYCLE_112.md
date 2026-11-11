# Local multi-epoch stateful lifecycle

## Scope

These tests use only this repository's contracts and local mocks. They use no RPC endpoint, wallet,
private key, signature or broadcast transaction. The starting point is local commit `ce068ef`.

Unlike the focused rollover unit tests, both sequences below connect the actual local
`BondIssuer`, `BondsManager`, SR/JR `PerpToken`, `PerpController`, `FeePolicy` and `PerpBalancer`.

## Reproduction

```sh
forge test --offline --match-test testGenesisStatefulFourEpochPriceRolloversAndSingleSideFlows -vv
forge test --offline --match-test testGenesisMultiEpochRolloversPreserveFullUserExit -vv
forge test --offline
python3 script/check_runtime_sizes.py
python3 script/check_controller_storage_layout.py
forge fmt --check
```

Results:

- Complete offline suite: 112 passed, 0 failed, 0 skipped.
- `PerpController`: 22,475 runtime bytes.
- Controller storage: matches the frozen 84/84 baseline.

## Mixed single-side and wide-price sequence

The sequence uses weekly prices `88,000 -> 72,000 -> 96,000 -> 76,000`, three successful balanced
Bond deposits of `12,000,000` underlying units, a JR-only underlying mint, an SR-only basket exit,
and two real Controller rollovers.

At the fourth epoch, the new Bond is issued and registered, but the attempted balanced mint is
required to revert with `OpDisabled()`. In that state, the operation would move the already-low
system deviation farther from one. The probe starts from and returns to a test snapshot. The
Manager deposit is a separate call: outside the snapshot probe, a rejected Controller mint would
leave the newly created tranche tokens with their owner rather than undo the prior deposit.

Observed rollover and final-state values:

| Observation | Value |
|---|---:|
| First stale SR before rollover | `3,996,063,059,837` |
| First stale SR after rollover | `0` |
| Second stale SR before rollover | `1,843,847,903,899` |
| Second stale SR after rollover | `0` |
| Final `subDR` | `789,667,517,408,072,953` |
| Final `vmDR` | `1,083,578,363,037,272,673` |

The underlying token balance is checked after Genesis, each user-flow stage and each rollover. The
sum held by the Manager, both Perps, Controller, Seeder, test deployer and receiver equals the mock
underlying total supply at every checkpoint.

## Moderate-price sequence and full user exit

The second sequence uses weekly prices `82,000 -> 79,000 -> 84,000 -> 80,000`, four balanced Bond
deposits of `10,000,000` underlying units, and two real Controller rollovers. Both stale SR tranche
balances become zero in the SR reserve.

After the second rollover, the receiver redeems every SR and JR Perp share it owns:

| Observation | Value |
|---|---:|
| Receiver SR shares exited | `5,288,462,592,080` |
| Receiver JR shares exited | `13,256,355,330,906` |
| SR total fee percentage | `745,215,475,077,769,955` |
| JR total fee percentage | `745,215,475,077,769,955` |
| Remaining `subDR` | `837,566,057,479,597,592` |
| Remaining `vmDR` | `1,060,773,474,369,273,237` |

The receiver's Perp balances become zero and the permanent locked shares remain unchanged. This is
technical exit availability, not acceptable production economics: the approximately 74.52% fee is
a material economic blocker that requires parameter/launch-capital analysis before audit or use of
real funds.

## Conclusion

The actual local modules can complete multi-Bond issuance and two consecutive rollovers without an
asset-accounting break. The same run also demonstrates that price path and one-sided flow history
can push the system into either an operation-disabled state or a technically open but prohibitively
expensive exit. Future stateful work must therefore test economic liveness thresholds in addition
to Solidity-level atomicity and conservation.
