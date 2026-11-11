# Round 8 — reserves ABI, approvals, setters, and rebalance trace

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

All versions matched at both fork blocks. The probes used local Base Anvil at
`http://127.0.0.1:8545`; no verified source/frontend or real-chain transaction was used.

Reproduce from the probe workspace root:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --offline --via-ir --fork-url http://127.0.0.1:8545 --fork-block-number 54990962 --match-path test/Round8ReviewProbe.t.sol -vvv
```

Raw logs are archive members in `evidence/raw-logs.tar.xz`.

| Probe | Black-box result | Evidence |
|---|---|---|
| `reserves()` ABI | SR/JR raw returndata length `320`; tuple `(uint256 underlyingBal,(address,uint256)[] trancheTokens)` decodes to three registration-ordered entries. Every decoded amount equals direct `balanceOf(perp)`. SR underlying `0`; amounts `3149185188264`, `3133547705520`, `3392625737181`. JR underlying `271549615`; amounts `3149185188266`, `3133547705527`, `3392625737183`. | `evidence/raw-logs.tar.xz::round8_review_probe.log:68-75` |
| SR approval selectors | Calls `0x397e327f` and `0x484685b0` from Controller both failed with empty revert data. | `evidence/raw-logs.tar.xz::round8_review_probe.log:79-80` |
| `updateDRTargets` | System targets `1e18-1` and `1e18` rejected `InvalidParamDefn()`; `1e18+1` succeeded with JR VM target `1e18` or `1e18-1`; JR VM `0` rejected. | `evidence/raw-logs.tar.xz::round8_setter_followup.log:15-18` |
| Other setters | `updateLiquidityThresholds` rejected percentage `1e18+1` with `InvalidPerc()`; zero rollover eligibility reverted empty-selector `InvalidParamDefn()` (`0xd126d255`); `updateRebalanceWindow` rejected zero frequency, offset above frequency, zero length, and length above frequency, while offset equal to frequency succeeded. Tested liquidity amount values and valid percentages, min-cleanup/value-cap values `0,1,WAD-1,WAD,WAD+1,max`, rollover eligibility `1,current±1,current,max`, and pause booleans succeeded. | `evidence/raw-logs.tar.xz::round8_setter_followup.log:19-71` |
| `updateIssuer` | Current issuer accepted. Zero, EOA/address `1`, BondsManager, and PerpSR empty-reverted. No inferred validation rule is implemented; behavior remains provisional. | `evidence/raw-logs.tar.xz::round8_setter_followup.log:26-30` |
| Rebalance ordering | `computeRebalanceVal` staticcall at line 1288 follows both fee burns and cbBTC fee transfer; plan staticcall at 1291; payer transfer at 1293; receiver hook at 1307; SR/JR AUM mints at 1328/1334. | `evidence/round8_rebalance_trace.log:1132-1143,1288-1293,1307-1334` |

The fork regressions passed 3/3 in `Round8ReviewProbe` and 1/1 in the setter follow-up.
