# Executable local DEX / Inventory lifecycle

## Classification

This phase is **LOCAL-CLEANROOM**. The topology follows the target-confirmed natural rebalance traces
in `USD_VAULT_PHASE5A_REAL_REBALANCE.md`, but the pool liquidity, working capital and Controller used
by the focused lifecycle test are local mocks. Results must not be labeled target-pool compatibility.

No RPC, wallet, private key, signature or broadcast is used by this lifecycle.

## Implemented local topology

```text
MockUsdInventory
  |-- UniswapV3DexStrategy.trade
  |     |-- MockUniswapV3Pool.swap
  |     `-- uniswapV3SwapCallback (exact input payment)
  |-- UsdVault.swap (authorized Inventory only)
  |     `-- Controller flashMint2 / flashRedeem2
  `-- returns settlement surplus to UsdVault
```

The pool starts execution-disabled. `DeployGenesisLocal` explicitly seeds both assets and enables it.
Its exact-input swap math matches the Strategy quote math for the current active liquidity, transfers
the output before callback, verifies exact input receipt and commits the next square-root price only
after callback success.

## Executed lifecycle

`testGenesisInventoryDexControllerAndUserExitLifecycle` runs:

1. owner activates USD Vault Genesis with `10,001` USD units;
2. a user deposits `1,000,000e6` USD and receives notes;
3. Inventory spends `100,000e6` USD through the real local Strategy/pool;
4. Inventory supplies the acquired underlying to authorized `UsdVault.swap`;
5. Vault calls Controller `flashMint2`, receives Perp SR, pays the provisional USD and commits the
   mint-direction session;
6. in the next session the system direction flips;
7. Vault burns the Perp through `flashRedeem2`, Inventory sells the returned underlying through the
   Strategy/pool and the redeem-direction session commits;
8. Inventory finishes both directions with its starting working USD and zero underlying residue;
9. the user burns all user-owned notes and exits while the fixed Genesis notes remain locked.

For the fixed pool state, the mint trade consumes `100,000,000,000` USD units and receives
`124,683,273` underlying units. Selling those units back after the price transition returns
`99,900,087,826` USD units; the `99,912,174`-unit difference is the local pool's fee/round-trip
price impact, not missing accounting.

## Atomic rollback

The failure regression first completes the mint direction, then disables the pool immediately before
the redeem-direction DEX leg. The Vault swap and Controller burn/withdraw execute earlier in the same
top-level call, but the later `ExecutionDisabled()` revert restores:

- Vault USD, underlying and Perp balances;
- Controller underlying reserve and Perp supply;
- Inventory USD and underlying balances;
- pool balances and square-root price;
- session active flag, direction, budget and opened-at timestamp.

This proves local transaction atomicity across the complete Inventory -> Vault -> Controller -> DEX
graph, including a failure after the Vault leg.

## Boundary kept explicit

The permissionless direct `UsdVault.rebalance()` fallback is not used to claim this lifecycle. Target
evidence confirms that entry and its delay guard, while natural successful transactions use the
authorized Inventory architecture. Exact production slippage construction for a fee-bearing direct
pool remains a separate compatibility question; this phase does not alter it to make a local test pass.

## Verification

```sh
forge test --match-path test/UsdVaultLocalDexLifecycle.t.sol -vv
forge script script/DeployGenesisLocal.s.sol:DeployGenesisLocal -vv
```

- Executable local DEX lifecycle: **3 passed, 0 failed**.
- Genesis + lifecycle focused suites: **8 passed, 0 failed**.
- Operational deployment suite: **2 passed, 0 failed**.
- Full local suite: **239 passed, 0 failed, 0 skipped**.
- Secret-free deployment script: success, `38,237,339` gas; local DEX execution logged `true`.
- Controller, USD Vault and Underlying Vault storage guards: passed.
- Underlying Vault frozen ABI: passed (`83` entries).
- Runtime guards: passed; Controller `22,475`, UsdVault `16,865`, Strategy `4,530` bytes.
- JSON validation, `forge fmt --check` and `git diff --check`: passed.
