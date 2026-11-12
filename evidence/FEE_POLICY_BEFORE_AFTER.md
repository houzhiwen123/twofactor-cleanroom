# FeePolicy correction — before and after

## Compatibility result

| Vector or suite | Before | After | Target |
|---|---:|---:|---:|
| Original exit vectors | `0/40` | `40/40` | `40/40` |
| Semantic side comparisons | `184/272` | `272/272` | `272/272` |
| Independent exact model | unresolved | `4430/4430` | `4430/4430` |
| First frozen vector | `737786924881158484` | `24668775771025119` | `24668775771025119` |
| Extreme B-100 vector | `1e18` | `2e18` | `2e18` |

## Local Genesis exit examples

These are local clean-room lifecycle results, not claims that the target Controller has the same
Genesis state. The fee arithmetic for the same DR inputs is target-matched.

| Local exit row | Before | After |
|---|---:|---:|
| User-owned proportional, 1% | `737786924881158484` (73.778692%) | `24668775771025119` (2.466878%) |
| User-owned proportional, 100% | `745215475077769955` (74.521548%) | `32097325967636589` (3.209733%) |
| SR-only, 1% | `713118149110133366` (71.311815%) | `0` (0%) |
| SR-only, 100% | `947509560190094392` (94.750956%) | `234391411079961027` (23.439141%) |
| JR-only, 1% | `737905982056804770` (73.790598%) | `24787832946671404` (2.478783%) |
| JR-only, 100% | `750137099039168250` (75.013710%) | `37018949929034885` (3.701895%) |
| Total-supply proportional, 100% | `1e18`, `OpDisabled()` | `2e18`, `OpDisabled()` | FeePolicy returns `2e18` |

The regenerated 40-row report remains isolated by snapshot, marks B-mode 95% and 99% as `N/A`,
and confirms underlying conservation in every row.

## What changed

- Equal pre/post DR now contributes zero.
- Each DR impact is capped separately at `1e18`.
- The final total is no longer capped at `1e18`.
- Piecewise-linear averages use the target-matched absolute-coordinate rounding and split at knots.

No curve parameters, storage slots, interfaces, permissions, Controller code, or exit-product
designs were changed.
