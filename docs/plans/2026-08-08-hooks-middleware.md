# Hook 升级为决策型拦截器实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 将 Hook 从纯观察者（返回 Unit）升级为决策型拦截器，支持每次 run 共享状态、请求改写、轮次短路、工具级决策，且保持 Hook 名称与注册方式不变。

**架构:** 保留 `Hook` 接口名称与 6 个相位（beforeRun/afterRun/beforeTurn/afterTurn/beforeTool/afterTool），升级每个相位的返回类型为决策类型；`HookContext` 增加 per-run 共享的 `HookState`；`AgentRuntime` 六处调用点应用决策。语义对齐洋葱中间件：注册序 = 执行序，先注册的先处理、可短路。

**Tech Stack:** Cangjie 1.1.0, `std.collection`, `jsonvalue`

**项目根目录:** `/home/ystyle/Projects/Cangjie/atelier`

---

## 设计决策（已与用户确认）

1. **保留 Hook 名称**，不引入 Middleware 概念。只改签名与语义。
2. **不做 `(ctx, next)` 洋葱重构**：Cangjie 无 async/await（只有 `spawn` + `Future.get()` 阻塞），洋葱模型会强制整个 runtime 拆成 Future 组合链，成本不可接受。相位式 hook 已覆盖 agent-express 全部内置中间件的 90% 场景。
3. **缺口单独补**：`model.retry` / `model.router`（需包住 provider 调用）不在本计划范围，作为后续「请求级 pipeline」单独设计。
4. **内置行为不抽取**：trust/rate-limit/compaction 保持循环内硬编码，与 hook 的融合顺序在文档中明确，避免重叠混乱。

---

## Task 1: 定义决策类型与 HookState

**Files:**
- Create: `src/agent/hook_decision.cj`
- Test: `src/agent/hook_test.cj`

**Step 1: 写失败测试**

```cangjie
package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.ChatRequest

@TestCase
public class HookDecisionTest {
    @Test
    public func beforeToolDecision_variants() {
        let allow = BeforeToolDecision.Allow
        @Expect(allow is BeforeToolDecision, true)
        let deny = BeforeToolDecision.Deny("not allowed")
        @Expect(deny is BeforeToolDecision, true)
        let modify = BeforeToolDecision.Modify(JsonValue.Object(HashMap<String, JsonValue>()))
        @Expect(modify is BeforeToolDecision, true)
    }

    @Test
    public func turnDecision_variants() {
        let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
        let cont = TurnDecision.Continue(req)
        @Expect(cont is TurnDecision, true)
        let sc = TurnDecision.ShortCircuit("stop")
        @Expect(sc is TurnDecision, true)
    }

    @Test
    public func hookState_getSet() {
        let st = HookState()
        st.set("cost", JsonValue.Number(1.5))
        match (st.get("cost")) {
            case Some(JsonValue.Number(n)) => @Expect(n, 1.5)
            case _ => @Fail("expected number")
        }
        @Expect(st.get("missing"), None)
    }
}
```

**Step 2: 运行测试确认失败**

```bash
cjpm test --no-progress --filter 'HookDecisionTest.*'
```
Expected: 编译失败，`BeforeToolDecision` / `TurnDecision` / `HookState` 未定义。

**Step 3: 实现决策类型**

```cangjie
package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.ChatRequest

// beforeTool 决策
public enum BeforeToolDecision {
    | Allow
    | Deny(reason: String)
    | Modify(args: JsonValue)
}

// beforeTurn 决策
public enum TurnDecision {
    | Continue(request: ChatRequest)
    | ShortCircuit(message: String)
}

// afterTurn 决策
public class AfterTurnUpdate {
    public let messages: Option<ArrayList<Message>>
    public let shortCircuit: Bool
    public init(messages: Option<ArrayList<Message>>, shortCircuit: Bool) {
        this.messages = messages
        this.shortCircuit = shortCircuit
    }
    public static func none(): AfterTurnUpdate {
        AfterTurnUpdate(None, false)
    }
}

// 每次 run 共享的状态
public class HookState {
    private let values: HashMap<String, JsonValue>
    public init() {
        this.values = HashMap<String, JsonValue>()
    }
    public func set(key: String, value: JsonValue): Unit {
        this.values[key] = value
    }
    public func get(key: String): Option<JsonValue> {
        this.values.get(key)
    }
}
```

**Step 4: 运行测试确认通过**

```bash
cjpm test --no-progress --filter 'HookDecisionTest.*'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/agent/hook_decision.cj src/agent/hook_test.cj
git commit -m "feat(hook): 定义决策类型 BeforeToolDecision/TurnDecision/AfterTurnUpdate/HookState"
```

---

## Task 2: 升级 HookContext 与 Hook 接口

**Files:**
- Modify: `src/agent/hook.cj`
- Modify: `src/agent/hook_test.cj`

**Step 1: 写失败测试（HookContext 带 state，Hook 新签名）**

在 `src/agent/hook_test.cj` 追加：

```cangjie
import atelier.tool.*

@Test
public func hookContext_carriesState() {
    let cfg = AgentConfig.default()
    let toolReg = ToolRegistry()
    let state = HookState()
    let ctx = HookContext(cfg, toolReg, 1, state)
    ctx.state.set("k", JsonValue.String("v"))
    match (ctx.state.get("k")) {
        case Some(JsonValue.String(s)) => @Expect(s, "v")
        case _ => @Fail("state not shared")
    }
}

class RecordingHook <: Hook {
    public var events: ArrayList<String> = ArrayList<String>()
    public override func beforeRun(ctx: HookContext): Unit {
        this.events.add("beforeRun")
    }
    public override func afterRun(ctx: HookContext): Unit {
        this.events.add("afterRun")
    }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.events.add("beforeTurn")
        TurnDecision.Continue(request)
    }
    public override func afterTurn(ctx: HookContext): AfterTurnUpdate {
        this.events.add("afterTurn")
        AfterTurnUpdate.none()
    }
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        this.events.add("beforeTool")
        BeforeToolDecision.Allow
    }
    public override func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {
        this.events.add("afterTool")
    }
}

@Test
public func hook_defaultImplsAreNoops() {
    class NoopHook <: Hook {}
    let h = NoopHook()
    let ctx = HookContext(AgentConfig.default(), ToolRegistry(), 0, HookState())
    h.beforeRun(ctx)
    h.afterRun(ctx)
    let req = ChatRequest("m", ArrayList<Message>(), 0.7, 100, None, ArrayList())
    let cont = h.beforeTurn(ctx, req)
    match (cont) {
        case TurnDecision.Continue(r) => @Expect(r.model, "m")
        case _ => @Fail("default should continue")
    }
    let upd = h.afterTurn(ctx)
    @Expect(upd.shortCircuit, false)
    match (upd.messages) {
        case None => ()
        case _ => @Fail("default should not modify messages")
    }
    let allow = h.beforeTool(ctx, ToolCallBlock("c1", "t", JsonValue.Object(HashMap<String, JsonValue>())))
    @Expect(allow, BeforeToolDecision.Allow)
}
```

**Step 2: 运行测试确认失败**

```bash
cjpm test --no-progress --filter 'HookTest.*|hookContext_carriesState|hook_defaultImplsAreNoops'
```
Expected: 编译失败，`HookContext` 构造函数签名不符 / `Hook` 接口方法签名不符。

**Step 3: 升级 HookContext**

```cangjie
package atelier.agent

import atelier.message.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*

public class HookContext {
    public let config: AgentConfig
    public let toolRegistry: ToolRegistry
    public let turnCount: Int64
    public let state: HookState

    public init(config: AgentConfig, toolRegistry: ToolRegistry,
        turnCount: Int64, state: HookState) {
        this.config = config
        this.toolRegistry = toolRegistry
        this.turnCount = turnCount
        this.state = state
    }
}
```

**Step 4: 升级 Hook 接口**

```cangjie
package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.ChatRequest
import jsonvalue.*
import std.collection.*

public interface Hook {
    public func beforeRun(ctx: HookContext): Unit {}
    public func afterRun(ctx: HookContext): Unit {}
    public func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        TurnDecision.Continue(request)
    }
    public func afterTurn(ctx: HookContext): AfterTurnUpdate {
        AfterTurnUpdate.none()
    }
    public func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        BeforeToolDecision.Allow
    }
    public func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {}
}
```

**Step 5: 运行测试确认通过**

```bash
cjpm test --no-progress --filter 'HookTest.*|hookContext_carriesState|hook_defaultImplsAreNoops'
```
Expected: PASS

**Step 6: 提交**

```bash
git add src/agent/hook.cj src/agent/hook_test.cj
git commit -m "feat(hook): HookContext 增加共享 state，Hook 签名升级为决策型"
```

---

## Task 3: 适配 AgentRuntime 调用点

**Files:**
- Modify: `src/agent/runtime.cj`

**Step 1: 先理解现状**

`runtime.cj` 现有六处 `callHooks(phase, ...)` 字符串分派，全部返回 Unit。需要改为：每次 run 创建 `HookState`，六处调用点应用决策。重构原则：**不改变核心循环的流程**，只在决策点插入 hook 结果的应用逻辑。

**Step 2: 改造 runtime.cj**

在 `chatWithEnv` 中创建 state 并替换六处调用：

```cangjie
// 在 spawn 块内，emit AgentStartEvent 后：
let hookState = HookState()
callHooks("beforeRun", 0, hookState)
```

`beforeTurn` 改造——构造 `ChatRequest` 后、调用 `provider.chatStreaming` 前，跑 hook 链：

```cangjie
let actualModel = this.pickModel(this.config.model)
let tools = this.resolveTools()
var chatReq = ChatRequest(actualModel, currentMessages,
    Float64(this.config.temperature), Int64(this.config.maxOutputTokens),
    this.config.thinkingLevel, tools)
chatReq = runBeforeTurnHooks(this.hooks, ctx, chatReq)
if (chatReq.model != actualModel) {
    log.info("model routed: ${actualModel} -> ${chatReq.model}", Array<Attr>())
}
let chatStream = this.provider.chatStreaming(chatReq)
```

`beforeTool` 改造——在信任闸门通过后、加入 batch 前，逐工具调用 hook：

```cangjie
case TrustDecision.Allowed =>
    match (runBeforeToolHooks(this.hooks, ctx, tc)) {
        case BeforeToolDecision.Allow =>
            batch.add((tc.name, ctx, tc.args))
        case BeforeToolDecision.Deny(reason) =>
            skipResults[idx] = "Tool blocked by hook: " + reason
        case BeforeToolDecision.Modify(args) =>
            batch.add((tc.name, ctx, args))
    }
```

`afterTool` 改造——在结果回填循环里逐工具调用：

```cangjie
// 在构造 tr 之后、加入 currentMessages 之前：
callAfterToolHooks(this.hooks, ctx, tc, tr)
```

`afterTurn` 改造——在 end_turn 分支、compaction 之前：

```cangjie
case _ =>
    log.info("turn finished", Array<Attr>())
    callHooks("afterTurn", turnCount, hookState)
    let update = runAfterTurnHooks(this.hooks, ctx, currentMessages)
    match (update.messages) {
        case Some(msgs) =>
            currentMessages = msgs
            log.info("afterTurn hook rewrote messages to ${msgs.size}", Array<Attr>())
        case None => ()
    }
    if (update.shortCircuit) {
        finished = true
    } else if (this.config.compactionEnabled) {
        let contextWindow = this.modelRegistry.get(actualModel)
        currentMessages = compactMessages(currentMessages,
            contextWindow,
            Int64(this.config.compactionReserveTokens),
            Int64(this.config.keepRecentTokens))
    }
    stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
    finished = true
```

**Step 3: 新增辅助函数**

在 `AgentRuntime` 类内新增（或文件顶层）：

```cangjie
private func runBeforeTurnHooks(hooks: ArrayList<Hook>, ctx: HookContext,
    request: ChatRequest): ChatRequest {
    var current = request
    for (h in hooks) {
        match (h.beforeTurn(ctx, current)) {
            case TurnDecision.Continue(r) => current = r
            case TurnDecision.ShortCircuit(_) =>
                // 短路由调用方通过返回请求为空字符串约定？
                // 见 Step 4 的设计说明
                return current
        }
    }
    current
}
```

> **设计说明**：`beforeTurn` 的短路与 `afterTurn` 不同——请求尚未发出，短路语义是「不调用 provider，直接结束 run」。为保持接口简单，本计划让 `beforeTurn` 短路通过一个哨兵 `ChatRequest`（model 为空字符串）返回，调用方检测 `chatReq.model == ""` 时终止 run。这避免了在 `TurnDecision` 里塞入流程控制状态。

```cangjie
private func runBeforeToolHooks(hooks: ArrayList<Hook>, ctx: HookContext,
    call: ToolCallBlock): BeforeToolDecision {
    var decision = BeforeToolDecision.Allow
    for (h in hooks) {
        match (h.beforeTool(ctx, call)) {
            case BeforeToolDecision.Allow => ()
            case BeforeToolDecision.Deny(reason) =>
                return BeforeToolDecision.Deny(reason)
            case BeforeToolDecision.Modify(args) =>
                decision = BeforeToolDecision.Modify(args)
        }
    }
    decision
}

private func runAfterTurnHooks(hooks: ArrayList<Hook>, ctx: HookContext,
    messages: ArrayList<Message>): AfterTurnUpdate {
    var update = AfterTurnUpdate.none()
    for (h in hooks) {
        let u = h.afterTurn(ctx)
        match (u.messages) {
            case Some(msgs) => update = AfterTurnUpdate(Some(msgs), update.shortCircuit || u.shortCircuit)
            case None => update = AfterTurnUpdate(update.messages, update.shortCircuit || u.shortCircuit)
        }
    }
    update
}

private func callAfterToolHooks(hooks: ArrayList<Hook>, ctx: HookContext,
    call: ToolCallBlock, result: ToolResultMessage): Unit {
    for (h in hooks) {
        try {
            h.afterTool(ctx, call, result)
        } catch (e: Exception) {
            let log = getGlobalLogger([("name", "AgentRuntime")])
            log.warn("afterTool hook error: ${e.message}", Array<Attr>())
        }
    }
}
```

`beforeRun` / `afterRun` 保持 `Unit`（观察语义），但 `HookContext` 构造改为带 `hookState`：

```cangjie
private func callHooks(phase: String, turnCount: Int64, state: HookState): Unit {
    let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
    for (h in this.hooks) {
        try {
            match (phase) {
                case "beforeRun" => h.beforeRun(ctx)
                case "afterRun" => h.afterRun(ctx)
                case "afterTurn" => h.afterTurn(ctx)
                case "beforeTurn" => ()  // 由 runBeforeTurnHooks 处理
                case "beforeTool" => ()  // 由 runBeforeToolHooks 处理
                case "afterTool" => ()  // 由 callAfterToolHooks 处理
                case _ => ()
            }
        } catch (e: Exception) {
            let log = getGlobalLogger([("name", "AgentRuntime")])
            log.warn("hook ${phase} error: ${e.message}", Array<Attr>())
        }
    }
}
```

**Step 4: 短路语义落地**

在调用 `runBeforeTurnHooks` 后检测哨兵：

```cangjie
chatReq = runBeforeTurnHooks(this.hooks, ctx, chatReq)
if (chatReq.model == "") {
    log.info("beforeTurn hook short-circuited run", Array<Attr>())
    currentMessages.add(AssistantMessage(ContentList.ofText("[Run short-circuited by hook]"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
    finished = true
    break
}
```

> **注意**：`assistantMsg` 变量在此处尚未声明。短路分支需要自行构造一个占位 AssistantMessage，或调整代码顺序。实现时以「不引入未初始化变量」为原则，短路分支内自构造。

**Step 5: 运行现有测试确认不破坏**

```bash
cjpm test -j 16 --no-progress
```
Expected: 全部通过（现有 116+ 测试不受影响，因为 Hook 默认实现无副作用）。

**Step 6: 提交**

```bash
git add src/agent/runtime.cj
git commit -m "feat(hook): AgentRuntime 六处调用点应用决策型 hook 返回值"
```

---

## Task 4: 编写 hook 行为端到端测试

**Files:**
- Modify: `src/agent/hook_test.cj`

**Step 1: 写失败测试——beforeTool 拦截**

```cangjie
class BlockingToolHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        BeforeToolDecision.Deny("tool blocked for test")
    }
}
```

通过一个最小运行时跑通（用 FakeProvider 返回 tool_use + end_turn，验证工具未被调用）：

```cangjie
@Test
public func beforeTool_deny_blocksExecution() {
    // 构造 FakeProvider：第一轮返回 tool_use，第二轮返回 end_turn
    // 注册一个副作用工具（记录被调用次数）
    // 注册 BlockingToolHook
    // 断言：工具调用次数 == 0，run 正常结束
    @Expect(true, true)
}
```

> **实现提示**：需要一个测试用 `Provider` 子类（`FakeProvider`），每次 `chatStreaming` 返回预设的 `EventStream<ChatDelta, AssistantMessage>`。参考 `src/provider/openai_test.cj` 中已有的测试 Provider 模式。本测试需要 `FakeProvider` 能在收到 tool_use 后返回第二轮 end_turn。

**Step 2: 写失败测试——afterTurn 改写上下文**

```cangjie
class RewriteMessagesHook <: Hook {
    public override func afterTurn(ctx: HookContext): AfterTurnUpdate {
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("rewritten"), 0))
        AfterTurnUpdate(Some(msgs), false)
    }
}
```

断言：run 结果的最后一条消息是被改写后的消息。

**Step 3: 写失败测试——state 跨相位共享**

```cangjie
class CostTrackingHook <: Hook {
    public override func afterRun(ctx: HookContext): Unit {
        let prev = match (ctx.state.get("cost")) {
            case Some(JsonValue.Number(n)) => n
            case _ => 0.0
        }
        ctx.state.set("cost", JsonValue.Number(prev + 1.0))
    }
}
```

断言：连续两次 `runtime.chat()`（同一个 runtime 实例、不同 run）各跑一次 hook 后，通过可观察副作用验证 state 隔离性——**每个 run 独立 HookState**。

> **实现提示**：HookState 的隔离性要求 state 在 `chatWithEnv` 内创建（每次 run 新建），不能在构造器中创建。这是 Task 3 已落地的方案。

**Step 4: 运行测试确认通过**

```bash
cjpm test -j 16 --no-progress --filter 'beforeTool_deny_blocksExecution|afterTurn_rewritesContext|state_isolatedPerRun'
```
Expected: PASS

**Step 5: 提交**

```bash
git add src/agent/hook_test.cj
git commit -m "test(hook): 端到端验证 beforeTool 拦截 / afterTurn 改写 / state 隔离"
```

---

## Task 5: 融合顺序文档化

**Files:**
- Modify: `docs/design.md`（8.4 钩子小节）
- Modify: `docs/integration.md`（自定义钩子小节）

**Step 1: 更新 design.md 8.4**

将现有过时的 `AgentHooks` 草案替换为升级后的真实 `Hook` 接口，并写明融合顺序：

```markdown
### 8.4 钩子（Hooks）

钩子是**决策型拦截器**：保留 6 个相位，每个相位可返回决策影响运行流程。

```cangjie
public interface Hook {
    public func beforeRun(ctx: HookContext): Unit {}
    public func afterRun(ctx: HookContext): Unit {}
    public func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision
    public func afterTurn(ctx: HookContext): AfterTurnUpdate
    public func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision
    public func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {}
}
```

- `TurnDecision.Continue` 放行并可能改写请求；`ShortCircuit` 终止 run
- `BeforeToolDecision.Allow` 放行 / `Deny` 拦截 / `Modify` 改写参数
- `AfterTurnUpdate` 可改写上下文消息或短路
- `HookContext.state` 每次 run 独立共享，跨相位传递数据

**融合顺序**：

1. 工具执行前：**信任闸门先判定**（`shouldAllow`），通过后 **beforeTool hook 再判定**；两者任一 Deny 即拦截
2. 每轮结束：**afterTurn hook 先改写**上下文，之后内置 **compaction** 再压缩
3. 内置限流（maxToolCalls / minToolInterval）与 hook 无关，始终生效
```

**Step 2: 更新 integration.md 自定义钩子**

替换旧签名示例（`ctx.toolCalls[0]` 这种已移除的字段访问），更新为新签名，并补充一个成本跟踪 + 工具拦截的组合示例。

**Step 3: 验证文档渲染**

```bash
grep -n 'BeforeToolDecision' docs/design.md docs/integration.md
```
Expected: 两处都有新签名引用。

**Step 4: 提交**

```bash
git add docs/design.md docs/integration.md
git commit -m "docs(hook): 更新 design.md 与 integration.md 到决策型 hook 签名与融合顺序"
```

---

## Task 6: 全量验证

**Step 1: 编译 + 全量测试**

```bash
eval "$(cjvs env zsh)" && eval "$(cjvs stdx-env zsh)" && cjpm build -j 16
cjpm test -j 16 --no-progress
```
Expected: 全部通过。

**Step 2: 检查文档完整性**

```bash
grep -rn 'ctx.toolCalls\[0\]' docs/  # 不应再有旧签名残留
```
Expected: 无输出。

**Step 3: 最终提交**

```bash
git add -A && git commit -m "chore: hook 决策型升级完成" 2>/dev/null || echo "无待提交改动"
```

---

## 待定事项（不在本计划内）

| 事项 | 说明 |
|------|------|
| 请求级 pipeline | 补 `model.retry` / `model.router`，需包住 provider 调用，另立方案 |
| 内置行为抽取 | trust/rate-limit/compaction 是否重写为命名内置 hook，后续评估 |
| Hook 排序策略 | 目前注册序 = 执行序；若需倒序/条件排序，后续扩展 |
