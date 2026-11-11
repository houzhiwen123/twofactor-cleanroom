# Round 15 — Controller fee-side, issuer and genesis gaps

## Scope

These observations used public Base state at block `54,990,962` through a local Foundry fork.
Only public ABI calls, local deployments, local state mutation and simulated transactions were
used. No target source or frontend bundle was read, and no real-chain transaction was signed or
broadcast.

Reproduce:

```sh
BASE_RPC_URL=https://mainnet.base.org \
FOUNDRY_TEST=evidence/round15-probes \
forge test --match-path evidence/round15-probes/Round15ControllerGapProbe.t.sol \
  --no-proxy --via-ir -vv

BASE_RPC_URL=https://mainnet.base.org \
FOUNDRY_TEST=evidence/probe-tests \
forge test --match-path evidence/probe-tests/Round4GenesisProbe.t.sol \
  --no-proxy --via-ir -vv
```

Results: **4/4** Controller-gap tests and **1/1** fresh-genesis test passed.

## Observations

| Question | Target observation | Consequence |
|---|---|---|
| Does `mint2` inspect the zero-input side fee? | No. SR-only mint succeeded with JR base fee at `1e18`; JR-only mint succeeded with SR base fee at `1e18`. The zero side returned fee `(0,0)`. | Only input sides call `computeOpFees` and participate in the `OpDisabled` guard. |
| What does `updateIssuer` validate? | A contract returning any nonzero BondsManager was accepted, including a wrong manager. Zero and EOA issuers reverted with empty data. A zero manager reached the JR approval and reverted `ERC20: approve to the zero address`. | Validation is observable through the `bondsManager()` read and JR approval, not an address registry check. |
| How are approvals rotated? | The old manager allowance became `0`; the new manager allowance became `uint256.max`. | Revoke old JR underlying approval, prime the new one, and commit the issuer only after both calls succeed. |
| Can ordinary flash mint bootstrap an empty system? | No. With supply and reserves at zero, first SR flash mint reverted with arithmetic panic `0x4e487b71`; supply and reserves stayed zero. | Genesis seeding is still a deployment-process gap. Do not invent an automatic first-mint price. |
| AUM parameter boundary | `1e18-1` succeeded; `1e18` and `1e18+1` reverted `0xcdc62692`. | AUM percentages must be strictly below 100%. |

## Implementation status

The input-side-only `mint2` fee path and atomic issuer approval rotation are implemented and have
offline regression tests. Genesis bootstrap remains deliberately unimplemented because its target
deployment mechanism has not been observed.

Summary output: `round15_controller_gap_results.log`.
