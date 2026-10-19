# 阶段 2 设计：事件事实化 + 投影层

> 日期：2026-10-20 ｜ 前置：阶段 1（B 类修复）在 `probe/loop-orchestration` 分支
> 依据：`2026-10-19-loop-orchestration-audit.md` §3.3，以及 `atelier-yggdrasil` 的实测现状

---

## 0. 为什么做（需求已被下游用代价证明）

原本我判断「投影层可能不该做」，前提是「不需要多读者、不需要回放」。这两条需求被确认成立后，结论反转。

更硬的证据来自 `atelier-yggdrasil`——它已经在为缺失的这层**自己付账**，而且是三份互不对齐的副本：

| 副本 | 位置 | 形态 |
|---|---|---|
| ① 宿主事件 DTO | `agent_plugin/src/main.cj:465` `toEventDto` | `AgentEventDto(sid, eventType())`，**结构化字段大量丢弃** |
| ② `TurnTermination` | `agent_plugin/src/turn_termination.cj`（~200 行） | 专门猜「这一轮到底结束没有」的状态机 |
| ③ UI `SessionView.items` | `yggdrasil_host/src/chat_page.cj:68,150-190` | 自己用 `items.add` / `items[n-1]` 重建消息投影 |

② 的注释是核心证据：

> **权威终局是「生产端收尾」（`isClosed`），不是 `AgentEndEvent`。**
> 引擎报"这一轮完了"常常先到，但最后那段正文可能还没写完整。

也就是说下游在**猜语义**而不是读事实。这份补丁应该回到内核，而不是每个宿主各写一遍。

`session_pool.cj` 同样印证：「三层状态的生死不同步，这是绝大多数困惑的来源」（内存会话 / 引擎会话 / 存储）。

---

## 1. 关键判断：不需要重写 SessionStore

原计划 §3.3 ① 写的是「先建会话事件流」。那个说法过重——**真正的缺口不在存储，在事件信息量**：

| 现有能力 | 状态 | 结论 |
|---|---|---|
| `AgentEvent` 携带结构化字段 | ✅ 大部分齐全（`TurnEndEvent` 有 message + toolResults，工具事件有 id/name/result） | 够用 |
| **回合结束原因** | ❌ **缺失**：`TurnEndEvent` 不带 reason，`StopReason` 只有 5 值，表达不了「预算耗尽 / 钩子短路 / 挂起 / 崩溃遗留」 | **主缺口** |
| 跨进程恢复 | ⚠️ 靠整份 `save()` + `load()` | 够用，不改 |
| 历史可回放 | ⚠️ 靠存储里的消息 | 够用，不改 |
| **可查询的派生状态** | ❌ 没有 fold 层，读者各自维护（见上表） | **次缺口** |

**所以阶段 2 的范围收缩为两件事**：
- **2a** 事件携带完整事实（主要是结束原因）
- **2b** 一层纯 fold 投影，让读者查状态而不是猜

不动 `SessionStore` 的存储形态。工程量从「五位数行」降到可控。

---

## 2. 2a：`TurnEndReason` 枚举

参照 dsh `TurnEndReasonMap`（`dsh-session/lib/types/types.d.ts:166-211`）的 7 个变体，收成仓颉枚举：

```cangjie
/**
 * 一次回合结束的真实原因。
 *
 * 为什么必需：`StopReason` 描述的是**模型这一条回复**怎么停的，
 * 而回合可能因为别的原因结束（预算耗尽、钩子短路、宿主要求挂起、崩溃遗留）。
 * 两者混用会让消费端把"任务被预算掐断"当成"模型正常收尾"。
 */
public enum TurnEndReason {
    /** 模型自然收尾，无后续动作 */
    | Completed
    /** 因输出截断在**同一回合内**续跑（预算未耗尽） */
    | ContinuedAfterTruncation
    /** 工具调用预算耗尽，剩余调用未执行 */
    | ToolBudgetExhausted
    /** `beforeTurn` 钩子短路了整个 run */
    | BlockedByHook
    /** 宿主要求先确认/补充：历史停在 assistant(tool_calls)，等下一次 run 带回 */
    | Suspended
    /** 调用方取消 */
    | Cancelled
    /** 失败（provider 错误 / 工具批次异常 / 内部异常） */
    | Failed(String)
    /** 达到 maxTurns 上限 */
    | MaxTurnsReached
    /** 崩溃遗留：由恢复流程事后补写，运行时不发 */
    | Interrupted
}
```

放进 `TurnEndEvent`：`TurnEndEvent(message, toolResults, reason)`。

**兼容性**：`TurnEndEvent` 是公开类。加字段两种做法——
- 新增命名可选参数 `reason: TurnEndReason = TurnEndReason.Completed`（构造点不动，语义默认为已完成）
- 缺点：默认值会把「旧的错误收尾」也当成 Completed

**建议**：**不设默认值**，逐个改全仓 11 个发射点。这正是我们要修的事实缺口，默认值等于留下一个静默错误源。11 个点都在 `runtime.cj`，可控。

同时把 `RunScope.finished: Bool` 升级为 `RunScope.endReason: Option<TurnEndReason>`（`None` = 还在跑），对应 dsh 的 `turnEnds`。这解决 B8。

---

## 3. 2b：纯 fold 投影

### 3.1 形态

不引入 dsh 那种「字符串 key 动态注册表」（仓颉无动态派发/运行时类型字典）。改成**显式具体类型 + `match`**：

```cangjie
/**
 * 一次 run 的可查询状态：由事件流 fold 出来的**纯派生事实**。
 *
 * 为什么需要：多个读者（宿主 UI / 协议适配层 / 面板 / 导出）现在各自维护一份状态
 * （宿主 DTO 丢字段、UI 自建 items、termination 状态机猜终局），三份互不对齐。
 * 折叠成一份之后，读者只读，不再各自重建。
 */
public class RunProjection {
    public var status: RunStatus            // Idle | Running | Suspended | Finished
    public var turns: ArrayList<TurnRecord> // 每个回合：序号、结束原因、消息
    public var toolCalls: HashMap<String, ToolCallRecord>  // 按 id：name/started/ended/isError
    public var text: ArrayList<(String, String)>           // (role, content) 渲染用
    public var lastEndReason: Option<TurnEndReason>

    /** 纯函数：吃一条事件返回新状态（不就地修改入参） */
    public static func fold(prev: RunProjection, ev: AgentEvent): RunProjection
}
```

**关键约束**：`fold` 必须是纯函数（`prev` 不改，返回新对象）。这样它可以：
- 被单测直接喂事件序列断言结果
- 被回放（读历史事件重建任一时刻状态）
- 被多个读者共享（同一份 fold 结果）

### 3.2 与现有 EventBus 的关系

`EventBus` 现在是**同步通知**（`publish` 逐个调订阅者）。投影层**不改它**，而是并列提供：

- `EventBus`：实时推送（现有语义不变）
- `RunProjection`：状态快照（新）

两者都从同一份事件流来，所以不会分叉。可选：提供 `EventBus.subscribeProjection(初始态, 回调)` 的便捷封装，但非必需。

---

## 4. 2c：世界树改造（验收标准）

**验收判据：`TurnTermination` 那 200 行能删掉，且行为等价。** 如果删不掉，说明投影层没做对。

改造点：
1. `agent_plugin/src/turn_termination.cj` → 删除，改读 `RunProjection.status`
2. `agent_plugin/src/main.cj:465` `toEventDto` → 不再丢字段，`AgentEventDto` 携带 `endReason`
3. `yggdrasil_host/src/chat_page.cj` 的 `SessionView.items` → 由投影驱动（或至少不再自己拼 message_update）

**但要逐条核对哪些能删、哪些是合法的流语义**：

`TurnTermination` 里有两类逻辑，必须区分：

| 逻辑 | 性质 | 处置 |
|---|---|---|
| `sawEnd` / `idleRounds` / `drainRounds`：事件流关闭后仍可能有排队事件 | **合法的流语义**（生产端 `setResult → emit → close` 的顺序） | **保留**，但它不是「猜终局」，是「等流真正空」 |
| 用 `AgentEndEvent` 推断「这一轮完了」 | **绕路**（真实原因拿不到） | 删除，改读投影 |

所以 2c 不是无脑删 200 行，而是**把猜语义的部分换成读事实**，等流的部分保留。这点必须在实施时守住。

---

## 5. 阶段 3 的前提（本次不做）

只有当 2b 落地、读者改读投影之后，才谈得上「按状态归属切类 → 拆文件」。那时：
- 权威状态有唯一归属（投影）
- 子系统只持派生/瞬时状态
- 每个类自然有自己的文件

在那之前拆文件仍然是「把 `this.` 的访问搬到别的文件」。

---

## 6. 实施顺序与风险

| 步骤 | 内容 | 风险 |
|---|---|---|
| 2a-1 | 新增 `TurnEndReason` 枚举 + 改 11 个 `TurnEndEvent` 发射点 | 低（编译期全暴露） |
| 2a-2 | `RunScope.finished` → `endReason` | 中（涉及控制流判断，但要逐个改，编译器会抓） |
| 2b-1 | `RunProjection` + 纯 fold + 单测 | 低（纯新增） |
| 2b-2 | 提供「事件流 → 投影」的驱动（可选便捷封装） | 低 |
| 2c-1 | 世界树：`toEventDto` 带上 endReason | 低 |
| 2c-2 | 世界树：删 `TurnTermination` 猜语义部分，保留等流部分 | **中高**（需逐条核对，行为等价验证） |
| 2c-3 | 世界树：UI 由投影驱动 | 中 |

**回滚点**：2a 与 2b 都是纯新增/编译期可查，随时可停。2c 在世界树侧，与内核解耦，可单独回滚。

---

## 7. 明确不做

- ❌ 不改 `SessionStore` 的整份 `save()` 语义
- ❌ 不做跨进程恢复的新机制（现有够用）
- ❌ 不引入动态注册的投影表（仓颉无此能力，显式类型更安全）
- ❌ 不在本阶段拆 `AgentRuntime` 文件
