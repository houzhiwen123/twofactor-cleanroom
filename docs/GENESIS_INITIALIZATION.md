# Genesis initialization (local clean-room design)

## Scope

This design applies only to the Solidity contracts in this repository. The deployment script uses
local mocks, a fixed local administrator (`0xA11CE`), no RPC URL, no wallet and no private key. It
must be run without `--broadcast`. The script now continues beyond core Genesis to deploy the two
UnderlyingPerpVaults, both Routers, a USD Vault dependency graph and the DEX Strategy.

The USD Vault first-notes rule is now closed by a fresh-proxy target fork probe. The local deployment
seeds it with `10,001` six-decimal USD units, mints `10,001e12` notes, locks `1e16` notes in the
Vault and assigns the remaining `1e12` notes to the initializer. The local Uniswap V3 mock also
supports explicitly enabled execution and is connected through a local-only Inventory settlement
harness. These are regression and deployment fixtures, not production-liquidity claims.

## State machine

1. Deploy and initialize `BondsManager`, `BondIssuer`, `FeePolicy` and `PerpController` proxies.
2. Deploy the SR/JR `PerpToken` contracts and connect them to the Controller.
3. Configure the underlying asset, oracle, issuer, fee policy and stateless planners.
4. `PerpController.init` starts with `userOpsPaused = true`; public mint/redeem calls therefore
   cannot establish the initial price.
5. Issue exactly one first Bond and deposit the administrator's seed underlying into it.
6. Transfer both resulting tranche legs plus a bounded JR-idle-underlying budget to a one-use
   `GenesisSeeder` and temporarily set that Seeder as Controller keeper.
7. In one transaction, the Seeder checks empty reserves and zero supplies, temporarily unpauses,
   performs a balanced two-sided `mint2`, computes the JR idle underlying needed to bring JR VM to
   the Controller target, performs a JR-only `flashMint2`, refunds unused underlying, pauses again,
   locks the minimum shares and transfers the remainder to the configured receiver.
8. The Controller owner restores the final keeper and the final keeper explicitly enables user
   operations.
9. Initialize the USD Vault with its Controller, Oracle, DEX Strategy and dedicated local Inventory,
   then call the owner-only one-use `initDeposit(10_001)` activation path.
10. Seed and enable the local DEX pool, fund the Inventory's working balance and leave all external
    settlement calls atomic across Inventory, Strategy, pool, USD Vault and Controller.

The seed transaction is atomic. If minting, slippage, `valueCap`, reserve validation or the final
pause fails, the Seeder's `used` flag, approvals, supplies, balances and pause state all roll back.

## Initial pricing

- Ordinary `flashMint2` cannot initialize a zero-supply side; it reverts `ZeroSupply()`.
- A tranche Genesis must initialize SR and JR together. A one-sided or partially initialized state
  reverts `ZeroSupply()`.
- Both sides must have zero supply and zero reserve value.
- The first gross Perp shares equal the corresponding input tranche units. `BondsManager` creates
  those tranche units from the Bond's opening price and tranche ratio, so Genesis does not accept a
  caller-selected share price.
- The first two-sided mint is fee-free. Later mints continue to use proportional reserve value and
  the normal dynamic fee policy.
- A first-Bond-only JR reserve has VM above the configured target and would make both sides hit the
  100% operation-fee ceiling. The Seeder therefore adds JR idle underlying using
  `ceil(jrReserveValue * (jrVm - targetVm) / (targetVm - 1e18))`. This changes reserve composition,
  not the fee curve. The caller supplies a maximum top-up; exceeding it reverts atomically.
- `computeJrUnderlyingTopUp` exposes that calculation as a pure audit surface. If dilution is
  required, a target at or below the underlying VM (`1e18`) is unreachable and rejected. If JR VM
  is already at or below the target, the required top-up is zero.

## Defensive limits

`GenesisSeeder` enforces:

- one successful use only;
- the configured deployer as caller;
- the Controller is paused and the Seeder is the current keeper;
- zero SR/JR supplies;
- no underlying balance, registered reserve balance or Genesis-tranche donation in either Perp;
- at least `1,000e8` initial shares on each side;
- a caller-defined maximum for the computed JR idle-underlying top-up, with unused underlying
  refunded to the Seeder deployer;
- `1e8` shares (one 8-decimal Perp token) permanently sent to
  `0x000000000000000000000000000000000000dEaD` on each side.

The locked shares ensure total supply cannot later return to zero through ordinary redemption. The
non-empty-reserve check rejects donation-based initial price manipulation instead of silently
pricing around donated assets.

## Initialization replay

The upgradeable Controller, BondsManager, BondIssuer and FeePolicy are initialized through proxy
constructors. A second initializer call reverts `InvalidInitialization()` and leaves configuration
unchanged. `PerpToken` is constructor-initialized and has no initializer to replay.

The target-observed USD Vault `initDeposit` is also one-use. Calls up to and including `10,000`
six-decimal USD units are successful no-ops while supply is zero. A call with `10,001` transfers the
USD, mints `1e16` permanently Vault-held notes plus `1e12` initializer notes, and emits the exact
five-event sequence fixed in `test/UsdVaultGenesis.t.sol`. A later call reverts `VaultInitialized()`
and leaves balances and supply unchanged. A non-owner reaches `OwnableUnauthorizedAccount(address)`.

## Local reproduction

```sh
forge script script/DeployGenesisLocal.s.sol:DeployGenesisLocal --offline -vvv
forge test --offline --match-path test/GenesisDeployment.t.sol -vv
forge test --offline --match-path test/OperationalDeployment.t.sol -vv
forge test --offline --match-path test/UsdVaultGenesis.t.sol -vv
forge test --offline --match-path test/UsdVaultLocalDexLifecycle.t.sol -vv
```

The script intentionally contains no `startBroadcast(privateKey)` call and no network endpoint. Do
not add `--broadcast` to the documented local simulation command.

The frozen local baseline logs are `evidence/local_genesis_baseline_105_tests.log`,
`evidence/local_genesis_baseline_105_sizes.log`,
`evidence/local_genesis_baseline_105_storage.log` and
`evidence/local_genesis_baseline_105_deploy.log`; their manifest is
`evidence/local_genesis_baseline_105_sha256.txt`.

## Verified regression properties

`test/GenesisDeployment.t.sol` covers:

- first Bond creation and balanced seed;
- initial share amounts and permanent minimum liquidity;
- default pause and public first-mint rejection;
- zero-supply flash-mint and one-sided tranche-mint rejection;
- pre-Genesis donation rejection;
- Seeder replay rejection;
- late-failure atomic rollback;
- initializer replay rejection;
- minimum seed rejection;
- locked Genesis shares remaining outside a normal user's control;
- direct 10% two-sided `redeem2` under the real local FeePolicy, including exact inputs, pre/post
  `subDR`, `vmDR` and both fee percentages;
- the top-up maximum at one-unit precision: `100,000,000` is insufficient and rolls back, while
  the computed `100,000,001` succeeds;
- unreachable and near-underlying JR VM targets, including ceiling rounding and atomic rollback;
- the maximum successful one-sided inputs for SR/JR basket and underlying redemption, including
  the next-unit failure selector;
- four weekly price/issuance epochs using the real local BondIssuer, BondsManager, Perp tokens,
  Controller and Balancer, including two complete rollovers and per-step underlying conservation;
- a mixed single-side path where a later balanced mint is atomically disabled after it would worsen
  an already-low `subDR`;
- a moderate-price path where all receiver-owned Perp shares can exit after two rollovers, while
  recording the economically severe exit fee rather than treating technical success as readiness;
- the full local sequence `initialize -> first Bond/deposit -> rebalance -> partial redeem -> all
  remaining user-owned shares redeemed`, while locked shares remain untouched.

`test/UsdVaultGenesis.t.sol` separately covers the target-observed USD first-notes threshold,
locked-note amount, transfer/event order, authorization, replay rollback, pre-deposit donation and
the first ordinary deposit/redeem. `test/UsdVaultLocalDexLifecycle.t.sol` covers executable
`quote -> trade -> callback` settlement, both Inventory rebalance directions, session commits,
user exit and a post-Vault DEX failure that rolls the entire cross-contract flow back.

The post-baseline local boundary run is recorded in `evidence/LOCAL_GENESIS_BOUNDARY_110.md`.
The multi-epoch lifecycle run is recorded in `evidence/LOCAL_STATEFUL_LIFECYCLE_112.md`.

The Genesis changes do not add or reorder Controller storage. The frozen Controller slots `0–17`
must continue to pass `script/check_controller_storage_layout.py`, and the Controller runtime must
remain below the repository's 22,500-byte guard.

## UNKNOWN / production decisions

- The economically optimal minimum seed and locked-share values for a production market.
- The production oracle, asset addresses, admin/keeper multisig and ownership-acceptance runbook.
- Whether a production deployment should wrap all setup calls in a dedicated deployment factory.
- Formal verification of all long-sequence donation, rounding and redemption economics.
- The economically appropriate capital budget for the JR idle-underlying top-up in markets with a
  different opening tranche VM or target VM.
- Whether production Genesis should also seed SR idle underlying. In the current tranche-first
  fixture, SR `flashRedeem2` cannot produce a positive underlying unit until SR has idle underlying;
  basket redemption remains available.
- Economic calibration of the fee curve after multi-epoch price moves. The local moderate path
  remains technically redeemable but charges about 74.52% on the final all-user-share basket exit.
- Independent security audit results.
- Production pool selection, liquidity calibration, Inventory financing and settlement incentives.

These items must not be filled with assumptions. This local deployment is a regression fixture and
design candidate, not a production-readiness claim.
