# PerpController 规格草案（待用户确认后再实现）

## 版本锁定（证据对应的链上版本）
chainId 8453；参考区块 53494912 和 54990962，两个区块上的实现完全相同。
| 合约 | 代理 | 实现 | 实现 codehash |
|---|---|---|---|
| Controller | 0x682F3a05…A200 | 0x16e324ba…f02a | 0xc18d3bcb…6e31 |
| FeePolicy | 0x1E3DbDc2…00E8 | 0x9cefc3cf…1900 | 0x2147e3a9…a755 |
| Balancer | 直接部署 0x30333a6B…aCbf | — | 0x540e400d…b1f8（代码本身的 hash） |
| BondIssuer | 0xc56CCbF6…EBB0 | 0xe024bd49…763b | 0x2a5e0bee…cbe8 |
| BondsManager | 0xe8c13955…fde3 | 0x427758ed…aac2 | 0xb2318665…16c6 |
| PerpSR | 0x4be28E75…b70b | 0x96fc14b1…1574 | 0x1d57fb7d…1a53 |
| PerpJR | 0x8cd04668…e8AB | 0x8e9ed113…1529 | 0xa34e6fcb…0ebb |
完整地址和 codehash 见 evidence/reviewer_fork_versions.log。

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
  - 错误的判断顺序（见第 3 节“手续费和错误码”）：先计算手续费，totalFee ≥ 1e18 时报 OpDisabled()；否则，JR 应得金额 > availPerpJrLiquidity 时报 InsufficientLiquidity()。✅
- mint2(srTranche, jrTranche, ...)：
  - 存入价值 = floor(tranche 数量 × trancheClaim ÷ trancheSupply)，份额按储备价值比例计算，手续费以 Perp 代币扣下。✅
- redeem2(srIn, jrIn, minValOut)：
  - 手续费份额 feePerp = floor(perpIn × fee% ÷ 1e18)，netPerp = perpIn − feePerp
  - 篮子里每项资产单独计算：out_i = floor(储备余额_i × netPerp ÷ 操作前总份额)
  - 总供应减少 netPerp，手续费份额留在 Controller
  - ✅（2 组有手续费的案例逐位一致，其中一组输入 +1 后输出也跟着 +1）
- fee%：pre 取操作前的 subDR / vmDR，post 取操作后的，两侧共用同一组 DR 输入。SR、JR 各调用一次 computeOpFees(isPerpSrOp=true/false, isFlashOp)，结果分别计算。✅
  - 把两侧费率改成不一样后，返回的百分比也不一样，并且分别与各自那次调用的结果一致
  - flashMint2 和 mint2 都测过
- totalFee% ≥ 1e18 时报 OpDisabled()。✅
- JR 赎回量超过可用流动性、且手续费低于 100% 时，报的是 InsufficientLiquidity()（0xbb55fd27），不是 OpDisabled。✅
  - 此前测到的 OpDisabled 是因为那次的手续费已经 ≥ 100%
- valueCap：超过上限时，双边铸造回滚；会让 subDR 恶化的单边铸造回滚；有助于纠偏的单边铸造放行。✅
  - 超过上限时，纠偏方向的铸造如果把 subDR 推过 1e18，报 ValueCapExceeded()（0x8f61fa9a）；不越过 1e18 的纠偏铸造可以成功。✅
  - 相邻边界已经测到 ✅：SR 方向能成功的最大金额为 6,423,365，此时 post subDR = 1.000000004321734011；再多 1 sat 就越过 1，报 ValueCapExceeded。JR 方向是镜像关系，最大成功金额为 10,184,377
  - 正好等于 1e18 时允许还是拒绝 ❌：整数金额凑不出正好 1e18 的状态，实际几乎不会遇到
- 暂停用户操作后，以上 4 个操作全部报 UserOpsPaused()。✅

## 4. Junior 流动性底线
- reserved = max(floor(JR 储备价值 × perc ÷ 1e18), abs)，当前参数为 1% 和 0.01 cbBTC。✅
- avail = max(JR 闲置 cbBTC − reserved, 0)。✅

## 5. rebalance（Funding）
- 只在时间窗口内可调用；与上一次调用间隔太近时报 LastRebalanceTooRecent()。窗口参数：频率 86400，偏移 64800，窗口长度 86400。✅
  - 窗口开始前 1 秒、开始那一秒、结束前 1 秒、结束那一秒、结束后 1 秒，5 个时间点全部成功，窗口之间无缝衔接。✅
  - 测试前提：每个时间点都从同一个快照开始单独测，上次 rebalance 已经过去很久
  - “开始前 1 秒”其实落在上一个窗口里
  - 同一个窗口内连续调用，第二次会先报 LastRebalanceTooRecent()
  - 这几个时间点和连续调用的情况已经固化成回归测试（evidence/probe-tests/Round4Probe.t.sol）✅
  - 外部审核认为“结束那一秒会被拒”，实测结果相反
- 金额由 FeePolicy.computeRebalanceVal 算出。✅
- 资产搬运计划由 Balancer.computeSystemRebalancePlan 给出：先用闲置 cbBTC，再按到期先后使用 tranche。从付款方转到收款方。✅
- 每次成功 rebalance 时收取 AUM 费：floor(总供应 × p ÷ (1e18 − p))，铸给 protocolFeeCollector。✅
  - 这是 gross-up 公式：分母是 1e18 − p，不是 1e18
  - 用 p = 10% 和 5% 区分了两个公式；第一轮只用了 1e-9 的费率，两个公式算出来相同，所以当时没区分出来
  - 按次收取：间隔 1 天和 7 天收到的金额相同
  - 当前链上费率为 0
- 暂停系统操作后，rebalance、upkeep、rollover 全部报 SystemOpsPaused()。✅

## 6. upkeep 与 rollover
- upkeep()：让 BondIssuer 发行新一期（到发行窗口时才会发），把已到期的 Bond 结算掉，并把新 tranche 登记进储备，新登记的余额为 0。⚠️（顺序已观察到，内部步骤没有逐位验证）
- 用户操作也会顺带触发（更正第一版）：
  - 含 SR 输入的 flashMint2：过了发行时间会发行新一期；如果存在 stale 的 Bond，会执行 rollover ✅
  - 只有 JR 输入的 flashMint2：不会触发 rollover ✅
  - mint2：只接受最新一期 Bond 的 tranche，传入非最新一期的报 UnexpectedAsset()（0x59102332）✅
  - mint2 会先尝试发行新一期：过了发行时间后，调用追踪显示先执行了发行和登记，随后因为传入的 tranche 已经不是最新一期而回滚 ✅
  - SR 闪铸触发 rollover 的条件和 minCleanupVal 有关：阈值为 1 亿时跳过，阈值为 100 万时触发 ✅；触发条件是存入后 SR 闲置 > minCleanupVal（严格大于）✅：阈值为 1,000,000 时，闲置 999,999 和 1,000,000 都不触发，1,000,001 触发
  - JR 付款方向的 rebalance：在 JR 可用流动性为 0 时也能成功，只搬闲置 cbBTC，不触发 rollover ✅
  - 把 minCleanupVal 调高后，SR 闪铸仍然成功，存入的 cbBTC 留在闲置资产里 ✅；外部审核认为“补不满就回滚”，实测结果相反
- rollover() 的调用顺序：Balancer.computePerpSrRolloverPlan → 把 stale 的 SR tranche 转给 JR → 在 BondsManager 中把 SR、JR 两份一起赎回 → perpJr.bondDepositsForRollover 按期存入 → 新切出的 Senior tranche 从 JR 转回 SR。✅
- stale：距到期时间 ≤ minMaturitySec（604800）。✅
- 资金分配规则，在 35 个案例里全部逐位一致 ✅：
  - S = SR 闲置 cbBTC + stale 的 SR tranche 价值
  - N = 非 stale 的 Bond 期数，按到期先后排序，最后一个是最新一期
  - target = max(ceil((S + Σ v) ÷ N), 除最新一期外各期 v 的最大值)
  - 除最新一期外，按顺序逐期补到 target，S 用完为止；剩下的全部给最新一期
  - 每期存入的 cbBTC = ceil(补足的价值 × 1e18 ÷ 该期 senior 的 valueRatio)
- 走标准方案还是备用方案：标准方案需要的资金 ≤ free + unlocked 时走标准方案；否则走备用方案，全部存入一期选中的 Bond。
  - 备用方案总额 = min(free, floor(S × 1e18 ÷ 选中那期的 senior valueRatio)) ✅
    - 价格 −30%、+30% 两种情况都逐位对上
    - “2S”只是 valueRatio = 0.5 时的特例，原来那 23 组正好都是这种情况
  - 选中哪一期 ⚠️：目前最吻合的规则是选 senior valueRatio 最接近 0.5e18 的那期，距离相同时选 ≥ 0.5e18 的
    - 6 组直接调用 Balancer 的合成案例全部吻合；其他候选规则只吻合 1–4 组
    - 价格 ±30% 的两次实际 rollover 也吻合
    - 第五轮已推翻这条规则：用不同开仓价发行的接近平局的一组里，0.390244 和 0.609756333 两期中选了后者，而后者离 0.5 更远 ❌
    - 选期规则仍然未知，实现时先不写
  - 标准方案的逐期分配规则，在价格移动后仍然逐位成立 ✅
  - free = avail
  - unlocked = SR 闲置 + Σ floor(jr 持有量 × jrTotalClaim ÷ jrSupply)
- 公开 rollover() 在资金不足时报 InsufficientRollover()（0xbbb27b39）。可以部分完成 ✅：实测中 stale 价值从 41,875,890 降到 14,656,562
- updateRolloverEligibility 可以调整 rollover 的期限门槛。⚠️

## 7. 手续费去向（更正第一版）
- Controller 持有的手续费分两部分：collectedFeeBal = Controller 余额 − protocolFeeBals ✅
- 成功执行 rebalance 时结算 collectedFeeBal ✅：
  - SR、JR 的手续费份额全部销毁（总供应正好减少对应数量）
  - cbBTC 手续费转入 Perp JR
  - SR 手续费份额是直接销毁，SR 储备没有转给 JR ✅（用特殊的手续费金额区分了两种假设）
  - 搬运金额为 0 的 rebalance 也会结算手续费 ✅
  - protocolFeeBals 不受 rebalance 结算影响 ✅
- 含 JR 输入的 flashMint2 / mint2 不会结算手续费 ✅
- 第一版写的“rebalance 不动手续费”是错的：那次实测中手续费余额本来就是 0
- protocolMaxOpFeePerc > 0 时，protocolFeeBals 单独累积 ✅
- 提取协议费：protocolFeeCollector 可以提走正好等于 protocolFeeBals 的金额；随机地址调用报 0x7bf6a16f ✅
  - 接口为 pullProtocolFees(address,address,uint256)
  - owner 调用报 0x7bf6a16f，也就是只有 collector 能提 ✅
  - 超额提取报算术溢出 Panic(0x11) ✅
  - 提取后 protocolFeeBals 正好减少对应数量 ✅

## 7b. Perp SR / JR 代币（第四轮实测）
- 名称 / 代号 / 精度：SR 为 "cbBTC Senior" / cbBTC-SR / 8，JR 为 "cbBTC Junior" / cbBTC-JR / 8 ✅
- 只有 controller 能调用 recover、registerTranche、transferReservesTo、handleTransferReservesIn、mintTo、burnFrom、logBalance；其他地址调用报 0x7bf6a16f ✅
- updateController 只有 owner 能调用；其他地址调用报 OwnableUnauthorizedAccount（0x118cdaa7）✅
- maxTrancheCount = 50。注册第 51 个报 ReserveOverflow()（0x446c8cc9）✅
- 重复注册已经登记的 tranche 不报错，也不改变列表 ✅
- JR 的 primeApproval：只有 controller 能调用，作用是把 cbBTC 对 BondsManager 的授权设为最大值 ✅
- SR 调用 primeApproval / revokeApproval 时空返回失败，可能根本没有这个函数 ⚠️
- recover()：放进去的 cbBTC 和 USDC 都没有被转走，语义不明 ❌
- tranche 什么时候被移出列表、移出后列表顺序怎么变 ❌
- 首次铸造：新部署的空系统里，总供应为 0 时调 flashMint2 会 Panic（0x4e487b71）✅。也就是说空系统不能直接铸造，genesis 怎么建立 ❌
- AUM 费率：设成 1e18 − 1 可以成功；设成 1e18 或更大报 InvalidPerc()（0xcdc62692）✅，所以分母 1e18 − p 不会为 0

## 8. 尚未闭环的部分（实现时列为 ❌）
- genesis 和首次铸造、recover 的语义、tranche 移出列表的规则
- rollover 什么时候部分完成、什么时候回滚的完整边界（已知能部分完成）
- 备用方案选哪一期 Bond：已覆盖 6 个直接调用的合成案例和 2 个整体价格偏移案例，但还没有让各期开仓价独立变化
- valueCap 中 post subDR 正好等于 1e18 的情况
- upkeep 的完整内部步骤，以及 stale tranche 清理阈值 minCleanupVal 的具体作用
- tranche 价值为零、或 senior 封顶时的 VM
