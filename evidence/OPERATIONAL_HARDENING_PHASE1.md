# Operational hardening Phase 1 — local deployment and automation boundaries

Status: **LOCAL-CLEANROOM deployment candidate; not production-ready**

> Historical status note: the activation limits recorded in this Phase-1 snapshot were closed later.
> `USD_VAULT_GENESIS.md` fixes the target first-notes rule, and `LOCAL_DEX_LIFECYCLE.md` adds an
> executable local-only pool/Inventory lifecycle. The original Phase-1 observations below are kept
> as a baseline rather than rewritten as if those later results were already known.

Repository baseline: `eb6fbb9`.

## Scope and safety

This phase turns the existing core Genesis simulation into a reproducible local full-stack
deployment. It reads no RPC endpoint, wallet or private key, performs no signature or broadcast,
and must be run without `--broadcast`. No target source or frontend bundle was used.

The fixed local administrator is `0x00000000000000000000000000000000000A11cE`. All operational
values are recorded in `config/local-cleanroom-deployment.json`.

## Deployment result

`DeployGenesisLocal` now deploys and wires:

1. cbBTC and USD local tokens plus underlying/USD price oracles;
2. BondsManager, BondIssuer, first Bond, SR/JR Perps, FeePolicy, PerpBalancer and Controller;
3. the one-use GenesisSeeder and the balanced core Genesis state;
4. target-configured Junior and Senior UnderlyingPerpVault proxies;
5. target-confirmed UnderlyingSingleAssetRouter and USD SingleAssetRouter;
6. UniswapV3DexStrategy and a local quote/health pool;
7. a USD Vault proxy initialized with Controller, Oracle, DEX and authorized inventory addresses.

The script validates the selected SR/JR Perps, both Vault keeper values, USD Vault execution
dependencies, authorized inventory role and DEX health before completing. The latest local run used
`36,789,439` gas and completed with user operations unpaused.

The Underlying Vaults each receive `1,000,000` underlying units and lock their normal minimum notes.
Their target DR, equilibrium ranges, timing, minimum size and maximum flash fee match the
version-locked target configuration recorded in `UNDERLYING_PERP_VAULT_PHASE4A_REAL_CONFIG.md`.

## Activation matrix

| Component | Local state | Classification |
|---|---|---|
| Bond/Controller/Perp core | Genesis completed and user operations enabled | LOCAL-CLEANROOM |
| Junior Underlying Vault | configured, seeded and initialized | TARGET-CONFIGURED / LOCAL-CLEANROOM deployment |
| Senior Underlying Vault | configured, seeded and initialized | TARGET-CONFIGURED / LOCAL-CLEANROOM deployment |
| Underlying Router | deployable and covered by the completed JR/SR lifecycle | TARGET-CONFIRMED behavior / LOCAL deployment |
| DEX Strategy | dependency, health and quote surface initialized | LOCAL-CLEANROOM |
| Local DEX pool execution | intentionally disabled | LOCAL SAFETY LIMIT |
| USD Vault | dependencies initialized; zero notes and zero seed assets | ACTIVATION BLOCKED |
| USD Router | deployed; downstream USD activation still required | DEPLOYED / NOT ACTIVE |

The USD Vault cannot yet establish its first notes through its production surface. Adding an
unverified mint entry, editing proxy storage or using a test harness would violate the evidence
boundary. This phase therefore records the gap instead of concealing it.

## Keeper and caller matrix

| Surface | Allowed caller behavior |
|---|---|
| Controller `rebalance`, `rollover`, `upkeep` | permissionless subject to normal state/time gates |
| Controller `updateKeeper` and parameter setters | owner-only |
| Underlying Vault `rebalance` | permissionless; balanced state reaches `NoOp()` rather than an auth error |
| Underlying Vault `pause` / `unpause` | configured keeper only |
| Underlying Vault `updateKeeper` / parameter setters | owner-only |
| USD Vault `rebalance` / `upkeep` | permissionless subject to state, health and delay gates |
| USD Vault `swap` | authorized inventory address only; others get `UnauthorizedCall()` |

`OperationalDeploymentTest` additionally proves that a failed USD dependency initialization rolls
back and can be followed by one valid initialization, both Vault initializers reject replay, a
former Underlying Vault keeper immediately loses pause authority, and unrelated callers reach the
permissionless maintenance state machine.

## Verification

- Secret-free full-stack deployment simulation: success, `36,789,439` gas.
- Operational deployment tests: `2 passed, 0 failed`.
- Full offline suite: `219 passed, 0 failed`.
- Runtime sizes: Controller `22,475` bytes, UnderlyingPerpVault `11,806` bytes, UsdVault `15,996`
  bytes, UnderlyingSingleAssetRouter `3,994` bytes and UniswapV3DexStrategy `4,530` bytes.
- Controller, UnderlyingPerpVault and UsdVault frozen storage-layout checks passed.
- Frozen UnderlyingPerpVault ABI check passed: 83 entries, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`.
- Both JSON files parse, and `forge fmt --check` plus `git diff --check` pass.

## Reproduction

```sh
forge script script/DeployGenesisLocal.s.sol:DeployGenesisLocal --offline -vvv
forge test --match-contract OperationalDeploymentTest -vv
python3 -m json.tool config/local-cleanroom-deployment.json
```

## Remaining blockers

- Evidence-backed USD Vault first-notes issuance and minimum locked liquidity.
- A production DEX pool/address, executable settlement and live-liquidity calibration.
- Production multisig, ProxyAdmin ownership acceptance and keeper operating runbook.
- Stateful invariants and economic/adversarial sequence tests, which are the next phase.
- Independent audit.

No blocker above is silently replaced with a local guess.
