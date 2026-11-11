# 2Factor 净室实现代码审查与收口建议

> 2026-11-11 状态补充：本文正文保留的是较早的 80-test 审查快照。当前 Controller 瘦身候选
> 已从基线 `10cba49` 的 23,981 bytes 降到 22,052 bytes，存储槽 0–17 未变，完整离线测试
> 为 88/88；CI 已单独执行 22,500-byte Controller 闸门。实现与验证细节见
> `CONTROLLER_SIZE_REFACTOR.md`。Oracle、Manager、自动目标差分、50-tranche 活性与
> stateful invariant 等未完成项仍按本文执行，不因尺寸达标而视为关闭。

## 当前结论

- 当前完整离线测试：80 passed，0 failed，0 skipped。
- Round 13/14 已补充 backup rollover 选择和执行向量，方向正确。
- 当前定位仍是“高质量净室研究实现”，不是可直接承载主网资金的发布版本。
- 在下列 P0/P1 项目收口前，暂停扩展新模块和新功能。

## P0：必须先解决

### 1. 接通交易级 Oracle 价格快照

现状：`PerpController.rollover()` 末尾调用 `resetCache()`，入口没有建立 `cachePrice()` 快照。

要求：

- 先用目标合约 probe 确认 `rollover`、`flashMint2`、`redeem2`、`rebalance`、`upkeep` 的真实缓存调用语义和顺序。
- 对需要一致价格的顶层操作，在入口建立价格快照，并在成功结束时重置。
- revert 路径必须依赖 EVM 原子回滚，不得残留缓存状态。
- 增加“同一交易中底层 feed 改价，但后续估值仍保持一致”的测试。
- 不得仅凭接口存在就宣称价格缓存已经接通。

验收标准：目标 fork 调用顺序有证据；净室实现有离线回归；所有价格相关入口均有明确结论。

### 2. 明确 BondsManager 单 Manager 或多 Manager 模型

现状：`PerpToken` 保存 immutable `bondsManager`，但 `_recoverTranche()` 信任 `tranche.manager()`，`bondDepositsForRollover()` 又接受外部传入的 manager。

要求：

- 首先通过目标 probe 验证不同 Manager、假 tranche、Manager 返回异常地址时的真实行为。
- 如果原协议是单 Manager：校验 `manager == bondsManager`，并补错误 selector/空 revert 兼容测试。
- 如果原协议支持多 Manager：改成明确的白名单或注册表设计，删除具有误导性的单 Manager 假设。
- 覆盖恶意 Manager、EOA Manager、零地址、错误 bondID、重复 SR/JR 和混合 Manager 批次。

验收标准：设计决策、目标证据、实现和测试四者一致。

### 3. 建立真正的目标合约/净室实现自动差分框架

现状：目前主要是“观察目标结果，再把结果写成固定断言”，尚未形成同输入自动对拍。

要求：

- 对同一前置状态和同一输入，分别运行目标 fork 与净室实现。
- 自动比较：返回值、revert selector、用户余额、SR/JR supply、储备数组、Bond 状态、费用、事件及顺序。
- 对允许存在差异的字段建立显式 allowlist，禁止静默忽略。
- 优先覆盖 mint/redeem、flashMint/redeem、rebalance、rollover、upkeep 和 value-cap 边界。
- 差分失败必须输出最小可复现输入和前后状态快照。

验收标准：CI 中可以一条命令运行，差异会让任务失败，而不是只生成日志。

## P1：主网候选版本前必须解决

### 4. 50 tranche 最坏情况 gas 与活性

- 测试 50 个 reserve tranche 的 `recover`、`reserveData`、rollover 和 rebalance。
- 覆盖全部到期、全部未到期、交替到期、同 Bond 的 SR/JR 同时登记。
- 测量最坏 gas，确认不会接近区块 gas 上限或形成永久无法清理的状态。
- 验证重复 Bond 是否会被调用两次；若目标没有去重，记录兼容性和 gas 影响；若净室选择去重，必须标成有意设计差异。
- 增加容量达到 49、50、51 时的边界与原子回滚测试。

### 5. 控制 Controller 字节码尺寸

现状：运行时代码约 23,643 bytes，距项目 24,000-byte guard 仅约 357 bytes，距 EIP-170 上限 24,576 bytes 约 933 bytes。

- 禁止继续把规划算法和辅助逻辑塞进 Controller。
- 优先把纯计算、rollover planner、估值辅助函数拆到库或独立策略模块。
- CI 保持 24,000-byte guard，并显示每次改动的尺寸增量。
- 拆分后重新验证 storage layout、代理初始化和权限边界。

### 6. Stateful invariant、fuzz 和长序列测试

至少建立以下不变量：

- 用户资产 + 协议资产 + 已收费用在允许舍入误差内守恒。
- SR/JR supply 与可赎回储备关系不会被随机操作序列破坏。
- `subDR`、`vmDR`、value cap 和 session capacity 的边界始终满足规格。
- 失败操作完全回滚，储备数组和索引映射不漂移。
- 随机 mint/redeem/rebalance/rollover/upkeep 长序列不会累积不可解释的价值。

还应覆盖恶意 ERC20、异常 decimals、fee-on-transfer、callback/reentrancy、失效 Oracle 和 sequencer 状态。

### 7. 加强 backup rollover 的真实证据

- 当前执行证据主要集中在 `valueRatio = 0.5e18`。
- 补非 0.5 valueRatio、多 fresh Bond、多 stale Bond、零流动性、刚好够、差一单位和超额流动性。
- 至少补一条通过目标 Controller 端到端成功执行的非 0.5 backup 向量。
- 对 selector 选择、实际 deposit、fresh SR 数量和 stale 消耗同时做差分。

## P2：工程收口

### 8. 格式、版本与证据固定

- 执行 `forge fmt`，确保 `forge fmt --check` 通过。
- 清理编译 warning，不保留无意义的 mutability 或未使用参数告警。
- 建立第一个可审计 Git 基线 commit；以后每轮 probe、实现和测试分别提交。
- 每份证据记录目标地址、implementation、链、区块、RPC 类型、测试文件和原始日志 SHA-256。
- 文档中的“已实现”“已验证”“推导”必须分开，不得互相替代。

### 9. 安全工具和发布闸门

- 增加 Slither、Foundry invariant/fuzz、存储布局比较和 bytecode size CI。
- 对代理初始化、升级权限、暂停、keeper、owner、fee collector 做完整权限矩阵。
- 上测试网长期运行并监控 keeper、Oracle、rollover gas 和失败 selector。
- 未经独立人工审计和修复复审，不得标记为主网可用。

## 建议执行顺序

1. 冻结新功能。
2. 用 target probe 查清 Oracle 缓存与 Manager 模型。
3. 修改实现并补离线回归。
4. 建立自动差分 harness。
5. 补 50 tranche gas/liveness 和恶意依赖测试。
6. 拆分 Controller，保持部署尺寸余量。
7. 建立 stateful invariant/fuzz。
8. 格式化、清警告、提交 Git 基线。
9. 跑完整 CI、安全工具和测试网验证。

## 本轮完成定义

本轮不是以“又多写了一个模块”为完成标准，而是以下条件全部满足：

- `forge test -vv` 全部通过；
- `forge fmt --check` 通过；
- 自动差分测试通过；
- 50 tranche 最坏路径有 gas 报告且可执行；
- Controller runtime size 低于 24,000 bytes，并保留合理余量；
- Oracle 和 Manager 语义有目标证据；
- 文档、证据哈希和 Git commit 对应同一源码状态；
- 未解决项明确列为 UNKNOWN，不以推断代替证据。
