package server

import std.collection.*
import std.time.DateTime
import stdx.encoding.json.stream.*
import jsonvalue.JsonValue
import atelier.util.toJsonString

// AG-UI 事件定义（https://docs.ag-ui.com/concepts/events）。
//
// 判别字段在协议里叫 `type`，而 `type` 是仓颉关键字 → 字段名一律用 `kind`，
// 序列化时写成 "type"。事件结构集中在这里，翻译器只负责「内部事件 → 哪些 AG-UI 事件」，
// 序列化细节不外泄；SSE 帧由 sseFrame() 统一包装。
//
// 协议里除 type 外都可省；timestamp 带上便于前端算时延（毫秒）。

public interface AgUiEvent <: JsonSerializable {
    func eventType(): String
}

func agUiNowMillis(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

// 公共前缀：type + timestamp（顺序固定，便于前端与测试做前缀匹配）
func writeAgUiHead(w: JsonWriter, kind: String): Unit {
    w.writeName("type").writeValue(kind)
    w.writeName("timestamp").writeValue(agUiNowMillis())
}

public func sseFrame(ev: AgUiEvent): String {
    "data: " + toJsonString(ev) + "\n\n"
}

// ── 生命周期 ────────────────────────────────────────────────────────────────

public class RunStartedEvent <: AgUiEvent {
    public let threadId: String
    public let runId: String
    public init(threadId: String, runId: String) { this.threadId = threadId; this.runId = runId }
    public func eventType(): String { "RUN_STARTED" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("threadId").writeValue(this.threadId)
        w.writeName("runId").writeValue(this.runId)
        w.endObject()
    }
}

// 中断：run 暂停，等客户端在下一次 run 的 resume 里给结果。
// id 是跨 run 关联键；tool_call 类必须带 toolCallId（与 ToolCall* 序列绑定）。
//
// responseSchema 是答复契约（AG-UI 1.0：客户端据此建表单）：没有它，前端只知道
// 「要一段输入」，字段名/类型/必填全靠猜。schema 由提问（UserRequest）映射而来，
// 见 agUiResponseSchema。
public class AgUiInterrupt <: JsonSerializable {
    public let id: String
    public let reason: String
    public let message: String
    public let toolCallId: String
    // 答复的期望形状（JSON Schema）；无契约时为 None，序列化时整段省略
    public let responseSchema: Option<JsonValue>
    public init(id: String, reason: String, message: String, toolCallId: String,
        responseSchema!: Option<JsonValue> = None) {
        this.id = id; this.reason = reason; this.message = message
        this.toolCallId = toolCallId; this.responseSchema = responseSchema
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("reason").writeValue(this.reason)
        if (this.message != "") { w.writeName("message").writeValue(this.message) }
        if (this.toolCallId != "") { w.writeName("toolCallId").writeValue(this.toolCallId) }
        match (this.responseSchema) {
            case Some(v) => w.writeName("responseSchema").writeValue(v)
            case None => ()
        }
        w.endObject()
    }
}

public class RunFinishedEvent <: AgUiEvent {
    public let threadId: String
    public let runId: String
    public let stopReason: String
    public let turns: Int64
    // 非空 = 以中断收尾（outcome.type = interrupt）
    public let interrupts: ArrayList<AgUiInterrupt>
    public init(threadId: String, runId: String, stopReason: String, turns: Int64,
        interrupts!: ArrayList<AgUiInterrupt> = ArrayList()) {
        this.threadId = threadId; this.runId = runId
        this.stopReason = stopReason; this.turns = turns
        this.interrupts = interrupts
    }
    public func eventType(): String { "RUN_FINISHED" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("threadId").writeValue(this.threadId)
        w.writeName("runId").writeValue(this.runId)
        // outcome 是 1.0 的判别式联合；result 保留在根部供只认旧字段的客户端读
        w.writeName("outcome").startObject()
        if (this.interrupts.size > 0) {
            w.writeName("type").writeValue("interrupt")
            w.writeName("interrupts").writeValue(this.interrupts)
        } else {
            w.writeName("type").writeValue("success")
        }
        w.endObject()
        w.writeName("result").startObject()
        w.writeName("stopReason").writeValue(this.stopReason)
        w.writeName("turns").writeValue(this.turns)
        w.endObject()
        w.endObject()
    }
}

public class RunErrorEvent <: AgUiEvent {
    public let message: String
    public let code: String
    public init(message: String, code: String) { this.message = message; this.code = code }
    public func eventType(): String { "RUN_ERROR" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("message").writeValue(this.message)
        if (this.code != "") { w.writeName("code").writeValue(this.code) }
        w.endObject()
    }
}

public class StepStartedEvent <: AgUiEvent {
    public let stepName: String
    public init(stepName: String) { this.stepName = stepName }
    public func eventType(): String { "STEP_STARTED" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("stepName").writeValue(this.stepName)
        w.endObject()
    }
}

public class StepFinishedEvent <: AgUiEvent {
    public let stepName: String
    public init(stepName: String) { this.stepName = stepName }
    public func eventType(): String { "STEP_FINISHED" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("stepName").writeValue(this.stepName)
        w.endObject()
    }
}

// ── 文本消息 ────────────────────────────────────────────────────────────────

public class TextMessageStartEvent <: AgUiEvent {
    public let messageId: String
    public let role: String
    public init(messageId: String, role: String) { this.messageId = messageId; this.role = role }
    public func eventType(): String { "TEXT_MESSAGE_START" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.writeName("role").writeValue(this.role)
        w.endObject()
    }
}

public class TextMessageContentEvent <: AgUiEvent {
    public let messageId: String
    public let delta: String
    public init(messageId: String, delta: String) { this.messageId = messageId; this.delta = delta }
    public func eventType(): String { "TEXT_MESSAGE_CONTENT" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.writeName("delta").writeValue(this.delta)
        w.endObject()
    }
}

public class TextMessageEndEvent <: AgUiEvent {
    public let messageId: String
    public init(messageId: String) { this.messageId = messageId }
    public func eventType(): String { "TEXT_MESSAGE_END" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.endObject()
    }
}

// ── 思维链（协议 1.0 的 REASONING_* 系列；内容来自 AssistantMessage.reasoningContent）──

public class ReasoningStartEvent <: AgUiEvent {
    public let messageId: String
    public init(messageId: String) { this.messageId = messageId }
    public func eventType(): String { "REASONING_START" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.endObject()
    }
}

public class ReasoningMessageStartEvent <: AgUiEvent {
    public let messageId: String
    public init(messageId: String) { this.messageId = messageId }
    public func eventType(): String { "REASONING_MESSAGE_START" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.writeName("role").writeValue("reasoning")
        w.endObject()
    }
}

public class ReasoningMessageContentEvent <: AgUiEvent {
    public let messageId: String
    public let delta: String
    public init(messageId: String, delta: String) { this.messageId = messageId; this.delta = delta }
    public func eventType(): String { "REASONING_MESSAGE_CONTENT" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.writeName("delta").writeValue(this.delta)
        w.endObject()
    }
}

public class ReasoningMessageEndEvent <: AgUiEvent {
    public let messageId: String
    public init(messageId: String) { this.messageId = messageId }
    public func eventType(): String { "REASONING_MESSAGE_END" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.endObject()
    }
}

public class ReasoningEndEvent <: AgUiEvent {
    public let messageId: String
    public init(messageId: String) { this.messageId = messageId }
    public func eventType(): String { "REASONING_END" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.endObject()
    }
}

// ── 工具调用 ────────────────────────────────────────────────────────────────

public class ToolCallStartEvent <: AgUiEvent {
    public let toolCallId: String
    public let toolCallName: String
    public let parentMessageId: String
    public init(toolCallId: String, toolCallName: String, parentMessageId: String) {
        this.toolCallId = toolCallId; this.toolCallName = toolCallName
        this.parentMessageId = parentMessageId
    }
    public func eventType(): String { "TOOL_CALL_START" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("toolCallName").writeValue(this.toolCallName)
        if (this.parentMessageId != "") {
            w.writeName("parentMessageId").writeValue(this.parentMessageId)
        }
        w.endObject()
    }
}

public class ToolCallArgsEvent <: AgUiEvent {
    public let toolCallId: String
    public let delta: String
    public init(toolCallId: String, delta: String) { this.toolCallId = toolCallId; this.delta = delta }
    public func eventType(): String { "TOOL_CALL_ARGS" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("delta").writeValue(this.delta)
        w.endObject()
    }
}

public class ToolCallEndEvent <: AgUiEvent {
    public let toolCallId: String
    public init(toolCallId: String) { this.toolCallId = toolCallId }
    public func eventType(): String { "TOOL_CALL_END" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.endObject()
    }
}

public class ToolCallResultEvent <: AgUiEvent {
    public let messageId: String
    public let toolCallId: String
    public let content: String
    public let role: String
    public init(messageId: String, toolCallId: String, content: String, role: String) {
        this.messageId = messageId; this.toolCallId = toolCallId
        this.content = content; this.role = role
    }
    public func eventType(): String { "TOOL_CALL_RESULT" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messageId").writeValue(this.messageId)
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("content").writeValue(this.content)
        w.writeName("role").writeValue(this.role)
        w.endObject()
    }
}

// ── 状态与扩展 ──────────────────────────────────────────────────────────────

public class StateSnapshotEvent <: AgUiEvent {
    public let snapshot: JsonValue
    public init(snapshot: JsonValue) { this.snapshot = snapshot }
    public func eventType(): String { "STATE_SNAPSHOT" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("snapshot").writeValue(this.snapshot)
        w.endObject()
    }
}

// CUSTOM 承载协议未覆盖的 atelier 事件（工具进度、压缩、等外部输入、客户端工具请求）
// 会话消息快照（AG-UI 的 MESSAGES_SNAPSHOT）：中断边界上把完整会话交给客户端，
// 恢复时客户端（或重放式实现）才有重建上下文所需的一切。
public class AgUiOutMessage <: JsonSerializable {
    public let id: String
    public let role: String
    public let content: String
    public let toolCallId: String
    public let toolCalls: ArrayList<AgUiToolCallDTO>

    public init(id: String, role: String, content: String, toolCallId: String,
        toolCalls: ArrayList<AgUiToolCallDTO>) {
        this.id = id; this.role = role; this.content = content
        this.toolCallId = toolCallId; this.toolCalls = toolCalls
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("role").writeValue(this.role)
        w.writeName("content").writeValue(this.content)
        if (this.toolCallId != "") { w.writeName("toolCallId").writeValue(this.toolCallId) }
        if (this.toolCalls.size > 0) {
            w.writeName("toolCalls").writeValue(this.toolCalls.map { tc =>
                JsonValue.fromObject(AgUiOutToolCall(tc.id, tc.function.name, tc.function.arguments))
            })
        }
        w.endObject()
    }
}

// 出站 tool call 形状（AG-UI 用 OpenAI 风格的 {id, type, function:{name, arguments}}）
public class AgUiOutToolCall <: JsonSerializable {
    public let id: String
    public let name: String
    public let arguments: String
    public init(id: String, name: String, arguments: String) {
        this.id = id; this.name = name; this.arguments = arguments
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("type").writeValue("function")
        w.writeName("function").startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("arguments").writeValue(this.arguments)
        w.endObject()
        w.endObject()
    }
}

public class MessagesSnapshotEvent <: AgUiEvent {
    public let messages: ArrayList<AgUiOutMessage>
    public init(messages: ArrayList<AgUiOutMessage>) { this.messages = messages }
    public func eventType(): String { "MESSAGES_SNAPSHOT" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("messages").writeValue(this.messages)
        w.endObject()
    }
}

public class CustomEvent <: AgUiEvent {
    public let name: String
    public let value: JsonValue
    public init(name: String, value: JsonValue) { this.name = name; this.value = value }
    public func eventType(): String { "CUSTOM" }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        writeAgUiHead(w, this.eventType())
        w.writeName("name").writeValue(this.name)
        w.writeName("value").writeValue(this.value)
        w.endObject()
    }
}
