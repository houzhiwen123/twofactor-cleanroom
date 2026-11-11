# Local Genesis top-up and exit boundaries

## Scope

This evidence uses only the contracts and mocks in this repository. It uses no RPC endpoint,
wallet, private key, signature or broadcast transaction. The starting point is local baseline commit
`69019c9` (105 tests).

## Reproduction

```sh
forge test --offline --match-path test/GenesisDeployment.t.sol -vv
forge test --offline
forge build --offline --sizes
forge script script/DeployGenesisLocal.s.sol:DeployGenesisLocal --offline -vvv
python3 script/check_runtime_sizes.py
python3 script/check_controller_storage_layout.py
forge fmt --check
```

Results:

- Genesis suite: 17 passed, 0 failed.
- Complete offline suite: 110 passed, 0 failed, 0 skipped.
- Offline local deployment script: succeeded; user operations ended unpaused.
- `PerpController`: 22,475 runtime bytes.
- `GenesisSeeder`: 5,438 runtime bytes.
- Controller storage: matches the frozen 84/84 baseline.

## JR idle-underlying top-up

For the local first Bond and configured target JR VM:

| Case | Result |
|---|---:|
| Exact computed top-up | `100,000,001` underlying units |
| Maximum `100,000,000` | `InsufficientSeed()`; entire bootstrap rolls back |
| Maximum `100,000,001` | succeeds |
| Target VM exactly `1e18` while dilution is required | `InvalidParamDefn()`; entire bootstrap rolls back |
| Reserve `1`, JR VM `1e18 + 2`, target `1e18 + 1` | ceiling result `1` |
| Reserve `1e8`, JR VM `2e18`, target `1e18 + 1` | `99,999,999,999,999,999,900,000,000` |
| JR VM already below target | zero top-up |

The very large near-`1e18` result is expected from the denominator
`targetVm - 1e18`; it demonstrates why the caller-provided maximum is mandatory.

## Launch deviations and two-sided exit

Immediately after local Genesis:

- `subDR = 1,053,565,000,564,452,713`;
- `vmDR = 999,999,998,583,333,343`.

A direct 10% two-sided basket redemption succeeds with zero SR and JR fee in this fixture. Its
post-operation values are:

- `subDR = 1,053,563,050,303,984,771`;
- `vmDR = 999,999,994,694,449,627`.

## One-sided exit matrix

The search probes each amount from the same snapshot and fixes the next-unit error selector.

| Path | Receiver balance | Maximum successful input | Fee at boundary | Next-unit result |
|---|---:|---:|---:|---|
| SR basket `redeem2` | `3,999,900,000,000` | `3,929,294,079,999` | `999,999,004,051,073,382` | `OpDisabled()` (`0x07380a2e`) |
| JR basket `redeem2` | `11,999,900,080,000` | `11,999,900,080,000` | `33,576,125,417,389,864` | all receiver-owned shares are accepted |
| SR underlying `flashRedeem2` | `3,999,900,000,000` | `79,999` | `0` | ERC-20 insufficient balance (`0xe450d38c`) |
| JR underlying `flashRedeem2` | `11,999,900,080,000` | `4,429,248,799,999` | `999,999,969,473,694,182` | `OpDisabled()` (`0x07380a2e`) |

The SR underlying boundary is not a fee ceiling. The tranche-first fixture gives SR no idle
underlying, and inputs through `79,999` round to zero underlying output. At `80,000`, the quote
first becomes one underlying unit and settlement cannot source it from the SR idle reserve. SR
basket redemption remains available. This is a launch-liquidity design observation, not a claim
that `79,999` is a general protocol limit.
