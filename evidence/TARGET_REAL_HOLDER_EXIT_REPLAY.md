# Target real-holder exit replay

**Classification: TARGET-CONFIRMED historical success vectors plus synthetic local-fork boundary calls using the same natural balances.**

No target balance or storage was manufactured with `deal`/`store`. Every fork starts at the exact transaction-hash prestate, which includes all earlier transactions in the block.

## Result

| Layer | Success evidence | Failure boundary | Local clean-room status |
|---|---|---|---|
| Controller | Natural JR holder calls `redeem2` from tx-prestate | aggregate `minVal + 1` reverts atomically | FeePolicy compared exactly; Controller end-to-end not claimed |
| USD Vault | Original natural-holder `redeem` transaction replayed | natural note balance + 1 reverts atomically | NO_LOCAL_IMPLEMENTATION |
| SingleAsset Router | Original ERC-4337 exit replayed | exact output succeeds; exact output + 1 reverts atomically | NO_LOCAL_IMPLEMENTATION |

## Version-locked vectors

| Layer | Block | transactionIndex | Transaction | Natural holder |
|---|---:|---:|---|---|
| Controller | 51777385 | 125 | `0x98fceb34a3ddb3b6ac1ed396fbb5250ce05cfb75c8827910aa4e13d6cee92173` | `0xd7daaa0648d72afd2470e5b68b3cf1c9fd88c92b` |
| USD Vault | 51820780 | 61 | `0x69303607f150b7ccd9e3137a1e621cc18437405f7788dfc35dc122537148be44` | `0xd7daaa0648d72afd2470e5b68b3cf1c9fd88c92b` |
| SingleAsset Router | 53243583 | 77 | `0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab` | `0x11649a794f918508027765f6280c1b396ee59f8f` |

### Contract versions

| Layer | Component | Target | Implementation | Target codehash | Implementation codehash |
|---|---|---|---|---|---|
| Controller | Controller | `0x682f3a053b0260dad4ebeee3924b1618b330a200` | `0x16e324bae2098317477129a5e71f770bff51f02a` | `0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e` | `0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31` |
| Controller | FeePolicy | `0x1e3dbdc2adf4d5fdd1efdfb9ff05e4154d0c00e8` | `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900` | `0x2a16f92d0d60ffb240c4be576111b0e8a195a4c5b0f98856380c8943b9bbaa44` | `0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755` |
| SingleAsset Router | DEX Strategy | `0xe0fc0566adcd6b83149874619a1fafdf3345144f` | `0x0000000000000000000000000000000000000000` | `0x5179730df56d2d569376affd12ff8014ac2c7d9940dca3b78cb9dc22db5d5302` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| SingleAsset Router | SingleAsset Router | `0x8e868c1f8f82b84a6b0d19d235d50c47b253559f` | `0x0000000000000000000000000000000000000000` | `0x33f265f8c51da59240326566d89a19548bf6ebeb9bb225cb1ab8079d701d71bf` | `0x0000000000000000000000000000000000000000000000000000000000000000` |
| SingleAsset Router | USD Vault | `0xe356d1ed9ad82ccc79e70f50abce08057e8d75f3` | `0xf85ee52a320f2b8cf4e670cd40d8218519fdaacf` | `0x09099f0c6e5a45bc0cb72ba0f8f08f637304a410ae758b21a88589ad7240242b` | `0x8154d40af93b7d547f9f706103bf7c5a794e8f19c24e04710b4e72d463d780a4` |
| USD Vault | USD Vault | `0xe356d1ed9ad82ccc79e70f50abce08057e8d75f3` | `0x569021bc0975ad5b67793cd31d9e2b0707a9f626` | `0x09099f0c6e5a45bc0cb72ba0f8f08f637304a410ae758b21a88589ad7240242b` | `0x39e3ae92930befdd960644c662c9386f98f17a80117974b84d15371ebe354c21` |

## Controller direct exit

Natural JR input: `21200000000`; aggregate minimum value: `251879`. The exit returned `168003` cbBTC units and `1` tranche asset(s).

| Metric | Before | After |
|---|---:|---:|
| subDR | 1038993523725927985 | 1025799406232600248 |
| vmDR | 1002206757557942000 | 1002206743712286605 |
| JR totalSupply | 1669427965747 | 1648227965747 |
| Controller collected JR fee | 0 | 0 |

Returned JR fee: total `0`, protocol `0` WAD.

### Reserve-asset conservation

| # | Token | Reserve before | Reserve after | User delta | Returned | Conserved |
|---:|---|---:|---:|---:|---:|---|
| 0 | `0xcbb7c0000ab88b473b1f5afd9ef808440eed33bf` | 13229714 | 13061711 | 168003 | 168003 | yes |
| 1 | `0x1cc60029d6ef7f87ef77cd515267528c562d2b9e` | 557643460666 | 550561968318 | 7081492348 | 7081492348 | yes |

### FeePolicy differential

| Side | Target total | Clean-room total | Target protocol | Clean-room protocol | Result |
|---|---:|---:|---:|---:|---|
| SR | 0 | 0 | 0 | 0 | MATCH |
| JR | 0 | 0 | 0 | 0 | MATCH |

### Controller events

| Side | Topic | Token | Total fee amount | Protocol fee amount |
|---|---|---|---:|---:|
| JR | `0x9e03bc7cc34768c06442831b31f8f3b829f42a93c54a2c0777d51287ac154ca5` | `0x8cd04668292dc32f519972495c179e4f02c0e8ab` | 0 | 0 |

## USD Vault exit

The target quote for `11042700000000000000000` notes was `10779663296` USDC units plus `26250405020` Perp SR units. The historical transaction delivered exactly `10779663296` and `26250405020`. Vault balance deltas and note-supply burn match those outputs exactly.

This is **TARGET-CONFIRMED** only. The clean-room Vault does not exist yet.

## SingleAsset Router exit

The historical route burned `3762930374354620392` Vault notes, used minOut `3761293`, and delivered `3780194` USDC units through strategy `0xe0fc0566adcd6b83149874619a1fafdf3345144f`. The Vault supplied `1294` USDC directly plus `375200394` Perp SR; the DEX leg produced `3778900` USDC. `healthCheck` was `true`.

The observed six-argument exit ABI has **no `maxIters` field**. The report records that absence instead of inventing a value. Direct local-fork calls proved minOut is inclusive at the actual output and reverts atomically at actual output + 1.

This is **TARGET-CONFIRMED** only. The clean-room Router does not exist yet.

## Exact failure boundaries

| Layer | Attempted input | Boundary | Selector | State unchanged |
|---|---:|---:|---|---|
| Controller | 21200000000 | 251880 | `0xbc3944e7` | yes |
| SingleAsset Router | 3762930374354620392 | 3780195 | `0x850c6f76` | yes |
| USD Vault | 11196344068000000000001 | 11196344068000000000000 | `0xe450d38c` | yes |

## Minimal Vault clean-room interface and behavior checklist

The next implementation needs only the behavior demonstrated here before broader features are added:

- ERC-20 note `balanceOf`, `totalSupply`, `approve` and allowance semantics used by Routers.
- `computeRedemptionAmts(notes)` returns the exact pro-rata USDC and Perp SR quote with target rounding.
- `redeem(notes)` burns exactly the supplied notes and transfers both quoted assets to `msg.sender`.
- `usdBalance()` and `perpSrBalance()` track actual redeemable reserves; the observed exit conserves both assets exactly.
- A natural balance + 1 input reverts atomically with the recorded selector.
- Router allowance consumption, direct USDC leg, Perp SR → Controller → cbBTC leg, DEX strategy swap, health check and inclusive `minOut` must remain one atomic transaction.
- Capacity/session and rebalance behavior are outside this three-vector exit scope and remain UNKNOWN here.

## Reproduce

```sh
cd analysis/2factor/twofactor-cleanroom-codex
BASE_RPC_URL=https://mainnet.base.org python3 script/export_target_real_holder_exit_replay.py
```

Strict transaction-index reconstruction may take several minutes per vector on a public RPC.
