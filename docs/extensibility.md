# SDK 可替换点

Atelier 的**内核行为**可以整块换掉，而不只是加钩子。本文记录三个可替换点、它们的边界，
以及一个容易误解的地方（`ProviderMiddleware` 对流式不生效）。

> 与 [Hook](hooks.md) 的区别：Hook 是**生命周期拦截**（单次调用前后观察/改写/短路）；
> 本文的三个点是**契约级替换**（整个判定策略 / 整个压缩策略 / 整个循环换掉）。

---

## 一、三个可替换点

| 能力 | 契约类型 | 默认实现 | 装配方式 |
|---|---|---|---|
| **信任判定** | `type TrustGate`（函数类型） | `pathTrustGate(trustManager)` | `HarnessSpec.withTrustGate(g)` |
| **压缩策略** | `interface Compactor` | `BasicCompactor` | `HarnessSpec.withCompactor(c)` |
| **Agent 循环** | `interface AgentLoop` | `AgentRuntime` | `HarnessSpec.withLoopFactory(f)` |

选择判据（为什么前两个/第三个的类型不同）：

> **有状态 → interface + 类；单方法无状态 → 函数类型。**
> 不是因为语言做不到，而是**状态藏在闭包里对开发者不友好**：看不见、不好调试、不好复用。

`TrustGate` 是无状态单方法（三个入参、一个决策），所以是函数类型；
`Compactor` 与 `AgentLoop` 都有状态与多方法，所以是 interface。

---

## 二、`TrustGate`：信任判定

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
（见 [trust.md](trust.md) 的审批小节）。

---

## 三、`Compactor`：压缩策略

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

## 四、`AgentLoop`：Agent 循环

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

## 五、容易误解的一处：`ProviderMiddleware` 对流式不生效

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

## 六、与装配的关系

三个点都在 `HarnessSpec` 上，**值语义派生**（`with*` 返回新 spec，不动共享组件）：

```cangjie
HarnessSpec(tools: ..., store: ..., trust: ..., ...)
    .withTrustGate(myGate)          // 换信任判定
    .withCompactor(myCompactor)     // 换压缩策略
    .withLoopFactory(myFactory)     // 换整个循环
```

派生规则见 [design.md](design.md) 的装配束章节。
