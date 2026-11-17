# Local full-protocol deployment

## Scope

This is a **LOCAL-CLEANROOM/BNB-DESIGN** deployment workflow. It uses only this repository's
contracts, local mocks, and an ephemeral loopback Anvil. It does not deploy to Base, read a private
key, or claim that the local Genesis design matches the target protocol's private deployment
procedure.

## One-command deployment

From the repository root:

```sh
python3 -m keeper.local_anvil --repo-root . --output-dir .keeper/full-protocol
```

The command:

1. starts an ephemeral Anvil on a random `127.0.0.1` port with chain ID `31337`;
2. deploys and initializes the complete stack through `DeployGenesisLocal`;
3. writes a mode-`0600` schema-v2 manifest to `.keeper/full-protocol/deployment.json`;
4. performs deployment identity and Keeper preflight checks;
5. executes and confirms Controller rebalance, issue upkeep, stale upkeep, and rollover;
6. writes structured Keeper events/results and terminates Anvil.

Anvil auto-impersonates the fixed local admin `0x00000000000000000000000000000000000A11cE`.
No generated private key is accepted or persisted, and Anvil's mnemonic banner is suppressed.

## Deployment contents

The manifest records 24 component addresses and their runtime codehashes:

- underlying, USD token, and both price oracles;
- BondsManager, BondIssuer, first SR/JR tranches;
- Controller, FeePolicy, canonical PerpBalancer, RolloverPlanGuard, and GenesisSeeder;
- Perp SR and Perp JR;
- Junior, Senior, and USD Vaults;
- USD SingleAssetRouter, UnderlyingSingleAssetRouter, and PairRouter;
- executable local DEX pool, Strategy, and Inventory.

For the seven transparent proxies, the manifest additionally records implementation address,
implementation codehash, and implementation byte length. It also records the fixed block identity,
roles, four wiring groups, and Keeper attestations.

## Full lifecycle drill

The following regression invokes the same `DeployGenesisLocal.run()` entry point and then exercises
the deployed address graph:

```sh
forge test --offline --match-path test/FullProtocolDeploymentLifecycle.t.sol -vv
```

The sequence is:

```text
deploy + Genesis
  -> verify ownership and dependency wiring
  -> rebalance Junior Vault into its required paired inventory state
  -> PairRouter deposit
  -> issue and balanced-mint three additional price-varied Bond epochs
  -> Controller rollover and stale reserve cleanup
  -> PairRouter redeem
  -> burn user notes, check zero Router dust, and reconcile total supplies
```

The drill tracks underlying, USD, Perp SR, Perp JR, USD notes, and JR notes across every known holder.
At the deposit, post-rollover, and final-exit checkpoints, tracked balances must equal each token's
total supply exactly.

## Operator checklist

Before accepting a local deployment:

- confirm the command uses only a literal loopback RPC;
- confirm `deployment.json` has `schemaVersion: 2`, chain ID `31337`, and classification
  `LOCAL-CLEANROOM/BNB-DESIGN`;
- confirm all 24 identities contain non-empty runtime code and codehashes;
- confirm all seven proxies contain implementation identities;
- review the `bondSystem`, `controller`, `vaults`, and `routing` wiring groups;
- confirm `result.json` contains four confirmed maintenance tasks and no outstanding single-flight
  transaction;
- run the full lifecycle test and repository gates below.

Release gates:

```sh
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

Generated `.keeper/full-protocol/` files describe only the ephemeral chain that produced them. They
must not be reused as a production deployment record.
