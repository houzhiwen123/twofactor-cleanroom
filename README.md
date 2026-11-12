# 2Factor Phase 1a clean-room implementation

This repository is a behavioral reimplementation of the 2Factor protocol's Phase 1a components
(Bond layer, Oracle, FeePolicy, and Balancer) based on public ABIs, on-chain observations, and
black-box test vectors. No target source was used. The work is research/experimental, unaudited, and
not for mainnet use.

## Modules

- `src/oracle/CachedOracle.sol`: Chainlink answer validation, optional sequencer checks, exact
  18-decimal scaling, and an EIP-1153 per-transaction price cache.
- `src/bond/Tranche.sol`: manager-controlled ERC-20 tranche implementation intended for EIP-1167
  clones.
- `src/bond/BondsManager.sol`: oracle registry, issuer allow-list, bond creation and deposits,
  fractional immature redemptions, two-ceiling maturity settlement, and side-specific mature claims.
- `src/bond/BondIssuer.sol`: weekly issue-window scheduling and mature-bond cleanup.
- `src/policy/FeePolicy.sol`: piecewise-linear fees and bounded reserve-rebalance values.
- `src/policy/PerpBalancer.sol`: underlying-first rebalance plan, then tranche withdrawals ordered
  by time to maturity.
- `src/vault/UsdVault.sol`: clean-room USD Senior Vault core with exact paired mint quotes,
  USDC/Perp SR deposits and pro-rata exits. Session, capacity and rebalance behavior remain pending.
- `test/ref/`: independent integer settlement and rebalance models.
- `test/mocks/`: 8-decimal ERC-20, mutable Chainlink/sequencer feeds, and a settable price oracle.

Upgradeable contracts use OpenZeppelin v5.4.0 and are exercised behind
`TransparentUpgradeableProxy` instances. The tranche initializer follows the target public ABI
(`init(manager, bondID, underlying, maturityDate, isSenior)`), resolving a difference from the
prose signature in the Phase 1a description.

## Run

```sh
forge build
forge test
```

The test suite includes the supplied settlement, tranche value-ratio/VM, two-ceiling, FeePolicy
(`computeOpFees` and rebalance), and Balancer plan vectors, plus fuzz properties and independent
reference-model comparisons. Foundry's default fuzz run count is used.

## Unverified behaviors and implementation choices

- Fee curves are extended linearly beyond their first/last x coordinates. The VM `1.0 → 0.8`
  disabled-operation vector returns 100% only under this extrapolation behavior.
- For equal pre/post deviation, the selected direction is the Up curve and its point value is used.
  This agrees with the zero-at-target observations; non-target equal-point fees have no golden vector.
- `flashBasePerc` replaces `basePerc` for flash operations rather than adding to it; the supplied
  vectors all use zero base fees and are not discriminating.
- `TrancheData` edge handling is not observed: a capped Senior claim uses a WAD Senior multiplier and
  zero Junior multiplier; when total claim is zero, value ratios fall back to the configured
  tranche ratio and Senior volatility is zero. A zero Junior fallback ratio yields multiplier zero.
- The `redeem` convenience entry point (maturely redeeming both sides) and exact token metadata
  naming for arbitrary underlying assets lack dedicated target vectors. A mature claim with zero
  tranche supply remains unallocated and cannot be redeemed; this edge is also unobserved.
- `BondIssuer.updateIssuanceTimingConfig` rejects a zero interval and offsets greater than or equal
  to the interval; those invalid-configuration edges were not observed.
- The behavior notes describe 19 `computeRebalanceVal` vectors, but the authoritative
  `RECON_FINDINGS.md` contains 14 explicit numeric inputs. Tests also cover five fixed checks from
  the provided CoreInvariants test inputs; the CoreInvariants values overlap some of those 14.

These notes are behavioral boundaries, not security claims.

## Phase 1b scope

The pre-split 84/84 verification point, dependency revisions, runtime sizes and proxy storage
layout are frozen in [`docs/BASELINE_84.md`](docs/BASELINE_84.md). CI enforces formatting, the
24,000-byte general runtime ceiling, the 22,500-byte Controller ceiling and the frozen Controller
storage layout. The current stateless-math extraction and size verification are recorded in
[`docs/CONTROLLER_SIZE_REFACTOR.md`](docs/CONTROLLER_SIZE_REFACTOR.md).

`src/perp/PerpToken.sol` and `src/controller/PerpController.sol` implement the evidenced core
operations. The status matrix and explicit pending-evidence boundaries are in
[`docs/PHASE1B_STATUS.md`](docs/PHASE1B_STATUS.md). The public standard-rollover branch is now
implemented with the Round 9 call order and vectors. Rounds 13–14 close and implement backup
selection/execution, upkeep, the oracle configuration entries, and SR lazy rollover. Rounds 15–17
close `mint2`'s zero-input-side fee guard, observable `updateIssuer` approval rotation, exact
post-operation value-cap equality, extreme VM behavior, and a non-0.5 backup rollover executed
through the target Controller. The target's deployment-time genesis mechanism remains outside the
compatibility evidence. This repository now has a separate defensive local Genesis design with a
paused Controller, balanced tranche bootstrap, a bounded JR idle-underlying top-up to reach target
VM, locked minimum shares and a secret-free simulation;
see [`docs/GENESIS_INITIALIZATION.md`](docs/GENESIS_INITIALIZATION.md). It is a clean-room safety
design, not a claim about third-party deployment behavior. Round 12 closed the previously open Perp
recovery and reserve-array removal/order rules for the captured paths.

Round 6 fork probes confirmed permissionless rebalance calls, an inclusive-start/exclusive-end
rebalance window, input-side-only `OpDisabled` checks for `flashMint2`, `flashRedeem2`, and `redeem2`,
and zero-amount AUM fee events when the configured rate is positive. See
[`evidence/ROUND6_PROBES.md`](evidence/ROUND6_PROBES.md) for raw values and logs.

The first USD Vault implementation phase is recorded in
[`evidence/USD_VAULT_PHASE1.md`](evidence/USD_VAULT_PHASE1.md). It matches the version-locked
historical redemption vector, event order, floor rounding and insufficient-balance boundary. Its
proxy initializer and defensive guards are identified separately as local clean-room choices; the
unobserved operating state machines are not implemented. Phase 2 is recorded in
[`evidence/USD_VAULT_PHASE2_MINT_DEPOSIT.md`](evidence/USD_VAULT_PHASE2_MINT_DEPOSIT.md); it adds
five exact historical mint vectors, the target's two-stage Perp valuation rounding, paired asset
movement and deposit event order. Session/capacity and full target deposit preflight remain deferred.
