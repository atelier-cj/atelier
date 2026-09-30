package cli

import jsonvalue.*
import std.collection.*
import stdx.encoding.json.stream.*
import atelier.message.*
import atelier.agent.*
import atelier.util.toJsonString

// 机器可读的一次性运行日志（`cli.app run --json-events`）：stdout 每行一个 JSON 对象，
// 人类可读的进度继续走 stderr —— 两者各自独立可解析，互不干扰。
//
// 为什么要有它：CI 与评测框架要的是**结构化事实**（回合边界、工具调用与结果、token 用量、
// 停止原因），而不是去解析人类日志、或另外起一个协议客户端（ACP）来观测同一次运行。
// 字段口径与 harness-bench 的 SessionIR 对齐（message / tool_call / tool_result / turn_end），
// 停止原因沿用 atelier 自己的命名（end_turn / tool_use / length / error / aborted）。
//
// 行型（每行一个对象，互不嵌套）：
//
//	{"type":"agent_start","sessionId":"..."}
//	{"type":"turn_start"}
//	{"type":"message","role":"assistant","text":"...","stopReason":"tool_use","usage":{"input":N,"output":M}}
//	{"type":"tool_call","id":"...","name":"...","args":{...}}
//	{"type":"tool_start","id":"...","name":"..."}
//	{"type":"tool_result","id":"...","ok":true,"bytes":N}
//	{"type":"turn_end","stopReason":"end_turn","usage":{"input":N,"output":M}}
//	{"type":"compaction","reason":"...","tokensBefore":N,"tokensAfter":M}
//	{"type":"agent_end"}
//
// 消费方注意：答案就是最后一条 `message` 的 text；`tool_call` 是模型**要求**的调用，
// `tool_start`/`tool_result` 是**实际执行**（被钩子拦掉或超预算的调用只有前者）。
//
// 序列化一律走 stdx.encoding.json.stream（每个行型实现 JsonSerializable，经 toJsonString 落成一行）：
// 手拼字符串就得自己处理引号与控制字符转义，漏一个整行就不是合法 JSON ——
// 而消费方是**按行解析**的，一行坏掉整条记录就废了。

// ── 行型 ────────────────────────────────────────────────────────────────────────

public struct EvAgentStart <: JsonSerializable {
    public let sessionId: String
    public init(sessionId: String) { this.sessionId = sessionId }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("agent_start")
        w.writeName("sessionId").writeValue(this.sessionId)
        w.endObject()
    }
}

public struct EvSimple <: JsonSerializable {
    // 字段名不能叫 type：`type` 是仓颉关键字（JSON 键仍是 "type"）
    public let kind: String
    public init(kind: String) { this.kind = kind }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue(this.kind)
        w.endObject()
    }
}

public struct EvMessage <: JsonSerializable {
    public let role: String
    public let text: String
    public let stopReason: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public init(role: String, text: String, stopReason: String,
        inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens!: Int64 = 0, cacheWriteTokens!: Int64 = 0) {
        this.role = role; this.text = text; this.stopReason = stopReason
        this.inputTokens = inputTokens; this.outputTokens = outputTokens
        this.cacheReadTokens = cacheReadTokens; this.cacheWriteTokens = cacheWriteTokens
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("message")
        w.writeName("role").writeValue(this.role)
        w.writeName("text").writeValue(this.text)
        w.writeName("stopReason").writeValue(this.stopReason)
        w.writeName("usage").startObject()
        w.writeName("input").writeValue(this.inputTokens)
        w.writeName("output").writeValue(this.outputTokens)
        // 命中缓存的输入量单列：消费方要能区分「真没命中」与「没上报」
        w.writeName("cacheRead").writeValue(this.cacheReadTokens)
        w.writeName("cacheWrite").writeValue(this.cacheWriteTokens)
        w.endObject()
        w.endObject()
    }
}

public struct EvToolCall <: JsonSerializable {
    public let id: String
    public let name: String
    public let args: JsonValue
    public init(id: String, name: String, args: JsonValue) {
        this.id = id; this.name = name; this.args = args
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("tool_call")
        w.writeName("id").writeValue(this.id)
        w.writeName("name").writeValue(this.name)
        w.writeName("args").writeValue(this.args)
        w.endObject()
    }
}

public struct EvToolStart <: JsonSerializable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { this.id = id; this.name = name }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("tool_start")
        w.writeName("id").writeValue(this.id)
        w.writeName("name").writeValue(this.name)
        w.endObject()
    }
}

public struct EvToolResult <: JsonSerializable {
    public let id: String
    public let ok: Bool
    public let bytes: Int64
    public init(id: String, ok: Bool, bytes: Int64) {
        this.id = id; this.ok = ok; this.bytes = bytes
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("tool_result")
        w.writeName("id").writeValue(this.id)
        w.writeName("ok").writeValue(this.ok)
        w.writeName("bytes").writeValue(this.bytes)
        w.endObject()
    }
}

public struct EvTurnEnd <: JsonSerializable {
    public let stopReason: String
    public let inputTokens: Int64
    public let outputTokens: Int64
    public let cacheReadTokens: Int64
    public let cacheWriteTokens: Int64
    public init(stopReason: String, inputTokens: Int64, outputTokens: Int64,
        cacheReadTokens!: Int64 = 0, cacheWriteTokens!: Int64 = 0) {
        this.stopReason = stopReason
        this.inputTokens = inputTokens; this.outputTokens = outputTokens
        this.cacheReadTokens = cacheReadTokens; this.cacheWriteTokens = cacheWriteTokens
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("turn_end")
        w.writeName("stopReason").writeValue(this.stopReason)
        w.writeName("usage").startObject()
        w.writeName("input").writeValue(this.inputTokens)
        w.writeName("output").writeValue(this.outputTokens)
        w.writeName("cacheRead").writeValue(this.cacheReadTokens)
        w.writeName("cacheWrite").writeValue(this.cacheWriteTokens)
        w.endObject()
        w.endObject()
    }
}

public struct EvCompaction <: JsonSerializable {
    public let reason: String
    public let tokensBefore: Int64
    public let tokensAfter: Int64
    public init(reason: String, tokensBefore: Int64, tokensAfter: Int64) {
        this.reason = reason; this.tokensBefore = tokensBefore; this.tokensAfter = tokensAfter
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("compaction")
        w.writeName("reason").writeValue(this.reason)
        w.writeName("tokensBefore").writeValue(this.tokensBefore)
        w.writeName("tokensAfter").writeValue(this.tokensAfter)
        w.endObject()
    }
}

// ── 事件 → 行 ───────────────────────────────────────────────────────────────────

func stopReasonName(r: StopReason): String {
    match (r) {
        case StopReason.EndTurn => "end_turn"
        case StopReason.ToolUse => "tool_use"
        case StopReason.Length => "length"
        case StopReason.Error => "error"
        case StopReason.Aborted => "aborted"
    }
}

func textOf(content: ContentList): String {
    let sb = StringBuilder()
    for (b in content.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}

// 一个运行时事件 → 若干 JSONL 行（带工具调用的 assistant 消息会展开成 1 + N 行）。
// 未纳入的事件（增量、思考块等）返回空列表：JSONL 只承担「事后可核算的事实」，
// 增量属于实时呈现，交给 stderr 的进度通道。
public func jsonLinesFromEvent(ev: AgentEvent): ArrayList<String> {
    let lines = ArrayList<String>()
    match (ev) {
        case e: AgentStartEvent =>
            lines.add(toJsonString(EvAgentStart(e.sessionId)))
        case _: TurnStartEvent =>
            lines.add(toJsonString(EvSimple("turn_start")))
        case e: MessageEndEvent =>
            match (e.message) {
                case am: AssistantMessage =>
                    lines.add(toJsonString(EvMessage("assistant", textOf(am.content),
                        stopReasonName(am.stopReason), am.usage.inputTokens, am.usage.outputTokens,
                        cacheReadTokens: am.usage.cacheReadTokens,
                        cacheWriteTokens: am.usage.cacheWriteTokens)))
                    for (tc in am.toolCalls()) {
                        lines.add(toJsonString(EvToolCall(tc.id, tc.name, tc.args)))
                    }
                case _ => ()
            }
        case e: ToolExecutionStartEvent =>
            lines.add(toJsonString(EvToolStart(e.toolCallId, e.toolName)))
        case e: ToolExecutionEndEvent =>
            lines.add(toJsonString(EvToolResult(e.toolCallId, !e.isError, e.result.size)))
        case e: TurnEndEvent =>
            lines.add(toJsonString(EvTurnEnd(stopReasonName(e.message.stopReason),
                e.message.usage.inputTokens, e.message.usage.outputTokens,
                cacheReadTokens: e.message.usage.cacheReadTokens,
                cacheWriteTokens: e.message.usage.cacheWriteTokens)))
        case e: CompactionEvent =>
            lines.add(toJsonString(EvCompaction(e.reason, e.tokensBefore, e.tokensAfter)))
        case _: AgentEndEvent =>
            lines.add(toJsonString(EvSimple("agent_end")))
        case _ => ()
    }
    lines
}

// JSONL 消费方的兜底判断：本轮是否已经产出过 assistant 消息。
// 没有的话（例如 provider 直接报错、回合被短路）调用方仍需给出一行收尾，
// 否则消费方看到的是「日志为空」而不是「这一轮失败了」。
public func hasAssistantMessage(messages: ArrayList<Message>): Bool {
    for (m in messages) {
        match (m) {
            case _: AssistantMessage => return true
            case _ => ()
        }
    }
    false
}

// 兜底行：整个 run 一条 assistant 消息都没产出时，至少给消费方一行事实。
public func fallbackMessageLine(text: String): String {
    toJsonString(EvMessage("assistant", text, "end_turn", 0, 0))
}
