# Fixed-Block Base Fork Interface Rehearsal

## Classification

- **TARGET-CONFIRMED:** public code/address presence, dependency getters, Oracle configuration,
  Oracle price and DEX view results at the pinned Base snapshots below.
- **LOCAL-CLEANROOM:** deployments of `PairRouter`, `CachedOracle`, `UnderlyingPerpVault`,
  `UsdVault` and `UniswapV3DexStrategy` exist only inside Foundry's temporary local EVM fork.
  They do not create contracts or state on Base.

## Scope and safety boundary

This is an interface/configuration rehearsal, not a target economic-lifecycle replay. It uses
public Base RPC reads and a local test EVM only. The test contains no `broadcast`, target-owner
impersonation, `deal`, `store`, target token transfer, target swap, target upkeep, private key,
signature or wallet operation.

The full local Genesis deploy script is deliberately **not** run on the fork: it requires mock
assets and a synthetic seed. That would not prove compatibility with the public cbBTC/USDC
environment and is outside this evidence's scope.

## Pinned snapshots

| Purpose | Base block |
|---|---:|
| Controller, USD Vault, JR Vault, Oracle and zero-input Router rehearsal | `53,526,143` |
| DEX view/repricing rehearsal | `53,243,583` |

Public dependencies checked include Controller
`0x682F3a053B0260daD4EbEee3924B1618B330A200`, USD Vault
`0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`, JR Vault
`0xebEe489B84C1b3408838A87A691A4370aED139DB`, cbBTC,
USDC, Perp SR/JR, and the public USDC/cbBTC pool.

## Result

Command:

```bash
BASE_RPC_URL=https://mainnet.base.org FOUNDRY_TEST=evidence/probe-tests \
  /Users/mac/.foundry/bin/forge test --offline --threads 1 \
  --match-path evidence/probe-tests/BaseForkInterfaceRehearsal.t.sol -vv
```

Result: **4 passed, 0 failed, 0 skipped.**

| Test | What it demonstrated |
|---|---|
| `testLocalPairRouterReadsPinnedTargetDependenciesWithoutTargetStateChanges` | A new local PairRouter completed zero-input deposit/redeem against the real pinned USD/JR Vault and Controller getters. All outputs were zero; target vault supplies and relevant public token balances were identical before and after. |
| `testLocalProxiesInitializeAgainstPinnedPublicDependencies` | Fresh local JR/SR Vault and USD Vault proxies initialized using real pinned token/Controller/dependency addresses and exposed the expected stored dependencies. |
| `testLocalOracleMatchesPinnedTargetConfigurationAndPrice` | A fresh local CachedOracle built from the target Oracle's public configuration returned the same valid price. Its transient cache/reset path remained local to the test EVM. |
| `testLocalDexAdapterMatchesPinnedTargetQuotes` | A fresh local DEX strategy against the public pool matched target health, both reference-price directions, three quote vectors per direction and matching `maxFillable` outcomes. |

The Foundry output includes a non-fatal message that its optional local RPC cache did not yet have
one historical block. Foundry fetched the public data and all assertions completed successfully.

## What this does **not** prove

1. It does not prove that the clean-room initializer ABI matches the target's initializer. The
   clean-room `UsdVault.initExecution` remains explicitly local scaffolding.
2. It does not prove a full public-asset Genesis lifecycle: that would require real cbBTC/USDC
   balances and permissions, which this project intentionally does not use.
3. It does not replace testnet deployment, governance wiring, operational monitoring or an
   independent security audit.

The executable probe is
[`BaseForkInterfaceRehearsal.t.sol`](probe-tests/BaseForkInterfaceRehearsal.t.sol).
