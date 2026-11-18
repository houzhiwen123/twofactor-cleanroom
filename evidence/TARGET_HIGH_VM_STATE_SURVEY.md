# Target High-VM State Survey

## Boundary

This fixed 11-block public Base survey asks whether target 2Factor reached a `vmDR` comparable to the local high-VM input: `1.060773479096730879`.

It uses only local Foundry block forks and public `systemDeviations()` calls. No wallet, private key, signature, broadcast, `deal`, or `store` was used. It is a bounded sample, not a full history scan.

## Version lock

Every readable point has the same Controller version:

- Proxy: `0x682F3a053B0260daD4EbEee3924B1618B330A200`
- Implementation: `0x16e324BAe2098317477129a5E71f770bFf51f02a`
- Proxy codehash: `0x2439ee0ade6a1d06e3704a98bcd13ba2efd1426e8bf25d3456caa16f741f2e2e`
- Implementation codehash: `0xc18d3bcb6fb9e0f54b93f7d431901e13ee879a86502da786841e2f12d9606e31`

## Fixed samples

| Base block | Readable | subDR | vmDR |
|---:|:---:|---:|---:|
| 51,000,000 | no | N/A | N/A |
| 51,500,000 | no | N/A | N/A |
| 51,777,385 | yes | 1.025799406232600248 | 1.002206743712286605 |
| 52,250,000 | yes | 1.058124255418572710 | 0.998063048432670782 |
| 52,750,000 | yes | 1.051140705255981599 | 1.000127970148566184 |
| 53,243,583 | yes | 1.037957360646473772 | 1.003759218472700709 |
| 53,750,000 | yes | 1.044088086984864517 | 1.002269182964640096 |
| 54,250,000 | yes | 1.059521693190810143 | 0.998594484041626227 |
| 54,750,000 | yes | 1.055112499925392702 | 0.998792678872971450 |
| 54,990,962 | yes | 1.049678448816785329 | 1.000925651512358813 |
| 57,015,384 | yes | 1.049008142808840695 | 1.001085976679671604 |

## Result

The 9 readable block-end samples range from `0.998063048432670782` to `1.003759218472700709` for `vmDR`. None reaches `1.05`; none is close to the local `1.060773479096730879` input.

No high-VM candidate therefore exists in this fixed set, so no natural high-VM flash-exit replay was started. This is a **bounded no-observation result**, not proof that target 2Factor can never reach high VM deviation. It does not cover every block, intra-block state, or later/future state.

The local high-fee multi-epoch path remains `LOCAL CLEANROOM / BNB-DESIGN` pending a real target high-VM vector. No production contract changed.

## Reproduce

```sh
FOUNDRY_TEST=evidence/probe-tests BASE_RPC_URL=https://mainnet.base.org \
  forge test --match-path evidence/probe-tests/TargetHighVmStateSurvey.t.sol -vv
```
