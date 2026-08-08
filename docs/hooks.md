# Hook —— 决策型拦截器

Hook 是 Atelier 的生命周期**拦截器**：在 Agent 运行的关键节点介入，观察、改写或短路运行流程。所有 hook 都是可选的，不实现即放行。

## 核心概念

一次 `Run` 的生命周期中，6 个相位按固定顺序触发：

| 相位 | 触发时机 | 能力 |
|------|----------|------|
| `beforeRun` | Run 开始后，第一轮 Turn 前 | 观察 |
| `afterRun` | Run 结束时 | 观察 |
| `beforeTurn` | 每轮推理开始前 | 改写请求 / 短路 |
| `afterTurn` | 每轮推理结束后 | 改写上下文 / 短路 |
| `beforeTool` | 工具执行前 | 放行 / 拦截 / 改写参数 |
| `afterTool` | 工具执行后 | 观察 |

**执行语义**：注册序 = 执行序，先注册的先处理。`Deny` / `ShortCircuit` 立即短路，后续 hook 不再执行；`Modify` 改写后继续放行后续 hook。

## 决策类型

### BeforeToolDecision —— 工具决策

```cangjie
public enum BeforeToolDecision {
    | Allow                    // 放行
    | Deny(reason: String)     // 拦截，reason 会回填给模型
    | Modify(args: JsonValue)  // 改写工具参数后放行
}
```

### TurnDecision —— 每轮决策

```cangjie
public enum TurnDecision {
    | Continue(request: ChatRequest)  // 放行，可携带改写后的请求（模型路由）
    | ShortCircuit(message: String)   // 终止整个 run
}
```

### AfterTurnUpdate —— 每轮更新

```cangjie
public class AfterTurnUpdate {
    public let messages: Option<ArrayList<Message>>  // 改写上下文，None = 不修改
    public let shortCircuit: Bool                     // 是否短路
}
```

### HookState —— 状态共享

`HookContext.state` 在**每次 run 内独立**，跨相位传递数据（成本累计、token 统计等）。每次 `chat()` 新建，不会跨 run 泄漏。

## 融合顺序

1. **工具执行前**：信任闸门先判定（`shouldAllow`），通过后 `beforeTool` hook 再判定；两者任一 Deny 即拦截。用户通过信任闸门批准的工具**仍会过 hook 链**，hook 策略始终生效
2. **每轮结束**：`afterTurn` hook 先改写上下文，之后内置 compaction 再压缩
3. **内置限流**（maxToolCalls / minToolInterval）与 hook 无关，始终生效

## 快速开始

### 观察型：审计日志

```cangjie
import atelier.agent.*

class AuditHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        println(">>> 调用工具: ${call.name}")
        BeforeToolDecision.Allow
    }
    public override func afterTool(ctx: HookContext, call: ToolCallBlock, result: ToolResultMessage): Unit {
        println(">>> 工具结果: ${result.content.blocks().size} 块")
    }
}

let hooks = ArrayList<Hook>([AuditHook()])
let runtime = AgentRuntime(config, provider, toolReg,
    sessionStore, trustMgr, skillReg, agentReg, providerReg,
    hooks, askUserFn)
```

### 拦截型：策略防护

```cangjie
class GuardHook <: Hook {
    public override func beforeTool(ctx: HookContext, call: ToolCallBlock): BeforeToolDecision {
        if (call.name == "bash") {
            BeforeToolDecision.Deny("bash 工具被策略禁止")
        } else {
            BeforeToolDecision.Allow
        }
    }
}
```

### 改写型：模型路由

```cangjie
class RouteHook <: Hook {
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        // 简单任务路由到便宜模型
        TurnDecision.Continue(ChatRequest("deepseek-chat", request.messages,
            request.temperature, request.maxTokens, request.reasoningEffort, request.tools))
    }
}
```

### 状态型：成本跟踪

```cangjie
class CostHook <: Hook {
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        let cost = match (ctx.state.get("cost")) {
            case Some(JsonValue.Number(n)) => n
            case _ => 0.0
        }
        ctx.state.set("cost", JsonValue.Number(cost + 1.0))
        TurnDecision.Continue(request)
    }
    public override func afterRun(ctx: HookContext): Unit {
        match (ctx.state.get("cost")) {
            case Some(JsonValue.Number(n)) => println(">>> 本轮成本: $${n}")
            case _ => ()
        }
    }
}
```

## 最佳实践

- **per-run 数据只放 `ctx.state`**：不要用 hook 实例字段存运行状态，同一 runtime 会被多个 run 并发使用，实例字段跨 run 不安全
- **hook 抛异常不中断 run**：每个 hook 调用都被 try/catch 包裹，单个 hook 失败不影响其他 hook 和主流程
- **短路要谨慎**：`beforeTurn.ShortCircuit` / `afterTurn.shortCircuit` 会直接结束 run，用于预算超限、策略拒绝等终止场景
- **组合多个 hook**：按注册顺序执行，每个 hook 专注单一职责

## 注册方式

```cangjie
let hooks = ArrayList<Hook>([
    AuditHook(),      // 最先执行（外层）
    GuardHook(),      // 其次
    CostHook(),       // 最后（内层）
])
```

## 相关文档

- [集成指南](integration.md) —— 库模式 / HTTP / CLI 中的完整用法
- [架构设计 8.4 节](design.md) —— 接口定义与融合顺序
- [信任闸门](trust.md) —— beforeTool 与信任判定的先后关系
