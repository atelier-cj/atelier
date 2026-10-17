# C-2 完成记录：`AgentRuntime` 主循环的结构化

> 日期：2026-10-17/18 ｜ 状态：**✅ 已完成**（5 次提交，951 用例全程全绿）
> 归属：`atelier/src/agent/`
> 性质：**实施结果记录**，不是计划

---

## 0. 结果

| 指标 | 改前 | 改后 |
|---|---|---|
| `chatWithEnv` | **548 行** | **270 行**（-51%） |
| 主循环体 | 500 行 | **232 行** |
| `break` / `continue` 出口 | 15 个（散在 5–9 层嵌套） | 外层循环仅剩 3 处，其余改返回值 |
| 重复代码 | 工具准入 3 份 | 0 |
| 用例 | 951 | **951**（无新增无删除） |
| 行为变化 | — | **零** |

新增 `run_scope.cj`（104 行）：`RunScope` + 3 个枚举。

---

## 1. 最终结构

```
chatWithEnv (270 行)
  ├─ 装配（stream / ctx / cancelFlag / 状态推进）
  ├─ try
  │   ├─ 循环前：beforeRun 钩子 + 系统提示 + RunScope
  │   ├─ while (!finished && !cancelled && turn < maxTurns)    ← 232 行循环体
  │   │   ├─ openTurn                  ← 回合开场 + 插话落地 + 归档转换
  │   │   ├─ 工具解析（visible / tools / systemText）
  │   │   ├─ compactBeforeRequest      ← 请求前压力处理
  │   │   ├─ beforeTurn 钩子（短路带 break，未抽）
  │   │   ├─ 配对兜底 ensureToolCallResults
  │   │   ├─ invokeProvider            ← provider + 溢出恢复
  │   │   └─ match (stopReason)
  │   │       ├─ ToolUse → 预算裁决 → admitToolCall（逐 call）
  │   │       │            → executeToolBatch → 挂起判定
  │   │       └─ case _ → verdict → afterTurn 钩子 → 收尾
  │   └─ 异常 + finally（Idle + close + 清理取消标志）
  └─ stream
```

新增方法（全在 `AgentRuntime` 上，`private`）：

| 方法 | 职责 |
|---|---|
| `openTurn` | 回合开场：计数 / 续跑预算 / MCP 冷却 / 插话 / 归档 |
| `compactBeforeRequest` | 请求前修剪 + 压缩决策 + 替换历史 |
| `invokeProvider` | provider 调用 + 溢出恢复重试 |
| `executeToolBatch` | 批量执行 + 结果回写（守"每个 call 一条结果"不变量） |
| `admitToolCall` | 工具准入分流（信任闸门 / 钩子 / 审批） |
| `admitAfterHooks` | 过 beforeTool 钩子 |
| `admitByAsking` | 问宿主 + 校验答复 + 按结论决定 |

---

## 2. 关键设计决定

### 2.1 `RunScope`：只装"本次 run 内"的状态

```cangjie
internal class RunScope {
    var messages: ArrayList<Message>
    var turnCount / toolCallCount / lengthContinuations / verifyPasses: Int64
    var resumingSameTurn: Bool
    var lastToolTime: MonoTime
    var finished: Bool
}
```

**边界**：装配期组件（provider / store / 工具表 / 压缩器）仍在 `AgentRuntime` 上，
阶段方法通过 `this.` 访问，**不进 RunScope**。

**为什么需要它**：原循环体直接读写 8 个局部变量、共 81 处引用。抽成方法后，
每段要既收这几变量又回写，参数表立刻变成「4~9 个入参 + 同数量出参」。
收进一个对象后只传一个引用。

**它不是上帝对象**：字段全是「本次 run 内」的运行时状态，没有一个是配置或组件。
与早前被否掉的「5 个阶段共享 8 字段 RunState」的区别在于——
那个是把状态分给 5 个对象，这个是让**同类的 7 个私有方法**共享。

### 2.2 三个枚举表达"这一段的结论"

| 枚举 | 值 | 解决什么 |
|---|---|---|
| `ToolAdmission` | `Allow(JsonValue)` / `Skip(String)` / `Suspend(ExternalRequest)` | 准入判定与副作用分离（原来缠在一个 if/else 里） |
| `ToolBatchOutcome` | `ContinueRun` / `Suspended` | 批次执行要结束外层回合时，用返回值代替 `continue` |
| `ProviderAttempt` | `Ok(AssistantMessage)` / `Failed` | 调用失败要结束回合时，用返回值代替 `break` |

### 2.3 元组带回被重建的请求

`invokeProvider` 返回 **`(ProviderAttempt, ChatRequest)`**。

理由是它唯一的真难点：溢出恢复要**重建 `ChatRequest`**（保留 hook 改过的 model），
而重建结果在回合收尾与下一次迭代里都还要用。

- 可变捕获能绕开，但返回值只表达一半事实
- 参数列表会变成"入参 + 出参"混合
- **元组一次说清两件事**

---

## 3. 没有抽的部分与理由

| 段 | 行数 | 为什么不抽 |
|---|---|---|
| **beforeTurn 钩子** | 35 | 短路时要 `break` 跳出**外层回合循环**；抽成方法会丢失该语义，改成返回值只为一个 `break` 不值得 |
| **`match (stopReason)` 骨架** | 57 | 它是回合的分派点，两个分支各自已抽成方法调用 |
| **收尾哨兵** | 40 | 顺序语句（afterRun 钩子 / Idle / setResult / AgentEndEvent），无分支 |
| **循环前后装配** | 38 | 顺序语句 |

**判据**：剩下每一块都 ≤ 57 行、没有重复、没有跨层控制流。再切只会把顺序代码切成碎片。

---

## 4. 途中确认的边界（值得记住）

### 4.1 传输级重试不归 atelier

查证结果：

| 错误类型 | 负责方 |
|---|---|
| 连接级失败（Socket / Connection） | `llm_api` 的 `ResilientHttpClient`（重试 1 次） |
| 429 / 瞬时 5xx | 同上（退避重试 3 次，默认） |
| **超上下文窗口** | **atelier 的 `invokeProvider`**（压头部再试） |
| 400 / 解析失败 / auth | 都不重试，直接失败（正确） |

**`invokeProvider` 只处理"必须改写历史才能继续"这一种失败**，
不是通用重试循环。这条已写进方法注释，避免下次读代码时误判。

> **遗留**：`Provider` 接口本身没有约定"重试归谁管"——现在这条契约藏在
> provider 实现内部。自实现的 Provider 默认没有传输级重试。**未处理，见 §6。**

### 4.2 `extend` 不能用来给自己的类拆文件

实测（`carbon-cj` / `mustache-cj` 参考）：

| 场景 | 结果 |
|---|---|
| 类体方法 → 调**别的文件** extend 方法 | ❌ `not a member of class` |
| extend 方法 → 调主类字段/方法 | ✅ |
| extend 方法 → 调另一个 extend 文件的方法 | ✅ |
| 类声明写了接口，方法只写在 extend | ❌ `missing abstract modifier` |

**规则单向：extend 依赖主类，主类不依赖 extend。**

`carbon-cj` 能按主题拆 12 个文件，是因为它的 `struct Carbon` **不声明任何接口**、
主类只有 53 行且不反向调用。`AgentRuntime` 是 `AgentLoop` 的实现类，
正常写法就是类声明 `<: AgentLoop` + 类体实现——**不能为了让拆文件成立而把接口挪进 extend**。

### 4.3 访问修饰符

`atelier` 是**一个模块内含 15 个兄弟包**。

| 修饰符 | 包及子包 | 模块 |
|---|---|---|
| `internal` | ✅ | ❌ |
| `protected` | ✅ | ✅（放行整个模块，**不用**） |

`RunScope` 与三个枚举用 `internal`：同包（含测试）可见，`atelier.context` /
`atelier.trust` 等兄弟包不可见。

---

## 5. 提交记录

```
dfc99af  provider 调用 + 溢出恢复抽成 invokeProvider
4b08b6d  工具批次的执行与结果回写抽成 executeToolBatch
4ba71bd  工具准入判定抽成 ToolAdmission，消掉三份重复逻辑
b5f17af  抽出主循环的回合开场与请求前压缩两个阶段
5f8c748  主循环的跨回合可变状态收进 RunScope
```

每步独立提交、独立跑全量测试，全程 **951 全绿**。

---

## 6. 遗留与后续

| 项 | 说明 |
|---|---|
| `Provider` 接口的重试契约 | 当前未声明"传输级重试由实现负责"。可考虑补接口文档或提供 `RetryingProvider`（复用现有 `ProviderMiddleware`，不必新机制） |
| 可测性 | 本轮改善的是**可读性**。压缩 / 准入 / 批次执行虽有方法边界，但测试仍需构造完整 runtime。若要真正可测，需把它们做成独立类（本轮未做，因为主循环也调用它们，抽成类要改调用点） |
