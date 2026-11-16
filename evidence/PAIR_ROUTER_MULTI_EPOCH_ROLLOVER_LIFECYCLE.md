# PairRouter multi-epoch rollover lifecycle

## Scope and evidence label

This report is **LOCAL-CLEANROOM** evidence for the independently written contracts in this
repository. It is not a claim that this synthetic deployment, its prices, or its balances occurred
on the target 2Factor deployment. No production Solidity contract was changed in this phase.

The test deploys the real local Bond, BondsManager, BondIssuer, FeePolicy, PerpBalancer,
PerpController, SR/JR Perp tokens, USD Vault, JR Vault, Uniswap-style Strategy/pool and PairRouter.
It uses only Foundry mocks for the two external assets, price oracle and pool execution.

## Lifecycle

`test/PairRouterRealIntegration.t.sol` now executes the following path in one fresh deployment:

```text
core Genesis and first Bond at 80,000
  -> USD and JR Vault Genesis
  -> JR Vault rebalance into Perp JR
  -> PairRouter deposit creates USD and JR notes
  -> weekly Bond issue and balanced Controller mint at 82,000
  -> weekly Bond issue and balanced Controller mint at 79,000
  -> weekly Bond issue and balanced Controller mint at 84,000
  -> Controller rollover
  -> PairRouter redeem burns both user note positions
```

The three additional issues produce four live Bond epochs before rollover. Both SR and JR reserve
arrays contain four tranche rows before rollover and three afterward, establishing that rollover
changed the tracked system state rather than returning a successful no-op.

## Exact observed values

| Item | Local result |
|---|---:|
| USD notes minted by PairRouter | `8002142000000000000` |
| JR notes minted by PairRouter | `499129641481629` |
| SR reserve rows before / after rollover | `4 / 3` |
| JR reserve rows before / after rollover | `4 / 3` |
| Final USD output | `8002142` |
| Final underlying output | `45819` |

The test proves exact supply accounting for underlying, USD, Perp SR, Perp JR, USD notes and JR
notes after the PairRouter deposit, after each of the three issue/mint epochs, after rollover and
after final redemption. At every checkpoint, the sum of every known holder balance equals the
token's total supply. The Router has zero balance in all six user-facing assets after successful
operations.

## Atomic slippage boundary

The successful post-rollover redemption is first simulated from a snapshot to obtain exact output.
The same prestate is then restored:

- `minUnderlyingOut == 45819` succeeds and returns exactly `45819`;
- `minUnderlyingOut == 45820` reverts with `SlippageTooHigh()`;
- a full fingerprint of supplies, tracked balances, DRs, both reserve arrays, active Bonds, user
  notes and user settlement balances is identical before and after the failed call.

This is a local atomicity proof. It does not expand the previously recorded target PairRouter
slippage claims beyond their version-locked evidence.

## Reproduction and gates

```sh
forge test --match-test testMultiEpochRolloverPairLifecycleConservesAssetsAndIsAtomic -vv
forge test --offline
forge build --sizes
python3 script/check_runtime_sizes.py
python3 script/check_controller_storage_layout.py
python3 script/check_underlying_perp_vault_storage_layout.py
python3 script/check_usd_vault_storage_layout.py
python3 script/check_underlying_perp_vault_abi.py
forge fmt --check
git diff --check
```

Results:

- focused lifecycle: `1 passed, 0 failed`;
- full offline suite: `290 passed, 0 failed, 0 skipped`;
- PairRouter runtime: `7,129` bytes;
- Controller runtime: `22,497 / 22,500` bytes;
- Controller, USD Vault and Underlying Vault frozen storage checks: passed;
- Underlying Vault frozen ABI: passed (`83` entries);
- formatting and diff checks: passed.

## Result

The local PairRouter integration is no longer limited to a single-epoch deposit/redeem. It remains
redeemable after three price-varied issues, balanced tranche mints and an actual Controller
rollover, with exact asset conservation and an atomic one-unit failure boundary. This phase found
no production compatibility defect and therefore made no production-contract change.
