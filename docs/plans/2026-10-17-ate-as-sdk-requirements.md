# atelier 作为 SDK 的能力需求整合（重构基准）

> 日期：2026-10-17 ｜ 状态：**需求整合稿**（重构的基准，先定它再动代码）
> 定位：**atelier 是底层 SDK**，世界树 / atelier-lumine / starline 都是**基于它做的产品**。
> 本文整合三方需求 + 现有缺口，推导出**重构的基准模式**，作为后续所有改动的前提。
>
> 关联：
> - `docs/plans/2026-10-17-always-on-requirements.md`（always-on 需求 A~E 组）
> - `/home/ystyle/Projects/Cangjie/docs/plans/2026-10-02-always-on-agent.md`（产品总设计 v4）
> - `docs/design.md` 第十三章（库集成扩展点矩阵，2026-09-05 盘点）

---

## 0. 本文要解决的问题

**atelier 的定位是「嵌入式 harness 底层 SDK」，但它的可替换性只做到了数据层和工具层，没做到控制流层。**

三方产品现在的真实需求把这件事暴露出来了：

| 产品 | 定位 | 需要 atelier 提供的 | 现状 |
|---|---|---|---|
| **atelier-lumine** | Windows 桌面 AI 工坊 | **自己的会话存储**（jsonl） | ⚠️ **有自己的 jsonl 实现，但没接进 `SessionStore` 接口** |
| **世界树**（atelier-yggdrasil） | 复刻 dsh 的插件宿主 | **能换掉循环实现** + 换压缩策略 | ❌ 压缩焊在循环里；循环已提为 `AgentLoop` 接口（世界树当前用的是 `chatWithSessionId`，尚未换实现） |
| **starline** | 常驻智能体产品 | **不需要 atelier 的循环**（自持 `LiveboardRuntime`） | ✅ 已自持循环；从 atelier 只取叶子组件（Message / Provider / Tool / Skill） |

**一句话：三个产品要换的是三样不同的东西。** 循环与压缩的可替换点已就位（`AgentLoop` /
`Compactor`），但**没有任何下游真的换过实现**——目前所有宿主都还在用 `AgentRuntime`。

> **一处必须纠正的预期**：曾把 starline 当作 atelier 循环的消费者，据此设计了「无会话 run 入口」。
> 核实后不成立：starline `docs/design.md:123` 明确「**不改造现有 AgentRuntime**……Liveboard 是
> **平行新层**」，其 `src/core/runtime.cj` 是自研的 74 行循环，全仓 `AgentRuntime` /
> `createLoop` / `HarnessSpec` 引用数为 **0**。**不要把 starline 的产品形态当作 atelier 接口的设计依据。**

---

## 1. 需求来源一：下游要换什么（按能力分类，不按产品）

> **本节只记「atelier 需要提供哪几类可替换点」，不记任何下游产品的实现细节或取舍**。
> 某个产品用不用、为什么不用，是它自己文档里的事，写在这里会把通用库绑在消费方身上。

### 1.1 存储（已有接口，无需新增）

`SessionStore`（`atelier/src/session/store.cj`）**已存在且已有一个以上实现**：

| 实现 | 位置 |
|---|---|
| `StormSessionStore`（bstorm 后端） | `atelier/src/session/file_store.cj:36` |
| `MemorySessionStore`（内存后端） | `atelier/src/session/memory_store.cj:6` |

**判据：接口是否需要新增能力？** 现有方法集（`save` / `appendBranch` / `load` / `loadEntries` /
`list` / `delete` / `fork` / `appendCompaction` / `loadCompactions` / `close`）覆盖了
会话持久化的完整面。**本档不需要动它。**

> **一条对外契约（写给所有下游）**：`SessionStore` 的模型是「**agent 会话**」——
> `SessionHeader` + 树形 `Entry` + 密封 `Message`（User/Assistant/ToolResult/Compaction）。
> **产品侧的聊天记录若与这个模型不同构，就不该硬接这层**：写适配层换来的是
> 双向转换 + 字段丢失，比不接更糟。是否需要「产品聊天记录」这类存储，属于产品自己的设计。

### 1.2 循环（缺失，本设计要补）

下游需要能**换掉整个 agent 循环**。

**dsh 的分层可作参照（290 个包）**：

```
dsh-agent          → Agent 接口 + AgentRegistry + AgentFactory（只管"是什么"）
dsh-agent-loop     → ReactLoopAgent implements Agent（2494 行，管"怎么跑"）
dsh-compaction     → 压缩接口
dsh-compaction-basic            → 1027 行实现
dsh-compaction-image-offload    → 图片卸载
dsh-compaction-tool-result-pruner → 工具结果修剪
```

**dsh 的关键设计**（`dsh-agent` 的注释原文）：

> **Agent service: live registry, factory delegation... Concrete creation and driving belong to the loop.**

**即：`Agent` 接口只管身份（`readonly id: SessionId`），行为约束在 `AgentHandle`（`status`/`cancel`/`send`/`whenIdle`），真正的循环是 `loop` 这个可替换实现。**

**atelier 现状**：`AgentRuntime`（约 1579 行）是**具体类**，主循环在 `private func chatWithEnv`，
`HarnessSpec` 无 `loop` 字段 —— 详见 §2.4。

### 1.3 压缩（缺失，本设计要补）

**下游为什么需要换压缩策略**（来自 always-on 需求 §D3）：记忆层与上下文压缩
**触发条件不同**（token 用量 vs 分段信号），混成一根管子会"调窗口参数莫名改动记忆质量"。

**现状**：压缩代码分两处——

| 位置 | 内容 |
|---|---|
| `atelier/src/context/compaction.cj`（727 行） | `CompactSpec` / `resolveCompactSpec` / `CompactionLedger` / 修剪 / 摘要 |
| `atelier/src/agent/runtime.cj`（约 1579 行）**里的调用逻辑** | 请求前压力检测、溢出恢复、括弧事件、台账写入、`retry` 路径 |

**所以压缩现在既不是接口，也没独立成包。**

### 1.4 四类可替换点的小结

| 能力 | 现状（v3，2026-10-17 核） | 本设计要做的 |
|---|---|---|
| **存储**（`SessionStore`） | ✅ 接口 + 两个实现 | 不动 |
| **信任判定**（`TrustGate`） | ✅ **已提为函数类型**（A-1 完成） | 无 |
| **压缩**（`Compactor`） | ✅ **已提为 interface**（`BasicCompactor` / `NoopCompactor`） | 剩 B-2：默认实现独立成包（当前与接口同包不同文件） |
| **循环**（`AgentLoop`） | ✅ **已提为 interface + 工厂**，硬编码构造点已全部改走 `createLoop` | 剩 C-2：主循环内部再拆（已完成 2 步） |

---

## 2. 需求来源二：现有缺口盘点（2026-10-17 实测）

### 2.1 接口 vs 实现的总体比例

| 项 | 数量 |
|---|---|
| `public interface` | **7** |
| `public class` | **96** |
| `public open class` | 4 |
| `public enum` / `struct` | 15 / 29 |
| `public func`（顶层） | 143 |

### 2.2 按包分布（**按被引用次数排序**）

| 包 | interface | class | 被引用 | 诊断 |
|---|---|---|---|---|
| **message** | 0 | 0（纯 struct/enum） | **58** | 数据层，合理 |
| **tool** | **1**（`Tool`） | 17 | **54** | `ToolRegistry`/`ToolExecutor`/`McpManager` **未抽象** |
| **provider** | 0（复用外部 `llm_api.Provider`） | 1 | **31** | 外部接口已存在，合理 |
| **session** | **1**（`SessionStore`） | 5 | **26** | ✅ 接口在，但**消费者没接**（见 §1.1） |
| **skill** | 0 | 3 | **24** | `SkillRegistry` 未抽象（低优先） |
| **context** | **1**（`PromptSegmentContributor`） | 5 | **22** | ⚠️ **压缩、ContextBuilder 未抽象** |
| **trust** | **0** | 1 | **20** | ⚠️ **完全不可替换** |
| **event** | 0 | 0 | 18 | `EventStream` 为泛型类，无需接口 |
| **interaction** | 0 | 4 | **16** | 数据层为主，合理 |
| **util** | 0 | 1 | 12 | 合理 |
| **agent** | **3** | **38** | **10** | ⚠️ **核心控制流，却是接口最少、被引用最少** |
| **config** | 0 | 10 | 0 | 数据层，合理 |
| **ptc** | **1** | 5 | 5 | 尚可 |
| **acp / a2a** | 0 | 5 + 5 | 0 | 边界适配层，合理 |

### 2.3 现有 7 个接口（全部）

| # | 接口 | 位置 | 粒度 |
|---|---|---|---|
| 1 | `Tool` | `tool/interface.cj` | 工具 |
| 2 | `SessionStore` | `session/store.cj` | 存储 |
| 3 | `Hook`（6 相位，全默认实现） | `agent/hook.cj` | 回合/工具 |
| 4 | `ProviderMiddleware`（`wrap` 链） | `agent/provider_middleware.cj` | **单次模型请求** |
| 5 | `AgentEvent` | `agent/event.cj` | 事件 |
| 6 | `PromptSegmentContributor` | `context/system_prompt_builder.cj` | 提示段 |
| 7 | `PtcSubCallHost` | `ptc/binding.cj` | PTC 子调用 |

### 2.4 三个最刺眼的缺口

#### 🔴 缺口 1：核心循环不是接口

| 事实 | 位置 |
|---|---|
| `AgentRuntime` 是 `open class`，**4 个入口是 `open`** | `runtime.cj:99,534,543,557,562` |
| **但 537 行的主循环在 `private func chatWithEnv(sessionId, ...)`** | `runtime.cj:585` |
| 那 4 个 `open` 方法**全是转发壳** | 覆盖它们等于丢掉整个 agent 能力 |
| **10 处**硬编码 `AgentRuntime(...)` 构造** | `server/handler.cj`×3、`cli/tui.cj`×2、`cli/app/main.cj`、`server/ag_ui_handler.cj`、`agent/agent_tool.cj`、`agent/session_loop.cj`、`agent/harness.cj` |
| `HarnessSpec` **没有 runtime/loop 字段** | `harness.cj:32-56`（**13 个字段**，无 factory） |
| `agent/` 下**没有任何 loop 接口** | 只有 `Hook`/`ProviderMiddleware`/`AgentEvent` |

#### 🔴 缺口 2：`trust` 包 0 接口，且是自由函数

```cangjie
// atelier/src/trust/gate.cj（27 行，全部内容）
public func shouldAllowFor(tool: Tool, workDir: String,
                            trustManager: TrustManager, sessionId: String): TrustDecision
```

**问题**：这是**顶层函数**而非方法，参数是**具体类 `TrustManager`**。想换信任策略只能改源码。

> 而 always-on 的 A2（便利性预授权）明确要求"可换策略"——**这一条现在做不到**。

#### 🔴 缺口 3：`Idle` 状态无处安放（always-on B 组）

**核实**：`AgentRuntime` **每次 run 新建一个**（`session_loop.cj:77`）。

**后果**：`Idle`/`Queued` 这类"run 之间"的状态**没有持有者**。

**dsh 的对照**——它有原生答案：

```typescript
/** An agent's lifecycle state, emitted on every transition as `agent/status` */
export type AgentStatus = 'idle' | 'running';
```

> `idle` means no driver is active; `running` begins when waking input starts cancellable pre-step processing...
> **Disposal removes the agent from its registry; it is not a third observable status.**

**即：dsh 的 loop 实例比一次执行长寿**，所以 `idle` 有地方住。

---

## 3. 需求来源三：always-on（沿用 A~E 组，此处只列**对 SDK 的影响**）

详细条目见 `2026-10-17-always-on-requirements.md`。本文只吸收**改变 SDK 形状**的部分：

| always-on 组 | 对 SDK 形状的影响 |
|---|---|
| **A0** 入口解绑会话 | loop 接口**不能要求 `sessionId`**（改成可选的"注意力快照"） |
| **A1** RunPolicy | 模式是 **loop 实例的属性**，不是 per-run 的 config 字段 |
| **A2** 便利性预授权 | 需要 `TrustGate` 接口（对应 §2.4 缺口 2） |
| **A3** 唤醒门控接口 | 新增 `WakeGate` 接口（无实现，只定契约） |
| **B** run 之间的状态 | **必须有比 run 长寿的持有者** → loop 实例长寿 + `AgentStatus` |
| **C** 触发源 | `run` 的入参，可扩展类型 |
| **D1** 缓存友好布局 | 提示装配必须能分"稳定前缀 / 动态段" → `PromptSegmentContributor` 要标明段性质 |
| **D2** PTC 注册 | 已有 `PtcSubCallHost`，够用 |
| **E1** 特权代执行 | 复用 `ExternalRequest.reason`（已核实是 `String` 非枚举，加取值零成本） |
| **E2/E3** 资源与审计 | 只需事件/日志埋点，不改变接口形状 |

---

## 4. 重构的基准模式 ⭐（本文的核心产出）

盘点清楚后，**要做的不是发明新机制，而是把已经正确的东西补齐到缺它的位置上。**

### 4.1 三段式（所有能力都按这个套）

```
① 接口在哪       —— atelier/src/<domain>/interface.cj（纯契约，零外部依赖）
② 默认实现在哪   —— atelier/src/<domain>/default_*.cj 或独立成员包
③ 怎么装         —— HarnessSpec 的一个字段 + 一个 with* 派生
```

**验证：现有 7 个接口里已有 5 个符合这个模式**（`Tool` / `SessionStore` / `Hook` / `ProviderMiddleware` / `PromptSegmentContributor`）。

**所以这次重构 = 把这个模式补到 `AgentLoop` 与 `Compactor` 两个缺失位置。**

### 4.2 接口还是函数类型？——先问「有没有状态」

仓颉的函数是一等公民，`type XxxFn = (...) -> ...` 本身就是可注入的扩展点，
**而且我们已经在重用它三次**：

| 现成的函数类型 | 位置 |
|---|---|
| `AskFn = (UserRequest) -> UserAnswer` | `tool/interface.cj:25` |
| `PtcBindingFunction = (JsonValue) -> PtcBindingOutcome` | `ptc/types.cj:78` |
| `PtcAuthorizer = (Tool, JsonValue) -> PtcAuthDecision` | `ptc/types.cj:255` |

**判据（按优先级）**：

| 条件 | 用什么 | 理由 |
|---|---|---|
| **有状态**（跨调用保留 `idle`/`running`、计数、台账） | **interface + 类** | 函数靠闭包也能捕获变量，但**对开发者不友好**：状态藏在闭包里看不见、不好调试、不好复用 |
| **无状态但多方法** | interface | 函数类型表达不了多方法 |
| **单方法且无状态** | **函数类型 `type XxxFn`** | 宿主一行 lambda 就能接，不必写类（`withAsk` 已是这个体验） |

**据此对四个扩展点分类**：

| 扩展点 | 形态 | 理由 |
|---|---|---|
| **`AgentLoop`** | **interface（必须）** | 要持有 `idle`/`running` 生命周期 + 三个方法。**闭包捕获状态对开发者不友好**——这是决定性理由，不是语言能力的限制 |
| **`Compactor`** | interface | 多方法（`shouldCompact` + `compact`），且台账/去重可能需要状态 |
| **`TrustGate`** | **函数类型** | 单方法、无状态：`type TrustGate = (Tool, String, String) -> TrustDecision` |
| **`WakeGate`** | **函数类型** | 单方法、无状态：`type WakeGate = (OverviewFeatures) -> WakeDecision` |

> **一条设计纪律**：**SDK 的扩展面优先做成函数类型**（接入成本一行），
> **interface 只留给确实有状态的**。这条对三个消费方都友好——世界树复刻 dsh 时
> 大量注入点都是无状态的策略判断，用 lambda 比写类轻得多。

### 4.3 为什么不做第三套回调机制（`RunStage`）

**曾考虑**：加 `RunStage`（wrap 链，仿 `ProviderMiddleware`）。

**否决理由**：

| 理由 | 说明 |
|---|---|
| **已有两套够用** | `Hook`（6 相位，run/turn/tool 粒度）+ `ProviderMiddleware`（请求级） |
| **压缩不是"横切"，是"可替换的核心能力"** | dsh 的做法是独立包而不是中间件（`dsh-compaction-basic` 是插件，不是 middleware） |
| **SDK 要保持机制数量少** | 三个产品各有偏好，机制越多越难对齐 |

**结论**：用「**接口 + 装配字段**」——与 `SessionStore`/`Tool` 完全同构，不发明新概念。

### 4.4 分层插拔点（最终形态）

| 层 | 粒度 | 机制 | 状态 |
|---|---|---|---|
| **请求级** | 一次模型调用 | `ProviderMiddleware` | ✅ 已有 |
| **回合级** | 一轮「模型+工具」 | `Hook`（6 相位） | ✅ 已有 |
| **能力级** | 压缩 / 提示装配 / PTC | **`Compactor`** / `PromptSegmentContributor` / `PtcSubCallHost` | ⚠️ **`Compactor` 缺** |
| **循环级** | 整个 run 的生命周期 | **`AgentLoop`** | ⚠️ **缺** |
| **装配级** | 组件从哪来 | `HarnessSpec`（13 字段 → **15 字段**） | ⚠️ 缺 `loop` / `compactor` |

> **插话（`steer`/`inject`，§11）不属于上面任何一层**：它不是"插拔点"，而是
> **loop 运行期的输入通道**——所以在 `AgentLoop` 接口上，不在 `HarnessSpec` 里。

---

## 5. 要实现的东西（三档，全部要做）

> 用户决定：**不考虑工期，夯实 SDK 优先。** 以下三档按依赖顺序排列，但都要完成。

### 档 A —— 标准化已有能力

| # | 做什么 | 现状问题 | 验收 | 状态 |
|---|---|---|---|---|
| **A-1** | 信任判定提为可注入闸门 | `shouldAllowFor` 是自由函数、策略焊在函数体 | `type TrustGate = (Tool, String, String) -> TrustDecision` + `pathTrustGate` 工厂 + `HarnessSpec.withTrustGate`；旧函数保留兼容包装 | ✅ **已完成**（2026-10-17） |
| **A-2** | **提示段稳定性标记**（原 A-3） | 所有 `PromptSegmentContributor` 一律当稳定段排在前面；动态段（时间戳、面板渲染）会打掉缓存前缀 | `PromptSegmentContributor.stability(): SegmentStability`（默认 `Stable`）；`ContextBuilder` 按稳定性排序 | ✅ **已完成** |
| **A-3** | 补 `HarnessSpec` 派生（原 A-4） | 新增字段要有对应 `with*` | `withTrustGate` 已加；后续新增接口逐个补 | 随各档进行 |

**关于 `ContextBuilder` / `SystemPromptBuilder` 要不要接口化**（原待决 1）：**不做**。核实结论见 §7 已决第 1 条。

> **A-2 为什么不是「让某个下游接上 SessionStore」**：那是产品自己的决策，写进 SDK 文档会
> 把通用库绑在消费方身上（仓库 AGENTS.md 的注释规范同理）。SDK 侧只负责
> **把契约说清**（见 §1.1 的对外契约），用不用是下游自己的事。

### 档 B —— 压缩可替换

| # | 做什么 | 拆解 |
|---|---|---|
| **B-1** | 抽 `Compactor` 接口 | ✅ **已完成**：`shouldCompact` / `compact` / `pruneForRequest` 三方法 + `CompactDecision` |
| **B-2** | 默认实现独立成包 | ⚠️ **部分完成**：接口与新实现已在新文件 `context/compactor.cj`，但**未拆成独立成员包**。收益已不大，暂缓 |
| **B-3** | **把主循环里的压缩调用逻辑抽出来** | ✅ **决策边界已抽出**（交给 `Compactor` 判定）；⚠️ 时序编排（括弧/台账/互斥）**有意留在运行时**——见 §6.2 的边界说明 |
| **B-4** | 装配 | ✅ **已完成**：`HarnessSpec.compactor` + `withCompactor` + `resolvedCompactor()` |
| **B-5** | 提供"不压缩"实现 | ✅ **已完成**：`NoopCompactor` |

**B-3 是本档的真难点**：压缩不只在 `compaction.cj`，主循环里还有一大坨调用与事件编排。

### 档 C —— 循环可替换

| # | 做什么 | 拆解 |
|---|---|---|
| **C-1** | 抽 `AgentLoop` 接口 | ✅ **已完成**：`loop_interface.cj`，9 个方法 |
| **C-2** | **切分 `AgentRuntime` 主循环** | ⚠️ **部分完成（2 步）**：回合收尾判定、工具预算裁决已抽为纯函数；剩余候选边际收益递减，暂缓 |
| **C-3** | 默认实现改名 | ✅ **已决策不做**：保留 `AgentRuntime`，它 `<: AgentLoop`。零改名 |
| **C-4** | `HarnessSpec.loop` + 工厂 | ✅ **已完成**：`withLoopFactory` + `createLoop`，硬编码构造点已全部改走 |
| **C-5** | **`AgentStatus` 生命周期** | ✅ **已完成并修缺陷**：状态推进下沉到 `chatWithEnv`（四个入口真实生效）、按会话而非 agent 名记录、异常路径经 `finally` 回 `Idle` |
| **C-6** | 迁移 `SessionLoop` | ⬜ **未做**：当前位置（加载历史→调 runtime→收事件→落库）是合理的**宿主封装**，与 `AgentLoop` 不同层。见 §7 待决 5（决定保留为 (a)） |
| **C-7** | **`steer` / `inject` 插话** | ✅ **已完成**（入队 + 循环顶部 drain + 标注）；⚠️ "idle 时唤醒"未做（属 A1） |
| **C-8** | ~~`applyArchiveMarks` / `applyArchives` 保插话验证~~ | ✅ **已核实安全**：两者只处理 `ArchiveMessage`（按 index 裁剪）与 `toolName == "archive_history"` 的 `ToolResultMessage`，`UserMessage` 原样保留（§11.4 第 1 行已更新） |

**进度小结（2026-10-17 核）**：三档的**接口层已全部就位**——`TrustGate`（函数类型）、
`Compactor`（interface + 2 实现）、`AgentLoop`（interface + 工厂 + 状态 + 插话）。
剩余项都不是"接口没做"，而是**实现内部再拆**（C-2 剩余）与**包结构**（B-2），
两者收益都在递减。测试基线：**951 用例全绿**。

**C-2 与 C-6 是两个未收口项，但性质不同**：C-2 是"可以继续、但没有强理由"；
C-6 是"看过之后判定不该做"（`SessionLoop` 是宿主封装，不是循环实现）。

---

## 6. 接口草案（供讨论，非最终）

### 6.1 `AgentLoop`（档 C）

```cangjie
// atelier/src/agent/loop_interface.cj —— 纯契约（草案；落地形态见 §6.1.1）

// run 的输入：不要求 sessionId
public class RunInput {
    public let messages: ArrayList<Message>   // 本次执行的输入消息
    public let sessionId: String              // 可空串：归属线索，不是执行前提
    public let env: SessionEnvironment        // 工作目录等
}

public interface AgentLoop {
    // 生命周期状态（比 run 长寿）
    func status(): AgentStatus                // idle / running
    func drive(input: RunInput): EventStream<AgentEvent, ArrayList<Message>>
    func cancel(sessionId: String): Unit

    // 会话型入口（既有宿主的形态）
    func chat(messages: ArrayList<Message>): ...
    func chatWithSessionId(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): ...

    // 插话与注入（见 §11）：必须 interface —— 要操作队列，队列就是状态
    func steer(sessionId: String, msg: Message): Unit
    func inject(sessionId: String, msg: Message): Unit
}
```

### 6.1.1 落地后收回的设计假设（2026-10-17 补）

**`attention` / `trigger` / `policy` 三个字段没有落进 `RunInput`。**

草案里 `RunInput` 装的是「注意力快照 + 触发源 + 运行模式」，落地时只保留了
`messages` / `sessionId` / `env`。理由不是"以后再说"，而是**没有依据支撑那三个字段**：

- **`attention`（注意力快照）**：它服务的形态是「面板渲染 + 最近 N 条 + 记忆概览」，
  前提是**面板由 atelier 的循环驱动**。核实结果不是这样——starline 自持循环
  （`atelier-starline/docs/design.md:123` 原文：「**不改造现有 AgentRuntime**：它的循环
  深度耦合会话，保留给对话流；**Liveboard 是平行新层**」），其 `LiveboardRuntime.chat()`
  自行拼上下文。**没有任何宿主会传 `attention` 进来**。
- **`trigger` / `policy`**：服务的是无人值守模式（本文档 A1）。它依赖的信任/授权改造
  尚未开始，在此之前这两个字段没有消费者。

> **判据**：接口字段应当由**真实消费者**反推，而不是由想象中的产品形态正推。
> 先落 `messages`（唯一每个宿主都真有的东西），等 A1 真正落地时再加字段——
> `RunInput` 用字段而非位置参数，加字段本来就不改签名（见下方 §6.1 语言约束）。

**「面板模式的 run 入口」这份设计已迁出本文档** → 见
`atelier-starline/docs/2026-10-17-panel-mode-run-entry.md`（状态：挂起）。

它是**产品形态的设计**，归属 starline；atelier 侧没有任何消费者。留在 SDK 需求里会让
下一个维护者以为它是既定方向。**SDK 只承载已被验证的需求，产品形态留在产品仓。**

**现状备忘**：`drive` / `RunInput` 目前没有生产调用点（唯一调用在测试）。`chat` /
`chatWithEnv` / `drive` / `chatWithSessionId` 已收敛到同一份实现，`drive` 只是
「`sessionId` 可空」的语义化包装，价值是**语义清晰**（宿主不必自造空会话 id）。
**它不是"为面板模式准备的入口"**——面板模式不走 atelier 循环。

**✅ 已探针验证的语言约束（2026-10-17 实测，cjc 1.2.0）**：

| 语法 | 结果 | 对接口设计的影响 |
|---|---|---|
| `interface` 方法带默认参数 `func foo(a: Int64, b!: Int64 = 1)` | ❌ **不通过** | **接口方法的参数必须全必填** |
| `open` 函数带默认参数 | ❌ 不通过 | 与已知限制一致（`SessionLoop.run` 踩过） |
| `interface` 方法带默认实现 `func foo(a: Int64): Int64 { ... }` | ✅ 通过 | 加方法不破坏已有实现（`Hook` 就是这个用法） |
| `interface` 方法收发 `ArrayList<T>` | ✅ 通过 | `Compactor` 的消息列表传递没问题 |
| **用 Options 类包参数** `func drive(o: Opts)` + `Opts(a!: Int64 = 1)` | ✅ **通过** | ⭐ **绕开限制的标准做法** |

> **结论：接口方法一律收敛成「少数几个必填参数」**，变化的部分装进一个 Options 类
> （`RunInput` 就是这个作用）。这既绕开了语言限制，也让接口**更容易演进**
> （加字段不改签名）——两个好处方向一致。
>
> **落地佐证**：`AgentLoop.drive(input: RunInput)` 已按此形态实现。`RunInput` 当前只有
> `messages` / `sessionId` / `env` 三个字段，后续加 `trigger` / `policy` 无需改签名
> （见 §6.1.1）。

### 6.2 `Compactor`（档 B）

```cangjie
public interface Compactor {
    // 是否该压：给定当前消息与路由信息，返回决策
    func shouldCompact(messages: ArrayList<Message>, info: RouteInfo): CompactDecision
    // 执行压缩：返回替换后的历史（或原样 = 放弃）
    func compact(messages: ArrayList<Message>, decision: CompactDecision,
                 ctx: CompactionContext): CompactionResult
}
```

### 6.3 `TrustGate` / `WakeGate`（档 A，**函数类型**）

按 §4.2 的判据：单方法、无状态 → **用函数类型，不用 interface**。

```cangjie
// atelier/src/trust/interface.cj
// 与现有 AskFn / PtcAuthorizer 同一形态：宿主一行 lambda 就能接
public type TrustGate = (Tool, String, String) -> TrustDecision
//                                tool  workDir sessionId

// atelier/src/agent/wake.cj
public type WakeGate = (OverviewFeatures) -> WakeDecision
```

**默认实现仍然是函数**（不是类）：

```cangjie
// 等价于现有 shouldAllowFor 的行为，零变化
public func pathTrustGate(tool: Tool, workDir: String, sessionId: String): TrustDecision {
    ...
}
```

**装配**（`HarnessSpec.withTrustGate`）：

```cangjie
// 用默认
spec.withTrustGate(pathTrustGate)
// 或者宿主一行 lambda 覆盖
spec.withTrustGate({ tool, wd, sid => 
    if (tool.name() == "bash") { TrustDecision.NeedsApproval } else { TrustDecision.Allowed }
})
```

> **注意**：现有的 `shouldAllowFor(tool, workDir, trustManager, sessionId)` 是**自由函数**，
> 且把 `TrustManager` 作为参数传进来。改成函数类型后，`TrustManager` 由**闭包捕获**：
>
> ```cangjie
> let gate: TrustGate = { tool, wd, sid => shouldAllowFor(tool, wd, trustManager, sid) }
> ```
>
> 这样**既保留了现有行为**（零改动），又让"换策略"变成换一个函数——不需要新类型。

---

## 7. 待决问题

1. ~~**`ContextBuilder` / `SystemPromptBuilder` 要不要接口化？**~~
   **已决（2026-10-17）：不接口化。** 核实结论：
   - `ContextBuilder` **是 runtime 内部 new 出来的**（`runtime.cj:598`），`HarnessSpec` 没有它的字段——
     也就是说它**本来就不是"外部注入的组件"，而是循环内部的装配细节**；
   - 它的四个方法里，`buildChatRequest` / `applyArchives` / `applyArchiveMarks` 是**既定语义的胶水**，
     换掉等于换语义，不该开放；
   - 唯一需要扩展的是 `buildSystemText`（提示装配），而那个能力**已有官方扩展点**
     `PromptSegmentContributor`。
   **所以要做的是给 contributor 加稳定性标记（A-2），不是把 builder 接口化。**

2. **`Compactor` 的方法集边界在哪？**
   - 只给 `compact(messages) -> messages`？那"该不该压"的判断留在循环里（压缩策略不完整可换）。
   - 给 `shouldCompact` + `compact`？那循环只负责"问它、按它说的做"（推荐）。
   - 还要不要 `report`（台账/事件）？**建议事件由循环统一发**（保证括弧成对），`report` 只返回数据。

3. **`AgentLoop` 的方法集：`drive` 一次还是暴露阶段回调？** ✅ **已定：方案①**
   - 方案①：`drive(input)`（最简单，循环内部完全自主）
   - 方案②：加 `onBeforeRequest` / `onAfterTurn` 等回调（能插入中间，但等于把 `Hook` 又造一遍）
   - **定①**，理由：需要中间介入的场景已有 `Hook` 覆盖；循环级替换要的就是"整个换掉"。
   - **落地形态**：`drive(input: RunInput): EventStream<AgentEvent, ArrayList<Message>>`，
     不返回自造的 `RunOutcome` —— 事件流是既有的唯一进度出口，另造一个结果类型等于并行两套。

4. **`AgentRuntime` 这个名字保留吗？** ✅ **已定：保留**
   接口叫 `AgentLoop`，现有类保留 `AgentRuntime` 名字并 `<: AgentLoop`（零改名，语义也通）。
   附带澄清：它是 `AgentLoop` 的**当前唯一实现**，不是"默认实现之一"——仓内没有第二个实现，
   所以"能不能换"这件事只能靠测试与文档保证，没有第二个实现做实证。

5. **`SessionLoop` 的归宿？**
   它现在承担"加载历史 → 调 runtime → 收事件 → 落库"。抽 `AgentLoop` 后它可能：
   - (a) 保留，变成"会话型宿主"的便利封装
   - (b) 被吸收进 `AgentLoop` 的默认实现
   - **建议 (a)**：它是 acp/a2a/subagent 共用的宿主循环，与"agent 循环"不是一层。

6. **`AgentConfig` 的 27 个字段里，哪些该挪到 `HarnessSpec`？**
   `RunPolicy` 之类**属于实例而非配置**的，应该放 `HarnessSpec`（装配期定），而不是 `AgentConfig`（每个 agent 一份）。这条要逐个审。

7. **`AgentLoop` 确定用 interface（已定）**
   理由不是语言能力（函数靠闭包也能捕获状态），而是**对开发者不友好**：状态藏在闭包里看不见、
   不好调试、不好复用。**有状态的扩展点一律 interface + 类**——这条已写入 §4.2 的判据。

---

## 8. 不做什么（明确排除）

| 项 | 理由 |
|---|---|
| **不引入 DI 容器 / 服务发现** | 现有「装配束 + 显式注入」是刻意选择（`design.md` 十三章），与 dsh 的 cordis 是两条路 |
| **不抄 cordis 插件体系** | 那是**世界树**的职责，atelier 不该知道插件生命周期 |
| **不新增 `RunStage` 等第三套回调** | 见 §4.2 |
| **不为了"跟 dsh 一致"而改名** | 命名对齐只在语义确实相同处做（如 `AgentLoop`） |
| **不改变 903 个既有用例的行为** | 重构以**全绿**为硬验收；行为变化必须单独立项 |

---

## 9. 验收标准

| 层 | 标准 |
|---|---|
| **回归** | `cjpm test` **951 用例全绿**（2026-10-17 实测基线，`TOTAL: 951, PASSED: 951, FAILED: 0`） |
| **档 A** | lumine 能用**自己的** `SessionStore` 跑通一个会话；`TrustGate` 可换（有测试证明换了行为变） |
| **档 B** | 存在**至少两个** `Compactor` 实现（默认 / 不压缩），装配切换有测试 |
| **档 C** | **存在至少两个 `AgentLoop` 实现**（默认 / 测试用的假实现），10 处构造点全走工厂；`AgentStatus` 能从 `idle→running→idle` 有事件；**`steer` 在工具执行中途投递的插话，下一次模型调用可见**（测试要有断言） |
| **文档** | `design.md` 第十三章的扩展点矩阵同步更新（7 接口 → N 接口） |

---

## 10. 与既有文档的关系

| 文档 | 关系 |
|---|---|
| `2026-10-17-always-on-requirements.md` | **本文吸收它的 A~E 组**（只取改变 SDK 形状的部分，见 §3）；具体的 always-on 行为要求仍在那边 |
| `docs/design.md` 第十三章 | 重构完成后**回写**：扩展点矩阵从 7 个接口扩到 N 个 |
| `2026-10-02-always-on-agent.md`（产品总设计 v4） | 本文不动它；它是产品视角，本文是 SDK 视角 |
| `docs/plans/2026-09-05-acp-server-plan.md` 等历史计划 | 不受影响 |

---

## 11. 插话与连续对话（`steer` / `inject`）

> **需求来源**：starline 的产品形态要求「对话不受其它 panel 操作影响，能连续对话；
> agent 也能同时操作其它 panel」。**即：用户在 agent 干活时补一句话，它要看得到。**

### 11.1 现状：atelier 不支持插话

| 位置 | 现状 | 证据 |
|---|---|---|
| **主 agent 循环** | ❌ 无外部取消息的入口 | `runtime.cj` 主循环只看 `finished` / `cancelFlag` 两个信号；`currentMessages.add(UserMessage(...))` 仅两处，都是**内部生成**（截断续跑 / 自验 prompt），不是用户输入 |
| **TUI** | ❌ busy 时直接拒绝 | `cli/src/tui.cj:725-730`：`"上一轮仍在进行中（等它结束，或 Ctrl+C 退出）"` |
| **服务端** | ❌ 一请求一回合 | `/agent/run`、`/agent/stream` 都是"进来跑完整个回合" |
| **对比：子 agent** | ✅ **有** | `agent/subagent.cj:65` 的 `LinkedBlockingQueue<AgentMail> inbox`；`respond` 在回合中未等待时仍能投递（`:103-111`） |

**所以最有意思的一条：atelier 在子 agent 上已经在实现类似机制，主 agent 上没有。**
子 agent 的 `inbox` 正是 dsh 那套的雏形（投递 / 串行消费 / 回合内外分派），**只是没推广到主循环**。

### 11.2 参照：dsh 的四档投递

`dsh-agent/lib/types/runtime-types.d.ts` 把"往运行中的 agent 送消息"拆成四个 API：

| API | 语义（注释原文要点） |
|---|---|
| **`steer(msg)`** | 「An idle driver starts a turn; **a running driver consumes it at its next step boundary**」—— 插话，最近一个 step 边界消费 |
| `followup(msg)` | 「The item becomes the **sole ordinary message of its own turn**」—— 排队成新的一轮 |
| `inject(msg)` | 「Queue model-facing context for the next pre-step **without waking** the driver」—— 注入，不唤醒 |
| `send(msg, target, wakeup)` | 底层，`target: 'next-turn' | 'next-step'` |

**dsh 的 `step` = 一次模型调用 + 它的工具执行**（`turn` 下一级）。
所以 `steer` 的准确语义是「**下一次模型调用就能看到**」，而不是「打断当前动作」。

`inbox` 另有 `nextStep` / `nextTurn` 两个列表与 `clear()`，且 `cancel(keepInbox: true)` 能**保留待办插话**。

### 11.3 本设计的选择：**A + C**

| 维度 | 选择 | 理由 |
|---|---|---|
| **A. 生效时机** | **下一次模型调用**（不打断正在跑的工具） | starline 里 agent 正在**写面板**；打断工具会留下半写状态。需要"停下来"的场景已有 `cancelSession` |
| **C. 消息形态** | **带显式标注** `[User interjection]` | 模型默认把"最后一条用户消息"当**最新指令**。裸插会让它以为你**推翻了**原任务，而非**补充** |

**明确不做 B（立刻打断工具批次）**：与 `cancel` 语义重叠，且副作用不可控。

### 11.4 ⚠️ 历史可变性核查（**这是能不能安全插话的前提**）

`currentMessages` 在主循环里有 **5 处被整体替换**。逐条判定「插话会不会被冲掉」：

| # | 位置 | 操作 | 会丢插话吗 | 说明 |
|---|---|---|---|---|
| 1 | `runtime.cj:637-638` | `applyArchiveMarks` / `applyArchives` | ✅ **不会（已核实）** | `applyArchives`（`builder.cj:61`）只处理 `toolName == "archive_history"` 的 `ToolResultMessage`；`applyArchiveMarks`（`builder.cj:131`）只按 `ArchiveMessage` 的 `(startIndex, endIndex)` 裁剪。**两者都不碰 `UserMessage`** |
| 2 | `:675` | `compactBracketed`（压力压缩） | ✅ **不会** | `compactWithSummary`（`compaction.cj:361-371`）明确：头部换成检查点，**`cut` 之后的消息全部原样保留** |
| 3 | `:696` | `currentMessages = chatReq.messages`（hook 改写后收编） | ✅ **不会** | 请求是从 `currentMessages` 构建的；插话若已在其中，收编时自然还在 |
| 4 | `:763` | `recoverFromOverflow` 的 `nextMsgs`（溢出恢复） | ⚠️ **会** | 该路径只保"最后一条用户消息起"——插话落在其之前就丢。**可接受**（最后手段），但**必须记日志** |
| 5 | `:1074` | `afterTurn` hook 改写 `messages` | ⚠️ 取决于 hook 实现 | hook 拿到全量历史，正常实现不丢；**文档要写出这条契约** |

**一个正面的关键发现**：压缩是"最危险"的一环，但它恰好是安全的——
`retainTokens` 保证「最近一段逐字保留」，**插话天然落在保留区**。
这是现有压缩策略白送的性质，不需要额外设计。

### 11.5 三条实现纪律

| # | 纪律 | 依据 |
|---|---|---|
| **1** | **只在循环顶部（step 边界）插入，追加到 `currentMessages` 尾部** | 尾部是压缩的保留区（`retainTokens`），插在那里不会被压掉 |
| **2** | **插入必须发生在 `applyArchiveMarks` 之前** | 它是每轮的转换步骤；插话应先落地再被这轮转换处理 |
| **3** | **溢出恢复路径丢插话时必须留痕** | 那条路径是"救不了就失败"，丢是预期内的，但**不能静默** |

### 11.6 实现方案

**照现有 `cancels` 的形状加一个按会话的队列**：

```cangjie
// 现有（runtime.cj:599 附近）
private let cancels = HashMap<String, AtomicBool>()

// 新增：同形状
private let steerQueues = HashMap<String, LinkedBlockingQueue<Message>>()
private let steerLock = Mutex()
```

**循环顶部**（`while` 体第一件事）：

```cangjie
while (!finished && !cancelFlag.load() && turnCount < Int64(this.config.maxTurns)) {
    // ① 插话先落地（纪律 2：在 applyArchiveMarks 之前）
    let queue = this.steerQueueOf(sessionId)
    while (true) {
        match (queue.tryRemove()) {
            case Some(m) => currentMessages.add(withInterjectionMark(m))
            case None => break
        }
    }
    // ② 原有的每轮转换
    currentMessages = ctxBuilder.applyArchiveMarks(currentMessages)
    currentMessages = ctxBuilder.applyArchives(currentMessages)
    ...
}
```

**C 语义的标注**：

```cangjie
func withInterjectionMark(m: Message): Message {
    match (m) {
        case um: UserMessage =>
            UserMessage(ContentList.ofText("[User interjection] " + plainTextOf(um)), 0)
        case _ => m
    }
}
```

**`steer` / `inject` 的差别只在"要不要唤醒"**：

| 方法 | 设计行为 | **当前落地** |
|---|---|---|
| `steer` | 入队 + **若 loop 当前 idle 则启动一轮**（dsh 语义："An idle driver starts a turn"） | ⚠️ **只做了入队**：目标 run 结束后消息留在队列里，等下一次 `drive`/`chat*` 取用；**不会自己唤醒启动一轮** |
| `inject` | 入队，**不唤醒**；已在跑的 loop 在下一个 step 边界取走，idle 就一直挂着 | ✅ 与设计一致（入队，不唤醒） |

> **"idle 时唤醒"为什么先不做**：唤醒意味着 loop 要持有调度能力（谁被唤醒、按什么策略、
> 与宿主既有触发源如何不打架）。这属于 A1「无人值守」的范畴，在信任/授权改造落地前做，
> 等于先造一个没有策略来源的调度器。**先让消息"不丢失"，唤醒等 A1。**

### 11.7 边界：`steer` 解决不了什么

starline 那条需求还有一半不在这里：

| 需求 | 归属 | 现状 |
|---|---|---|
| 用户能插话 | **atelier（本节）** | 本文档补齐 |
| **对话不被面板操作卡住** | **starline** | ❌ **现在是坏的**：`atelier-starline/src/core/runtime.cj` 用 `board.withWrite { => toolExecutor.execute(...) }` 把工具执行包在**面板写锁**里 |
| **两个对话循环并行** | **starline** | ❌ `handlers.cj:191` 的 `spawn { rt.chat(...) }` **无并发闸门**，连发两条会跑两个循环，逐轮交错写同一块板 |

> **结论**：**atelier 补 `steer` + starline 修锁粒度与并发闸门，两件事都要做。**
> 只做前者，插话还是会被面板写锁卡住——**这不属于 SDK 的职责**。

### 11.8 与接口判据的关系（§4.2 又被验证一次）

`steer` / `inject` 要往**队列**里投，队列就是**跨调用保留的状态**。

**函数类型做不了这个**（除非闭包捕获队列，那正是 §4.2 明确否掉的形态）。
**所以它们必须是 `AgentLoop` interface 的方法**，这印证了「有状态 → interface」的判据。

---
