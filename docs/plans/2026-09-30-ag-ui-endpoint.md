# AG-UI 协议接入（`POST /ag-ui/agent`）

> 目标：让 atelier 的 HTTP 服务对外提供 **AG-UI**（Agent–User Interaction Protocol）端点，
> 使 AG-UI 生态的前端（CopilotKit / `HttpAgent` 等）能直接驱动 atelier 的 agent，
> 拿到与 atelier 内部事件一一对应的流式事件。

## 一、为什么单独做一层，而不复用现有 SSE

现有 `/agent/stream` 是**手拼 JSON** 的私有事件格式（`sseFromEvent`），字段随实现走，外部无法接。
AG-UI 是**公开协议**：事件类型、字段名、生命周期都有规范约束，且前端生态现成。
两层并存：`/agent/stream` 保持原样（TUI 在用），AG-UI 走新的 `/ag-ui/agent`。

## 二、线上契约

```
POST /ag-ui/agent
  Content-Type: application/json
  Accept: text/event-stream
  body: RunAgentInput {
    threadId, runId, state, messages[], tools[], context[], forwardedProps
  }
→ 200, Content-Type: text/event-stream, 逐条 `data: <json 事件>\n\n`
```

- `threadId` ↔ atelier 会话 id：同一个 threadId 的连续 run 共享会话上下文（多轮对话不需要前端回传历史）
- `forwardedProps.agent` 选择 agent（缺省用服务端配置的默认 agent）
- `messages` 只作为**本轮输入**：历史由会话承载，前端可以只发最后一条用户消息（也允许全量重发，幂等）
- SSE 帧只写 `data:`（事件靠自身 `type` 判别），与 AG-UI 客户端解析实现一致

### 回传通道（人在环 / 客户端工具）

```
POST /ag-ui/input  { runId, kind: "user_input" | "tool_result",
                     text?, toolCallId?, result? }
```

## 三、事件映射

| atelier 事件 | AG-UI 事件 | 说明 |
|---|---|---|
| （run 开始） | `RUN_STARTED` + `STATE_SNAPSHOT` | 快照含 agent / model / sessionId / cwd |
| `TurnStartEvent` | `STEP_STARTED(stepName="turn-N")` | N 从 1 起 |
| `MessageUpdateEvent` | `TEXT_MESSAGE_START`（首次）+ `TEXT_MESSAGE_CONTENT(delta)` | 起始事件惰性发出，只有真有增量才开消息 |
| `MessageEndEvent`(assistant) | `TEXT_MESSAGE_END`；若整段未流过增量则补发 START/CONTENT/END | 非流式 provider 也能拿到完整文本 |
| `MessageEndEvent`(assistant, 有 `reasoningContent`) | `REASONING_START` → `REASONING_MESSAGE_START/CONTENT/END` → `REASONING_END` | 思维链独立消息 id，不污染正文 |
| `ToolExecutionStartEvent` | `TOOL_CALL_START` + `TOOL_CALL_ARGS(全量参数)` + `TOOL_CALL_END` | 参数取自上一条 assistant 消息的 tool call（运行时事件不带参数） |
| `ToolExecutionEndEvent` | `TOOL_CALL_RESULT` | `role="tool"`，错误结果同样回传（内容里带错误文本） |
| `ToolExecutionUpdateEvent` | `CUSTOM` `tool_progress` | 协议无对应的进度事件 |
| `CompactionEvent` | `CUSTOM` `compaction` | 压缩是可观测事件，给前端展示 |
| `TurnEndEvent`(stopReason=Error) | `RUN_ERROR` | 之后不再发 `RUN_FINISHED` |
| `AgentEndEvent` | `RUN_FINISHED{outcome:{type:"success"}, result:{stopReason,turns}}` | |
| `askUser` 回调 | `CUSTOM` `user_input_request` | 等 `/ag-ui/input` 回传（同 run 内等待） |
| 客户端工具被调用 | `CUSTOM` `client_tool_request` | 同上；结果作为工具结果回填 |

`STATE_SNAPSHOT` 只在 run 开始时发一次（`state` 原样回显 + 服务端元信息）；本轮不发
`STATE_DELTA`/`MESSAGES_SNAPSHOT`（前端拿得到自己的输入，多发一份是浪费）。

## 四、客户端工具（`tools` 字段）

AG-UI 的 `tools` 是**前端实现**的工具。做法：为本次 run 建一个**run 作用域的 ToolRegistry**
（base 注册表拷贝 + 客户端工具 shim），shim 执行时发 `client_tool_request`，
阻塞等 `/ag-ui/input` 回传结果，再作为工具结果返回给运行时。

- 好处：不改核心库；不污染全局注册表（run 结束即弃）
- 语义诚实说明：这是**同 run 内等待**，不是"中断—恢复"模型。真正的 interrupt/resume
  （`RunFinished.outcome.type="interrupt"` + `resume` 数组）需要运行时支持挂起/恢复，
  留作后续（见 §六）

## 五、实现落点

| 文件 | 内容 |
|---|---|
| `server/src/ag_ui_dto.cj` | `RunAgentInput` / 消息 / 工具 / context 的 json.stream DTO |
| `server/src/ag_ui_events.cj` | AG-UI 事件结构体（`JsonSerializable`）+ SSE 帧函数 |
| `server/src/ag_ui_translator.cj` | 每 run 单实例：`AgentEvent` → 0..N 条 AG-UI 事件 |
| `server/src/ag_ui_handler.cj` | 路由、SSE 写出、run 注册表、客户端工具 shim、输入回传 |
| `server/src/ag_ui_*_test.cj` | DTO 往返 / 事件 JSON 精确串 / 翻译器事件序列 |
| `server/src/handler.cj` | 注册 `/ag-ui/agent`、`/ag-ui/input` 两条路由 |

`RunAgentInput.system` / `developer` 角色的消息与 `context` 条目 → 通过
`PromptSegmentContributor` 注入本轮系统提示（不塞进消息历史），与 atelier
"系统提示词独立通道"的设计一致。

## 六、已知顺序注意

`client_tool_request` 已由翻译器在 `TOOL_CALL_*` 之后发出（单写者，顺序确定）。
但 `askUser` 的 `user_input_request` 仍由**运行时线程**经 SSE 写出端直发：帧本身不会交错
（写出端有互斥），但它在流里的位置相对相邻事件不保证——提问可能出现在"它之前那段正文"之前。
前端把它当独立提示处理即可；要做到严格有序，需要核心侧为"请求外部输入"发出一个事件
（现在这类等待只走回调，事件流里看不到），留作后续。

## 七、后续（本轮不做）

1. **interrupt/resume（已完成 2026-10-01）**：客户端工具走 `RUN_FINISHED.outcome=interrupt` +
   下次 run 的 `resume[]`；核心新增 `ToolResult.external` / `ExternalRequest` / `SuspendEvent`，
   运行时遇 external 结果即挂起（不写伪结果）。剩余：`askUser` 仍阻塞（需要核心为"等外部输入"发事件）
2. `REASONING_*` 增量流（现在只有消息结束时一次性给出）
3. `STATE_DELTA`：把 todo 列表等会话内状态以 JSON Patch 增量推给前端
4. 二进制 transport（AG-UI 的可选高性能通道）
