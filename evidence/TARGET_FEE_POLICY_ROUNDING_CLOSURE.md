# Target FeePolicy rounding closure matrix

Clean-room black-box evidence from a fresh local proxy backed by the code-locked target implementation at public Base block `54,990,962`. The deployed target proxy is not mutated.

## Coverage

- Exact observations: `4158`; successful: `4158`; reverts: `0`.
- Rising and falling `32/43` segments: every origin shift `0..42` and every adjacent one-wei interval `0..42`.
- Falling `4/5` controls: every origin shift and adjacent interval `0..4`.
- Both lower/upper cross-knot intervals and independent near-`p1` / near-`p4` controls.

## First-interval coordinate fingerprints

The following values are ordered by origin shift. They are exact target WAD integer outputs, not percentages rounded for display.

- Rising `32/43`, `WAD + shift`: `1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0`
- Rising `32/43`, `TARGET_X + shift`: `0,0,1,1,0,0,1,1,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,1,1,0,0,1,1,0,0,1,1`
- Falling `32/43`, `WAD + shift`: `31,31,32,32,31,31,32,32,31,31,32,32,31,31,32,32,31,31,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32`
- Falling `32/43`, `TARGET_X + shift`: `32,32,31,31,32,32,31,31,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32,32,31,32,32,31,31,32,32,31,31,32,32,31,31`

## Group summary

| group | rows | unique target outputs |
|---|---:|---|
| inc_32_43_residue_grid | 1849 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |
| inc_32_43_target_band_first_interval | 43 | `0, 1` |
| inc_32_43_cross_lower_knot | 43 | `0` |
| inc_32_43_cross_upper_knot | 43 | `31, 32` |
| dec_32_43_residue_grid | 1849 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |
| dec_32_43_target_band_first_interval | 43 | `31, 32` |
| dec_32_43_cross_lower_knot | 43 | `32` |
| dec_32_43_cross_upper_knot | 43 | `0` |
| dec_4_5_residue_grid | 25 | `0, 1, 2, 3, 4` |
| dec_4_5_target_band_first_interval | 5 | `3, 4` |
| inc_32_43_near_p1_control | 43 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |
| inc_32_43_near_p4_control | 43 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |
| dec_32_43_near_p1_control | 43 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |
| dec_32_43_near_p4_control | 43 | `0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32` |

## Surrounding-point controls

These controls keep the tested `p2/p3` segment unchanged while moving only `p1` or `p4`. Full rows are in the JSON.

- inc_32_43_near_p1_control: `0,1,2,3,3,4,5,6,6,7,8,8,9,10,11,11,12,13,14,14,15,16,17,17,18,19,20,20,21,22,23,23,24,25,26,26,27,28,29,29,30,31,32`
- inc_32_43_near_p4_control: `0,1,2,3,3,4,5,6,6,7,8,8,9,10,11,11,12,13,14,14,15,16,17,17,18,19,20,20,21,22,23,23,24,25,26,26,27,28,29,29,30,31,32`
- dec_32_43_near_p1_control: `32,31,30,29,29,28,27,26,26,25,24,24,23,22,21,21,20,19,18,18,17,16,15,15,14,13,12,12,11,10,9,9,8,7,6,6,5,4,3,3,2,1,0`
- dec_32_43_near_p4_control: `32,31,30,29,29,28,27,26,26,25,24,24,23,22,21,21,20,19,18,18,17,16,15,15,14,13,12,12,11,10,9,9,8,7,6,6,5,4,3,3,2,1,0`

## Reproduce

```sh
BASE_RPC_URL=https://mainnet.base.org python3 script/export_fee_policy_rounding_closure.py
```

- Probe SHA-256: `f1df2b2a535f4e36b511011944da83638eeb18a74cc393e0ef16fa97633380af`
- No verified source, wallet, private key, signature, broadcast, `deal`, or `store` is used.
