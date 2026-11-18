# Target SR Exit Liquidity Source

## Conclusion

The public historical-state replay proves that target 2Factor does **not** require Perp SR to hold
idle cbBTC for the observed SR flash redemption.

The externally observable target sequence is:

1. Perp SR starts and ends with zero idle cbBTC.
2. A tranche held by Perp SR is transferred to Perp JR.
3. cbBTC enters Perp JR during the same atomic call.
4. Perp JR transfers the complete gross cbBTC requirement to the Controller.
5. The Controller transfers the user output to the exiting holder.

In plain language: **the observed SR exit is funded through reserve assets moving into JR, while JR
acts as the cbBTC cashier.** The exact internal tranche-selection and recovery algorithm is not
established by this transfer-log probe. The clean-room implementation's guarded Balancer plan is an
independent compatible design and is classified separately below.

## Historical-state fork evidence

Probe: `evidence/probe-tests/TargetRealHolderExitReplay.t.sol`

- Network: Base, chain ID 8453.
- Strict historical prestate: transaction
  `0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab`, block `53,243,583`.
- Input assets came from the historical smart account's natural USD Vault note balance.
- The probe first redeemed those natural notes for their exact natural Perp SR output, then invoked the target
  Controller's SR-only `flashRedeem2` directly.
- No `deal`, `store`, wallet, private key, signature, or broadcast was used.

Observed values:

| Observation | Value |
|---|---:|
| Perp SR idle cbBTC before | 0 |
| Perp SR idle cbBTC after | 0 |
| Perp JR idle cbBTC before | 200,584,836 |
| cbBTC entering JR during the redemption call | 9,281 |
| cbBTC transferred JR → Controller | 4,723 |
| cbBTC transferred Controller → holder | 4,723 |
| Perp JR idle cbBTC after | 200,589,394 |
| SR tranche transfers into JR | 1 |
| Inactive JR returned total/protocol fee | 0 / 0 |

The JR accounting closes exactly:

`200,584,836 + 9,281 = 200,589,394 + 4,723`.

JR's ending idle cbBTC rises by `4,558`, even though it paid the exit, because more cbBTC entered JR
than this small redemption required. Looking only at JR's net before/after balance would therefore
give the wrong answer; the ERC-20 transfer trace establishes the gross payment path. Identifying the
exact internal recovery entry point requires separate black-box call-trace evidence and remains
outside this report.

## Clean-room deployment-model correction

The previous local Controller incorrectly moved `srGross` as raw cbBTC from Perp SR to Perp JR. That forced the
three-Vault acceptance test to mint `1,000,000` artificial cbBTC units directly to Perp SR.

The clean-room Controller now independently implements the observed asset-flow boundary by:

- obtaining the SR reserve data from `systemReserveState()`;
- using the guarded local Balancer to construct a bounded reserve plan;
- moving that reserve plan into JR;
- using the local canonical tranche-recovery path;
- withdrawing the complete gross cbBTC amount from JR;
- computing fees from the actual post-transformation state; and
- enforcing a post-operation JR liquidity floor.

The guarded planner choice, precise recovery routine and liquidity-floor implementation are
**LOCAL-CLEANROOM / BNB-DESIGN** unless a separate public-chain black-box probe establishes the same
internal boundary. They are not inferred from target source.

The artificial SR-liquidity fixture has been removed from `FullProtocolThreeVaultLifecycle.t.sol`. The complete
three-Vault lifecycle now passes while Perp SR has no dedicated idle exit reserve.

## Verification

- Target historical-state liquidity probe: 1/1 passed.
- Controller regression: 42/42 passed.
- Router regression group: passed.
- Genesis deployment regression: 20/20 passed.
- Complete three-Vault lifecycle: 1/1 passed without SR artificial liquidity.
- Full offline repository suite: 307/307 passed across 38 suites.
- Controller runtime: 21,519 bytes, below the repository limit of 22,500 bytes.
- Controller storage layout: frozen 84/84 entries matched.
- Formatting and diff checks: passed after the implementation update.

## Classification

- Historical-state transfer trace and exact amounts: **TARGET-CONFIRMED**.
- SR-zero-idle / SR-tranche-to-JR / JR-to-Controller / Controller-to-holder asset path:
  **TARGET-CONFIRMED** for the captured transaction prestate.
- Exact target tranche-selection function and internal recovery routine: **UNKNOWN** in this report.
- Local guarded Balancer plan, recovery execution and extra safety checks:
  **LOCAL-CLEANROOM / BNB-DESIGN**.
