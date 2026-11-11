# Round 16 — exact valueCap equality and extreme VM

## Scope

The tests used public Base state at block `54,990,962` in a local Foundry fork. Reserve balances,
oracle returns and administrative parameters were changed only inside the disposable fork. No
target source or frontend bundle was read, and no real transaction was signed or broadcast.

Reproduce:

```sh
BASE_RPC_URL=https://mainnet.base.org FOUNDRY_TEST=evidence/round16-probes \
forge test --match-path evidence/round16-probes/Round16ExactBoundaryProbe.t.sol \
  --no-proxy --via-ir -vv

BASE_RPC_URL=https://mainnet.base.org FOUNDRY_TEST=evidence/round16-probes \
forge test --match-path evidence/round16-probes/Round16ExtremeVmProbe.t.sol \
  --no-proxy --via-ir -vv
```

Results: **2/2** exact-boundary tests and **4/4** extreme-VM tests passed.

## Exact `subDR == 1e18`

The fork reserves were constructed so a one-satoshi corrective mint landed exactly on the WAD
balance point, rather than skipping across it because of integer granularity.

| Direction | pre-`subDR` | post-`subDR` | Result above cap |
|---|---:|---:|---|
| SR mint, from above | `1000000001000000000` | `1000000000000000000` | allowed |
| JR mint, from below | `999999999648811668` | `1000000000000000000` | allowed |

Therefore the closed rule is: a single-sided over-cap mint may improve toward one and may land
exactly on one, but may not cross it. A pre-state already equal to one still rejects another
single-sided over-cap mint (Round 6).

## Extreme VM

- At a near-zero price, every observed Senior tranche consumed the whole claim, used
  `valueRatio=1e18`, and reported VM `1e18`.
- The corresponding Junior tranches had zero claim/value, `valueRatio=0`, and used the saturating
  VM sentinel `type(uint128).max`.
- At 10x and 100x spot, Senior tranche VM was `0`; Junior tranche VM was finite and above one.
- Perp-level VM stayed finite because zero-value tranche rows contribute zero weight and idle
  underlying contributes VM one.

The Junior zero-claim sentinel is now implemented in `BondsManager` and fixed by an offline
regression test. Summary output: `round16_exact_vm_results.log`.
