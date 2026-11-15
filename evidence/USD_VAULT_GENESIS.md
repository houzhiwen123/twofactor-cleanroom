# USD Vault first notes / Genesis

## Classification and scope

- **TARGET-CONFIRMED**: fresh-proxy behavior of the locked target USD Vault implementation on a
  public Base fork.
- **LOCAL-CLEANROOM**: the independent `UsdVault.initDeposit` implementation and its regressions.
- No target source or frontend bundle was read. No wallet, private key, signature, broadcast,
  target storage edit or manufactured target-holder balance was used.

## Version lock

| Field | Value |
|---|---|
| chain / block | Base `8453` / `53,526,143` |
| target implementation | `0xF85EE52a320F2B8CF4E670cd40D8218519FDaACF` |
| implementation codehash | `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4` |
| Controller dependency | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |
| underlying | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` |

Each vector deployed a fresh local proxy pointing at the public target implementation and supplied
local USD/DEX dependencies. This is a **SYNTHETIC FORK target-implementation probe**, not a natural
historical deployment transaction.

## Exact state machine

| Input USD units | Call result | Total notes | Initializer notes | Vault-held notes | USD moved | Logs |
|---:|---|---:|---:|---:|---:|---:|
| `0` | success / return `0` | `0` | `0` | `0` | `0` | `0` |
| `1` | success / return `0` | `0` | `0` | `0` | `0` | `0` |
| `9,999` | success / return `0` | `0` | `0` | `0` | `0` | `0` |
| `10,000` | success / return `0` | `0` | `0` | `0` | `0` | `0` |
| `10,001` | success / return `10,001e12` | `10,001e12` | `1e12` | `1e16` | `10,001` | `5` |
| `99,999` | success / return `99,999e12` | `99,999e12` | `89,999e12` | `1e16` | `99,999` | `5` |
| `100,000` | success / return `100,000e12` | `100,000e12` | `90,000e12` | `1e16` | `100,000` | `5` |
| `1,000,000` | success / return `1,000,000e12` | `1e18` | `0.99e18` | `1e16` | `1,000,000` | `5` |

The target rule is:

```text
notes = usdAmount * 1e12
if notes <= 1e16: successful no-op
otherwise: lock 1e16 notes in the Vault and mint notes - 1e16 to the initializer
```

The exact successful event order is:

1. USD `Transfer(initializer, Vault, usdAmount)`;
2. notes `Transfer(0, Vault, 1e16)`;
3. notes `Transfer(0, initializer, notes - 1e16)`;
4. `Deposit(0, 0, 1e16)`;
5. `Deposit(usdAmount, 0, notes - 1e16)`.

## Authorization, replay and donation

- The initializer caller becomes owner and keeper on the fresh target proxy.
- A random caller reverts `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`).
- A second positive initialization reverts `VaultInitialized()` (`0x13056cf1`); notes, USD and
  caller/Vault balances remain byte-for-byte unchanged.
- One USD unit donated before initialization does not change note issuance. `10,001` input still
  mints `10,001e12` notes; the Vault ends with `10,002` USD units. Owner-only initialization prevents
  an unrelated caller from selecting the initial recipient, but donation economics remain a
  production review item.

## Clean-room implementation

`UsdVault.initDeposit` independently implements only the matrix above. It adds `OwnableUpgradeable`
through its namespaced storage, so the frozen linear USD Vault slots remain unchanged. The local
deployment now activates the USD Vault with `10,001` USD units instead of editing proxy storage or
using a test-only note mint.

## Reproduction and verification

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL="$BASE_RPC_URL" forge test \
  --match-path evidence/probe-tests/UsdVaultGenesisProbe.t.sol -vv
forge test --match-path test/UsdVaultGenesis.t.sol -vv
```

- Target fork probe: **2 passed, 0 failed**.
- Local Genesis regressions: **5 passed, 0 failed**.
- Full local suite after Genesis and DEX lifecycle: **239 passed, 0 failed, 0 skipped**.
- Storage-layout guard: passed.
- UsdVault runtime after implementation: `16,865` bytes.
- Controller runtime remains `22,475` bytes and its frozen layout is unchanged.
