# Round 6 — Controller behavior probes

All target calls used the local Base Anvil fork at `http://127.0.0.1:8545`, chain ID 8453,
fork block `54,990,962`. No verified source or frontend bundle was read, and no real-chain
transaction was sent.

Reproduce the focused matrix:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/Round6ControllerProbe.t.sol -vv
```

The lazy-issue follow-up used the existing Controller probe contract, which relies on Foundry's
fork option rather than creating a fork in `setUp()`:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test --fork-url http://127.0.0.1:8545 --fork-block-number 54990962 --match-path test/ControllerProbe.t.sol --match-test 'testReviewLazyFlashMint(SrAfterIssueWindowBeforeMaturity|JrWithStaleBond)' -vv
```

| # | Question | Result and discriminating raw values | Raw log |
|---|---|---|---|
| 1 | `rebalance()` caller authorization | Permissionless in the tested valid window: distinct random EOA `0xBEEF`, owner `0xd349…8454d`, and configured keeper `0xCA11` each succeeded when invoked separately. The configured keeper was deliberately different from the random caller and owner. | `/home/ubuntu/work/probes/round6_controller_probes.log` |
| 2 | Window and cooldown boundaries | With `updateRebalanceWindow(86400,64800,3600)`, window `[1794420000,1794423600)`: `1794419999` reverted `OutOfRebalanceWindow()` (`0xb4675acc`), `1794420000` and `1794423599` succeeded, and `1794423600` and `1794423601` reverted with the same selector. A successful call at `1794419999` stored `lastRebalanceTimestampSec=1794333600` (the window start), not the call time. With `freq=86400`, `last+freq-1=1794419999` reverted `LastRebalanceTooRecent()` (`0xa3b3f090`); `last+freq=1794420000` succeeded. An isolated call at `nextStart+1=1794420001` also succeeded. | `/home/ubuntu/work/probes/round6_controller_probes.log` |
| 3 | Zero-input-side `OpDisabled` guard | All six cases succeeded: SR-only `flashMint2`, `flashRedeem2`, and `redeem2` with SR base/flash-base fee `0` and zero-input JR base/flash-base fee `1000000000000000000`; and the mirrored JR-only calls with SR fee at WAD and JR fee `0`. This supports input-side-only guards for these three entry points; `mint2` was not probed. | `/home/ubuntu/work/probes/round6_controller_probes.log` |
| 4 | Zero-amount AUM mint and event | With rate `1`, SR supply `9581311974479` and JR supply `33850817003440`, both calculated mint amounts were `0`; rebalance succeeded and emitted two `AumFees` events with amounts `0`, plus two zero-value mint `Transfer` events. With rate `0`, it emitted no `AumFees` or mint `Transfer` events. | `/home/ubuntu/work/probes/round6_controller_probes.log` |
| 5 | Value-cap boundary and direction | With total reserve value `515764630`, cap `515764629`, and pre-`subDR=1000000000000000000`, SR-only input `1000` reverted `ValueCapExceeded()` (`0x8f61fa9a`). At cap exactly `515764630` and pre-`subDR=1049678448816785329`, JR-only input `1` (worsening) reverted with that selector, while SR-only input `1` (corrective) succeeded. Exact post-operation `subDR == 1e18` remains unproven. | `/home/ubuntu/work/probes/round6_controller_probes.log` |
| 6 | Lazy issue in `flashMint2` | After issue time `1794510000`, an SR-only flash mint at `1794510001` (`2000000` underlying) succeeded, increased SR supply from `9581311974479` to `9729516061528`, returned `147354487431` SR perp, and changed the latest bond from `0x93dc…177ca8` to `0xff7319…74181b`. A JR-only flash mint at `1795114801` (`2000000` underlying) succeeded with `175163276286` JR perp but left latest bond `0x93dc…177ca8` unchanged. | `/home/ubuntu/work/probes/round6_lazy_issue_probes.log`; earlier corroboration: `evidence/CODEX_REVIEW_PROBES.md` Round 1 H1 |

## Verification

- `Round6ControllerProbe.t.sol`: **22 passed, 0 failed**.
- Existing lazy-issue follow-up: **2 passed, 0 failed**.
- The lazy issue follow-up uses fork block `54,990,962`; it sets `minMaturitySec=1` in the SR case so issue eligibility is reached without upkeep.
