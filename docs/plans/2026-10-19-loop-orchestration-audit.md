# Agent 主循环编排审计与拆分可行性

> 日期：2026-10-19 ｜ 对象：`atelier/atelier/src/agent/runtime.cj`（1675 行，`chatWithEnv` 270 行）
> 参考实现：dsh `@deepseek-ai/dsh-agent-loop` 0.2.1-rc.2、pi `@earendil-works/pi-coding-agent` 1.3.0（含其依赖包 `pi-agent-core`）
> 性质：调研 + 修复记录。修复在 worktree 分支 `probe/loop-orchestration`。

---

## 0. 结论先行

**「编排有没有问题」与「文件能不能拆」是两个问题，但答案指向同一件事。**

1. **编排确实有问题，而且不是小问题**：审计出 5 条 A 类（崩溃/数据损坏/权限串台），已全部实测确认、全部修复。最严重的一条（A3）是 **PTC 模式下 `run_xisp` 泄漏进跨 runtime 共享的工具根表**，并发会话时信任判定的键（workDir）会与请求来源脱节——这是权限问题，不是性能问题。
2. **「拆文件」这条路在两个成熟 harness 里都没走**。dsh 的主类净剩 ~520 行、`turn`+`step` 仍合 236 行且明确不拆；pi 的 `agent-session.ts` 从 3441 行**涨到** 4428 行，没拆类、没 mixin。它们做的是**搬走循环 + 隔离状态**，不是把大方法切成碎片。
3. **atelier 前两次拆文件失败的根因不是行数，而是状态归属**：`AgentRuntime` 上放的是**权威状态**（messages / cancels / steers / resumedAnswers），而 dsh 的主类私有字段里**没有一个**是业务消息集合。行数只是症状。
4. **本次实际能做、且已经做成的**：把 run 作用域状态收进 `RunScope`（工具视图 + 执行器），修掉 5 条编排缺陷。**真正「拆成多文件」需要先有事件/投影层**，那是另一个量级的改造，不建议现在做。

---

## 1. 两个参考实现怎么组织核心方法

### 1.1 dsh：1 个骨架类 + 5 个状态持有者 + 2 个服务

| 单元 | 持有状态 | 与主类通信 |
|---|---|---|
| `ReactLoopAgent`（净 ~520 行，14 方法） | 仅 8 个字段，全是游标与注入依赖 | — |
| `ReactLoopInbox` | **零业务状态**，全是投影的即时读取 | 构造注入 3 个协作者 |
| `SystemPromptProjection` | 只持 `session` | `project()` 返回待提交 commit，不自己落盘 |
| `RuntimeContextProjection` | `retained` 三态（从没出现/现在没有/现在有） | 订阅 `session/event` 自恢复 |
| `AssistantStreamAttempt` | 单次尝试的累积状态 | 注入两个回调 |
| `FactoryOwnership` / `AgentLoop extends Service` | 生命周期 | Cordis Service |

关键：**`turn` + `step` 合计 236 行，它自己也没拆**。拆走的是"会腐坏的子系统状态"和"生命周期"。
控制流全部用**返回值 + 封闭枚举**表达（`PreStepDecision{enter|reject}`、`step()` 三态、`turn()` 返回 Bool），异常只在固定两处被接住后收敛成 `turnEnds` 记账——"每个错误只上报一次"。

最值得抄的一招：`turn-stopping` 监听器**不能否决**，只能 `steer` 塞数据；主循环在 dispatch 之后**重新读 inbox** 决定收不收尾。atelier 的 `AfterTurnUpdate{messages, shortCircuit}` 是"钩子直接给结论"，多钩子组合会打架。

### 1.2 pi：纵向分层，循环搬到更低层

- `AgentSession`（4428 行 / 168 方法）只剩 **10 行驱动壳**；turn/step 双 `while` 在依赖包 `pi-agent-core` 的**顶层纯函数** `runLoop()`（950 行，无 class）。
- 循环与上层的**唯一耦合面是一组回调钩子**（`prepareRequest` / `prepareNextTurn` / `finishTurn` / `getSteeringMessages` / `getFollowUpMessages` / `beforeToolCall` / `afterToolCall` / `transformContext`）。
- 它用四个手法把大方法摊平：`_installXxx()` 钩子注册、阶段回调成对、纯函数下沉（压缩判定/切点/摘要全在 `compaction/`）、枚举化返回值。
- 历史是 `sessionManager.buildSessionProjection()` 的**投影**（19 处调用），压缩 = 往日志追加 entry 再重投影，**不是**改写数组。

### 1.3 两边的共同点（这才是可迁移的）

| 共同做法 | dsh | pi |
|---|---|---|
| 主循环本身不拆 | `turn`+`step` 236 行不拆 | 双 `while` 整块搬走，骨架不动 |
| 状态搬到主类之外 | 5 个状态持有者 + 投影 | 队列在 `Agent`、历史在投影 |
| 控制流用返回值枚举 | `PreStepDecision` / `turnEnds` | `finishTurn({action})` |
| 接缝都是数据契约 | waterfall / serial / `session.append` | 8 个具名钩子 |
| **权威状态有唯一归属** | session 事件流 | session 日志 + 投影 |

---

## 2. 我们的编排问题（A/B/C 分级，A 类已全修）

### A 类：必修（5 条，全部实测确认 + 已修复）

| # | 缺陷 | 实测证据 | 后果 |
|---|---|---|---|
| A1 | 工具预算耗尽分支只写一条 `id=""` 的结果 | 历史 `assistant(calls=2) → tool_result(id='')`，`ensureToolCallResults` 审出 unpaired=2 | 历史落库带孤儿结果 |
| A2 | 空历史入参 `scope.messages[0]` 越界 | `IndexOutOfBoundsException: index 0, size 0` | 新会话首轮崩溃 |
| **A3** | **`run_xisp` 泄漏进共享根表** | 两个 runtime 共用一份 `HarnessSpec`，rtA 跑完后根表变成 `[probe_tool, run_xisp]` | **PTC 下并发会话信任判定串台** |
| A4 | 不变式收口只在"发请求前"，不在"交结果前" | 最后一轮仍裸写历史（6 处） | 最后一轮写脏直接进 `result()` |
| A5 | 归档绝对下标 vs 截断错位 | 12 条 → 截断 6 条 → 标记后剩 4 条（普通消息 5→4） | **当前窗口内的正常消息被静默吃掉** |

**A3 最值得记录**：机制是 `this.toolRegistry = spec.tools`（不复制） + 每轮 `register(new RunXispTool(...))`。而 `RunXispTool.env` 绑着**这一次 run** 的 workDir / sessionId / cancelFlag / authorizer。修法是让 run 作用域工具落进 `ToolRegistry.derived(...)` 派生视图、收尾即弃，`ToolExecutor` 与视图同源。

**A5 的含义**：`ArchiveMessage(startIndex, endIndex)` 记的是绝对下标，`applyArchiveMarks` 却拿当前循环下标去比。截断让下标整体前移而记录不变 → 误跳。`builder.cj` 只有"全跳过则回退"兜底，**部分误跳不兜**。ACP 每回合 `maxLoad=15` 是常规路径。

### B 类：结构隐患（当前宿主不触发，换宿主就炸）

| # | 隐患 | 判定要点 |
|---|---|---|
| B1 | 每轮 `register` 会 `masked.remove(name)` | 宿主在 run 作用域 `remove` 遮蔽的工具会被主循环**静默恢复可见** |
| B2 | 压缩跑在 `beforeTurn` 之前 | 钩子整体替换 messages → 压缩白花钱；路由到小窗口模型 → 阈值永远用错窗口 |
| B3 | 每轮重算工具列表，`list()` 走 `HashMap.values()` | 顺序抖动 = 提示词前缀从第一个工具起就不命中缓存 |
| B4 | `ToolBatchOutcome.Suspended` 表达两种语义 | 异常路径返回 `Suspended` 却不发 `SuspendEvent`；宿主按文档语义会误判 |
| B5 | `RunXispTool.runSeq` 跨回合重复 | 每个回合第一次 PTC 都是 `run_xisp#1`，子调用 id 撞号（只影响事件显示） |
| B6 | `resumedAnswersForSub` / `statusKey` 是实例字段 | 7 处宿主创建点全部每请求新建 → 隐患非 bug；但一旦复用实例，**重放可能命中别人的答复等于跳过审批** |
| B7 | verify 与 length-continuation 回合计数不一致 | 自验会重置续跑预算（上界靠 maxTurns 兜）；默认 `maxVerifyPasses=0` 关闭 |
| B8 | `scope.finished` 是 Bool | 结束原因丢失，AG-UI 的 `RunFinished.reason` 把"钩子短路""预算耗尽"都报 success |
| B9 | 异常路径跳过 `afterRun` 钩子 | `callHooks("afterRun")` 在 try 内，catch 直接跳过，而 finally 照走 |
| B10 | 压缩期间无取消检查点 | `compactBeforeRequest` 签名无 cancelFlag，内部有完整同步 provider 调用 |

### C 类：可接受（有理由的取舍）

- 修剪口径分叉（`measureMessages` 用修剪版测压、压缩作用未修剪版）：实测**不会索引错位**（`pruneToolResults` 每条消息恰好输出一条），方向也不是过度压缩而是压得更轻；唯一偏差是台账报的 token 偏小。
- `TurnEndEvent` 11 个发射点：配对成立不重复，仅两处瑕疵（provider 失败路径缺 `MessageEndEvent`、钩子短路会发空步）。
- `continue` / `break` 混用、死参数（`recoverFromOverflow` 的 `chatReq`）、`status.cj` 注释与实现不符。

---

## 3. 「文件能不能拆」的结论

### 3.1 为什么前两次失败了

日志记录的两次尝试：①「阶段类共享 RunState」②「extend 按主题拆」——都撞在同一个墙上。
这次核对到两个结构性事实：

1. **`extend` 不能给自己的类拆文件**：规则是单向的（extend 可调主类字段/方法，主类调不到 extend 的方法），且类声明接口后方法只写在 extend 会报 `missing abstract modifier`。carbon-cj 能按主题拆 12 个文件，是因为它的 struct **不声明任何接口**、主类仅 53 行且不反向调用。`AgentRuntime` 是 `AgentLoop` 的实现类，正常写法就是 `<: AgentLoop` + 类体实现。
2. **真正的原因是状态归属**：`AgentRuntime` 的 27 个字段里放的是**权威状态**。dsh 主类 8 个字段里**没有一个**是业务消息集合——它把权威状态放进了 session 事件流 + 投影。**没有这层，任何拆分都只是把 `this.` 的访问搬到别的文件里，耦合没变。**

### 3.2 现在能做什么、不能做什么

| 做法 | 可行性 | 结论 |
|---|---|---|
| 把大方法切成更多私有方法 | 已做过（548→270） | **边际收益在下降**，剩余块都 ≤57 行且无重复 |
| 用 `extend` 拆文件 | ❌ | 语言限制，主类调不到 extend 方法 |
| 搬走循环（pi 路线）：`runTurnLoop(scope, driver)` 顶层函数 + `LoopDriver` interface | ⚠️ 可行但有代价 | 仓颉无闭包逃逸，要靠 interface；`AgentRuntime` 实现 `LoopDriver`。**但这只搬走 270 行，主类还剩 1400 行**，不解决状态问题 |
| 拆成"状态持有者"（dsh 路线） | ✅ 正确方向 | 前提是**先建事件/投影层**，让权威状态有唯一归属 |
| 现在就拆文件 | ❌ 不建议 | 没有状态层，拆出来的是"同一个类的碎片文件"，比现在更差 |

### 3.3 若要真拆，正确顺序

1. **先建会话事件流**：`AgentEvent` 目前是**过程通知**（agent_start / turn_end…），不是**可物化的真相**。`SessionStore` 是整份 `save()` 快照，不是追加式事件日志。dsh 与 pi 都靠"事件/日志 + 投影 fold"让子系统只持派生状态。
2. **再按状态归属切类**：`cancels` / `steers`（权威，留 runtime）、`resumedAnswersForSub` / `statusKey`（瞬态，进 `RunScope`）、去重游标（`warnedModels` / `warnedCompactionSpec`，应独立）。
3. **最后才谈文件**：那时每个类自然有自己的文件。

> 一句话：**先有可物化的真相，才谈得上拆。** 这不是"行数问题"，是"状态所有权问题"。

---

## 4. 本次实际改动

worktree 分支 `probe/loop-orchestration`（基于 master `9e6f7d9`），6 个提交：

| 提交 | 内容 |
|---|---|
| `2fe2b99` | A1 预算耗尽：给每个 tool_call 补配对结果；文案收口到 `skippedByToolBudgetNote()` |
| `83d7d23` | A2 空历史：抽 `announceTurnMessage`，源头判空；**空历史不发 MessageStartEvent**（载荷是一条具体消息，伪造会让协议适配层等一个永不到来的正文） |
| `b9adeef` | A3 run 作用域工具落派生视图：`RunScope` 增 `tools` + `toolExecutor`，run 期注册/查表/PTC 授权/5 个 hook 统一走视图 |
| `abd9747` | A4 交还历史前收口（正常 + 异常路径），`RunScope.suspended` 跳过挂起 |
| `0794650` | B2 压缩移到 `beforeTurn` 之后，并按 `chatReq.model` 重算窗口（压完重建请求） |
| `0b479ba` | A5 截断时同步平移 Archive 下标（含空范围表达，避免钳到 [0,0] 反吃第一条） |

**A4 途中发现的真实设计冲突**：挂起路径是**刻意**让历史停在 `assistant(tool_calls)` 且不写结果的（结果由下次 run 带回，注释原话"写了就等于伪造"）。无脑收口会伪造结果——既有用例 `suspend_doesNotWriteResultMessage` 立刻抓住了，于是补 `RunScope.suspended` 跳过。**既有用例在这里起到了正确的守护作用。**

**测试**：基线 958 → **982**（+24），全绿。B2 的用例做了**反向验证**（临时回退旧行为 → 两条正向用例确实 FAILED，反向锚点仍 PASS），不是靠"总是压"蒙过去。

---

## 5. 建议的下一步（按性价比排序）

1. ~~A5 修完~~（已完成）
2. **B3 工具列表排序**——一行改动，直接改善提示词前缀缓存命中率。
3. **B4 拆分 `ToolBatchOutcome`**——把"等外部输入"与"整批失败"分开，避免宿主误判。
4. **B8 把 `scope.finished` 升级成 `TurnEndReason` 枚举**——对应 dsh 的 `turnEnds`，让 AG-UI 能报出真实结束原因。
5. **B9 `afterRun` 钩子挪进 `finally`**——"run 结束"契约在失败路径才成立。
6. 事件/投影层（工程量大，需单独立项）。
