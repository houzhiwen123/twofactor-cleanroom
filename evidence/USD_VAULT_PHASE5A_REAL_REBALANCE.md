# USD Vault phase 5A: real rebalance execution evidence

## Scope

This phase freezes the target-observed execution behavior needed before a clean-room external
`rebalance()` implementation is written. It replays two natural Base transactions from their exact
transaction prestates and adds narrowly scoped target-implementation probes for caller authorization,
the active-delay boundary, DEX views, and dependency-failure atomicity.

No production contract was changed. No wallet, private key, signature or broadcast transaction was
used. Natural vectors use only public historical state and balances. The delay and failure probes are
explicitly marked **SYNTHETIC FORK** because they deploy a fresh proxy pointing at the public target
implementation and use local tokens/mocks; they are not represented as natural user history.

Baseline commit: `9ceeccc78891244dbc187d55a30cd58ae327ffa1`.

## Version lock

- Chain: Base (`8453`).
- Vault proxy: `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`.
- Vault implementation: `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF`.
- Implementation codehash: `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4`.
- Controller: `0x682F3a053B0260daD4EbEee3924B1618B330A200`.
- Perp SR: `0x4be28E7597A928835245a10E9161E0c44687b70b`.
- DEX strategy: `0xE0fC0566ADCD6b83149874619A1FAFdF3345144f`.
- USDC: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`.
- cbBTC: `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`.
- Authorized inventory/swapper: `0x7f3D9cA062371429666018E949FbCB39fa602e25`.
- Batch executor seen in the natural trace: `0x60Bf78233f48eC42eE3F101b9a05eC7878728006`.
- Vault owner and keeper at both prestates: `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d`.

## Architecture correction

The target path is not simply “Vault calls a DEX and then calls Controller.” The two natural traces
show an inventory/settlement architecture:

```text
external batch / settlement
        |
        v
authorized inventory contract -- tokenIn --> Vault.swap(...)
                                           |
                                           +--> Controller.flashMint2 / flashRedeem2
                                           |
                                           +--> tokenOut back to inventory
                                           |
                                           +--> Rebalance event + session debit
        |
        +--> Vault.upkeep() health/state checks in the same top-level flow
        |
        +--> external DEX settlement; execution surplus is returned to Vault
```

The DEX strategy exposes health, reference-price, quote, maximum-fill and direct-trade behavior.
`swap()` is a separate authorized inventory entry. Phase 5B must preserve both paths instead of
collapsing them into one synchronous AMM call.

## Natural redeem-Perp vector — TARGET-CONFIRMED

| Field | Value |
|---|---:|
| transaction | `0xf49ebfa4f7833f8dec9ed901eb4edaddfaeed352e84362c6c687d52f17c7568e` |
| block / transactionIndex | `53,480,534 / 64` |
| block timestamp | `1,793,750,415` |
| top-level from / to | `0x588ef3de14875ff9c4fc74c9e2c308767d665e30` / `0x9da8b48441583a2b93e2ef8213aad0ec0b392c69` |
| top-level selector | `0xe7c438c9` |
| direction | redeem Perp SR for cbBTC, sell cbBTC for USDC |

Exact Vault/Controller leg, in event order:

1. Inventory transfers `731,851,567` USDC to Vault.
2. Vault supplies `73,659,360,073` Perp SR to `flashRedeem2`; the same amount is burned.
3. Controller sources `960,289` cbBTC gross and transfers it to Vault.
4. Vault transfers `955,487` cbBTC to the authorized inventory contract.
5. Vault emits `Rebalance(1019867585526484997, 77368295716660000000000,
   742959233254557147400, false)`.
6. External settlement realizes `739,303,149` USDC; after repaying the inventory advance,
   `7,451,582` USDC is returned to Vault.

Exact Vault state deltas:

| Asset/state | Pre | Post | Delta |
|---|---:|---:|---:|
| USDC | `302,318,628` | `1,041,621,777` | `+739,303,149` |
| cbBTC | `38,782` | `43,584` | `+4,802` |
| Perp SR | `9,886,455,001,392` | `9,812,795,641,319` | `-73,659,360,073` |
| Perp SR total supply | `9,916,265,965,245` | `9,842,606,605,172` | `-73,659,360,073` |
| session budget | `33,016,915,546,003,499,111,958` | `32,273,956,312,748,941,964,558` | `-742,959,233,254,557,147,400` |

USDC and cbBTC total supplies are unchanged across the full transaction.

## Natural mint-Perp vector — TARGET-CONFIRMED

| Field | Value |
|---|---:|
| transaction | `0x4adb0572701aa84dabb661ad72d31617cf80a441f5696f69825b8a4ee5b80276` |
| block / transactionIndex | `53,491,335 / 117` |
| block timestamp | `1,793,772,017` |
| top-level from / to | `0xbee156a1f0c92a1c1da9b31595e4b88d163dcccc` / `0xbee162fa5ae892be74f3f3e01c23da89adbccccc` |
| top-level selector | `0x6d7b7040` |
| direction | buy cbBTC with USDC, mint Perp SR |

Exact Vault/Controller leg, in event order:

1. Inventory transfers `4,316,589` cbBTC to Vault.
2. Vault transfers the same `4,316,589` cbBTC into the Perp SR reserve.
3. Controller `flashMint2` mints `332,778,700,917` Perp SR gross.
4. Controller transfers `331,220,012,568` Perp SR net to Vault and retains
   `1,558,688,349` Perp SR as operation fee.
5. Vault transfers `3,390,111,185` USDC to inventory.
6. Vault emits `Rebalance(1063211455382090274, 77759215172770000000000,
   3390111185000000000000, true)`.
7. External settlement consumes `3,353,191,860` USDC and returns `36,919,325` USDC surplus to Vault.

Exact Vault state deltas:

| Asset/state | Pre | Post | Delta |
|---|---:|---:|---:|
| USDC | `3,728,960,649` | `375,768,789` | `-3,353,191,860` |
| cbBTC | `61,287` | `61,287` | `0` |
| Perp SR | `9,544,991,123,949` | `9,876,211,136,517` | `+331,220,012,568` |
| Perp SR total supply | `9,574,802,087,802` | `9,907,580,788,719` | `+332,778,700,917` |
| Controller Perp-SR balance | pre | post | `+1,558,688,349` |
| session budget | `33,016,963,790,403,425,541,687` | `29,626,852,605,403,425,541,687` | `-3,390,111,185,000,000,000,000` |

USDC and cbBTC total supplies are unchanged across the full transaction.

## DEX health, quote and maximum fill — TARGET-CONFIRMED

`isHealthy()` returned `true` at both exact transaction prestates.

| Direction / input | `quote` | `maxFillable` input | `maxFillable` output |
|---|---:|---:|---:|
| sell `955,487` cbBTC for USDC | `739,076,600` USDC | max sell `960,289` cbBTC, min buy `0` | sell `960,289`, buy `742,790,479` |
| sell `3,390,111,185` USDC for cbBTC | `4,362,680` cbBTC | max sell `3,390,111,185` USDC, min buy `0` | sell `3,390,111,185`, buy `4,362,680` |

The inventory leg can use worse provisional terms than `quote`, but the top-level settlement returns
surplus to Vault. Therefore Phase 5B must account by actual post-settlement balances/session debit,
not treat the provisional `swap()` transfer alone as the final economic execution.

## Caller authorization — TARGET-CONFIRMED

- `swap()` is restricted by `isSwapper`: inventory is `true`; random `0xBEEF` is `false` and reverts
  `UnauthorizedCall()` (`0x7bf6a16f`).
- At natural block `53,493,126`, random `0xBEEF` and owner both reach the same business guard in
  `rebalance()` and `upkeep()`: `NoOp()` (`0x00219cf1`). There is no owner/keeper authorization guard
  before the business-state check.
- The natural batch trace invokes `upkeep()` from the batch executor, which is neither owner/keeper
  nor an authorized swapper at the checked prestates.

This evidence supports permissionless `rebalance()` and `upkeep()`, while `swap()` remains explicitly
authorized.

## Active-delay boundary — SYNTHETIC FORK, TARGET IMPLEMENTATION

A fresh proxy pointing at the locked target implementation was initialized with local USD/oracle/DEX
mocks and the target Controller. Capacity remained nonzero so the delay branch was not masked by
`NoOp()`.

| Time relative to session window start | Result |
|---:|---|
| `activeRebalanceDelaySec - 1` (`3,599`) | `OpUnavailable("active delayed")` |
| exactly `activeRebalanceDelaySec` (`3,600`) | delay passed; execution continued to the deliberately constrained mock and reverted `SlippageTooHigh()` |
| `activeRebalanceDelaySec + 1` (`3,601`) | same post-delay `SlippageTooHigh()` |

The exact boundary is inclusive: automatic/direct `rebalance()` becomes eligible at `openedAt + 3600`.
The natural mint transaction occurring only 17 seconds after its window start succeeds through the
authorized external `swap()` path, confirming the delay is not a blanket ban on inventory execution.

## Failure atomicity — SYNTHETIC FORK, TARGET IMPLEMENTATION

At the post-delay execution point, forced failures in each dependency were tested separately:

1. underlying oracle `cachePrice()`;
2. DEX `trade()`;
3. Controller `systemReserveState()`.

Each marker error bubbled unchanged. After each revert, the following fingerprint was byte-for-byte
unchanged: Vault USD/cbBTC/Perp balances, mock DEX balances, Perp SR total supply, session active flag,
direction, remaining budget and opened-at timestamp. This confirms atomic rollback for the tested
dependency boundaries.

## Phase 5B implementation contract

The minimum clean-room implementation surface now supported by evidence is:

- permissionless `rebalance()` with `NoOp`, direction/capacity/minimum guards and the inclusive
  `activeRebalanceDelaySec` gate;
- authorized `swap(tokenIn, tokenOut, tokenInAmt, tokenOutAmt)` restricted by `isSwapper`;
- permissionless `upkeep()` that revalidates health/state;
- both mint and redeem Controller directions;
- DEX `isHealthy`, `referencePrice`, `quote`, `maxFillable` and `trade` integration;
- session budget debited by the exact `Rebalance.rebalanceUsdVal`, committed only after success;
- all token movement, Controller calls, event emission and session commit in one atomic transaction;
- exact slippage and health failures with no partial state or asset movement.

Phase 5B must not add general admin/governance/emergency recovery. Those remain Phase 6.

## Reproduction

```sh
FOUNDRY_TEST=evidence/probe-tests \
BASE_RPC_URL="$BASE_RPC_URL" forge test \
  --match-path evidence/probe-tests/UsdVaultPhase5ARealRebalanceProbe.t.sol \
  --jobs 1 -vv
```

Use `-vvvv` to regenerate full call traces. `--jobs 1` avoids archive-RPC pressure while rebuilding
transaction-index prestates.

Machine-readable values are in `evidence/usd-vault-phase5a-real-rebalance.json`.

## Verification

- Phase 5A target/synthetic fork suite: **6 passed, 0 failed**.
- Existing local suite: **151 passed, 0 failed**.
- Runtime sizes: `PerpController` **22,475 bytes**; `UsdVault` **8,807 bytes**.
- Controller frozen storage layout: unchanged.
- USD Vault frozen slots `0`–`5`: unchanged; Phase 4 fields remain in appended slots `6`–`7`.
- `forge fmt --check`, `git diff --check` and JSON validation: passed.
- Production Solidity changed: **no**.
- Natural vectors use `vm.createSelectFork(rpc, txHash)` plus `vm.transact(txHash)`; no `deal/store`.
- `deal` is used only to fund the locally deployed synthetic DEX and is labeled SYNTHETIC FORK.
