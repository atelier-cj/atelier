# dsh 上下文压缩方案调研（对照 `@deepseek-ai/dsh` 0.2.0-rc.2）

> 目的：弄清 dsh 的压缩在**什么时候、按什么口径、压哪一段、怎么记账**，以及 atelier 现在缺什么。
> 结论供"把默认压缩改成 dsh 那种"这一步使用；本文件只做调研与差异分析，不含实现决策的最终拍板。

## 一、它拆成了五个包，各管一段

| 包 | 职责 |
|---|---|
| `dsh-compaction` | **seam**（接口契约）：定义 `compactIfNeeded`（自动：压力 / 溢出）、`compactNow`（按需）、`compactRegion`（显式范围）；本身不压缩 |
| `dsh-compaction-basic` | 随附后端：策略（阈值/保留）、范围选择、摘要调用、事务与锁 |
| `dsh-token-meter` | 计量服务：回放持久日志的 fold，给"压力/保留/选区/缩减验证"用同一份数字 |
| `dsh-compaction-tool-result-pruner` | 可选：把超大工具结果换成"头 + middle pruned + 尾" |
| `dsh-command-compact` | `/compact` 用户命令（**不是模型工具**） |

另有两个相关件：`dsh-compaction-image-offload`（图片省略）、`ctx.llm.resolveModelInfo().context`（容量来自**适配器**，即 provider × model 路由）。

## 二、策略公式（核心，代码里逐字确认）

```text
W = 适配器声明的上下文窗口（provider × model 路由）
O = 该路由**生效请求**的输出预留（envelope.maxTokens）
B = headroomTokens（默认 65536）

messageBudget  = W − O
pressureBudget = messageBudget − B
threshold      = floor(min(W × thresholdRatio, pressureBudget))   // thresholdRatio 默认 0.8
retain         = floor(messageBudget × retainRatio)              // retainRatio 默认 0.16，或绝对 retainTokens
```

不变量（违反即报 `TargetPressureConfigError`，消息里直接教你怎么配）：

- `messageBudget > 0` —— "configure the adapter model's contextWindow above the effective request maxTokens"
- `pressureBudget > 0` —— 提示减小 maxTokens / headroom，或换更大窗口的模型
- `retain < threshold`

按 `(provider, model)` 路由解析，`modelPolicies` 可逐路由覆盖；**低于阈值绝不触碰**。

要点：阈值把**输出预留**（O，真实请求要花的）与**额外余量**（B，估算误差/图片/工具声明的缓冲）分成两笔，而不是一个笼统的 reserve。默认 B 很大（64k），所以默认行为相当保守——自动压缩只在真正逼近上限时才发生。

## 三、触发点有三处

1. **`agent/pre-step`（请求派发之前）**：串行 listener，用 token meter 给"最新持久化的路由请求 envelope"计价，越过阈值就先修剪、再摘最旧的平衡范围。
2. **`agent/request-error` + `CONTEXT_WINDOW_EXCEEDED`**：**绕过阈值与保留策略**，做一次"最大平衡头部缩减"，成功后才授权重试该请求（`maxOverflowRetries` 默认 1，0 = 关闭恢复）。
3. **`/compact` / `compactRegion`**：按需；agent 正在回合中或压缩已在进行时报"暂不可用"（busy），期间的提示词被接受、压缩结束后才开始。

另外：压缩后压力仍高于阈值时可再试 `compactionRetries`（默认 1）次。

**降级行为值得抄**：自动路径遇到配置错误（容量缺失、预算算不出来）时，**只警告一次并跳过主动压缩**，而溢出恢复仍然可用——坏配置不会把会话变成不可用。

## 四、压哪一段：最旧的"平衡"范围

- 取**最旧**的平衡范围替换为一条摘要消息，近期尾部逐字保留（retain 预算）。
- 范围**绝不从 surface 节点 0 开始** → 系统提示词永不被遮蔽；历史中追加的 `system/message` 属于普通历史，可以被遮蔽。
- **工具配对边界**：`toolPairingBalancedBefore/After` 保证不跨越"尚未被回答的 assistant 工具调用"，且边界必须落在当前表层上。
- 不可分单元（例如一次超大工具调用）压不动 —— 这是修剪器的活儿。
- 压缩**不碰**系统提示词、工具声明、会话前缀。

## 五、表层只改一次，日志留痕做事务

- 唯一表层变更：一条带 `surfaceOp: { op: 'replace', startSeq, endSeq }` 的 `user/message`，正文是 `<compacted-summary>…</compacted-summary>` 包装的摘要。
- 日志留痕形成事务与锁：`compaction/start`（取锁）→ `compaction/summary`（原始摘要留档）→ 替换 → `compaction/end`（释放）。
- 替换发生在 start/end **之内**：中途崩溃留下可检测的残留锁，而不是谎报成功；闭合失败**故意**留下未匹配 start 表达 busy。
- 被遮蔽的事件仍留在日志里 → 回放可确定性地重现同一份"压缩后的对话"。

## 六、摘要子调用怎么发（和我们现在的做法相反）

- `ctx.llm.stream()`，`GenerateOptions.purpose = "compaction"`。
- 消息构造：**surface 节点 0 的系统提示词** + 被遮蔽区域的消息 + 该路由**有效工具声明**，最后追加一条 user 指令；目的是**复用 provider 的热前缀（KV cache）**——只有尾部指令与摘要输出未命中缓存。
- 只取返回文本：推理与工具调用一律丢弃；空摘要或"没让输入变短"的摘要被**拒绝**。
- 目标模型：显式 `summarizationProvider/Model` > 最新已路由请求目标 > `AgentOptions`。
- `maxTokens` 默认 = headroomTokens（65536），需覆盖时按模型单独给。

## 七、计量口径：回放 fold + 严格条件下的 usage 复用

- `ctx.tokenMeter.measure(session)` 是**回放持久日志的 fold**：确定性、不发模型调用、O(surface)。
- **只有**"最新成功调用的规范请求 envelope 与当前测量 envelope 完全一致，且其总量不低于该次调用的完整路由定价"时才复用 provider 报告的 usage；否则对完整 envelope 与表层做估算。
- 启发式是固定规则（约 4 字符/token + 块与角色开销）；官方自己点名 **CJK 与 JSON schema 会严重低估**。
- 对外三个投影：`tokenUsage`（uncached/输出/缓存读写）、`contextPressure`（`pressureTokens` 提供方报告、`projectedTokens` 下一个请求的预估、`contextWindow`）、`contextBreakdown`（system/tools/messages 的近似构成）。
- 明确声明：占用数字是参考，不是计费；harness 里只有压缩读 `measure()` 做决策。

## 八、修剪器：可能把摘要整个省掉

- 默认：合并文本超过 **8192 码点**的工具结果 → 保留头 **4096** + `middle pruned` 标记 + 尾 **1024**；按 Unicode 码点切，不会劈开 emoji 对。
- **只在压缩触发条件满足之后**运行（低于压力绝不触碰）。
- 修剪后若压力已回到阈值内 → **跳过摘要调用**（省钱省时间）。
- 原始结果仍在会话日志；替换保留工具调用、步骤、错误与元数据，只改文本内容。

## 九、与 atelier 现状的对照

| 维度 | dsh | atelier 现状 | 差距 |
|---|---|---|---|
| 阈值模型 | `min(W×0.8, W−O−B)`：输出预留与余量分两笔 | `total > W − reserve`（reserve 笼统，默认 16384） | **要改口径** |
| 保留预算 | `(W−O) × 0.16` 或绝对 `retainTokens` | `keepRecentTokens`（默认 20000，绝对） | 口径不同，可共存 |
| 触发时机 | 请求派发**前**（pre-step） | 回合结束**后**（afterTurn） | 可前移 |
| 溢出恢复 | 有：`CONTEXT_WINDOW_EXCEEDED` → 最大头部缩减 → 重试一次 | **完全没有**（长任务直接 400 失败） | **最大空白** |
| 范围选择 | 最旧平衡范围 + 工具配对 + 不动系统提示词 | 切点选择 + 工具调用配对保护（`cutpoint.cj`） | 基本对齐 |
| 摘要子调用 | 复用主对话热前缀（带 system + tools） | 刻意**不带** system/tools（注释理由：缓存 Key 独立、不污染主对话） | 取舍需实测 |
| 工具结果修剪 | 有，且可能省掉摘要 | 无 | 缺 |
| 事务/锁 | 日志标记对，可检测残留 + busy 语义 | 无（压缩在回合内同步做，崩溃窗口小） | 视是否需要并发入口 |
| 计量 | 回放 fold；严格条件下复用 usage；4 字符/token 提示 CJK 低估 | usage 优先 + `estimateTokens` 兜底 | 口径接近 |

## 十、给 atelier 的落地建议（分步）

1. **P0 · 阈值换成 dsh 口径**：`messageBudget = W − maxOutputTokensInUse`，`threshold = min(W × 0.8, messageBudget − headroom)`，`retain = messageBudget × 0.16`（保留绝对覆盖的口子）；三个不变量校验，配置错误时"警告一次 + 跳过主动压缩"而不是让会话不可用。
   —— 我们刚加的 `ModelInfo.maxTokens`（provider × model 的完成预算）正好就是 O；`AgentConfig.maxOutputTokens = 0` 时它由模型事实解析。
2. **P0 · 补溢出恢复**：识别 provider 的上下文超限报错 → 强制一次最大头部缩减 → 重试该请求一次（上限可配）。**这是当前最大的功能空白**。
3. **P1 · 触发点前移到请求前**：在 `ContextBuilder` 构建请求处检查压力，避免"已经超了才在回合后压"。
4. **P1 · 工具结果修剪器**：超大 bash/read 输出做头+尾保留，只在触发后跑；对"一次 bash 输出十万行"这类会话收益最大（还可能省掉摘要）。
5. **P2 · 摘要调用复用热前缀**：把我们现在的"独立子调用"改成"带 system + tools 的前缀调用"，但要先实测缓存命中与计费口径再定（我们原注释的顾虑是真问题，不是笔误）。
6. **P2 · 台账与 busy**：日志标记对（start/summary/end）与未匹配 start 的 busy 语义——取决于我们是否要引入并发压缩入口（`/compact`）。

## 十一、实施状态（本分支）

| 步骤 | 状态 | 提交 |
| :--- | :--- | :--- |
| P0-1 阈值 dsh 口径（三个不变量 + 配置错误不压） | 已落地 | `74b39ac` |
| P0-2 溢出恢复（文本匹配 + 最大头部缩减 + 重试） | 已落地 | `74b39ac` |
| P1-3 触发点前移到请求前 | 已落地 | `d1486ca` |
| P1-4 工具结果修剪器（先修剪后摘要，只作用于请求） | 已落地 | `d1486ca` |
| P1-5 默认摘要指令换 dsh 八节骨架 | 已落地 | `d1486ca` |
| P2-5 摘要子调用复用热前缀 | 已落地（DeepSeek 硬盘缓存按"缓存前缀单元完整匹配"计费，内联对话等于整段未命中） | `de5963a` |
| P2-6 台账与 busy：`compaction_start`/`compaction_end` 成对 + 跨 runtime 会话级互斥 | 已落地（内存台账；压缩结果与消息表同一次原子写入，不留持久悬挂态） | 本分支 |
| P2 检查点前言 + `<compacted-summary>` 标签 | 已落地（需 `llm_api` 1.4.1：`CompactionMessage` 原样渲染） | `dd8e817` / `llm_api 97db060` |

未做（有意留白）：`/compact` 手动入口（有了它才需要持久化的事务台账才值得做）、图片/结构化块的专门修剪策略。

## 附：本次调研的证据位置

- 文档：`dsh-compaction`、`dsh-compaction-basic`、`dsh-token-meter`、`dsh-compaction-tool-result-pruner` 各自的 `README.zh.md`
- 代码：`dsh-compaction-basic/lib/index.js`（`resolveCompactSpec` 的阈值与不变量、`agent/pre-step` / `agent/request-error` 两个 listener）
- atelier 现状：`atelier/src/agent/runtime.cj`（afterTurn 触发）、`atelier/src/context/compaction.cj`、`atelier/src/context/cutpoint.cj`
