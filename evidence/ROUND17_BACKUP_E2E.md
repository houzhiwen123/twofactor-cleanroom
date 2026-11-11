# Round 17 — non-0.5 backup rollover through Controller

## Scope

The target Controller, Balancer, Perps and BondsManager were executed only on a local Foundry fork
of public Base block `54,990,962`. The +30% oracle price, upkeep, liquidity threshold and rollover
calls existed only in the disposable fork. No target source or frontend bundle was read, and no
real transaction was signed or broadcast.

Reproduce:

```sh
BASE_RPC_URL=https://mainnet.base.org FOUNDRY_TEST=evidence/round17-probes \
forge test --match-path evidence/round17-probes/Round17BackupEndToEndProbe.t.sol \
  --no-proxy --via-ir -vv
```

Result: **1 passed, 0 failed**.

## Observation

At a +30% price shift the target planner selected Bond
`0x342b…108d`, whose Senior `valueRatio` was `0.414961863727109880`, not `0.5e18`.

| JR free / deposit | Planned rolled value | Controller result |
|---:|---:|---|
| `2,000,000` | `829,923` | reverted `InsufficientRollover()` because the result was below the `1,000,000` cleanup threshold |
| `2,500,000` | `1,037,404` | succeeded |

On success, the selected SR tranche balance in Perp SR changed from `3,392,625,737,181` to
`3,493,542,621,620`; the paired JR tranche in Perp JR changed from `3,392,625,737,183` to
`3,493,542,621,622`.

This closes the earlier evidence gap between public planner output and stateful Controller
execution for a non-0.5 backup selection. The generic Controller executor and Balancer backup
formula already cover this path; no new Controller bytecode was added. Summary output:
`round17_backup_e2e_results.log`.
