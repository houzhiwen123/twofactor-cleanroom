# Round 7 — Phase 1b review probes

All probes used the local Base Anvil fork at `http://127.0.0.1:8545`, chain ID 8453, block
`54,990,962`. No verified source or frontend bundle was read, and no real-chain transaction was
sent.

Reproduce:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --via-ir --match-path test/Round7ReviewProbe.t.sol -vv
```

Raw log: `/home/ubuntu/work/probes/round7_integrated_probe.log`.

| Probe | Result | Raw evidence |
|---|---|---|
| **R7.1 Perp return ABI** | Both live Perps returned `reserves()` with 320 bytes. Raw words decode as one dynamic `ReserveTokens` struct containing `underlyingBal` and `TokenAmount[] trancheTokens`, where each entry is `(address token,uint256 amount)`. SR underlying `0`; entries `(0x2b97045571Ec78aE1010Df47b3e275eCdAE53300,3149185188264)`, `(0x7C82fD6DCA95554b8Ad5B3207Ea5aEb6028cf91B,3133547705520)`, `(0x15a5Ff3B2D9c05301F31DaF788aa72380bA34A68,3392625737181)`. JR underlying `271549615`; entries `(0x0BC26651B2Fbc4230F5C34a9eD186c28aEA48414,3149185188266)`, `(0xF012e0Fc76306aE1374B577483Cf6b79dE8cf9b1,3133547705527)`, `(0x73D500c3fE50c320b6E0db0DB3c34Ff9A2aF3582,3392625737183)`. `reserveData()` returned 1,664 bytes and decoded as the rich struct with 3 `(TrancheData,balance,value)` entries. First SR entry: balance `3149185188264`, value `42084862`; first JR entry: balance `3149185188266`, value `40852120`. The initial `address[]` hypothesis misread each amount as an address; the corrected integrated and focused decodes confirm the token/amount pair stride. | Raw words and rich data: `round7_integrated_probe.log:142-210,213-283`; corrected focused decode: `round7_reserve_abi_corrected.log:26-41,97-112` |
| **R7.2 Perp ownership, permissions, ERC20** | Owner `0xd349…8454d` successfully changed each Perp controller to `0xCA11B00B`. Thereafter owner/old-controller/random calls to controller-only functions failed with `UnauthorizedCall()` (`0x7bf6a16f`); the new controller succeeded for `mintTo`, `burnFrom`, `registerTranche`, `transferReservesTo`, `handleTransferReservesIn`, `logBalance`, and JR `primeApproval`/`revokeApproval`. Non-owner `updateController` calls failed with `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`). Ownable2Step transfer, pending owner, acceptance, and renunciation succeeded; random acceptance failed with `0x118cdaa7`. SR and JR holder `transfer`, `approve`, and `transferFrom` succeeded. Names/symbols/decimals: `cbBTC Senior` / `cbBTC-SR` / `8`, and `cbBTC Junior` / `cbBTC-JR` / `8`. | `round7_integrated_probe.log:46-138` |
| **R7.3 Controller admin roles** | With owner, keeper `0xCA11`, and random `0xBEEF` distinct, `pauseUserOps`, `pauseSystemOps`, and `updateValueCap` succeeded only for keeper; owner/random reverted `UnauthorizedCall()` (`0x7bf6a16f`). `updateDRTargets`, `updateFeePolicy`, `updateIssuer`, `updateKeeper`, `updateLiquidityThresholds`, `updateMinCleanupVal`, `updatePerpBalancer`, `updateRebalanceWindow`, and `updateRolloverEligibility` succeeded for owner and rejected keeper/random with `OwnableUnauthorizedAccount(address)` (`0x118cdaa7`). | `round7_integrated_probe.log:7-42` |
| **R7.4 Setter validation** | `updateRebalanceWindow`: `freq=0`, `offset>freq`, `length=0`, and `length>freq` reverted `InvalidParamDefn()` (`0xd126d255`); `offset==freq` and `(86400,64800,3600)` succeeded. `updateLiquidityThresholds` percentage `1e18+1` reverted `InvalidPerc()` (`0xcdc62692`); `1e18` succeeded. `updateDRTargets` with zero system target, zero JR VM, or both zero reverted `InvalidParamDefn()`; current on-chain targets succeeded. | `round7_integrated_probe.log:113-124` |
| **R7.5 Rebalance ordering** | Collected fees were SR `74102043`, JR `87590731`, cbBTC `198`; mocked plan value `100` was nonzero and paid JR→SR. With mocked AUM rates SR `1e17`, JR `5e16`, event indices were SR fee-perp burn `27`, JR burn `28`, cbBTC fee transfer to JR `29`, `Rebalance` `31`, JR→SR reserve transfer `32`, SR `AumFees` `36` for `1071993013534`, and JR `AumFees` `38` for `1785766833181`. `ReserveSynced` was also observed around settlement and reserve transfers, including zero balances. | `round7_integrated_probe.log:287-308` |

For R7.5, only FeePolicy responses (`computeOpFees`, `computeRebalanceVal`, and AUM rates) were mocked to make each amount nonzero; the Controller, Perps, and Balancer executed on the local fork. The integrated probe suite passed **7/7** with the corrected reserve-ABI decode; the focused reserve-ABI decode also passed **1/1**.
