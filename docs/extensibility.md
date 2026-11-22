# SDK 可替换点

Atelier 的可替换点分两层：**契约级**（换掉整块策略——怎么判定、怎么压、怎么跑）与
**组件级**（换掉某个组件的实现——历史存哪、工具从哪来、事件发到哪）。本文把两层都列全，
每项给契约、默认、装配方式，以及对应章节的链接。

> 与 [Hook](hooks.md) 的区别：Hook 是**生命周期拦截**（单次调用前后观察 / 改写 / 短路）；
> 契约级是**整块策略替换**（整个判定 / 整个压缩 / 整个循环换掉）；组件级是**换实现**
> （接口与语义不变，换谁来实现）。

---

## 一、可替换点一览

### 契约级（3 个）

| 能力 | 契约类型 | 默认实现 | 装配方式 |
|---|---|---|---|
| **信任判定** | `type TrustGate`（函数类型） | `pathTrustGate(trustManager)` | `withTrustGate(g)` |
| **压缩策略** | `interface Compactor` | `BasicCompactor` | `withCompactor(c)` |
| **Agent 循环** | `interface AgentLoop` | `AgentRuntime` | `withLoopFactory(f)` |

### 组件级（15 个）

| 组件 | 契约 | 默认 | 装配 | 详见 |
|---|---|---|---|---|
| 会话存储 | `SessionStore` | 进程内存（退出即丢） | `withStore(s)` | [会话管理 · 自定义 SessionStore](sessions.md#自定义-sessionstore) |
| Provider | `Provider` | 无；环境里有 `OPENAI_API_KEY` 才挂一个 `default` | `withProvider(name, p)` | [Provider · 自定义 Provider](providers.md#自定义-provider) |
| Provider 注册表 | `ProviderRegistry` | 空 | `withProviders(reg)` | [Provider · ProviderRegistry](providers.md#providerregistry) |
| 工具表 | `ToolRegistry` | 空表（`HarnessSpec.default()` 会注册内置工具） | `withTool` / `withToolsView` / `withToolRegistry` | [工具 · 自定义工具](tools.md#自定义工具) |
| MCP 连接 | `McpManager` | 空 | `withMcp(m)` | [工具 · MCP 工具](tools.md#mcp-工具) |
| Skill 注册表 | `SkillRegistry` | 空 | `withSkills(s)` | [Skill · 在 Agent 中使用](skills.md#在-agent-中使用) |
| Agent 注册表 | `AgentRegistry` | 空 | `withAgents(a)` | [子 Agent](subagents.md) |
| 钩子 | `ArrayList<Hook>` | 空 | `withHook` / `withHooks` | [Hook](hooks.md) |
| 提问通道 | `Option<AskFn>` | `None`（需要拍板的地方按取消处理） | `withAsk(f)` | [信任闸门 · 审批交互](trust.md#审批交互结构化提问) |
| 信任表 | `TrustManager` | 空表（所有目录未授权） | `withTrust(t)` | [信任闸门 · 三种状态](trust.md#三种状态) |
| 模型窗口表 | `ModelContextRegistry` | 空（解析时回落兜底窗口） | `withModelContext` / `withModelFacts` / `withDefaults` | [Provider · 上下文窗口](providers.md#上下文窗口) |
| 请求级中间件 | `ArrayList<ProviderMiddleware>` | 空 | `withMiddlewares(ms)` | [下文 §七](#七容易误解的一处providermiddleware-对流式不生效) |
| 系统提示段 | `ArrayList<PromptSegmentContributor>` | 空 | `withContributors(cs)` | [下文 §六](#六组件级替换换实现不换策略) |
| 事件总线 | `Option<EventBus>` | `None`（不发布） | `withEventBus(bus)` | [下文 §六](#六组件级替换换实现不换策略) |
| 生命周期状态 | `Option<AgentStatusRegistry>` | `None`（每个 runtime 自建，状态不跨 run） | `withStatusRegistry(r)` | [下文 §六](#六组件级替换换实现不换策略) |

表里不写 `AgentConfig`：它不是「换组件」，是 agent 的身份与参数（见[配置参考](configuration.md)）。

---

## 二、契约类型怎么选

为什么前两个/第三个的类型不同：

> **有状态 → interface + 类；单方法无状态 → 函数类型。**
> 不是因为语言做不到，而是**状态藏在闭包里对开发者不友好**：看不见、不好调试、不好复用。

`TrustGate` 是无状态单方法（三个入参、一个决策），所以是函数类型；
`Compactor` 与 `AgentLoop` 都有状态与多方法，所以是 interface。

组件级那张表同理：能用一个函数类型表达的（`AskFn`、`TrustGate`、`ProviderMiddleware`）就是函数类型，
要持有连接 / 索引 / 生命周期的是 interface 或具体类。

---

## 三、`TrustGate`：信任判定

```cangjie
public type TrustGate = (Tool, String, String) -> TrustDecision
//                        tool  workDir sessionId
```

```cangjie
public enum TrustDecision {
    | Allowed          // 直接放行
    | NeedsApproval    // 需要用户确认（走结构化提问）
    | Denied           // 拒绝（写进历史的原因）
}
```

**默认实现**是工厂 `pathTrustGate(trustManager)`——按目录路径查信任表。
不用零参函数做默认，因为判定必须查信任状态，而信任状态只有 `TrustManager` 持有；
硬造空 manager 会让所有目录恒定 `Undecided`（所有副作用工具都要审批），
那不是"默认行为"而是"默认故障"。

**典型替换场景**：把信任判定换成策略引擎、换成静态白名单、或按工具名硬编码：

```cangjie
let spec = HarnessSpec(...).withTrustGate({ tool, workDir, sessionId =>
    if (tool.name() == "read_file") { TrustDecision.Allowed }
    else { TrustDecision.NeedsApproval }
})
```

**边界**：闸门只回答"该不该问"，**不负责问**。提问由运行时的 `askFn` 通道发出
（见 [trust.md](trust.md#审批交互结构化提问) 的审批小节）。

---

## 四、`Compactor`：压缩策略

```cangjie
public interface Compactor {
    func shouldCompact(messages: ArrayList<Message>, route: CompactRoute): CompactDecision
    func compact(messages: ArrayList<Message>, plan: CompactPlan,
                 ctx: CompactionRuntime): ArrayList<Message>
    func pruneForRequest(messages: ArrayList<Message>, cfg: PruneConfig): ArrayList<Message>
}
```

| 方法 | 职责 |
|---|---|
| `shouldCompact` | 压不压、从哪切、预算多少（**只做决策，不发请求**） |
| `compact` | 把历史改写成「检查点 + 保留区」 |
| `pruneForRequest` | 求发前的轻量修剪（只影响本次请求，不落库） |

**内置两个实现**：

- `BasicCompactor`——默认，行为等同重构前（摘要 + 保留区）
- `NoopCompactor`——完全不压（宿主自持上下文策略时用它关掉）

### 边界：决策归实现，时序归运行时

| 归 `Compactor` | 归运行时（不可替换） |
|---|---|
| 压不压 / 从哪切 / 预算多少 | 事务括弧（`CompactionStartEvent` / `EndEvent` 成对） |
| 改写后的历史 | 会话级互斥（同一会话不并发压缩） |
| | 台账写入（`CompactionRecord`） |

原因：括弧与台账是**框架对压缩的可观测性承诺**——消费端据此显示进度，
并发压缩不能产生分叉历史。放开给实现自便，就要求每个实现都正确重做一遍，
且做不到跨实现一致。

### `compact` 的三条约定

1. **不得返回比入参更长的历史**（那是白花一次调用，还会计下轮再触发）
2. **压不动时原样返回** `messages`（运行时会记 `noop` 并留痕）
3. 允许抛异常（运行时按 `noop` 处理），但**不得就地修改** `messages`

> 注意第 2 条与"没变短就丢弃"不同：**是否算 noop 由调用方判**（`result.size < messages.size`）。
> 实现应当原样返回结果，让调用方决定。

---

## 五、`AgentLoop`：Agent 循环

```cangjie
public interface AgentLoop {
    // 生命周期（比一次 run 长寿）
    func status(): AgentStatus                    // Idle / Running
    func drive(input: RunInput): EventStream<AgentEvent, ArrayList<Message>>
    func cancel(sessionId: String): Unit

    // 插话与注入
    func steer(sessionId: String, message: Message): Unit
    func inject(sessionId: String, message: Message): Unit

    // 会话型入口（既有宿主的形态）
    func chat(messages: ArrayList<Message>): ...
    func chatWithSessionId(sessionId: String, messages: ArrayList<Message>,
                           sessionEnv: SessionEnvironment): ...
    func cancelSession(sessionId: String): Unit

    // 手动压缩（/compact 入口）
    func compactNow(sessionId: String, messages: ArrayList<Message>,
                    sessionEnv: SessionEnvironment): CompactionReport
}
```

**默认实现**是 `AgentRuntime`。它是当前**唯一**实现——
仓内没有第二个 `AgentLoop` 实现，所以"能不能换"这件事由测试
（`status_test.cj` 的 `loop_customFactoryIsUsed`）与本文保证，而非第二个实现做实证。

### 装配：工厂

```cangjie
public type AgentLoopFactory = (HarnessSpec, AgentConfig) -> AgentLoop
```

**为什么需要工厂**：只有接口还不够——散落在各宿主里的 `AgentRuntime(spec, cfg)` 硬编码
会让"换实现"变成逐个改调用点。工厂把「用哪个实现」收成装配期的一个决定。

```cangjie
// 换掉整个循环
let spec = HarnessSpec(...).withLoopFactory({ spec, cfg => MyLoop(spec, cfg) })
```

**新代码应走 `spec.createLoop(cfg)`**，不要直接 `AgentRuntime(spec, cfg)`。

### 不做的事：不暴露阶段回调

`AgentLoop` 不提供 `onBeforeRequest` / `onAfterTurn` 之类的回调。
需要中间介入的场景已有 `Hook`（6 相位）覆盖；循环级替换要的就是"整个换掉"，
再开一套回调只会让两套机制并存。

---

## 六、组件级替换：换实现，不换策略

下面这些没有「策略」可讲——接口是现成的，换的是实现或数据来源。逐类点一句要点，
细节走链接。

**会话存储**（`SessionStore`）。决定历史落在哪：进程内存、bstorm、还是宿主自己的库。
接口是 `append` / `save` / `load` / `close` 加压缩台账；实现要点（原子写、按会话分文件、
中断残留怎么捞）见 [会话管理 · 自定义 SessionStore](sessions.md#自定义-sessionstore)。
`HarnessSpec.default()` 用内存实现——进程退出即丢，适合一次性的嵌入；命令行与服务形态默认 bstorm。

**Provider 与 Provider 注册表**。`withProvider(name, p)` 写的是**本 spec 的叠加表**，
不动宿主共享的 `ProviderRegistry`；`AgentConfig.provider` 按名字取，找不到会明确报错。
自实现 Provider 要自己负责传输级重试（见下方 §七「重试到底归谁」）——
写法和注册方式见 [Provider · 自定义 Provider](providers.md#自定义-provider)。

**工具表**（`ToolRegistry`）。三种粒度：`withTool` 追加或同名覆盖一个工具、`withToolRegistry`
换整张表、`withToolsView` 只给本次 run 一个叠加视图（不动根表，跑完即弃）。内置工具注册、
自定义工具的 schema 与执行模式见 [工具 · 自定义工具](tools.md#自定义工具)；
MCP 工具走 `withMcp` 换连接管理器，详见 [工具 · MCP 工具](tools.md#mcp-工具)。

**Skill 与 Agent 注册表**。前者是按 AgentSkills 规范声明的技能来源，后者是子 Agent 注册表。
换的是「从哪里读」，用法见 [Skill · 在 Agent 中使用](skills.md#在-agent-中使用) 与
[子 Agent](subagents.md)。

**钩子**（`Hook`）。6 个相位的决策型拦截器，注册序即执行序。严格说它不是「换实现」而是
「加一层」，因为已经单独成文，入口见 [Hook](hooks.md)。

**提问通道**（`AskFn`）。审批 / 选择 / 表单收敛成一个 `(UserRequest) -> UserAnswer`；
不挂就等于没有交互通道——需要拍板的地方按**取消**处理（等同拒绝）。四端（TUI / ACP / AG-UI / HTTP）
各自怎么接线见 [信任闸门 · 审批交互](trust.md#审批交互结构化提问)。

**信任表**（`TrustManager`）。存的是「哪些目录被授权」的状态，不是策略；策略在 `TrustGate`。
三态与目录继承见 [信任闸门 · 三种状态](trust.md#三种状态)。

**模型窗口表**（`ModelContextRegistry`）。上下文窗口是 **`(provider, model)` 这一对的事实**，
不是 agent 的属性：同名模型走官方端点和走一个截断过的代理，窗口可以不同。用
`withModelContext` / `withModelFacts` 按端点声明，`withDefaults` 改兜底值——
解析顺序与「没人声明时打警告」的行为见 [Provider · 上下文窗口](providers.md#上下文窗口)。

**四个横切组件**：

| 组件 | 要点 | 装配 |
|---|---|---|
| 系统提示段 | 追加在 `[Session Context]` 之后，不进消息历史（租户 / 合规 / 元数据） | `withContributors` |
| 请求级中间件 | 包 `Provider.chat()`，按序 wrap（路由 / 限流 / 观测）——**流式不经过**，见 §七 | `withMiddlewares` |
| 事件总线 | 进程级发布/订阅，跨会话审计与 UI 聚合；钩子没有跨会话全局视角，横切建议走它 | `withEventBus` |
| 生命周期状态 | `Idle` / `Running` 的持有者；**必须由宿主在多个 runtime 之间共享**才有意义，否则只对单次 run 可观测 | `withStatusRegistry` |

---

## 七、容易误解的一处：`ProviderMiddleware` 对流式不生效

`ProviderMiddleware` 是**请求级**中间件链（按序 wrap，先注入者最外层）：

```cangjie
public type ProviderMiddleware = (Provider) -> Provider
```

典型用途：路由、限流、观测。

> ⚠️ **但它包的是 `Provider.chat()`（非流式）**。`chatStreaming()` 走的是
> provider 实现内部自己 spawn 的流式路径，**不经过中间件链**。
> 想在流式上做重试/观测，需要改 provider 实现，不是加 middleware。

### 重试到底归谁

| 错误类型 | 负责方 |
|---|---|
| 连接级失败（`SocketException` / `ConnectionException`） | `llm_api` 的 `ResilientHttpClient`：换连接重试 **1** 次 |
| 429 / 瞬时 5xx | 同上：退避重试 **3** 次（默认） |
| **超上下文窗口** | **循环内部**（`invokeProvider`）：压掉头部再试，次数受 `maxOverflowRetries` |
| 400 / 解析失败 / auth | **都不重试**，直接失败 |

**传输级重试在 `llm_api` 层，不在 atelier**。atelier 只处理"必须改写历史才能继续"
的那一种失败——因为只有循环知道怎么压消息。

> **契约缺口**：`Provider` 接口本身没有声明这条归属，它藏在 `llm_api` 的实现里。
> 自实现的 Provider 默认**没有**传输级重试。

---

## 八、与装配的关系

所有替换点都挂在 `HarnessSpec` 上，**值语义派生**（`with*` 返回新 spec，不动共享组件）：

```cangjie
HarnessSpec(tools: ..., store: ..., trust: ..., ...)
    .withStore(myStore)             // 换会话存储
    .withTool(myTool)               // 加/换工具
    .withTrustGate(myGate)          // 换信任判定
    .withCompactor(myCompactor)     // 换压缩策略
    .withLoopFactory(myFactory)     // 换整个循环
```

派生规则（哪些是副本、哪些只属于本 spec）见 [design.md](design.md) 的装配束章节，
最短的消费方式见[集成指南](integration.md) 的快速装配小节。
