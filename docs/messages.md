# 消息模型

消息是 Agent 对话的基本单位。Atelier 采用**密封接口 + 角色判别**模式，4 种角色。

## MessageRole

```cangjie
enum MessageRole {
    User
    Assistant
    ToolResult
    Compaction
}
```

## Message 接口

```cangjie
interface Message {
    func role(): MessageRole
}
```

消息还带一个 `metadata: HashMap<String,String>` 扩展通道（来自 llm_api）：宿主业务元数据随
消息持久化 roundtrip，不参与语义比较与 LLM 协议 JSON。**提问答复就走这条通道**——挂起后
宿主在下一次输入的消息上带 `ask.*` 键（`ask.id` / `ask.status` / `ask.selected` / `ask.text` /
`ask.values` / `ask.editedArgs`），运行时重放时先查它、命中就不再问宿主（见
[事件流](events.md) 的 `SuspendEvent`）。

## 4 种消息类型

### UserMessage

| 字段 | 类型 | 说明 |
|------|------|------|
| `content` | `ContentList` | 消息内容 |
| `timestamp` | `Int64` | 时间戳 |

```cangjie
let msg = UserMessage(ContentList.ofText("你好"), 0)
```

### AssistantMessage

| 字段 | 类型 | 说明 |
|------|------|------|
| `content` | `ContentList` | 文本 + 工具调用 |
| `model` | `String` | 生成模型 |
| `provider` | `String` | Provider 名称 |
| `stopReason` | `StopReason` | 停止原因 |
| `usage` | `TokenUsage` | Token 用量 |
| `reasoningContent` | `String` | 思考过程（deepseek-reasoner） |
| `timestamp` | `Int64` | 时间戳 |

```cangjie
let msg = AssistantMessage(
    ContentList.ofText("这是回答"),
    "gpt-4o", "openai",
    StopReason.EndTurn,
    TokenUsage(50, 100),
    0)
// 提取工具调用
let calls: ArrayList<ToolCallBlock> = msg.toolCalls()
```

#### StopReason

| 值 | 说明 |
|------|------|
| `EndTurn` | 正常结束 |
| `ToolUse` | 需要调用工具 |
| `Length` | 达到 Token 上限 |
| `Error` | 发生错误 |
| `Aborted` | 被中断 |

### ToolResultMessage

| 字段 | 类型 | 说明 |
|------|------|------|
| `toolCallId` | `String` | 关联的调用 ID |
| `toolName` | `String` | 工具名称 |
| `content` | `ContentList` | 执行结果 |
| `isError` | `Bool` | 是否错误 |
| `timestamp` | `Int64` | 时间戳 |

```cangjie
let msg = ToolResultMessage(
    "call_xxx", "bash",
    ContentList.ofText("hello\nworld"),
    false, 0)
```

### CompactionMessage

| 字段 | 类型 | 说明 |
|------|------|------|
| `summary` | `String` | 摘要文本 |
| `tokensBefore` | `Int64` | 压缩前 Token 数 |
| `timestamp` | `Int64` | 时间戳 |

```cangjie
let msg = CompactionMessage(
    "... 15 previous messages summarized ...",
    12000, 0)
```

## ContentBlock

消息的内容是 `ContentList`，由多个 `ContentBlock` 组成：

```cangjie
enum ContentBlock {
    TextBlock(text: String)
    ToolCall(tc: ToolCallBlock)    // 工具调用
    ToolResultBlock(toolCallId: String, result: String)
    ImageBlock(data: String, mimeType: String)  // 预留
}

class ToolCallBlock {
    id: String
    name: String
    args: JsonValue
}
```

### ContentList

```cangjie
// 纯文本
let text = ContentList.ofText("你好")

// 多模态
let multi = ContentList([
    ContentBlock.TextBlock("计算结果："),
    ContentBlock.ToolResultBlock("call_1", "42")
])

// 遍历
for (block in list.blocks()) {
    match (block) {
        case ContentBlock.TextBlock(t) => print(t)
        case ContentBlock.ToolCall(tc) => print("工具: ${tc.name}")
        case ContentBlock.ToolResultBlock(id, r) => print("结果: ${r}")
        case _ => ()
    }
}
```

## TokenUsage

```cangjie
struct TokenUsage {
    inputTokens: Int64    // 输入 Token
    outputTokens: Int64   // 输出 Token
}
```

## 序列化

所有 Message 类型通过 `extend` 实现 `JsonSerializable`，使用 `stdx.encoding.json.stream`：

```cangjie
import atelier.util.{toJsonString, fromJsonString}
import atelier.message.*

// 序列化消息列表
let json = toJsonString(messages)

// 反序列化（需指定具体消息类型）
let msg = fromJsonString<AssistantMessage>(json)
```
