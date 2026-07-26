# 事件流

Agent 运行过程中通过 `EventStream` 发出类型化事件，消费者可实时订阅。

## AgentEvent

密封接口，所有事件实现 `eventType(): String`：

```cangjie
interface AgentEvent {
    func eventType(): String
}
```

## 11 种事件

```
Agent (start / end)
  └── Turn (start / end)
       ├── Message (start / update / end)
       └── ToolExecution (start / update / end)
Compaction (独立事件)
```

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
| `message` | `Message` | 初始消息 |

流式消息开始播放。

### MessageUpdateEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `Message` | 当前完整状态 |
| `delta` | `String` | 文本增量 |

每次收到 Provider 的 SSE chunk 时触发，`delta` 是本次新增的文本片段。前端可逐 token 追加显示。

### MessageEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `message` | `AssistantMessage` | 完整的助手消息 |

流式消息完成，消息内容完整可用。

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

工具执行进度更新（如流式输出进度）。

### ToolExecutionEndEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `toolCallId` | `String` | 调用 ID |
| `result` | `String` | 执行结果 |
| `isError` | `Bool` | 是否错误 |

工具执行完成。

### CompactionEvent

| 字段 | 类型 | 说明 |
|------|------|------|
| `reason` | `String` | 触发原因 |
| `tokensBefore` | `Int64` | 压缩前 Token |
| `tokensAfter` | `Int64` | 压缩后 Token |

上下文压缩发生，可作为调试信息查看。

## EventStream

```cangjie
class EventStream<T, R> {
    func emit(event: T): Result<Unit>
    func receive(timeout: Duration): Option<T>
    func result(): R
    func setResult(value: R): Unit
    func setError(e: Exception): Unit
    func close(): Unit
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
        case Some(AgentEndEvent) =>
            let result = stream.result()
            break
        case Some(ev) => handle(ev)
        case None => break  // 超时
    }
}
```

### 直接取结果

跳过中间事件，直接等待最终结果：

```cangjie
let result: ArrayList<Message> = stream.result()
```

`result()` 与事件通道分离，即使不消费任何事件也能拿到结果。

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
