# Black-box recon findings (read-only eth_call on Base, latest block ~54.98M)

## computeDRs (PerpController 0x682F..A200, pure) — CONFIRMED by synthetic probes
subDR = floor(jrReserveValue * 1e36 / (srReserveValue * targetSystemRatio))
  - srValue == 0 -> returns 2^120 - 1 ; jrValue == 0 -> 0
  - srVM / supplies do not affect subDR
vmDR  = floor(jrVM * 1e18 / targetPerpJrVM)
Vectors: (sr100,jr300,tsr3e18)->1e18; (100,600)->2e18; (100,150)->5e17;
 (100,300,tsr2.847475019e18)->1053564993540686089; (1000,2847,2.847475019e18)->999833178870111098;
 (7,13,1e18)->1857142857142857142; jrVM 2e18 / tvm 1.333333333e18 -> 1500000000375000000;
 jrVM 1e18 / 1.333333333e18 -> 750000000187500000

## Live state
systemReserveState: SR (supply 9581311974479, value 128490118, vm 0); JR (supply 33850817003440, value 387274512, vm 1331780465841759294)
systemDeviations: subDR 1058496106120141102, vmDR 998835349631028307
=> SR reserve vm == 0 (only senior tranches); jrVM ~= 1 + srV/jrV (1.33178 at ratio 3.014).
=> target 2.847 vs 1.333 not mutually consistent under SR vm=0 (at R=2.847 jrVM would be ~1.351). Earlier "SR ~5% BTC exposure" inference was WRONG.

## Maturity price
BondsManager.mature(bytes32 bondID) takes no price arg; has assetPrice(address) view; BondMature event emits closePrice.
=> closePrice likely = oracle price at mature() execution time (to verify against BondMature events).
RPC notes: publicnode needs token for archive; mainnet.base.org supports archive eth_call (rate-limited); drpc getLogs max 10k blocks; blockscout behind Cloudflare.

## Maturity price — CONFIRMED (execution-time oracle price)
Bond 0xd6f5d200...b557: maturityDate 1792695600, srRatio 0.5e18, openPrice 84015086985250000000000.
Tx 0x8aeb7a4b...e3c3 (block 52953160, ts 1792695667 = maturity+67s, from 0xba887c8e.. via Multicall3) emits
BondMature(srClaim 87270, jrClaim 81307, closePrice 81145332071360000000000).
BondsManager.assetPrice(cbBTC) at block 52953159 = 81145332071360000000000 == closePrice.
mature(bytes32) has no price argument => closePrice = live oracle (0x636AF09C.., CachedOracle) price at mature() execution; permissionless (tryMature).

## Tranche valuation (BondsManager.trancheData, live) — CONFIRMED on 3 active bonds
trancheClaim(side) = computeSettlement(srRatio, underlyingBal, openPrice, CURRENT assetPrice) (two-ceil formula, current price)
valueRatio(side)   = floor(trancheClaim * 1e18 / underlyingBal)   (sr+jr = 1e18 - 1 possible)
vm(senior) = 0 (uncapped case observed); vm(junior) = floor(1e36 / jrValueRatio)
trancheSupply: sr = floor(B*Popen/1e18 * r/1e18) style; junior gets dust (+2..+7)
Edge cases (senior capped -> sr vm?, jr claim 0 -> jr vm?) NOT observed.

## BondID — CONFIRMED
bondID = keccak256(abi.encode(manager, underlying, uint64 srRatio, uint64 maturityDate, uint256 openPrice))

## BondIssuer config (live)
maxMaturitySec 2419200 (28d), minIssueTimeIntervalSec 604800 (7d), issueWindowOffsetSec 68400, srTrancheRatio 0.5e18
4 active bonds, maturities spaced exactly 604800 apart (e.g. 1794510000, 1795114800, 1795719600, 1796324400)

## FeePolicy.computeRebalanceVal — CONFIRMED (10 probes)
targetSrTvl = total/(tsr+1) (WAD); imbalance = |srTVL - targetSrTvl|; val = floor(imbalance/lag), lag=168
payer: SR if srTVL > targetSrTvl else JR
clip: SR payer <= srTVL * 0.6/365.25 (1e10 -> 16427105); JR payer <= jrTVL * 0.2/365.25 (1e10 -> 5475702) — rounding (ceil/nearest?) TBD from tvlPercLimits getters
vectors: (1e10,5e9,1)->14880952 SR; (1e10,2e10,1)->10951404 JR; (1e11,5e10,1)->148809523 SR; (1e10,3e10,3)->0; (1e10,2e10,3)->14880952 SR; (1e10,4e10,3)->14880952 JR; (1e10,0,1)->16427105 SR; (0,1e10,1)->5475702 JR; (128490118,387274512,2.847475019)->33110 JR
ABIs for controller impl/feepolicy impl/balancer/oracle saved in ~/work/abis (from Sourcify).

## FeePolicy params (live, SR and JR identical) — getters perpSrFees()/perpJrFees()
4 piecewise-linear curves, 4 points each (x,y WAD):
subDRUp:   (0,0) (1.078564994,0) (1.105439994,0.02) (2,0.05)
subDRDown: (0,0.05) (1.003564994,0.02) (1.028564994,0) (2,0)
vmDRUp:    (0,0) (1,0) (1.025,0.05) (1.07625,1)
vmDRDown:  (0.928571429,1) (0.975,0.05) (1,0) (2,0)
basePerc=0 flashBasePerc=0; AUM fees 0; protocolMaxOpFeePerc 0
Debasement: SR lag 168, tvlPercLimits (lower 13689300000000, upper 1642710500000000); JR lag 168, (4544800000000, 547570200000000)
=> rebalance clip upper = floor(tvl*upper/1e18) exact match.

## computeOpFees semantics — CONFIRMED by hand integration
Curve choice by direction: post>pre uses *Up curve, post<pre uses *Down curve; fee = average of curve over [min(pre,post), max] (integral / width); pre==post -> 0 at target (point value presumably).
total = base(+flash) + subDR term + vmDR term, clipped at 1e18 (vm 1->1.2 and 1->0.8 return exactly 1e18 = disabled). Outside curve x-range behavior: TBD (likely extrapolate/clamp, then cap 1e18).
Golden vectors (sr and jr identical, flash=false):
 sub 1->1.2: 11549414793129602 ; 1.2->1: 1607449202625840 ; 1->0.8: 23095912909054698 ; 0.8->1: 0
 sub 1->1.5: 21540710379864000 ; 1->2: 31578350210000000 ; 1->0.5: 27579927424212248 ; 0.9->1.1: 854808339014020
 vm 1->1.2: 1e18 ; 1->0.8: 1e18 ; 1->1.05: 153353658536585365 ; 1->0.95: 165384616565088768

## Rebalance clip — CONFIRMED
val = min(imbalance, clamp(floor(imbalance/lag), floor(payerTVL*lower/1e18), floor(payerTVL*upper/1e18))); imbalance==0 -> (0,false)
vectors tsr=3, sr=1e10: jr=2.99e10 ->148809 SR; 2.999e10 ->136893 SR (lower clamp); 2.99999e10 ->25000 SR (=imbalance); 3.00001e10 ->25000 JR; 3.01e10 ->148809 JR

## Perp tokens: "cbBTC Senior"/"cbBTC-SR", "cbBTC Junior"/"cbBTC-JR", 8 decimals, direct (non-proxy), owner Safe, controller() = PerpController.
Perp supply is ~USD-denominated (SR 95,813 tokens vs ~$96.4k value) => genesis perp units track tranche units (B*Popen/1e18). INFERRED.
## Bond schedule: all maturities ≡ 68400 mod 604800 (Thursdays 19:00 UTC); 28d term, new bond every 7d, 4 active.

## Controller fork probes (raw: ~/work/probes/CONTROLLER_PROBES.md, 940 OBS records) — summary
- flashMint2: perpOut = floor(underlyingIn * preSupply / preReserveValue), then fee taken in perp tokens (kept by Controller, collectedFeeBal == Controller balance == OpFees.totalFeeAmt). SR-only mint: whole cbBTC goes to SR reserve as IDLE underlying; JR side untouched (no tranching at mint).
- flashRedeem2: gross = floor(perpIn * preReserveValue / preSupply); fee kept in cbBTC. JR redeem above floor(supply*availPerpJrLiquidity/reserveValue) -> OpDisabled() 0x07380a2e.
- mint2: tranche value = floor(amt * trancheValue / trancheSupply) per tranche; perps from that value pro-rata.
- rebalance(): moved 28296 underlying JR->SR, Rebalance(28296,false); immediate repeat -> LastRebalanceTooRecent().
- upkeep()/rollover(): create new bonds, move tranche positions; flashMint2 alone did NOT lazily issue/mature.
- pauseUserOps -> UserOpsPaused 0xb3d197c4 on flashMint2/flashRedeem2/mint2/redeem2; pauseSystemOps -> SystemOpsPaused 0x237af6f0 on rebalance/upkeep/rollover.
- Open: rollover exact plan, fee-settlement to JR, outside-window revert, unidentified perp event topic 0xd1f...

## Rollover observation #1 (fork, ts 1794510001, after upkeep issued bond 0xff73.. maturity 1796929200) — lead analysis
Before SR tranches (bal,value,secsToMat): A 3149185188264/42084862/2135832, B 3133547705520/41875890/926232, C 3392625737181/45338138/1531032; SR U=0. JR mirrors (A 3149185188266, B 3133547705527, C 3392625737183), JR U=271549615.
rollover(): redeemImmature of bond B (secsToMat 604799 < minMaturitySec 604800) both sides -> 77232982 cbBTC; deposit 77245228 into new latest bond (=77232982 + 12246 from JR idle); deposit 6411258 into bond A (from JR idle) -> A bal 3392625912951 ≈ C bal 3392625737181 (equalizes per-bond tranche amount?). JR U 271549615 -> 265126111 (-6423504 = 6411258+12246).
SR side gets only senior tranches, JR side only junior; both sides' tranche counts stay equal per bond. Exact policy (amount targets) NOT yet derived -> probe PerpBalancer.computeRolloverPolicy / computePerpSrRolloverState / computeBackupRolloverPolicy / computePerpJrLiquidity directly.

## Rollover allocation rule — CONFIRMED 35/35 (33 direct policy cases + 2 real rollovers; ~/work/probes/ROLLOVER_PROBES.md "Allocation rule")
stale = SR rows with secondsToMaturity <= minMaturitySec; S = SR idle + Σ stale SR values; fresh rows ordered by maturity asc, last = latest bond.
avgTarget = ceil((S + Σ v_fresh)/N); target = max(avgTarget, max v over fresh rows except last)
for non-last rows in order: topUp = min(max(target - v,0), remaining); remaining -= topUp; last gets remaining.
underlyingAmt_i = ceil(topUp_i * 1e18 / valueRatio_i)   (valueRatio from trancheData, senior side)
Standard plan used iff its total deploy <= free + unlocked; else backup: total = min(free, 2*S) (into latest bond).
free = max(JR idle - reservedPerpJrLiquidity, 0); unlocked = SR idle + Σ floor(jrBal * jrTotalClaim / jrSupply) over stale bonds.
Unpaired stale SR = max(srBal - floor(jrBal*srSupply/jrSupply), 0).
Call path: rollover() -> Balancer.computePerpSrRolloverPlan -> stale SR tranche to JR -> BondsManager.redeem pair -> perpJr.bondDepositsForRollover -> deposits -> new SR tranches JR->SR.
Untested: varying open/current price at fixed valueRatio.

## Controller probes round 2 (~/work/probes/CONTROLLER_PROBES_2.md) — CONFIRMED unless noted
- Perp event 0xd1fb..6939 = ReserveSynced(address token, uint256 balance) (emitted on reserve balance changes).
- reservedPerpJrLiquidity = max(floor(JR.reserveValue*perc/1e18), abs); availPerpJrLiquidity = max(JR idle - reserved, 0) (4/4). JR flashRedeem gross > avail -> OpDisabled().
- Op fee amount = floor(gross * totalFeePerc / 1e18); totalFeePerc = FeePolicy.computeOpFees(pre/post DRs from trace) exact.
- Op fees stay in Controller (collectedFeeBal), NOT burned/converted by upkeep/rebalance/rollover; pullProtocolFees(owner) transfers them out (supply unchanged).
- AUM fee: on successful rebalance, minted/charged amount = floor(perp.totalSupply * aumFeePerc / 1e18) per rebalance (NOT time-proportional; 1d == 7d). Emits AumFees.
- valueCap: above-cap double-sided revert; worsening single-sided revert; corrective single-sided OK. Crossing 1e18: UNVERIFIED.
- updateRolloverEligibility raises maturity threshold for rollover eligibility.
- SR-payer rebalance: transfers exactly computeSystemRebalancePlan amounts SR->JR (tranche 76375148955 units, rebalanceValue 1020657).
- CORRECTION AUM: AUM amount floor(supply*aumPerc/1e18) is MINTED via perp.mintTo(protocolFeeCollector) on each successful rebalance (not held in Controller).
- Fee DR inputs: pre = state before op, post = state after op (both sides combined); one computeOpFees(isFlashOp) result applied to both sides in the traced both-sided flash ops.
- Perp token selectors: init(string,string,address,address), updateController, reserveData, reserves, transferReservesTo(address,(uint256,(address,uint256)[])), handleTransferReservesIn(...), registerTranche, mintTo, burnFrom, maxTrancheCount, underlying, recover, logBalance, controller; JR only: primeApproval, revokeApproval, bondDepositsForRollover(address,(bytes32,uint256)[]).

## External review hypotheses, round 1 (~/work/probes/CODEX_REVIEW_PROBES.md) — black-box only
- Fees: two computeOpFees calls (SR/JR flags) sharing pre/post DRs; distinct params -> distinct pct. EXACT.
- redeem2: feePerp=floor(in*fee/1e18); out_i=floor(bal_i*net/preSupply); supply -= net. EXACT (2 cases).
- AUM gross-up: floor(S*p/(1e18-p)) at p=10%,5%; per-rebalance, no time scaling. EXACT. (supersedes earlier floor(S*p/1e18)).
- JR over-avail with fee<1e18 -> InsufficientLiquidity() 0xbb55fd27; fee>=1e18 -> OpDisabled().
- Rebalance window: 5 edge timestamps all succeed (seamless).
- Lazy: SR-input flashMint2 issues new bond after issue time and rolls over stale; JR-only does not. SR lazy with high minCleanupVal succeeds, input left idle.
- Fee settlement on successful rebalance: SR/JR fee perps burned, cbBTC fee -> perpJR; JR-input mints don't settle. collected = balance - protocolFeeBals. Collector pulls exact protocol bal; random -> 0x7bf6a16f.
- valueCap: corrective crossing subDR=1 -> ValueCapExceeded() 0x8f61fa9a.
- Versions pinned (identical at 53494912 and 54990962): see probes/reviewer_fork_versions.log.
## Round 2
- mint2 accepts only latest-bond tranche pair (else UnexpectedAsset 0x59102332); mint2 first attempts issue+register (trace), so after issue time the old pair becomes non-latest and reverts.
- Rebalance fee settlement: SR fee perps burned, no SR->JR reserve move; settles even with zero transfer plan; protocolFeeBals preserved.
- pullProtocolFees(address,address,uint256): only protocolFeeCollector (owner -> 0x7bf6a16f); over-withdraw -> Panic 0x11.
- SR flashMint lazy rollover gated by minCleanupVal (skip at 1e8, trigger at 1e6 for 2e6 input). JR-payer rebalance with zero JR avail: underlying-only, no rollover.
- Public rollover with minCleanupVal 1e8 & no free JR liquidity -> InsufficientRollover 0xbbb27b39.
## Round 3
- Backup total = min(free, floor(S*1e18/vr_selected)); 2S is the vr=0.5 special case. Selected row: latest at -30%, previous fresh at +30% (selection rule UNRESOLVED).
- Standard allocation rule holds at shifted prices.
- Public rollover can partially complete (41,875,890 -> 14,656,562 stale).
- SR lazy rollover trigger: post-input SR idle > minCleanupVal (strict).
- valueCap adjacent boundary: SR max success 6,423,365 (post subDR 1.000000004321734011), +1 fails; JR mirrored max 10,184,377. Exact-equality unresolved.
