# UnderlyingPerpVault Phase 1

Status: **TARGET-CONFIRMED core behavior + LOCAL-CLEANROOM implementation**

Scope: shared `cbBTC + Perp JR` and `cbBTC + Perp SR` vault initialization, valuation, deposit and redemption.

Safety: public Base data, read-only `eth_call`, transaction receipts and local Foundry forks only. No wallet, private key, signing or broadcast was used.

## Version lock

| Item | Value |
|---|---|
| Chain | Base (`8453`) |
| Current-state fork block | `53,526,143` |
| Metadata block | `53,526,228` |
| Junior proxy | `0xebEe489B84C1b3408838A87A691A4370aED139DB` |
| Senior proxy | `0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB` |
| Shared implementation | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` |
| Implementation EVM codehash | `0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645` |
| Implementation runtime SHA-256 | `441c081b4e28f8f601a1871699594fec3fce7c1b64221f0f6634ad1b0bad7332` |

The implementation slot and EVM codehash are asserted at the current snapshot and at every historical pre-state used by the probe.

## Confirmed topology

Both proxies use the same implementation and the same cbBTC underlying. The initializer selects the Perp token from the Controller:

| Instance | Perp | `isPerpSrVault` | `mintsAboveTarget` | Notes metadata |
|---|---|---:|---:|---|
| Junior | Perp JR `0x8cd0…e8AB` | false | false | `cbBTC Junior Keeper` / `cbBTC-Jr-Keeper`, 18 decimals |
| Senior | Perp SR `0x4be2…b70b` | true | true | `cbBTC Senior Keeper` / `cbBTC-Sr-Keeper`, 18 decimals |

`MINIMUM_LIQUIDITY` is `10,000,000,000` notes for both instances.

## Exact state machine implemented

### Initialization

The target initializer ABI is:

```solidity
init(name, symbol, underlying, controller, isPerpSrVault, mintsAboveTarget)
```

`initDeposit(underlyingAmt)` converts cbBTC units to 18-decimal notes:

```text
initialNotes = floor(underlyingAmt × 1e18 / underlyingUnitAmt)
```

- If `initialNotes <= MINIMUM_LIQUIDITY`, the call returns `0`, moves no asset, emits no event and does not activate normal deposits.
- Otherwise it transfers cbBTC, mints `MINIMUM_LIQUIDITY` notes to the Vault itself, mints the remainder to the caller, emits the two target `Deposit` events, and activates normal deposits.
- A repeated successful initialization reverts `VaultInitialized()`.
- Before successful initialization, `deposit()` reverts `VaultNotInitialized()`; read-only quotes, TVL and zero redemption safely return zero.

The two real initialization transactions are:

| Side | Block / transactionIndex | Transaction | Result |
|---|---:|---|---|
| Senior | `51,749,945 / 74` | `0xd0ab7c…26872a` | `100,000 cbBTC units → 1e15 total notes` |
| Junior | `51,749,947 / 67` | `0x7be7a7…4c20a9` | identical |

Their exact log order is:

```text
cbBTC Transfer(user → vault, 100000)
notes Transfer(0 → vault, 1e10)
notes Transfer(0 → user, 999990000000000)
Deposit(0, 0, 1e10)
Deposit(100000, 0, 999990000000000)
```

### TVL

The Vault reports value in cbBTC base units:

```text
selectedPerpValue = floor(perpBalance × selectedPerp.reserveValue / selectedPerp.totalSupply)
TVL               = underlyingBalance + selectedPerpValue
```

At block `53,526,143` the exact results are:

| Side | cbBTC balance | Perp balance | TVL |
|---|---:|---:|---:|
| Junior | `0` | `32,102,063,162,351` | `375,476,086` |
| Senior | `10,259,975` | `170,465,061,177` | `12,403,293` |

### Mint quote and deposit

Let `S` be notes supply, `U` cbBTC balance and `P` Perp balance.

```text
if U == 0:
    accepted = (0, perpMax)
    notes    = floor(perpMax × S / P)
else if P == 0:
    accepted = (underlyingMax, 0)
    notes    = floor(underlyingMax × S / U)
else:
    underlyingFromPerp = floor(perpMax × U / P)
    if underlyingFromPerp < underlyingMax:
        accepted = (underlyingFromPerp, perpMax)
    else:
        accepted = (underlyingMax, floor(underlyingMax × P / U))
    notes = floor(acceptedUnderlying × S / U)
```

All divisions round down. Exact ratio and `perpMax ± 1` vectors are asserted. If the resulting notes are zero, `deposit()` returns zero without transfers, minting or events, even if the quote contains a one-unit Perp amount.

The target's post-initialization `P == 0` boundary is also fixed: at block `51,749,945`, `(S,U,P)=(1e15,100000,0)` and `computeMintAmt(100000,0)` returns exactly `(1e15,100000,0)`.

Successful event order is:

```text
underlying Transfer (when nonzero)
Perp Transfer (when nonzero)
notes mint Transfer
Deposit
```

### Redemption

Each leg is independently rounded down:

```text
underlyingOut = floor(notes × underlyingBalance / totalSupply)
perpOut       = floor(notes × perpBalance / totalSupply)
```

Successful event order is:

```text
notes burn Transfer
underlying Transfer (when nonzero)
Perp Transfer (when nonzero)
Redeem
```

Zero-note redemption returns `(0,0)` without events. Transfer failures revert the burn and all earlier asset movements atomically.

### Keeper administration and pause boundary

On a synthetic local fork, the target owner and keeper were separated before testing each role:

- `updateKeeper()` is owner-only; a random caller reverts with `OwnableUnauthorizedAccount(address)`.
- The owner may set the keeper to the zero address; no extra parameter validation is applied.
- `pause()` and `unpause()` are keeper-only. After setting a distinct keeper, owner and random calls both revert with `UnauthorizedCall()` (`0x7bf6a16f`), while the keeper succeeds.

The clean-room implementation matches these exact role and zero-address boundaries.

## Historical golden vectors

All four historical pre-states resolve to the locked implementation above.

| Side/path | Pre-state block | Inputs | Exact outputs |
|---|---:|---|---|
| Junior deposit | `51,777,455` | `(0, 1,636,069,530,773)` | `194,416,786,128,004,843 notes`, accepts the full Perp input |
| Senior deposit | `51,777,489` | `(1,590,000, 540,252,299,306)` | `80,494,093,785,850,860 notes`; accepts `1,587,122 cbBTC` and all Perp |
| Junior redeem | `51,777,349` | `41,562,290,000,000,000 notes` | `3,555,739 cbBTC + 50,480,992,204 JR` |
| Senior redeem | `51,777,358` | `49,620,700,000,000,000 notes` | `4,907,016 cbBTC + 4,656,119,783 SR` |

The corresponding successful transactions and receipts independently confirm the same results and event order.

## Test results

- Target fixed-block and synthetic-fork evidence: `UnderlyingPerpVaultPhase1ProbeTest`.
- Local clean-room regression: `UnderlyingPerpVaultTest`.
- The local suite covers both sides, initialization dust, exact historical values, limiting-leg `±1`, TVL, event order, zero/tiny inputs, allowance failure atomicity, pause and fuzzed redemption rounding.
- Runtime size is `8,146 bytes`. The phase-1 proxy storage baseline is frozen through slot 4 by `script/check_underlying_perp_vault_storage_layout.py`.
- Existing Controller and USD Vault layouts remain unchanged; Controller runtime remains `22,475 bytes`.

Reproduce target probes:

```bash
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-contract UnderlyingPerpVaultPhase1ProbeTest -vv
```

## Explicitly pending

Phase 1 does **not** claim target compatibility for:

- `computeRebalanceAmount()` and `rebalance()`;
- target DR/equilibrium-range updates;
- rebalance frequency, offset, minimum amount and flash-fee limits;
- keeper-driven asset movement beyond the confirmed pause/unpause boundary;
- all edge cases of administrative parameter validation.

Those paths remain for Phase 2 and must not be inferred from the ABI alone.
