# Phase 1a spec — Bond layer, Oracle, FeePolicy, Balancer (clean-room)

Authoritative inputs: this file + docs/RECON_FINDINGS.md (black-box observations of the Base deployment).
Clean-room rule: do NOT open or copy anything under ~/work/2factor/verified-source or the frontend bundle.
ABIs in ~/work/abis and ~/work/2factor/components/abis are public interface facts and may be used for names/signatures.
WAD = 1e18. Underlying = 8-decimals ERC20 (mock in tests). Solidity 0.8.24, cancun, optimizer 200, OpenZeppelin v5 (contracts + contracts-upgradeable).

## Governance shape (mirror target)
- BondIssuer, BondsManager, FeePolicy (and later PerpController): upgradeable via OZ TransparentUpgradeableProxy, Initializable `init(...)`, Ownable2StepUpgradeable.
- Oracle, PerpBalancer: plain (non-proxy) contracts. Balancer functions are `pure`.
- Tranche tokens: EIP-1167 clones of a Tranche template, created by BondsManager.

## 1. CachedOracle (`src/oracle/CachedOracle.sol`)
constructor(feed, staleAfter=3600, sequencerFeed, gracePeriod=3600). Getters FEED, STALE_AFTER, SEQUENCER_FEED, GRACE_PERIOD, DECIMALS (= feed decimals).
getValidPrice(): if a cached price exists in this tx return it; else validate:
- sequencer: answer != 0 -> SequencerDown(); block.timestamp - startedAt < GRACE_PERIOD -> SequencerDown() (boundary: == GRACE is OK).
- feed: answer <= 0 -> ZeroPrice()/InvalidPrice(); updatedAt == 0 or answeredInRound < roundId -> InvalidPrice(); block.timestamp - updatedAt > STALE_AFTER -> InvalidPrice() (== STALE_AFTER is OK).
- returns answer scaled to 18 decimals exactly.
cachePrice()/resetCache(): transient storage (tstore/tload) cache of the validated price for the current tx.

## 2. Tranche (`src/bond/Tranche.sol`)
ERC20 clone: init(name, symbol, decimals=8, manager, bondID, isSenior). mint/burn only by manager. Views bondID(), manager(), isSenior().

## 3. BondsManager (`src/bond/BondsManager.sol`, upgradeable)
Storage per bond: underlying, srTrancheRatio (uint64), isMature, maturityDate (uint64), senior, junior, openPrice, underlyingBal, srClaim, jrClaim.
- Asset oracle registry: owner sets oracleOf(asset); assetPrice(asset) = oracle.getValidPrice().
- Issuer allow-list: only allowed issuers may createBond.
- bondID = keccak256(abi.encode(address(this), underlying, srTrancheRatio, maturityDate, openPrice)) — matches target exactly (see RECON).
- createBond(underlying, srTrancheRatio, maturityDate): openPrice = assetPrice(underlying); deploy two Tranche clones; emit BondCreated(bondID, underlying, ratio, maturity, senior, junior, openPrice).
- deposit(bondID, U): before maturity only. totalTranche = floor(U*openPrice/1e18); senior = floor(totalTranche*r/1e18); junior = totalTranche - senior. underlyingBal += U. emit BondDeposit.
- redeemImmature(bondID, srAmtAvail, jrAmtAvail): f = min(sr/srSupply, jr/jrSupply) via cross-multiplication; srBurn = floor(srSupply*f), jrBurn = floor(jrSupply*f); underlyingOut = floor(underlyingBal * srBurn / srSupply) (verify against BOND_EDGE_FORMULAS.md / BEHAVIOR_FORMULAS.md vectors; follow the docs if they state otherwise). emit TranchesRedeemed.
- mature(bondID) / tryMature(bondID) returns bool: permissionless, requires block.timestamp >= maturityDate. closePrice = CURRENT assetPrice at execution (confirmed). Settlement:
  baseSenior = ceilDiv(B*r, 1e18); rawSenior = ceilDiv(baseSenior*openPrice, closePrice); srClaim = min(B, rawSenior); jrClaim = B - srClaim. Two ceilings, never merged. emit BondMature(bondID, srClaim, jrClaim, closePrice).
  computeSettlement(r, B, openPrice, closePrice) pure view of the same.
- redeemMature(bondID, isSenior, amt): auto-matures if needed; out = floor(claimBefore*amt/supplyBefore); last burner gets residual dust. emit TranchesRedeemed (side not redeemed = 0).
- trancheData(bondID, isSenior) returns the TrancheData struct (field order exactly as target ABI):
  trancheSupply, trancheClaim, totalClaim, volatilityMultiplier, underlyingOpenPrice, isMature, secondsToMaturity, trancheRatio, valueRatio, bondID, isSenior, tranche, counterpart, manager.
  Immature: (srClaim, jrClaim) = computeSettlement(r, underlyingBal, openPrice, currentPrice); totalClaim = underlyingBal;
  valueRatio = floor(claim*1e18/totalClaim); senior vm = 0; junior vm = floor(1e36 / jrValueRatio).
  Edge cases not observed on chain (choose and document in code + README "unverified" list): senior capped (srClaim == B) -> senior vm = 1e18, junior vm = 0; totalClaim == 0 -> valueRatio = trancheRatio-based, vm as uncapped; mature -> use stored claims, same vm rules.
- Other views per target ABI: bondsData, data, isMature, isValidBond, isValidTranche, maturityDate, secondsToMaturity, srTranche, jrTranche, tranches, underlying, bondClaim, assetAt/assetCount, oracles.
Golden vector (must pass): bond B=77232982, r=0.5e18, open=81145332071360000000000, current=75056153820660000000000 -> srClaim 41749382, jrClaim 35483600, srValueRatio 540564159493414355, jrValueRatio 459435840506585644, jrVM 2176582477538919392. Matured example: B=168577, r=.5e18, open=84015086985250000000000, close=81145332071360000000000 -> srClaim 87270, jrClaim 81307. Two-ceiling counterexample B=999999, r=.7e18, open 90e18, close 110e18 -> 572728/427271.
Also port every numeric vector from ~/work/2factor/BOND_EDGE_FORMULAS.md and BEHAVIOR_FORMULAS.md (Bond sections) into tests.

## 4. BondIssuer (`src/bond/BondIssuer.sol`, upgradeable)
init(bondsManager, underlying). Config: srTrancheRatio=0.5e18, maxMaturitySec=2419200, minIssueTimeIntervalSec=604800, issueWindowOffsetSec=68400; updateBondConfig, updateIssuanceTimingConfig (owner).
issue() returns (bool issued, BondInfo latest): issue window start = floor((ts - offset)/interval)*interval + offset; if window start > lastIssueWindowTimestamp: create bond with maturityDate = windowStart + maxMaturitySec, set lastIssueWindowTimestamp = windowStart, push to activeBondIDs; else no-op false. (Live: all maturities ≡ 68400 mod 604800.)
cleanupMature(): matures (tryMature) and removes matured bonds from activeBondIDs; returns whether anything changed. Views activeBondIDs, latestBondID, latestBondInfo (manager, bondID, srTranche, jrTranche).

## 5. FeePolicy (`src/policy/FeePolicy.sol`, upgradeable)
Structs: Point{x,y}; Curve{p1,p2,p3,p4}; Fees{subDRUp, subDRDown, vmDRUp, vmDRDown, basePerc(uint64), flashBasePerc(uint64)}; Range{lower,upper}; Debasement{lag(uint64), tvlPercLimits(Range)}.
Per side (perpSrFees/perpJrFees, perpSrDebasement/perpJrDebasement), perpSrAUMFeePerc, perpJrAUMFeePerc, protocolMaxOpFeePerc, protocolFeeCollector. Owner setters per target ABI (updateFeeParams, updateAumFeePerc, updateProtocolFeeConfig, updateRebalanceParams). Validate: curves x non-decreasing (else InvalidParamDefn), percents <= 1e18 (InvalidPerc), lower<=upper (InvalidRange).
computeOpFees(OpFeeInput{isPerpSrOp,isFlashOp,OpSystemChange{subDRPre,subDRPost,vmDRPre,vmDRPost}}) -> OpFees{totalFeePerc, protocolFeePerc}:
  fees = side fees; total = isFlashOp ? flashBasePerc : basePerc (check: maybe base+flash — no data, all zero; pick flash replaces base and note it);
  total += avg(subDRPost>pre ? subDRUp : subDRDown, pre, post) + avg(vm curve likewise);
  avg(curve,a,b): a==b -> curve value at a; else integral of piecewise-linear curve over [min,max] / (max-min). Outside [p1.x, p4.x] extend the end segment linearly? or flat? -> decide from vectors below; flat extension of the endpoint y is the default hypothesis.
  total = min(total, 1e18); protocolFeePerc = min(total, protocolMaxOpFeePerc).
  Golden vectors (live curves, both sides identical, flash=false), all must match EXACTLY (bit-for-bit), tune integration rounding until they do; if impossible, stop and report:
   sub 1->1.2: 11549414793129602 ; 1.2->1: 1607449202625840 ; 1->0.8: 23095912909054698 ; 0.8->1: 0 ; 1->1.5: 21540710379864000 ; 1->2: 31578350210000000 ; 1->0.5: 27579927424212248 ; 0.9->1.1: 854808339014020
   vm 1->1.2: 1e18 ; 1->0.8: 1e18 ; 1->1.05: 153353658536585365 ; 1->0.95: 165384616565088768 ; all-1e18 input: 0
computeRebalanceVal(srTVL, jrTVL, tsr) -> (val, isPerpSrPayer): targetSr = floor(total*1e18/(tsr+1e18)); imbalance = |srTVL - targetSr|; 0 -> (0,false); payer = SR iff srTVL > targetSr; d = payer debasement; val = min(imbalance, clamp(imbalance/lag, payerTVL*lower/1e18, payerTVL*upper/1e18)). All vectors in RECON_FINDINGS (19 of them) must match exactly.
Default params = live values in RECON_FINDINGS.

## 6. PerpBalancer (`src/policy/PerpBalancer.sol`, plain, pure)
Structs ReserveTrancheData{TrancheData data; uint256 balance; uint256 value}, ReserveData{underlyingBal, ReserveTrancheData[] trancheData}, TokenAmount, ReserveAmounts{underlyingAmt, TokenAmount[] trancheAmts}.
computeSystemRebalancePlan(reserves, rebalVal): consume underlying first, then tranches sorted by secondsToMaturity ascending; tranche amount = floor(balance*remaining/value) when partial, else full balance; total covered < rebalVal -> InsufficientRebalance(); rebalVal 0 -> empty plan.
Vector (from fork test): underlying 100; tranche later(bal 1000,value 1000? see helper _balancerTranche in ~/work/2factor/fork-test/test/TwoFactorCoreInvariants.t.sol), earlier(...); rebalVal 500 -> underlying 100, earlier 600, later 200; 901 -> revert. Read that test helper to reconstruct inputs exactly.
Rollover-plan functions (computePerpSrRolloverState/Plan, computeRolloverPolicy, computeBackupRolloverPolicy, computePerpJrLiquidity) are Phase 1b — leave out.

## 7. Tests
Foundry unit tests with all golden vectors above; fuzz: bond settlement conservation (srClaim+jrClaim==B, srClaim<=B), immature redeem never pays more than pro-rata, mature claims sum <= B and last burner empties; fee avg monotonic sanity; rebalance val <= imbalance and <= payer cap. An independent integer reference model (test/ref/*.sol) for settlement and rebalance used in fuzz equivalence.
