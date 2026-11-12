# FeePolicy exact clean-room model

## Result

- Semantic-matrix side comparisons: `272`; mismatches: `0`.
- Rounding-closure observations: `4158`; mismatches: `0`.
- Combined exact predictions: `4430/4430` with no tolerance.

## Derived arithmetic

For one linear segment from `(x0, y0)` to `(x1, y1)`, let `[left, right]` be the part of the operation interval inside that segment and `dx = x1 - x0`.

For a rising segment (`dy = y1 - y0`):

```text
segmentAverage = y0
               + floor((left + right) * dy / (2 * dx))
               - floor(x0 * dy / dx)
```

For a falling segment (`dy = y0 - y1`):

```text
segmentAverage = y0
               + floor(x0 * dy / dx)
               - floor((left + right) * dy / (2 * dx))
```

An interval crossing curve knots is split at every knot. Each segment average is multiplied by its width, the areas are summed, and the final sum is divided by the complete interval width with floor rounding. Equal pre/post DR contributes zero. Each DR component is capped independently at `1e18`; base and both components are then summed without a final total cap.

## Evidence boundary

This formula was independently derived from target outputs. It was not copied from verified source or inferred from target source code. The verifier consumes the previously archived target matrices and must report zero mismatches.

## Reproduce

```sh
python3 script/verify_fee_policy_exact_model.py
```
