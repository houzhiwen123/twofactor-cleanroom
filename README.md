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

`src/perp/PerpToken.sol` and `src/controller/PerpController.sol` implement the evidenced core
operations. The status matrix and explicit pending-evidence boundaries are in
[`docs/PHASE1B_STATUS.md`](docs/PHASE1B_STATUS.md). In particular, rollover/upkeep, recovery,
tranche removal/order changes, genesis seeding, and exact value-cap equality behavior are not
implemented as inferred behavior.
