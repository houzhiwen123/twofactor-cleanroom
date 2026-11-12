# USD Vault phase 1: evidence-backed redemption core

## Scope

This phase implements only the clean-room USD Vault behavior established by public Base state and the
strict transaction-prestate replay in `TARGET_REAL_HOLDER_EXIT_REPLAY.md`. It does not implement or
infer note issuance, deposits, sessions, capacity, rebalancing, keeper permissions or production
upgrade administration.

Baseline commit: `ef3046fa9a1ad0560998752baffbfde9171d4e6b`.

## Target-confirmed vector

- Base block: `51,820,780`.
- Transaction index: `61`.
- Transaction: `0x69303607f150b7ccd9e3137a1e621cc18437405f7788dfc35dc122537148be44`.
- Vault proxy: `0xe356D1Ed9AD82cCc79E70F50aBCE08057e8d75F3`.
- Historical implementation: `0x569021bc0975AD5B67793Cd31D9E2b0707A9f626`.
- Historical implementation codehash:
  `0x39e3ae92930befdd960644c662c9386f98f17a80117974b84d15371ebe354c21`.

Public read-only calls at the fixed block establish:

| Item | Target value |
|---|---|
| Name | `cbBTC Senior USDC Keeper` |
| Symbol | `cbBTC-Sr-USDC-Keeper` |
| Decimals | `18` |
| Notes supply before the transaction | `11196354068000000000000` |
| Notes redeemed | `11042700000000000000000` |
| USDC reserve before | `10929657330` |
| Perp SR reserve before | `26615667277` |
| USDC returned | `10779663296` |
| Perp SR returned | `26250405020` |

Both target reserve views equal the respective token balances after the historical transaction. The
quote matches exact floor pro-rata arithmetic for both assets:

```text
assetOut = floor(notesRedeemed * assetBalance / totalNotesSupply)
```

The historical receipt fixes the observable event order:

1. Vault note `Transfer(holder, address(0), notes)` burn.
2. USDC `Transfer(vault, holder, usdOut)`.
3. Perp SR `Transfer(vault, holder, perpSrOut)`.
4. Vault `Redeem(notes, usdOut, perpSrOut)` with no indexed arguments.

The natural holder balance plus one reverts with selector `0xe450d38c` and leaves the observed state
unchanged.

## Local clean-room implementation

- `src/interfaces/IUsdVault.sol` defines only the target-confirmed exit surface.
- `src/vault/UsdVault.sol` implements ERC-20 notes, reserve views, exact floor quotes and atomic
  two-asset redemption.
- The contract is proxy-compatible. Its `init` function is explicitly **LOCAL-CLEANROOM scaffolding**,
  not a target-confirmed initializer ABI.
- No production note-minting entry point is exposed. The test harness derives from the contract and
  uses the internal `_mintNotes` hook only to recreate version-locked historical state.
- `SafeERC20` and a reentrancy guard are local defensive choices. They are not presented as observed
  target internals.

## Regression coverage

`test/UsdVault.t.sol` fixes:

- target metadata and reserve views;
- the historical quote, return values, balances, total-supply burn and event order;
- the exact insufficient-balance selector and atomic rollback;
- Router-style allowance, `transferFrom` and redemption;
- full-supply exit and complete reserve conservation;
- rollback when a reserve-token transfer fails;
- one-time local initialization; and
- 256 fuzzed quote inputs with exact floor rounding.

The phase-1 upgradeable storage baseline is also frozen as `_usdToken` in slot `0` and
`_perpSrToken` in slot `1` by `script/check_usd_vault_storage_layout.py`.

Run:

```sh
forge test --match-path test/UsdVault.t.sol -vv
python3 script/check_usd_vault_storage_layout.py
```

## Unknown / deliberately not implemented

- Target initializer arguments, permissions and storage layout.
- Note mint/deposit mechanics and initial exchange rate.
- Session and capacity state machines.
- Vault rebalancing and keeper permissions.
- Zero-supply quote behavior.
- Donation handling beyond the confirmed use of actual reserve balances.
- Production upgrade administration.

Those items require separate target evidence before production behavior is added.

## Verification result

- Focused Vault suite: **8 passed, 0 failed**, including 256 fuzz runs.
- Full offline/local suite: **123 passed, 0 failed** across 11 suites.
- `UsdVault` runtime: **4,202 bytes**.
- `PerpController` runtime: **22,475 bytes**, unchanged and below the 22,500-byte guard.
- General runtime-size guard: passed.
- Frozen Controller storage slots: unchanged.
- Frozen USD Vault phase-1 storage slots: passed.
- `forge fmt --check`: passed.
- `git diff --check`: passed.
