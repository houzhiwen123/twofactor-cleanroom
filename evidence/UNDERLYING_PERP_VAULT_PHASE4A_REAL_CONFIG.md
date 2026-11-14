# UnderlyingPerpVault Phase 4A — real SR/JR deployment and configuration

## Scope

This phase freezes the real Base deployment topology and operating configuration of the cbBTC
Junior and Senior UnderlyingPerpVaults before end-to-end differential work begins. It uses only
public Base RPC data, public transaction receipts/calldata, and local Foundry forks. No verified
source, frontend bundle, wallet, private key, signature, or broadcast transaction was used.

Evidence labels:

- **TARGET-CONFIRMED** — directly observed from public chain state, receipt, calldata, or a fixed
  historical fork.
- **DERIVED** — mechanically decoded or calculated from target-confirmed bytes.
- **LOCAL-CLEANROOM** — behavior of this repository's independent implementation.
- **UNKNOWN** — not established by the present evidence.

Repository baseline: `401e84f`.

Primary executable evidence:

- `evidence/probe-tests/UnderlyingPerpVaultPhase4AConfigProbe.t.sol`
- Phase 1–3 target probes and reports already in `evidence/`

The Phase 4A target probe passes **5/5** tests. The complete version-locked Phase 1–4A target
probe set passes **37/37**, and the repository's local clean-room suite passes **206/206**.

## Exact deployment transactions

Both Vaults are top-level contract creations by
`0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b`. Public receipt logs show the implementation upgrade,
Vault ownership initialization, underlying and Perp approvals, initializer completion, ProxyAdmin
ownership initialization, and proxy admin assignment in the same successful transaction.

| Item | Junior Vault | Senior Vault |
|---|---|---|
| proxy | `0xebEe489B84C1b3408838A87A691A4370aED139DB` | `0x805D7eE7F03dE39f2F30F3A7069c6d46642398cB` |
| deployment block | `51,749,808` | `51,749,809` |
| transaction index | `89` | `94` |
| transaction hash | `0x72eb95ae4ffeab83d7e736a0018c60a584ddd23f4280f8b6a91f18290b2506c3` | `0xb1e500ac0e936bd907e09f515813156394d2b26dcc25f0a5a1824956ec40b5ce` |
| receipt status | success | success |
| created code size | `830` bytes | `830` bytes |
| deployment input size | `3,281` bytes | `3,281` bytes |
| deployment input keccak256 | `0xe342d67d910cfc6c9a916ce8ef48bbb4c8df7425af25cacffd1ea8b701075295` | `0x136a89a45b1ef9f3ba741047e0be12b6096ae51c310f9d7bb52a09af27286844` |

The code is absent at `deploymentBlock - 1` and present at the stated deployment block. The public
creation calldata mechanically decodes as an `(implementation, initialAdminOwner, initializerData)`
tuple:

| Constructor field | Both Vaults |
|---|---|
| implementation | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` |
| initial ProxyAdmin owner | `0xd7dAAA0648d72AFd2470e5B68B3Cf1c9Fd88c92b` |
| initializer selector | `0xc3d9e2fd` = `init(string,string,address,address,bool,bool)` |

Decoded initializer parameters:

| Parameter | Junior | Senior |
|---|---|---|
| name | `cbBTC Junior Keeper` | `cbBTC Senior Keeper` |
| symbol | `cbBTC-Jr-Keeper` | `cbBTC-Sr-Keeper` |
| underlying | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | same |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` | same |
| `isPerpSrVault` | `false` | `true` |
| `mintsAboveTarget` | `false` | `true` |

The fixed-block fork verifies the resulting default configuration immediately after deployment:

- owner and keeper are the deployer;
- Vault share decimals are `18`, underlying unit is `1e8`, and minimum locked liquidity is `1e10`;
- `targetDR`, lower bound, and upper bound are each `1e18`;
- rebalance frequency is `86,400`, offset and last timestamp are zero;
- minimum rebalance value is zero and maximum flash fee is `1e16`;
- supply and both asset balances are zero;
- underlying and selected Perp allowances to the Controller are initialized to `uint256.max`.

The public RPC did not complete Foundry's full `vm.transact` historical creation replay within the
bounded retry. The executable probe therefore locks the exact code-appearance boundary and all
post-transaction initializer results. The transaction hashes, receipts, calldata hashes, and decoded
arguments above remain public target evidence; this limitation is not presented as a successful
transaction-level replay.

## Version-locked proxy topology

**TARGET-CONFIRMED** at Base block `53,526,143`:

| Item | Junior | Senior |
|---|---|---|
| proxy runtime codehash | `0x0a16141b955fdc3548daeab3d02a4f007fcd407b6f88758a94caae8e8f4a4ab7` | `0x2aed056fa5d6761cedf311376549767d063f32970ddc944418f0f16c965b65c3` |
| implementation slot | `0xA1302bE3e96F1D057722AeDCCf4Cc6d58D6925ea` | same |
| implementation codehash | `0xf44934d03450e1a1ccec20b9f3d6031fb2176e2e90c4d1074a506b8f27285645` | same |
| ProxyAdmin | `0xe49e746cccd4c897ca3ad985747b30dd0a88d18d` | `0x558818c8f369e6804041a8bdca5afcafa9acb06d` |
| ProxyAdmin runtime codehash | `0x097b23f80b082223dac6782c1aac884dc42d49a1b459e83df1efe5c1d794e0ce` | same |
| ProxyAdmin owner | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d` | same |
| Vault owner | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d` | same |
| Vault keeper | `0xd3493F286f1B6e084D1CE5f6d6E6016fa7c8454d` | same |
| paused | `false` | `false` |

The two proxy runtime hashes differ because the proxy admin address is embedded independently; the
implementation and ProxyAdmin runtime hashes match across both deployments.

## Dependency and token configuration

| Item | Value |
|---|---|
| underlying | cbBTC `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf`, 8 decimals |
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` |
| Junior Perp | `0x8cd04668292dC32F519972495C179E4f02C0e8AB`, 8 decimals |
| Senior Perp | `0x4be28E7597A928835245a10E9161E0c44687b70b`, 8 decimals |
| Vault share decimals | `18` on both sides |

The selected Vault Perp equals the corresponding `perpJr()` or `perpSr()` returned by the same
Controller. This is a direct topology assertion, not a name-based inference.

## Runtime configuration matrix

**TARGET-CONFIRMED** at block `53,526,143`:

| Parameter | Junior | Senior |
|---|---:|---:|
| `isPerpSrVault` | `false` | `true` |
| `mintsAboveTarget` | `false` | `true` |
| `targetDR` | `1,053,564,994,000,000,000` | same |
| `eqDRRange.lower` | `1,053,564,994,000,000,000` | `1,043,029,344,100,000,000` |
| `eqDRRange.upper` | `1,230,000,000,000,000,000` | `1,064,100,643,900,000,000` |
| `lastRebalanceTimestampSec` | `1,793,318,400` | `1,793,785,200` |
| `rebalanceFreqSec` | `28,800` | `28,800` |
| `rebalanceOffsetSec` | `0` | `6,000` |
| `minRebalanceVal` | `100,000` | `100,000` |
| `maxFlashFeePerc` | `5,000,000,000,000,000` | same |
| note supply | `3,813,064,395,481,201,456` | `121,588,631,786,949,865` |
| idle cbBTC | `0` | `10,259,975` |
| selected Perp balance | `32,102,063,162,351` | `170,465,061,177` |
| TVL in cbBTC units | `375,476,086` | `12,403,293` |
| current rebalance amount | `0` | `0` |
| returned direction at zero | mint | redeem |

## Allowance state is not static

At deployment, both underlying and selected Perp allowances to the Controller are `uint256.max`.
At the fixed block, the selected Perp allowances remain at max, but cbBTC allowances have decreased:

| Side | Fixed-block cbBTC allowance | Amount consumed from max |
|---|---:|---:|
| Junior | `115792089237316195423570985008687907853269984665640564039457584007913118077089` | `11,562,846` |
| Senior | `115792089237316195423570985008687907853269984665640564039457584007913113892084` | `15,747,851` |

Future end-to-end differentials must compare the actual token's allowance semantics and must not
assume that a maximum allowance is permanently unchanged.

## Clean-room deployment mapping

The repository's single `UnderlyingPerpVault` implementation has the same six-argument initializer
shape and uses the two decoded booleans to select Junior or Senior behavior. Phase 4A makes no
production-code changes. The next phase can deploy two instances from this configuration matrix,
then compare deposits, rebalances, Controller rollover effects, and redemptions separately.

## Remaining unknowns

- The exact source/build identity of the target proxy creation bytecode was not used or inferred.
- A bounded full `vm.transact` replay of the historical creation transaction did not complete on the
  public RPC; code boundary, receipt, calldata, and post-state evidence are used instead.
- This phase does not enumerate every historical setter transaction or every earlier upgrade.
- End-to-end deposit → rebalance → rollover → redeem compatibility remains Phase 4B work.

## Reproduction

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-contract UnderlyingPerpVaultPhase4AConfigProbeTest --summary
```

## Verification gates

- target Phase 1–4A probes: **37 passed, 0 failed**;
- local clean-room suite: **206 passed, 0 failed**;
- `PerpController`: **22,475 runtime bytes**, within the `22,500`-byte project ceiling;
- `UnderlyingPerpVault`: **11,806 runtime bytes**, within the `18,000`-byte project ceiling;
- Controller, USD Vault, and UnderlyingPerpVault frozen storage-layout checks pass;
- UnderlyingPerpVault frozen ABI matches **83 entries**, SHA-256
  `c7eae5c0efe22100ea12ddf1c3148655548bdc8ba20c5bca30a02dba09362aea`;
- `forge fmt --check`, `git diff --check`, and JSON parsing pass.
