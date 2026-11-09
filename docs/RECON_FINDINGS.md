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
