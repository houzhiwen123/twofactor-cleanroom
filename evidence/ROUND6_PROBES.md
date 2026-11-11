# Round 6 — Controller behavior probes

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

All listed versions were identical at the two fork blocks. Round 6 used the local Base Anvil fork
at `http://127.0.0.1:8545`; no verified source/frontend or real-chain transaction was used.

Reproduce from the probe workspace root:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/Round6ControllerProbe.t.sol -vv
BASE_RPC_URL=http://127.0.0.1:8545 forge test --fork-url http://127.0.0.1:8545 --fork-block-number 54990962 --match-path test/ControllerProbe.t.sol --match-test 'testReviewLazyFlashMint(SrAfterIssueWindowBeforeMaturity|JrWithStaleBond)' -vv
```

Raw logs are archive members under `evidence/raw-logs.tar.xz`.

| # | Question | Result and discriminating raw values | Raw log |
|---|---|---|---|
| 1 | `rebalance()` caller authorization | Permissionless in the tested valid window: distinct random EOA `0xBEEF`, owner `0xd349…8454d`, and configured keeper `0xCA11` each succeeded when invoked separately. The configured keeper was deliberately different from the random caller and owner. | `evidence/raw-logs.tar.xz::round6_controller_probes.log` |
| 2a | Short-window snapshot at `1794419999` | Config `(86400,64800,3600)`; window `[1794420000,1794423600)`; last-before `1794160800`; call reverted `OutOfRebalanceWindow()` (`0xb4675acc`). This is a separate snapshot from the default-window case. | `evidence/raw-logs.tar.xz::round6_controller_probes.log:255-258` |
| 2b | Default-window snapshot at `1794419999` | Config `(86400,64800,86400)`; window `[1794333600,1794420000)`; last-before `1794160800`; call succeeded and stored `lastRebalanceTimestampSec=1794333600`. | `evidence/raw-logs.tar.xz::round6_controller_probes.log:110-112` |
| 2c | Other window and cooldown boundaries | Under the short window, start and end−1 succeeded; end and end+1 reverted `OutOfRebalanceWindow()`. With `freq=86400`, `last+freq−1=1794419999` reverted `LastRebalanceTooRecent()` (`0xa3b3f090`), `last+freq=1794420000` succeeded, and isolated `nextStart+1=1794420001` succeeded. | `evidence/raw-logs.tar.xz::round6_controller_probes.log:113-145,223-258` |
| 3 | Zero-input-side `OpDisabled` guard | All six cases succeeded: SR-only `flashMint2`, `flashRedeem2`, and `redeem2` with SR base/flash-base fee `0` and zero-input JR base/flash-base fee `1000000000000000000`; and the mirrored JR-only calls with SR fee at WAD and JR fee `0`. This supports input-side-only guards for these three entry points; `mint2` was not probed. | `evidence/raw-logs.tar.xz::round6_controller_probes.log` |
| 4 | Zero-amount AUM mint and event | With rate `1`, SR supply `9581311974479` and JR supply `33850817003440`, both calculated mint amounts were `0`; rebalance succeeded and emitted two `AumFees` events with amounts `0`, plus two zero-value mint `Transfer` events. With rate `0`, it emitted no `AumFees` or mint `Transfer` events. | `evidence/raw-logs.tar.xz::round6_controller_probes.log` |
| 5 | Value-cap boundary and direction | With total reserve value `515764630`, cap `515764629`, and pre-`subDR=1000000000000000000`, SR-only input `1000` reverted `ValueCapExceeded()` (`0x8f61fa9a`). At cap exactly `515764630` and pre-`subDR=1049678448816785329`, JR-only input `1` (worsening) reverted with that selector, while SR-only input `1` (corrective) succeeded. Exact post-operation `subDR == 1e18` remains unproven. | `evidence/raw-logs.tar.xz::round6_controller_probes.log` |
| 6 | Lazy issue in `flashMint2` | After issue time `1794510000`, an SR-only flash mint at `1794510001` (`2000000` underlying) succeeded, increased SR supply from `9581311974479` to `9729516061528`, returned `147354487431` SR perp, and changed the latest bond from `0x93dc…177ca8` to `0xff7319…74181b`. A JR-only flash mint at `1795114801` (`2000000` underlying) succeeded with `175163276286` JR perp but left latest bond `0x93dc…177ca8` unchanged. | `evidence/raw-logs.tar.xz::round6_lazy_issue_probes.log`; earlier corroboration: `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1 |

## Verification

- `Round6ControllerProbe.t.sol`: **22 passed, 0 failed**.
- Existing lazy-issue follow-up: **2 passed, 0 failed**.
- The lazy issue follow-up uses fork block `54,990,962`; it sets `minMaturitySec=1` in the SR case so issue eligibility is reached without upkeep.
