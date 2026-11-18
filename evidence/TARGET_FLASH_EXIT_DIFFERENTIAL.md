# Target Flash-Exit Differential

## Scope

Question: are the clean-room's previous 73.88%--83.69% cbBTC/flash-exit costs established target behavior?

Only public Base transaction-hash forks and read-only calls were used. No wallet, key, signature, broadcast, `deal`, or `store` was used. No target source was inspected.

| Item | Version lock |
|---|---|
| Network | Base, chain ID 8453 |
| Strict prestate | `0xaf7d86860fa149f0fdddb186f74753dc2b912294c7e4f4b1b8930934fe7144ab`, block `53,243,583`, transaction index `77` |
| Controller proxy / implementation | `0x682F3a053B0260daD4EbEee3924B1618B330A200` / `0x16e324BAe2098317477129a5E71f770bFf51f02a` |
| FeePolicy proxy / implementation | `0x1E3DbDc2aDF4d5fDd1efDFB9FF05e4154D0c00E8` / `0x9CEfc3cF756C6b2a7568B0539c956f1DD5691900` |

The probe verifies the locked EIP-1967 implementations and the proxy/implementation code hashes before every vector.

## Natural SR flash exit

The historical smart account redeems its natural USD Vault notes into `375,200,394` Perp SR, then calls target `flashRedeem2(perpSrOut, 0, 0)` on a local fork.

| Metric | Exact value |
|---|---:|
| SR returned total / protocol fee | `0` / `0` |
| JR returned total / protocol fee | `0` / `0` |
| cbBTC returned | `4,723` |
| pre/post subDR | `1.037908621221648993` / `1.037957360646473772` |
| pre/post vmDR | `1.003771134818793536` / `1.003759218472700709` |
| target / clean-room FeePolicy SR flash fee | `0` / `0` |

Classification: **TARGET-CONFIRMED** for target output, DR values, and transfers in this historical state; **SYNTHETIC FORK / natural balance** for the direct Controller call.

`TARGET_SR_EXIT_LIQUIDITY_SOURCE.md` retains the transfer trace: SR has no idle cbBTC, an SR tranche moves to JR, and JR routes cbBTC through Controller. Target tranche selection and recovery internals remain UNKNOWN.

## Same-state SR basket control

From an independent copy of the same strict prestate, the probe obtains the same natural Perp SR and calls `redeem2(perpSrOut, 0, 0)`.

| Metric | Exact value |
|---|---:|
| SR returned total / protocol fee | `0` / `0` |
| Basket underlying output / tranche entries | `0` / `3` |
| pre/post subDR | `1.037908621221648993` / `1.037957391606699294` |
| pre/post vmDR | `1.003771134818793536` / `1.003771134818793536` |
| target / clean-room FeePolicy SR basket fee | `0` / `0` |

Classification: **SYNTHETIC FORK / natural balance**. This is a same-state control, not a historical `redeem2` transaction replay.

## Local high-VM diagnostic

The previous high-fee regression is explicitly `LOCAL CLEANROOM / BNB-DESIGN`. Its 1% proportional flash exit changes `subDR` from `0.847534510909630408` to `0.847234148514625054` and `vmDR` from `1.060773479096730879` to `1.060883654856989096`.

The local returned fee is `0.738808066073795619` WAD per side. The target public `FeePolicy.computeOpFees`, called read-only with that identical DR pair, returns exactly `0.738808066073795619`. The clean-room FeePolicy configured from public target parameters returns the same value.

Classification: **TARGET-CONFIRMED FeePolicy semantics on SYNTHETIC input** plus **LOCAL CLEANROOM state construction**. This proves target's curve admits that fee at that DR transition. It does not prove target Controller reserve movements can reach it from the local multi-epoch lifecycle.

## Conclusion

The claim that target 2Factor necessarily charges 70%+ for proportional cbBTC exit is **not supported**: the natural target SR flash vector returns zero SR fee.

The local high result is **not a FeePolicy arithmetic mismatch**. Target's curve returns the same high fee for the local high-VM input. It remains UNKNOWN whether the local multi-epoch reserve/recovery state is target-compatible.

No FeePolicy or production Controller code changed. The local high-fee state remains a release/economic concern, not a target-incompatibility finding.

## Reproduce

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path evidence/probe-tests/TargetRealHolderExitReplay.t.sol \
  --match-test 'test(RouterHistoricalSr(ExitLiquiditySource|BasketExitFeeControl)|TargetFeePolicySyntheticLocalHighVmDr)' -vv

forge test --offline --match-path test/GenesisDeployment.t.sol \
  --match-test testGenesisProportionalBasketAndFlashExitComparison -vv
```
