# Round 7 — Phase 1b review probes

Version lock: chain ID `8453`; fork blocks `53,494,912` and `54,990,962`; EIP-1967 slot
`0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`.

| Contract | Proxy / direct address | Implementation | Proxy codehash | Implementation codehash |
|---|---|---|---|---|
| Controller | `0x682F3a053B0260daD4EbEee3924B1618B330A200` | `0x16e324bae2098317477129a5e71f770bff51f02a` | `0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e` | `0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31` |
| FeePolicy | `0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8` | `0x9cefc3cf756c6b2a7568b0539c956f1dd5691900` | `0x2a16f92d0d60ffb240c4be576111b0e8a195a4c5b0f98856380c8943b9bbaa44` | `0x2147e3a9366e8e48e04b2827d3e646c80c4adbe14cac06f490f9dc057ec4a755` |
| Balancer | direct `0x30333a6B8744a1203D060E108dDC8C155059aCbf` | — | `0x540e400d7517059a0d44fe7ed777c00c5b667c5a118cb98b322f24e713dbb1f8` | — |
| BondIssuer | `0xc56CCbF6219B780c879544FEe0404bD3B49fEBB0` | `0xe024bd4967185456df3de7d2365919b5fb89763b` | `0x2f45f7c8aecc0c1bcc29b357b888ab106dde9ae1c078cb4fa39c3a93a41d0080` | `0x2a5e0beeb8cdfd88b98395e5e11dccdb915a7be3f8e5e9502819aaa67864cbe8` |
| BondsManager | `0xe8c13955caED9c009fd2b335A10986407958fde3` | `0x427758ed7ba97d3602125f957cd9e6716fddaac2` | `0xb14a5bc7f2c4d16ee0e0948b9c6976d4349cdc2ab01f8d86fae83ae79650dd46` | `0xb2318665f51d6ea433c3f7ac358765d48a4dace3da3e708bdaa94f54ef6a16c6` |
| PerpSR | `0x4be28E7597A928835245a10E9161E0c44687b70b` | `0x96fc14b136300f9136c0d589ed7a787b66571574` | `0x8e01b75f6fea2f350c20251d68f1da319eb892dc96fcacdcc9c7700af40e82a0` | `0x1d57fb7d55c334bb60b1a6cf666790a5e3e95d24ea6044a1a70a5e5762ce1a53` |
| PerpJR | `0x8cd04668292dC32F519972495C179E4f02C0e8AB` | `0x8e9ed1138060434e56a5f7965017391c93631529` | `0x3c1c15d9fd1529b7c8045877a581eb564b0797bb1d2e21453c140b0338f023b0` | `0xa34e6fcb0bf4e6b4ad9978a870df69fd9adb607f572e2cfad291c12c093d0ebb` |

All listed versions were identical at the two fork blocks. Round 7 used the local Base Anvil fork
at `http://127.0.0.1:8545`; no verified source/frontend or real-chain transaction was used.

Reproduce from the probe workspace root:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --via-ir --match-path test/Round7ReviewProbe.t.sol -vv
BASE_RPC_URL=http://127.0.0.1:8545 forge test --via-ir --match-path test/Round7ReviewProbe.t.sol --match-test testR7RawReserveABIs -vv
```

Raw logs are archive members under `evidence/raw-logs.tar.xz`.

| Probe | Result | Raw evidence |
|---|---|---|
| **R7.1 Perp return ABI** | Both live Perps returned `reserves()` with 320 bytes. Raw words decode as one dynamic `ReserveTokens` struct containing `underlyingBal` and `TokenAmount[] trancheTokens`, where each entry is `(address token,uint256 amount)`. SR underlying `0`; entries `(0x2b97045571Ec78aE1010Df47b3e275eCdAE53300,3149185188264)`, `(0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B,3133547705520)`, `(0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68,3392625737181)`. JR underlying `271549615`; entries `(0x0BC26651B2Fbc4230F5C34a9eD186c28aEA48414,3149185188266)`, `(0xF012e0Fc76306aE1374B577483Cf6b79dE8cf9b1,3133547705527)`, `(0x73D500c3fE50c320b6E0db0DB3c34Ff9A2aF3582,3392625737183)`. `reserveData()` returned 1,664 bytes and decoded as the rich struct with 3 `(TrancheData,balance,value)` entries. First SR entry: balance `3149185188264`, value `42084862`; first JR entry: balance `3149185188266`, value `40852120`. The initial `address[]` hypothesis misread each amount as an address; the corrected integrated and focused decodes confirm the token/amount pair stride. | Raw words and rich data: `round7_integrated_probe.log:142-210,213-283`; corrected focused decode: `round7_reserve_abi_corrected.log:26-41,97-112` |
| **R7.2 Perp ownership, permissions, ERC20** | Owner `0xd349…8454d` successfully changed each Perp controller to `0xCA11B00B`. Thereafter owner/old-controller/random calls to controller-only functions failed with `UnauthorizedCall()` (`0x7bf6a16f`); the new controller succeeded for `mintTo`, `burnFrom`, `registerTranche`, `transferReservesTo`, `handleTransferReservesIn`, `logBalance`, and JR `primeApproval`/`revokeApproval`. Non-owner `updateController` calls failed with `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`). Ownable2Step transfer, pending owner, acceptance, and renunciation succeeded; random acceptance failed with `0x118cdaa7`. SR and JR holder `transfer`, `approve`, and `transferFrom` succeeded. Names/symbols/decimals: `cbBTC Senior` / `cbBTC-SR` / `8`, and `cbBTC Junior` / `cbBTC-JR` / `8`. | `round7_integrated_probe.log:46-138` |
| **R7.3 Controller admin roles** | With owner, keeper `0xCA11`, and random `0xBEEF` distinct, `pauseUserOps`, `pauseSystemOps`, and `updateValueCap` succeeded only for keeper; owner/random reverted `UnauthorizedCall()` (`0x7bf6a16f`). `updateDRTargets`, `updateFeePolicy`, `updateIssuer`, `updateKeeper`, `updateLiquidityThresholds`, `updateMinCleanupVal`, `updatePerpBalancer`, `updateRebalanceWindow`, and `updateRolloverEligibility` succeeded for owner and rejected keeper/random with `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`). | `round7_integrated_probe.log:7-42` |
| **R7.4 Setter validation** | `updateRebalanceWindow`: `freq=0`, `offset>freq`, `length=0`, and `length>freq` reverted `InvalidParamDefn()` (`0xd126d255`); `offset==freq` and `(86400,64800,3600)` succeeded. `updateLiquidityThresholds` percentage `1e18+1` reverted `InvalidPerc()` (`0xcdc62692`); `1e18` succeeded. `updateDRTargets` with zero system target, zero JR VM, or both zero reverted `InvalidParamDefn()`; current on-chain targets succeeded. | `round7_integrated_probe.log:113-124` |
| **R7.5 Rebalance ordering** | Collected fees were SR `74102043`, JR `87590731`, cbBTC `198`; mocked plan value `100` was nonzero and paid JR→SR. With mocked AUM rates SR `1e17`, JR `5e16`, event indices were SR fee-perp burn `27`, JR burn `28`, cbBTC fee transfer to JR `29`, `Rebalance` `31`, JR→SR reserve transfer `32`, SR `AumFees` `36` for `1071993013534`, and JR `AumFees` `38` for `1785766833181`. `ReserveSynced` was also observed around settlement and reserve transfers, including zero balances. | `round7_integrated_probe.log:287-308` |

For R7.5, only FeePolicy responses (`computeOpFees`, `computeRebalanceVal`, and AUM rates) were mocked to make each amount nonzero; the Controller, Perps, and Balancer executed on the local fork. The integrated probe suite passed **7/7** with the corrected reserve-ABI decode; the focused reserve-ABI decode also passed **1/1**.
