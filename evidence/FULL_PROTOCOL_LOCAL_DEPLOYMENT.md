# Full protocol local deployment and lifecycle

## Classification and version

This report is **LOCAL-CLEANROOM/BNB-DESIGN** evidence only. It does not describe target 2Factor
deployment behavior. The baseline entering this phase was commit `d64a471`.

No production Solidity business rule was changed. The phase extends the existing local deployment
script's returned deployment graph, expands the generated manifest, and adds integration coverage.

## One-command deployment result

Reproduction:

```sh
python3 -m keeper.local_anvil --repo-root . --output-dir .keeper/full-protocol
```

Observed result:

| Check | Result |
|---|---|
| Chain boundary | ephemeral Anvil, chain ID `31337`, literal loopback only |
| Secret boundary | no private-key input; Anvil mnemonic output suppressed |
| Manifest | schema v2, mode `0600` |
| Component identities | `24/24` runtime codehashes and byte lengths recorded |
| Proxy identities | `7/7` implementation addresses, codehashes, and byte lengths recorded |
| Wiring groups | `bondSystem`, `controller`, `vaults`, `routing` |
| Keeper attestations | Controller, Junior Vault, Senior Vault, USD Vault |
| Dry run | selected `controller_rebalance` |
| Confirmed maintenance | rebalance, issue upkeep, stale upkeep, rollover |
| Post-rebalance rescan | Controller idle; no duplicate submission |
| Read-RPC fault | one bounded failover to the live loopback endpoint |

The generated record is `.keeper/full-protocol/deployment.json`. It is intentionally ignored because
its block/RPC identity belongs to the terminated ephemeral process; the manifest generator and its
schema assertions are committed and reproducible.

## Full deployed-stack lifecycle

Reproduction:

```sh
forge test --offline --match-path test/FullProtocolDeploymentLifecycle.t.sol -vv
```

`testOneCommandDeploymentManifestWiringAndFullLifecycle` passed and exercised:

1. the actual `DeployGenesisLocal.run()` deployment entry point;
2. ownership, Controller/Perp/Planner/Vault/Strategy dependency wiring;
3. Junior Vault paired-inventory rebalance;
4. PairRouter deposit with zero residual Router balances;
5. three additional weekly Bond issues at `82,000`, `79,000`, and `84,000` price points;
6. balanced tranche minting into the Controller;
7. public rollover, reducing SR and JR reserve rows from four to three;
8. PairRouter redemption, exact user note burn, positive USD/underlying settlement, and zero Router
   dust;
9. exact total-supply accounting for underlying, USD, Perp SR, Perp JR, USD notes, and JR notes at
   every lifecycle checkpoint.

The initial attempted ordering deposited into the Junior Vault before establishing its paired
inventory ratio and correctly reverted with `SlippageTooHigh()`. The final drill rebalances first;
no slippage guard or production rule was relaxed.

## Regression and release gates

| Gate | Result |
|---|---|
| Full Foundry suite | `291 passed, 0 failed, 0 skipped` |
| Local Anvil manifest unit tests | `4 passed` |
| Opt-in local Anvil integration | `1 passed` |
| Controller runtime | `22,497` bytes, under the `22,500`-byte project ceiling |
| Controller storage | frozen layout matched |
| Underlying Vault storage | frozen prefix/append layout matched |
| USD Vault storage | frozen slots `0-7` preserved |
| Underlying Vault ABI | `83` entries, frozen hash matched |

Formatting and diff checks are part of the final commit gate. This phase does not authorize public
deployment or imply readiness for real funds.
