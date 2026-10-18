# 事件流

Agent 运行过程中通过 `EventStream` 发出类型化事件，消费者可实时订阅。

## AgentEvent

密封接口，所有事件实现 `eventType(): String`：

```cangjie
interface AgentEvent {
    func eventType(): String
}
```

## 14 种事件

```
Agent (start / end)
  └── Turn (start / end)
       ├── Message (start / update / end)
       └── ToolExecution (start / update / end)
Suspend (挂起：本次 run 到此为止，等外部结果)
Compaction (独立事件)
  ├── CompactionStart  (事务开始)
  ├── CompactionEnd    (事务结束，与 Start 成对)
  └── Compaction       (一次压缩的汇总，用于展示)
```

> **`CompactionStart` / `CompactionEnd` 必须成对**：同一 `compactionId` 的括弧要闭合。
> 消费端据此显示"正在压缩"的进度态。`messagesBefore == messagesAfter` 表示
> "尝试过但没替换"——括弧照样闭合，不留悬挂状态。

### AgentStartEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `sessionId` | `String` | 会话 ID |

在调用 Provider 前发出，标识一次 Run 开始。

### AgentEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `messages` | `ArrayList<Message>` | 本轮新增消息 |

整个 Run 结束，捎带所有新产生的消息。

### TurnStartEvent

新推理轮次开始，无额外数据。

### TurnEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `AssistantMessage` | 当前轮助手消息 |
| `toolResults` | `ArrayList<ToolResultMessage>` | 本轮工具结果 |

### MessageStartEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `Message` | 初始消息（接口类型） |

流式消息开始播放。

### MessageUpdateEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `Message` | 当前完整状态 |
| `delta` | `String` | 文本增量 |

每次收到 Provider 的 SSE chunk 时触发，`delta` 是本次新增的文本片段。

### MessageEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `Message` | 完整的消息（接口类型） |

流式消息完成。

### ToolExecutionStartEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `toolCallId` | `String` | 调用 ID |
| `toolName` | `String` | 工具名称 |

工具开始执行。

### ToolExecutionUpdateEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `toolCallId` | `String` | 调用 ID |
| `progress` | `String` | 执行进度 |

### ToolExecutionEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `toolCallId` | `String` | 调用 ID |
| `result` | `String` | 执行结果 |
| `isError` | `Bool` | 是否错误 |

工具执行完成。

### SuspendEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `requests` | `ArrayList<ExternalRequest>` | 正在等待的外部请求（可多条） |

`ExternalRequest`：`id` / `reason`（`tool_call` 绑定某次调用、`input_required` 要一段结构化输入、`confirmation` 要用户拍板）/ `message`（兜底展示文案）/ `toolCallId`（`reason=tool_call` 时绑定）。

本次运行挂起：需要外部结果（前端执行工具、用户确认/作答）才能继续。**挂起不是失败**——
历史停在 `assistant(tool_calls)`，调用方带上结果发起下一次 run 即可继续（本次 run 的答复随
消息 `metadata` 回传，见 [消息模型](messages.md)）；见到本事件后不应再期待后续回合。

### CompactionStartEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `compactionId` | `String` | 本次压缩的事务 id（与 End 配对用） |
| `trigger` | `String` | 触发原因（`pressure` / `overflow` / `manual`） |
| `tokensBefore` | `Int64` | 压缩前 Token |

### CompactionEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `compactionId` | `String` | 与 Start 相同 |
| `trigger` | `String` | 同上 |
| `messagesBefore` | `Int64` | 压缩前消息条数 |
| `messagesAfter` | `Int64` | 压缩后消息条数（== before 表示没替换） |
| `tokensAfter` | `Int64` | 压缩后 Token |

### CompactionEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `reason` | `String` | 触发原因 |
| `tokensBefore` | `Int64` | 压缩前 Token |
| `tokensAfter` | `Int64` | 压缩后 Token |

上下文压缩发生。

## EventStream

```cangjie
class EventStream<T, R> {
    func emit(event: T): Bool           // 发射事件，false 表示流已关闭
    func receive(): T                   // 阻塞接收
    func receive(timeout: Duration): Option<T>  // 带超时接收
    func result(): R                    // 取最终结果（可跳过中间事件）
    func setResult(r: R): Bool          // 设置结果
    func setError(e: Exception): Bool   // 设置错误
    func close(): Unit                  // 关闭流
}
```

### 类型别名

```cangjie
type LoopEventStream = EventStream<AgentEvent, ArrayList<Message>>
```

### 同步迭代

```cangjie
let stream = runtime.chat(messages)

while (true) {
    match (stream.receive(5 * Duration.second)) {
        case Some(ev) =>
            match (ev) {
                case _: AgentEndEvent =>
                    let result = stream.result()
                    break
                case _ => handle(ev)
            }
        case None => break  // 超时
    }
}
```

### 直接取结果

```cangjie
let result: ArrayList<Message> = stream.result()
```

`result()` 与事件通道分离，即使不消费任何事件也能拿到结果。

### Once 语义

SetResult / SetError / close 三者竞争，先到先赢。之后的调用返回 false。

## SSE 序列化

HTTP SSE 模式下，事件序列化为 JSON 行：

```
data: {"type":"agent_start","sessionId":"sess_0"}
data: {"type":"turn_start"}
data: {"type":"message_update","delta":"你好"}
data: {"type":"message_update","delta":"，我是"}
data: {"type":"message_end"}
data: {"type":"turn_end","stopReason":"end_turn","content":"你好，我是AI助手"}
data: {"type":"agent_end"}
```

CompactionEvent 当前 SSE 序列化仅输出 `{"type":"compaction"}`，数据字段为预留。
