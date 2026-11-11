# Round 14 — backup rollover execution vectors

Clean-room scope: the target public `PerpBalancer` ABI was called on the local Base Anvil fork at
block `54,990,962`. No target source or frontend bundle was read, and no real-chain transaction was
sent. Reproduce with:

```sh
BASE_RPC_URL=http://127.0.0.1:8545 forge test \
  --match-path evidence/round14-probes/Round14BackupExecutionProbe.t.sol -vv
```

The synthetic reserve state has `100` units of stale underlying, two ordered stale tranche rows
worth `400` and `300`, and a selected fresh senior row with `valueRatio = 0.5e18`.

| JR free liquidity | stale underlying | stale tranche amounts | fresh deposit | fresh SR amount | rolled value |
|---:|---:|---:|---:|---:|---:|
| 0 | 0 | none | 0 | 0 | 0 |
| 500 | 100 | 750, 0 | 500 | 500 | 250 |
| 1,199 | 100 | 1,000, 598 | 1,199 | 1,199 | 599 |
| 1,200 | 100 | 1,000, 600 | 1,200 | 1,200 | 600 |
| 2,000 | 100 | 1,000, 600 | 1,200 | 1,200 | 600 |

Observed rules for these vectors:

- stale underlying is consumed before stale tranches;
- stale tranche rows are consumed in their input order;
- a partial tranche amount is `floor(balance * remainingValue / trancheValue)`;
- the result contains one selected fresh deposit/SR row even when the amount is zero;
- `deposit = min(free, floor(totalStaleValue * 1e18 / selectedValueRatio))`;
- `underlyingValRolled = floor(deposit * selectedValueRatio / 1e18)`.

Verification: `1 passed, 0 failed`. Raw output is
`round14_backup_execution_results.log`; the evidence-only probe is
`round14-probes/Round14BackupExecutionProbe.t.sol`.
