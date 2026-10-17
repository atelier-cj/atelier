# C-2 计划 v3：先理控制流，再谈拆分

> 日期：2026-10-17 ｜ 状态：**计划（未开工）**
> 归属：`atelier/src/agent/runtime.cj`
> **v3 改变了顺序**：v1/v2 都想先拆文件，结果都撞在同一堵墙上——
> **主循环的控制流是乱的，拆什么都是在混乱之上加间接层。**

---

## 0. 顺序为什么反了

v1：把主循环切成 5 个阶段类，共享 `RunState` → **`RunState` 变成上帝对象**。
v2：用 `extend` 按主题拆文件 → **类体调不到 extend 方法，主循环拆不出去**。

两次都失败，根因同一个：**没先看主循环内部长什么样**。

实测后发现真相——`chatWithEnv` 548 行里有 **15 个 `break`/`continue`**，
散落在嵌套 **5 层到 9 层**的位置（含内层 `while` 与 `match`）。
在这种结构上做任何拆分，都只会把 `break` 换成别的噪音。

**所以顺序应当是：① 理清控制流 → ② 再看还剩什么可拆。**

---

## 1. 现状实测：控制流的真实结构

### 1.1 `chatWithEnv` 548 行里的所有出口

| 行 | 后接 | 场景 |
|---|---|---|
| 871 | `break` | beforeTurn 钩子短路 |
| 948 | `break` | provider 请求失败（溢出恢复也没救回来） |
| 961 | `break` | 工具边界处取消 |
| 970 | `break` | `stopReason=ToolUse` 但没给任何 tool call（防空转） |
| 982 | `break` | 工具预算耗尽（`Exhausted`） |
| 1109 | `continue` | 审批挂起（`SuspendEvent`） |
| 1181 | `continue` | 工具等外部结果（`SuspendEvent`） |
| 1190 | `break` | 回合收尾处取消 |
| 1234 | `break` | afterTurn 钩子短路 |
| 1238 | —— | 正常收尾 |

### 1.1b 完整清单（15 个，含内层循环）

| 行 | 深度 | 语句 | 归属 |
|---|---|---|---|
| 872 | d5 | `break` | 外层 while —— 钩子短路 |
| **903** | **d8** | `break` | **内层 while**（流式接收）—— 取消 |
| 935 | d7 | `continue` | **内层 while(true)**（溢出重试）—— 重试 |
| 949 | d5 | `break` | 外层 while —— provider 失败 |
| 962 | d6 | `break` | 外层 while（在 match 内）—— 工具边界取消 |
| 971 | d6 | `break` | 外层 while —— 空批次 |
| 983 | d6 | `break` | 外层 while —— 预算耗尽 |
| 1110 | d6 | `continue` | 外层 while —— 审批挂起 |
| 1133 | d6 | `continue` | 外层 while —— 批量执行异常 |
| **1154** | **d9** | `continue` | **内层 for**（结果回写）—— 跳过 external |
| 1182 | d6 | `continue` | 外层 while —— 外部结果挂起 |
| 1191 | d6 | `break` | 外层 while —— 收尾取消 |
| 1215 | d6 | `continue` | 外层 while —— 截断续跑 |
| 1220 | d6 | `continue` | 外层 while —— 自验续跑 |
| 1235 | d6 | `break` | 外层 while —— afterTurn 短路 |

**关键**：深度 d5/d6/d7 的是"控制外层 while"，d8/d9 的是"控制内层循环"，
**两者混在同一个函数里，读代码时必须先数清这个是跳哪一层**——这正是可读性的核心问题。

- 对外层 while：**9 个结束点**（7 `break` + 2 `continue`）
- 对内层循环：**3 个**（903 流式 break、935 重试 continue、1154 for continue）
- 另有 **2 个 continue 是"续跑同回合"**（1215 截断、1220 自验）

### 1.2 关键发现：`continue` 与 `break` 混用表达同一语义

```cangjie
// 1109：审批挂起
finished = true
continue        // ← 其实是"结束 run"，不是"继续下一轮"
```

这两个 `continue` 都跟在 `finished=true` 之后——因为 `finished` 已置位，
`while` 条件会退出。**但写成 `continue` 会让读者以为还有下一轮。**

这是最容易误读的地方：**`break` 和 `continue` 在这里的差别没有语义，只有位置巧合。**

### 1.3 归并后的真实语义（7 种）

| 语义 | 现有出口 |
|---|---|
| **① 正常收尾** | 1238 |
| **② 短路收尾** | 871, 1234 |
| **③ 异常收尾** | 948, 970, 982 |
| **④ 取消收尾** | 961, 1190 |
| **⑤ 挂起** | 1109, 1181 |
| **⑥ 续跑同回合** | 935（溢出重试）, 1215（截断续跑） |
| **⑦ 继续下一轮** | 隐式（工具批次正常完成） |

**9 个出口 → 7 种语义。** ①–⑤ 全部是"结束本次 run"，只有 ⑥⑦ 是"还要跑"。

---

## 2. 整理方案：一轮 = 一个函数，返回值取代 `break`

### 2.1 核心思路

**把"一轮"抽成一个方法，它只返回"这一轮怎么结束的"，不控制外层循环。**

```cangjie
public enum TurnOutcome {
    | ContinueTurn        // 继续下一轮（正常工具批次完成）
    | ResumeSameTurn      // 同回合续跑（截断 / 溢出重试），不推进回合计数
    | Finish              // 结束本次 run（含正常/短路/异常/取消/挂起）
}
```

外层循环变成 12 行：

```cangjie
while (!finished && !cancelFlag.load() && turnCount < maxTurns) {
    match (this.runOneTurn(...)) {
        case TurnOutcome.ContinueTurn   => turnCount++
        case TurnOutcome.ResumeSameTurn => ()          // 不推进计数
        case TurnOutcome.Finish         => finished = true
    }
}
```

**收益**：`while` 循环体从 ~500 行降到 ~12 行，**9 个跳跃出口收敛成 3 个枚举值**。

### 2.2 已验证（探针，2026-10-17）

```cangjie
class Loop {
    private var finished = false
    func runOneTurn(turn: Int64): Step { ... }     // 只返回 Step
    func run(): Int64 {
        while (!finished && turn < 5) {
            match (runOneTurn(turn)) {
                case Step.End => finished = true
                case Step.Continue => turn++
                case Step.ResumeSameTurn => ()
            }
        }
    }
}
// → cjpm build success
```

### 2.3 为什么这比"拆阶段类"好

| | 阶段类（v1） | 一轮一函数（v3） |
|---|---|---|
| 共享状态 | 5 个对象共用一个 `RunState`（上帝对象） | 只有 `runOneTurn` 一个方法，参数即接口 |
| 控制流 | 阶段返回时要处理 `continue`/`break` | **枚举值表达，天然无跳跃** |
| 能否单测 | 要造 `RunState` + 5 个阶段 | 可直接喂假 provider 测"这一轮" |

**关键差别**：v1 试图消解"共享状态"，v3 直接消解"控制流跳跃"。
而后者才是真问题（§1.2 的混用就是证据）。

---

## 3. 分步计划

### 第 1 步：抽出 `TurnOutcome` + `runOneTurn`

| 项 | 内容 |
|---|---|
| 做什么 | 把 `while` 循环体整体搬进 `runOneTurn(...)`，9 个出口改成 3 个返回值 |
| 行为变化 | **零**（纯重构，出口语义一一对应） |
| 风险 | **中**——9 个出口要逐个核对映射 |
| 验收 | 951 全绿 |

**映射表（必须逐条核对，写进提交信息）**：

| 原出口 | 新返回值 |
|---|---|
| 871 钩子短路 | `Finish` |
| 948 provider 失败 | `Finish` |
| 961 工具边界取消 | `Finish` |
| 970 空 tool call | `Finish` |
| 982 预算耗尽 | `Finish` |
| 1109 审批挂起 | `Finish`（挂起＝结束本次 run） |
| 1181 外部结果挂起 | `Finish` |
| 1190 收尾取消 | `Finish` |
| 1234 afterTurn 短路 | `Finish` |
| 1238 正常收尾 | `Finish` |
| 935 溢出重试 | `ResumeSameTurn` |
| 1215 截断续跑 | `ResumeSameTurn` |
| 隐式继续 | `ContinueTurn` |

> **待确认**：挂起与正常收尾是否要区分？
> 现在同为 `finished=true`。**建议先合并为 `Finish`**——
> 区分它们不改变外层行为（`SuspendEvent` 已经发了）。

### 第 2 步：消除 `resumingSameTurn` 标志

`resumingSameTurn` 用来阻止"续跑时重复推进回合计数"。有了
`TurnOutcome.ResumeSameTurn` 之后，**这个职责由返回值承担**，字段可删。

| 项 | 内容 |
|---|---|
| 做什么 | 删 `resumingSameTurn`，回合开场逻辑改由 `TurnOutcome` 驱动 |
| 收益 | 跨迭代可变状态 -1 |
| 风险 | 中（要确认 MCP 冷却推进仍只在真正新回合发生） |

### 第 3 步（可选）：`TurnState` 收拢参数

`runOneTurn` 参数较多（`currentMessages` / `turnCount` / `toolCallCount` / …），
可收进一个 `TurnState`。

> **注意**：它只装"一轮内"的状态，**不是** v1 那个"整个 run 的 8 字段上帝对象"。

### 第 4 步：此时再看能不能拆文件

控制流理顺后：

```
chatWithEnv (548) → chatWithEnv (~40 行) + runOneTurn (~500 行)
```

**`runOneTurn` 仍然大，但 9 个跳跃出口没了。** 这时再评估拆不拆——
若拆，拆的是"一轮内的几个自然段"，不再是"break 迷宫"。

---

## 4. 拆文件的语言约束（v2 教训，保留备查）

| # | 实测 | 结果 |
|---|---|---|
| 1 | 类体方法 → 调**别的文件** extend 方法 | ❌ `not a member of class` |
| 2 | extend 方法 → 调主类字段/方法 | ✅ |
| 3 | extend 方法 → 调**另一个 extend 文件**的方法 | ✅ |
| 4 | 跨文件访问 `private` | ❌ |
| 5 | 跨文件访问 `internal` | ✅ |
| 6 | `internal` 对**同模块兄弟包** | ❌ 不可见（`protected` 才行，但不用它——放行整个模块） |
| 7 | 接口**声明在 extend**（类声明不写） | ✅ 可编译 |
| 8 | 类声明写了接口，方法只写在 extend | ❌ `missing abstract modifier` |

> **第 7 条是语言上可行、但设计上不该做的**：`AgentRuntime` 是 `AgentLoop` 的实现类，
> 正常写法就是类声明 `<: AgentLoop` + 类体实现。把接口挪进 extend 只是为了配合拆文件，
> **属于让设计迁就拆法**。
>
> **所以 v2 的"carbon-cj 式按主题拆 extend"已废弃**：
> mustache-cj / carbon-cj 里 extend 用于**不属于自己的类型**（`Int64`/`String`）或**后加接口**，
> 与"给自己的类拆文件"不是一回事。

---

## 5. 明确不做

| 不做 | 理由 |
|---|---|
| **不用 `extend` 给自己的类拆文件** | 主类调不到 extend 方法；把接口挪进 extend 是本末倒置 |
| **不把接口实现移出类声明** | `AgentRuntime` 是 `AgentLoop` 的实现，正常写法就在类声明上 |
| **不在理顺控制流之前拆文件** | v1/v2 连撞两次墙，根因都是这个 |
| **不拆 `AgentRuntime` 类本身** | 27 个字段是它的装配身份 |
| **不拆 `SessionLoop`** | 宿主封装，与 `AgentLoop` 不同层 |

---

## 6. 验收标准

| 步 | 内容 | 预期效果 |
|---|---|---|
| 1 | `TurnOutcome` + `runOneTurn` | `chatWithEnv` 548 → ~40 行；出口 9 → 3 |
| 2 | 删 `resumingSameTurn` | 跨迭代可变状态 -1 |
| 3（可选） | `TurnState` 收拢 | 参数表变短 |
| 4 | 评估是否拆 | 视第 1 步结果决定 |

**每步硬性要求**：
1. `cjpm test -j 16 --no-progress` 全绿（基线 **951**）
2. 纯重构步骤不得有行为变化
3. 出口映射表逐条核对，写进提交信息

> **诚实提醒**：第 1 步**不减少总行数**（只是把循环体搬进方法），
> 也不马上带来可测性（`runOneTurn` 仍需完整 runtime）。
> 它买的是**可读性**：9 个跳跃出口变成 3 个返回值，后续任何改动都更容易判断影响面。
>
> **如果第 1 步做完仍觉得收益有限，那不拆文件也是正确的结论**——
> 至少控制流已经清楚了，而不是像现在这样靠 `break` 的位置猜测意图。

---

## 7. 与其它文档的关系

| 文档 | 关系 |
|---|---|
| `2026-10-17-ate-as-sdk-requirements.md` §5 档 C-2 | 本文是那一条的展开 |
| 本文 v1 / v2（已废弃） | v1＝阶段类 + `RunState`；v2＝extend 拆文件。失败原因见 §0 |
