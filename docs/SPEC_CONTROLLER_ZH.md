# PerpController 规格草案（待用户确认后再实现）

证据来源：docs/RECON_FINDINGS.md（链上只读调用 + 本地 Base 分叉实测，共约 1000 条原始记录，原始数据在 ~/work/probes）。
标记：✅ 已和链上逐位比对；⚠️ 方向已观察到，但边界没有逐位验证；❌ 未验证，实现时按标注的假设处理，并在 README 中列出。

## 1. 组件和权限
- PerpController：可升级代理，Ownable2Step。另设 keeper 地址，以及两类暂停开关：userOpsPaused、systemOpsPaused。✅（函数名来自 ABI）
- Perp SR / Perp JR 代币：直接部署，不走代理。名称 "cbBTC Senior" / "cbBTC-SR"、"cbBTC Junior" / "cbBTC-JR"，均为 8 位小数。代币合约自己持有储备（闲置 cbBTC 和 tranche），资产只能由 Controller 调动。✅
  接口：mintTo、burnFrom、reserveData、reserves、transferReservesTo、handleTransferReservesIn、registerTranche、maxTrancheCount、recover、logBalance。JR 另有 bondDepositsForRollover、primeApproval、revokeApproval。储备余额每次变化都会发出 ReserveSynced(token, balance) 事件。✅（函数选择器和事件已比对；内部实现细节为❌，按名称语义实现）

## 2. 储备估值
- reserveValue = 闲置 cbBTC + Σ tranche 价值；tranche 价值 = floor(持有量 × trancheClaim / trancheSupply)。✅
- vm = floor((闲置 cbBTC × 1e18 + Σ tranche 价值 × 该 tranche 的 VM) / reserveValue)。✅
- subDR、vmDR 公式见 RECON。✅

## 3. 用户操作
- flashMint2(srIn, jrIn, minSrOut, minJrOut)：
  - 存入的 cbBTC 作为闲置资产直接进入对应一侧的储备，不切成 tranche。✅
  - 份额 = floor(存入 × 操作前总份额 ÷ 操作前储备价值)。✅
  - 手续费 = floor(份额 × fee% ÷ 1e18)，以 Perp 代币形式留在 Controller；用户实际得到 份额 − 手续费。✅
- flashRedeem2(srIn, jrIn, minOut)：
  - 应得 cbBTC = floor(赎回份额 × 储备价值 ÷ 总份额)，手续费按向下取整从中扣除，以 cbBTC 留在 Controller。✅
  - JR 应得超过 availPerpJrLiquidity 时，回滚并报 OpDisabled()。✅
- mint2(srTranche, jrTranche, ...)：
  - 存入价值 = floor(tranche 数量 × trancheClaim ÷ trancheSupply)，份额按储备价值比例计算，手续费以 Perp 代币扣下。✅
- redeem2(srIn, jrIn, minValOut)：按比例取走储备篮子里的各项资产（闲置 cbBTC 和每个 tranche 分别按比例）。❌（返回值已记录，比例公式尚未逐位验证）
- fee%：pre 取操作前的 subDR / vmDR，post 取操作后的；调用一次 FeePolicy.computeOpFees(isFlashOp)，双边操作时两侧使用同一个百分比。✅（只测了 flash 操作；mint2 / redeem2 的 isFlashOp=false ⚠️）
- totalFee% 达到 1e18 时，该操作禁止执行，报 OpDisabled。⚠️
- valueCap：超过上限时，双边铸造回滚；会让 subDR 恶化的单边铸造回滚；有助于纠偏的单边铸造放行。✅
  单边铸造把 subDR 推过 1e18 这一情况未验证 ❌，暂按 VALUE_CAP_STATE_MACHINE.md 实现。
- 暂停用户操作后，以上 4 个操作全部报 UserOpsPaused()。✅

## 4. Junior 流动性底线
- reserved = max(floor(JR 储备价值 × perc ÷ 1e18), abs)，当前参数为 1% 和 0.01 cbBTC。✅
- avail = max(JR 闲置 cbBTC − reserved, 0)。✅

## 5. rebalance（Funding）
- 只在时间窗口内可调用；与上一次调用间隔太近时报 LastRebalanceTooRecent()。窗口参数：频率 86400，偏移 64800，窗口长度 86400。✅
  由于窗口长度等于频率，窗口之间无缝衔接，“窗口外”的情况实际不会出现。✅
- 金额由 FeePolicy.computeRebalanceVal 算出。✅
- 资产搬运计划由 Balancer.computeSystemRebalancePlan 给出：先用闲置 cbBTC，再按到期先后使用 tranche。从付款方转到收款方。✅
- 每次成功 rebalance 时收取 AUM 费：floor(perp 总供应 × aumFee% ÷ 1e18)，铸给 protocolFeeCollector。按次收取，不按时间累积。✅（当前 AUM 费率为 0）
- 暂停系统操作后，rebalance、upkeep、rollover 全部报 SystemOpsPaused()。✅

## 6. upkeep 与 rollover
- upkeep()：让 BondIssuer 发行新一期（到发行窗口时才会发），把已到期的 Bond 结算掉，并把新 tranche 登记进储备，新登记的余额为 0。⚠️（顺序已观察到，内部步骤没有逐位验证）
- 用户操作不会顺带触发发行或 rollover。✅
- rollover() 的调用顺序：Balancer.computePerpSrRolloverPlan → 把 stale 的 SR tranche 转给 JR → 在 BondsManager 中把 SR、JR 两份一起赎回 → perpJr.bondDepositsForRollover 按期存入 → 新切出的 Senior tranche 从 JR 转回 SR。✅
- stale：距到期时间 ≤ minMaturitySec（604800）。✅
- 资金分配规则，在 35 个案例里全部逐位一致 ✅：
  - S = SR 闲置 cbBTC + stale 的 SR tranche 价值
  - N = 非 stale 的 Bond 期数，按到期先后排序，最后一个是最新一期
  - target = max(ceil((S + Σ v) ÷ N), 除最新一期外各期 v 的最大值)
  - 除最新一期外，按顺序逐期补到 target，S 用完为止；剩下的全部给最新一期
  - 每期存入的 cbBTC = ceil(补足的价值 × 1e18 ÷ 该期 senior 的 valueRatio)
- 走标准方案还是备用方案：标准方案需要的资金 ≤ free + unlocked 时走标准方案；否则走备用方案，备用方案总额 = min(free, 2S)，全部存入最新一期。✅
  - free = avail
  - unlocked = SR 闲置 + Σ floor(jr 持有量 × jrTotalClaim ÷ jrSupply)
- 资金不足时回滚，报 InsufficientRollover()。⚠️
- updateRolloverEligibility 可以调整 rollover 的期限门槛。⚠️

## 7. 手续费去向
- 操作手续费留在 Controller，计入 collectedFeeBal。upkeep、rebalance、rollover 都不会动这部分资金。✅
- 只有 owner 能通过 pullProtocolFees 把手续费转出，转出不改变 Perp 总供应。✅
- 当前 protocolFee% = 0，因此 protocolFeeBals = 0。✅

## 8. 尚未闭环的部分（实现时列为 ❌）
- redeem2 篮子比例的取整方式
- valueCap 单边操作把 subDR 推过 1e18 时的行为
- upkeep 的完整内部步骤，以及 stale tranche 清理阈值 minCleanupVal 的具体作用
- tranche 价值为零、或 senior 封顶时的 VM
