# 全功能提问：审批 / 选择 / 表单统一到「挂起—答复」模型（重构级）

> 现状：`AskUserFn = (String) -> String` 同步回调，三个调用点各自拼菜单、比对魔法字符串
> （[runtime.cj:401](../../atelier/src/agent/runtime.cj)、[runtime.cj:813](../../atelier/src/agent/runtime.cj)、
> [ask_user.cj:25](../../atelier/src/tool/builtin/ask_user.cj)）。它阻塞 run 线程、无 id、无记录、
> 空串语义重载，协议层（AG-UI）无法表达"run 结束了，在等输入"。
>
> 目标：**一套提问原语**覆盖审批、选择、表单，并与上一轮做好的挂起原语
> （`ToolResult.external` / `SuspendEvent`）合成同一个模型。

## 一、类型设计（核心库，`atelier/src/agent/user_request.cj`）

```cangjie
// 问什么：三种形态共用一套请求，kind 决定哪些字段有意义
public enum UserRequestKind { | Approval | Choice | Form | ToolExecution }

// 候选项（Choice 与 Approval 共用）：id 是回填值，label 给人看
public class UserOption {
    public let id: String          // "allow_once" / "deny" / "opt-a" ...
    public let label: String
    public let description: String
    public let danger: Bool        // 前端可标红（删除类操作）
}

// 表单字段：够用即止的类型集合，不引入完整 JSON Schema 引擎
public enum UserFieldType { | Text | Number | Bool | Select | MultiSelect }
public class UserField {
    public let name: String
    public let label: String
    public let fieldType: UserFieldType
    public let required: Bool
    public let options: ArrayList<UserOption>   // Select / MultiSelect
    public let defaultValue: Option<String>
    public let placeholder: String
}

public class UserRequest {
    public let id: String                 // **确定性** id：恢复时靠它关联（见 §三）
    public let kind: UserRequestKind
    public let message: String            // 给人看的一句话（前端兜底渲染）
    public let detail: String             // 补充说明（多行；如工具参数预览）
    public let toolCallId: String         // ToolExecution / Approval 绑定
    public let toolName: String
    public let args: Option<JsonValue>    // 审批时展示被批准的操作
    public let options: ArrayList<UserOption>
    public let multi: Bool                // Choice 是否多选
    public let fields: ArrayList<UserField>
}

// 答什么：扁平结构 + status，便于跨协议序列化（ACP elicitation / AG-UI resume / TUI 共用）
public enum UserAnswerStatus { | Answered | Pending | Cancelled | TimedOut }

public class UserAnswer {
    public let requestId: String
    public let status: UserAnswerStatus
    public let selected: ArrayList<String>            // 选项 id（审批：allow_once/allow_always/deny）
    public let text: String                           // 自由文本（Text 字段或纯文本提问）
    public let values: HashMap<String, JsonValue>     // 表单值
    public let editedArgs: Option<JsonValue>          // 审批并改参数（AG-UI 的 approve-with-edits）
}
```

**关键点**：`Pending` 是给**可挂起宿主**用的返回值 —— 宿主立刻返回 `Pending`，
runtime 据此挂起本次 run（与工具"要外部结果"走同一条路）。阻塞式宿主（TUI/ACP）直接 park 线程，
返回 `Answered`，行为与今天一致。

## 二、runtime 流程

```
模型产出 assistant(tool_calls)
      │
      ├─ 逐个决定信任闸门 ──► NeedsApproval ──► runtime.ask(UserRequest(Approval)) ─┐
      │                                                                           │
      ├─ 执行工具 ──► 工具内 ctx.ask(UserRequest(Choice|Form)) ────────────────────┤
      │                                                                           │
      │                      宿主返回 Pending ──► 发 UserRequestEvent + SuspendEvent
      │                                            └─ 结束本次 run（历史停在 assistant(tool_calls)）
      │                      宿主返回 Answered ──► 就地继续（今天的行为）
      ▼
下一次 run 带 UserAnswer 输入（resume）
      └─ runtime 发现"历史停在 assistant(tool_calls) 且有未完成调用" → 用答复补齐 →
         继续同一批工具执行 → 模型继续
```

- **统一挂起**：`SuspendEvent` 的载荷从 `ExternalRequest` 泛化为 `UserRequest`
  （`kind=ToolExecution` 即今天的客户端工具场景），AG-UI 侧的中断类型直接由 `kind` 映射
- **答复即输入**：新增一种输入消息 `UserAnswerMessage`（随会话持久化 ✓），
  与工具结果同级；run 的恢复路径先消费它，再让模型继续
- **确定性 id**：`ask:<sessionId>:<turn>:<toolCallId|"gate">:<kind>` —— 同一处提问在重放时
  id 不变，宿主/前端才能把答复对上（也天然满足 AG-UI 的 resume 幂等要求）

## 三、恢复语义（必须写清楚，否则会埋雷）

- **审批在批量执行之前决定**：信任闸门与 PTC 授权都发生在 `executeBatch` **之前** →
  挂起后重放这一回合**没有已发生的副作用** ✓
- **工具内的提问**（`ask_user` 类）发生在执行**途中** → 挂起时同一批里可能有工具已经执行完。
  处理：挂起前把**已完成调用**的结果写进会话（正常工具结果），未完成的调用保持"无结果"；
  恢复时 runtime 只重放**缺结果**的调用（用答复作为其结果），已完成的调用不重放 → 副作用不翻倍
- 跨进程恢复依赖会话里的 `assistant(tool_calls)` + 已完成结果 + `UserAnswerMessage`
  （llm_api ≥1.3.7 已能持久化 tool calls ✓）；跨进程仍无法关联的答复按协议回错误，不静默丢

## 四、宿主适配

| 宿主 | `ask` 实现 | 说明 |
|---|---|---|
| TUI / CLI | park 线程 → 返回 `Answered` | 行为不变；菜单改由 `UserRequest.options` 渲染 |
| ACP | 映射到 `session/request_permission`（审批）与 **elicitation**（表单/选择） | 今天的 `elicitationAsk` 保留为传输层，语义由 `UserRequest` 决定；decline/cancel 不再折叠成空串 |
| AG-UI | 立刻返回 `Pending` | `kind` → `interrupt.reason`（`tool_call`/`confirmation`/`input_required`），`fields` → `responseSchema`，答复走 `resume[].payload` |
| 子 agent | 父向 `sendMessage` 通道 | 与今天一致，但载荷换成 `UserAnswer` |

## 五、迁移步骤（每一步独立可发布，均带用例）

1. **类型与事件**（不破坏签名）：新增 `user_request.cj` 全套类型 + `UserRequestEvent`；
   `SuspendEvent` 载荷泛化（`ExternalRequest` 保留为 `kind=ToolExecution` 的别名，旧代码不动）
2. **runtime 三处改造**：信任闸门、PTC 授权、`ToolContext.ask` 换成 `UserRequest`；
   `AskUserFn` 降级为兼容适配器（老宿主传字符串回调也能跑）
3. **答复即输入**：`UserAnswerMessage` + 恢复路径（缺结果调用只补不重放）+ 持久化
4. **`ask_user` 工具升级**：支持 `question` / `options` / `fields` 三种入参 → 一个工具覆盖选择与表单；
   新增 `request_approval` 语义（或由工具参数表达）
5. **宿主适配**：TUI/CLI（菜单渲染）、ACP（permission + elicitation）、AG-UI（interrupt 映射 + resume 幂等）
6. **删旧**：三处魔法字符串比对、`toolApprovalFn`（被吸收）、AG-UI 的私有 `/ag-ui/input` 与
   `CUSTOM user_input_request`

## 六、用例清单（先写用例再实现）

核心：
- 审批三态（once / always / deny）各自的效果与信任状态落点
- 选择：单选、多选、默认值、取消
- 表单：必填缺失、类型不符、Select 取值非法 → 结构化错误而非静默接受
- 挂起：`Pending` → 发 `UserRequestEvent` + `SuspendEvent`，不写伪结果
- 恢复：只补缺结果的调用；已完成调用不重放（用一个会计数的假工具断言执行次数）
- 确定性 id：同一处提问两次调用 id 相同
- 兼容：老 `AskUserFn` 字符串回调仍能驱动审批与 `ask_user`

宿主：
- AG-UI：`kind` → `reason`/`responseSchema` 映射；resume 幂等（同参数重放返回同一结果）
- ACP：decline / cancel / 传输失败三种结果可区分（不再都是 `""`）

## 七、破坏性变更与兼容

- `ToolContext.askUser: AskUserFn` → `ToolContext.ask: (UserRequest) -> UserAnswer`
  （旧字段保留一版，标注 deprecated，内部转调）
- `SessionLoop`/`AgentRuntime` 构造参数多一层（`ask`），旧签名保留重载
- 会话新增 `UserAnswerMessage`：旧数据无此类型，读回时忽略即可（向后兼容 ✓）

## 八、风险

- **重放安全**是这套设计的命门：任何在挂起点之前产生的副作用都必须要么已完成并落盘、
  要么可以安全重放。步骤 3 的用例（假工具计数）就是这条的守门人
- 表单/选择的校验放在 runtime 侧（不是前端）：前端只负责渲染，答复一律过校验，
  否则多端（TUI/AG-UI/ACP）行为会分叉
- `Pending` 与 `Answered` 的分支必须穷举匹配（仓颉枚举穷举 ✓），避免新增 kind 时漏处理

## 九、决策记录：**不做**兼容适配器（2026-10-01）

第 2 步曾把老的 `askUser(String) -> String` 用 `extend ToolContext { ask }` 包成结构化入口，
让老宿主零改动。**决定去掉这条兼容路径**：宿主本来就要改（第 5 步），留着会出现
"结构化提问 + 字符串提问"两条并存的路径——正是本次重构要消灭的东西。

改法：`ask` 从"方法适配器"升级为 `ToolContext` 的**一等字段**：

```cangjie
public type AskFn = (UserRequest) -> UserAnswer
public struct ToolContext { ... public let ask: AskFn ... }   // 5 个构造器同步加参数
```

宿主的改法都是**显式**的（不再有隐藏转换），各成员一次性改完，避免"一半结构化一半字符串"：

| 文件 | 改动 |
|---|---|
| `atelier/src/tool/interface.cj` | `askUser` 字段 → `ask: AskFn`；删掉 `extend ToolContext { ask }` 适配器；5 个构造器同步 |
| `atelier/src/tool/builtin/ask_user.cj` | 工具升级三形态（`question` / `options` / `fields`），直接构造 `UserRequest` |
| `atelier/src/agent/runtime.cj` | 构造参数 `askUser` → `ask`；`askHost` 的兜底从 `ctx.ask` 改为 `this.ask` |
| `atelier/src/agent/session_loop.cj` | `askUserFn` → `askFn`（默认 = 取消，而不是空串） |
| `atelier/src/acp/bridge.cj` | Approval → ACP permission 请求；Choice/Form → elicitation（表单桥） |
| `cli/src/app/main.cj`、`cli/src/shared.cj`、`cli/src/tui.cj` | 终端提问：渲染 `message` + `options`/`fields`，答复结构化 |
| `server/src/handler.cj`、`server/src/ag_ui_handler.cj` | AG-UI 侧：见下 |

### 两个必须先定的宿主行为

1. **AG-UI 的 `ask` 返回 `Pending`（挂起）还是沿用阻塞 `/ag-ui/input`？**
   建议 `Pending`（第 5 步）——理由：绑定 AG-UI 的 interrupt 契约后，前端渲染的是
   `RUN_FINISHED.outcome.interrupts`，私有 `CUSTOM user_input_request` + `/ag-ui/input` 都可以删掉；
   阻塞式通道留着的唯一好处是"不用等前端重放"，但那条通道标准前端根本不会用。
2. **ACP 表单桥**：`session/request_permission` 只适合审批（是/否），
   选择与表单需要走 elicitation 的多字段表单——需要确认 ACP 客户端（Zed 等）的 elicitation
   支持到什么程度，否则选择/表单在 ACP 端只能降级为"文本输入"。

在这两条定下来之前，**不启动这次删除**：否则宿主要改两遍（先适配字符串→结构化，再适配阻塞→挂起）。

### 两个待定行为的结论（2026-10-01 定）

**① AG-UI：`ask` 返回 `Pending`（挂起）** —— 已定。随之删除私有通道
（`CUSTOM user_input_request` 与 `POST /ag-ui/input`），标准前端只认 `RUN_FINISHED.outcome.interrupts`
+ 下一次 run 的 `resume[]`。

**② ACP：elicitation 能力调研结论（依据本仓 `acp-cj`，它按官方 schema 实现）**

| 能力 | 现状 | 映射策略 |
|---|---|---|
| 结构化表单 | `ElicitationSchema.of(props, required:)` + form 模式 ✓ | `Form` → 一个字段一个 property |
| 字段类型 | `string` / `number` / `integer` / `boolean` / `array` + `EnumOption` ✓ | `Text`→string、`Number`→number、`Boolean`→boolean、`Select`→enum |
| 单选 | enum + `EnumOption` ✓ | `Choice(multi=false)` → 单个 enum property |
| **多选** | 没有"数组元素为枚举"的明确表达 ✗ | **降级为 N 个 boolean property**（各客户端都能渲染；id 校验仍在 runtime 侧） |
| 审批 | `session/request_permission` 才是 ACP 的原生机制 ✓ | `Approval` → permission 请求（不走 elicitation），与现有 `toolApprovalFn` 桥合并 |
| 能力协商 | `clientCapabilities.elicitation` 可选 ✓，未声明时 form 模式必须拒绝 ✓ | 未声明 → **明确降级**：单字段文本提问；仍不可用则返回 `Cancelled` 并留痕（不再用空串表示失败） |

结论：不需要等外部调研，ACP 侧三种形态都能落；唯一需要降级的是**多选**（拆成多个 boolean）。

### ACP 迁移的实施笔记（2026-10-01 现场勘察）

已知可用（`acp-cj/src/types/elicitation.cj`）：

| 入口 | 说明 |
|---|---|
| `ElicitationPropertySchema.string()/.number()/.integer()/.boolean()/.array()` | 字段类型齐全 ✓ |
| `EnumOption` | 枚举项（`const`/`title`；注意 `const` 是仓颉关键字，访问写 ``opt.`const` ``）✓ |
| `ElicitationSchema.of(props, required:)` + `CreateElicitationRequest.form(...)` | 多字段表单 ✓ |
| `agent.createElicitation(req, timeout:)` → `Result` | 反向请求 ✓ |

需要新写的两处：

1. **答复提取**：现有 `elicitationAnswerOf` 只认单字段 `answer`（且只处理字符串）✗，
   要改成按 schema 逐字段取（string/number/boolean/enum/array → values/selected ✓）
2. **枚举属性的构造入口**：`ElicitationPropertySchema` 的静态构造器只看到
   string/number/integer/boolean/array；单选要落成 enum，需要确认是直接给属性对象的
   `enum` 字段赋值，还是有静态构造器（勘察一次即可）

映射与降级（照 §九 的定稿）：

- `Approval` → 建议走 `session/request_permission`（ACP 原生机制，与现有 `toolApprovalFn` 桥合并），
  不走 elicitation；三选项 allow_once/allow_always/deny
- `Choice(multi=false)` → 单 enum 字段；`Form` → 一字段一 property
- `Choice(multi=true)` → **降级为 N 个 boolean**
- 能力未声明 / 传输失败 / 用户拒绝 → 分别返回 `Cancelled`（并留痕），**不再折叠成空串**
- 接线：`SessionLoop` 增可选 `askFn`（转发给 runtime 的 `ask:`），bridge 传
  `{ req => this.answerUserRequest(acpId, req) }`

## 十、AG-UI 端到端验收（2026-10-01 实跑通过）

工具：`scripts/agui-probe.mjs` —— **零依赖**（fetch + SSE 解析），可直接进 CI：

```shell
node scripts/agui-probe.mjs http://127.0.0.1:8791 default
```

跑法（重建 → 起服务 → 探针 → 收尾）见 `.harbor/agui-probe-run.sh`；注意沙箱评测要用
**cjc 1.2.0 + stdx 1.2.0.1** 构建（1.1.3.1 过不了 srt 的认证代理）。

实测事件序列（真实模型）：

| 趟 | 事件 | 断言 |
|---|---|---|
| 1 | `RUN_STARTED → STATE_SNAPSHOT → STEP_STARTED → REASONING_* → TOOL_CALL_START/ARGS/END → CUSTOM → STEP_FINISHED → MESSAGES_SNAPSHOT → RUN_FINISHED{interrupt}` | 挂起 ✓ `reason=tool_call` ✓ 快照在 FINISHED 之前 ✓ |
| 2 | `RUN_STARTED → STATE_SNAPSHOT → TOOL_CALL_RESULT → STEP_STARTED → TEXT_MESSAGE_* → REASONING_* → STEP_FINISHED → RUN_FINISHED{success}` | 恢复补发 `TOOL_CALL_RESULT`（**不重发** `TOOL_CALL_START`）✓ 正常收尾 ✓ |

这一步同时验证了三件本轮改动：中断边界前给状态、恢复走"补结果"而不是重放整段、挂起期间不重复执行工具。

## 十一、TUI 迁移的实施笔记（2026-10-01）

收敛规则收在 `cli/src/ask.cj` 的 `AskPrompt`（与终端无关 → 可单测），TUI 只做两件事：
画它给的行（`panelLines`）、把按键喂给它（`handleAskKey`）。判定标准是**答复在送出前过一遍
`validateAnswer`**（runtime 同一套），不合格就地打回 —— 宿主自己造答复最容易出的错，
就是造出一个 runtime 认不出来的东西（用户已经走完流程，回合却报"答复不合格"）。

| 项 | 结论 | 理由 |
|---|---|---|
| 候选列表（审批 / 选择 / `bool`\|`select`\|`multi_select` 字段） | ↑/↓ 移动，空格勾选（多选），回车提交 | 候选自带 `label`/`description`/`danger`，比 y/a/n 菜单能承载语义 |
| 文本字段（`text`/`number`，含"普通提问"的单字段表单） | 走输入行，逐字段推进 | 与既有输入模型一致；打回时原文放回输入行 |
| Esc | 取消**本次提问**，不再是退出程序 | 提问是模态，模态里的 Esc 是取消；退出仍走 Ctrl+C |
| 取消的答复 | `Cancelled`（不是空串/空答复） | 空答复无法与"拒绝 / 答了个空 / 没通道"区分 |
| `ToolExecution`（客户端工具） | 直接 `Cancelled` + 面板说明 | TUI 没有执行外部工具的通道，等下去没人会按 |
| 表单值形态 | `text`/`number`/`select` → 字符串；`bool` → 布尔；`multi_select` → 字符串数组 | 与 ACP 侧字符串通道口径一致，校验侧接受"可解析成数字的字符串" |
| 无候选项的请求 | 初始化即 `Cancelled`，不进等待 | 让用户对着空列表敲回车 = 把回合挂死 |

模态性有跨线程用例守着（`tui_test.cj`）：回合线程登记提问并等待 → 主线程按键 → 答复回填；
提问期间打的字不会变成新消息。


## 十二、第 6 步收口：删掉字符串适配器（2026-10-01）

提问只剩一条通道：`AskFn = (UserRequest) -> UserAnswer`。所有"字符串问答"的残留一律退场 ——
留着它们，新宿主会照着旧例子接，最后又是三端行为分叉。

**删除**

| 位置 | 删掉的东西 | 原因 |
|---|---|---|
| `atelier.tool` | `AskUserFn`、`ToolContext.askUser` | 空串同时表示"拒绝/答了空/没通道"，下游无法区分 |
| `AgentRuntime` | `askUser` 位置参数、`toolApprovalFn` | 被 `ask` 吸收；审批不再走"y/a//"魔法字符串 |
| `SessionLoop` | `approvalFn!`、`askUserFn!` | 同上 |
| `atelier.acp` | `requestToolApproval`、`elicitationAsk`、`elicitationAnswerOf` | 审批/问答统一走 `answerUserRequest` → elicitation |
| `server`（AG-UI） | `AgUiInputDTO`、`inputKey`、`AgUiUserInputPayload`、`CustomEvent("user_input_request")` | 输入通道已由 `resume[]` 取代；`/ag-ui/input` 上一轮已删 |

**替换**

- `ToolContext.askFn: Option<AskFn>`；`ctx.ask(req)` 在无实现时返回 `Cancelled`（= "这条通道不存在"，
  不是"用户拒绝了"）。`callContext` 顺带修正：派生上下文原先没带 `askFn`，子调用会静默失去提问能力。
- `AgentRuntime`：13/11/9 参构造都接受 `ask!: Option<AskFn>`（命名、可选）；不传 = 无交互通道。
- **HTTP 提问通道**（`/agent/stream` + `/agent/input`，见 docs/http-api.md）：
  - 推 `data: {"type":"user_request","request":{...}}`（整条 `UserRequest`，含选项/字段/toolCallId）
  - 回传 `{requestId, status, selected, text, values}`；`requestId` 对不上 → `404`、答复不合格 → `400`
  - 旧实现把答案投给"任意一条等待中的提问"（并发下第一个等待者会拿到别人的答案）→ 改为按 id 精确投递
  - 表单值按字段声明类型包装（bool → 布尔、multi_select → 数组），再交 `validateAnswer`

**宿主接线速查**

| 宿主 | 接法 |
|---|---|
| TUI | `AgentRuntime(..., McpManager(), ask: Some({ req => this.askHost(t, req) }))` |
| ACP | `SessionLoop.run(..., askFn: Some({ req => this.answerUserRequest(acpId, req) }))` |
| AG-UI | `ask: Some({ req => UserAnswer.pending(req.id) })`（挂起 → `RUN_FINISHED{interrupt}`） |
| HTTP SSE | `/agent/stream` 内推 `user_request` 帧 + 等 `/agent/input` 回传 |
| 一次性 / 批处理 | 不传 `ask` → 提问按取消处理（配合 `ATELIER_TRUST_DIR` 预授权） |
