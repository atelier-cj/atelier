package server

import std.collection.*
import stdx.encoding.json.stream.*
import jsonvalue.JsonValue
import atelier.agent.*
import atelier.message.{AssistantMessage, StopReason}
// toText 是本包内 handler.cj 的辅助函数（同一 package，无需 import）
import atelier.util.toJsonString

// 把 atelier 运行时事件翻译成 AG-UI 事件（每 run 一个实例，内部维护消息 id 与工具参数表）。
//
// 关键约定：
// · assistant 文本消息 id 在"这条消息第一次需要它"时分配（运行时通常不发 MessageStartEvent，
//   所以不能依赖它），增量与结束事件共用同一个 id，消息结束后复位；
// · 起始事件惰性发出——只有真有增量才开消息，避免"空消息 + 立即结束"这种噪声；
// · 非流式 provider（一次性给出全文）在 MessageEnd 时补发 START/CONTENT/END；
// · 工具调用参数不在运行时事件里（ToolExecutionStartEvent 只有 id 与名字），
//   所以在上一条 assistant 消息结束时把 id → 参数 记下来，执行开始时一次性发出；
// · RunError 之后不再发 RunFinished；AgentEnd 之后本实例不再产出任何事件。

// ── 扩展载荷（CUSTOM / STATE_SNAPSHOT 的值）────────────────────────────────────

public class AgUiStateSnapshot <: JsonSerializable {
    public let agent: String
    public let model: String
    public let sessionId: String
    public let cwd: String
    public let state: Option<JsonValue>

    public init(agent: String, model: String, sessionId: String, cwd: String, state: Option<JsonValue>) {
        this.agent = agent; this.model = model; this.sessionId = sessionId
        this.cwd = cwd; this.state = state
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("agent").writeValue(this.agent)
        w.writeName("model").writeValue(this.model)
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("cwd").writeValue(this.cwd)
        match (this.state) {
            case Some(v) => w.writeName("state").writeValue(v)
            case None => ()
        }
        w.endObject()
    }
}

public class AgUiUserInputPayload <: JsonSerializable {
    public let question: String
    public init(question: String) { this.question = question }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("question").writeValue(this.question)
        w.endObject()
    }
}

public class AgUiClientToolPayload <: JsonSerializable {
    public let toolCallId: String
    public let toolName: String
    public let arguments: String
    public init(toolCallId: String, toolName: String, arguments: String) {
        this.toolCallId = toolCallId; this.toolName = toolName; this.arguments = arguments
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("toolName").writeValue(this.toolName)
        w.writeName("arguments").writeValue(this.arguments)
        w.endObject()
    }
}

public class AgUiToolProgressPayload <: JsonSerializable {
    public let toolCallId: String
    public let progress: String
    public init(toolCallId: String, progress: String) {
        this.toolCallId = toolCallId; this.progress = progress
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("progress").writeValue(this.progress)
        w.endObject()
    }
}

public class AgUiCompactionPayload <: JsonSerializable {
    public let reason: String
    public let tokensBefore: Int64
    public let tokensAfter: Int64
    public init(reason: String, tokensBefore: Int64, tokensAfter: Int64) {
        this.reason = reason; this.tokensBefore = tokensBefore; this.tokensAfter = tokensAfter
    }
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("reason").writeValue(this.reason)
        w.writeName("tokensBefore").writeValue(this.tokensBefore)
        w.writeName("tokensAfter").writeValue(this.tokensAfter)
        w.endObject()
    }
}

// ── 翻译器 ──────────────────────────────────────────────────────────────────

public class AgUiTranslator {
    private let threadId: String
    private let runId: String
    private var turn: Int64 = 0
    private var stepOpen: Bool = false
    private var msgSeq: Int64 = 0
    private var textMessageId: String = ""
    private var textStarted: Bool = false
    private var lastAssistantId: String = ""
    private var toolArgs: HashMap<String, String> = HashMap<String, String>()
    private var stopReason: String = "end_turn"
    private var finished: Bool = false

    public init(threadId: String, runId: String) {
        this.threadId = threadId; this.runId = runId
    }

    public func turns(): Int64 { this.turn }

    public func stopReasonName(): String { this.stopReason }

    // run 开始：RUN_STARTED + STATE_SNAPSHOT（快照只在开头发一次）
    public func start(snapshot: AgUiStateSnapshot): ArrayList<AgUiEvent> {
        let out = ArrayList<AgUiEvent>()
        out.add(RunStartedEvent(this.threadId, this.runId))
        out.add(StateSnapshotEvent(JsonValue.fromObject(snapshot)))
        out
    }

    // 扩展事件（handler 在等待外部输入时直接发出）
    public func userInputRequest(question: String): AgUiEvent {
        CustomEvent("user_input_request", JsonValue.fromObject(AgUiUserInputPayload(question)))
    }

    public func clientToolRequest(toolCallId: String, toolName: String, arguments: String): AgUiEvent {
        CustomEvent("client_tool_request",
            JsonValue.fromObject(AgUiClientToolPayload(toolCallId, toolName, arguments)))
    }

    public func translate(ev: AgentEvent): ArrayList<AgUiEvent> {
        let out = ArrayList<AgUiEvent>()
        if (this.finished) { return out }
        match (ev) {
            case _: AgentStartEvent => ()
            case _: TurnStartEvent =>
                this.closeText(out)
                this.closeStep(out)
                this.turn++
                this.stepOpen = true
                out.add(StepStartedEvent("turn-" + this.turn.toString()))
            case e: MessageStartEvent =>
                match (e.message) {
                    case _: AssistantMessage =>
                        this.newMessageId()
                    case _ => ()
                }
            case e: MessageUpdateEvent =>
                if (e.delta != "") {
                    this.ensureTextStart(out)
                    out.add(TextMessageContentEvent(this.textMessageId, e.delta))
                }
            case e: MessageEndEvent =>
                match (e.message) {
                    case am: AssistantMessage =>
                        // 非流式：整段文本在这里才拿到
                        if (!this.textStarted) {
                            let text = toText(am.content)
                            if (text != "") {
                                this.ensureTextStart(out)
                                out.add(TextMessageContentEvent(this.textMessageId, text))
                            }
                        }
                        this.closeText(out)
                        if (this.textMessageId != "") { this.lastAssistantId = this.textMessageId }
                        this.rememberToolArgs(am)
                        this.emitReasoning(out, am, this.textMessageId)
                        // 复位：下一条 assistant 消息要拿新 id（同一条消息的增量已全部发完）
                        this.textMessageId = ""
                        this.textStarted = false
                    case _ => ()
                }
            case e: ToolExecutionStartEvent =>
                let args = match (this.toolArgs.get(e.toolCallId)) {
                    case Some(a) => a
                    case None => "{}"
                }
                out.add(ToolCallStartEvent(e.toolCallId, e.toolName, this.lastAssistantId))
                out.add(ToolCallArgsEvent(e.toolCallId, args))
                out.add(ToolCallEndEvent(e.toolCallId))
            case e: ToolExecutionUpdateEvent =>
                out.add(CustomEvent("tool_progress",
                    JsonValue.fromObject(AgUiToolProgressPayload(e.toolCallId, e.progress))))
            case e: ToolExecutionEndEvent =>
                out.add(ToolCallResultEvent(this.resultMessageId(), e.toolCallId, e.result, "tool"))
            case e: CompactionEvent =>
                out.add(CustomEvent("compaction",
                    JsonValue.fromObject(AgUiCompactionPayload(e.reason, e.tokensBefore, e.tokensAfter))))
            case e: TurnEndEvent =>
                this.closeText(out)
                this.closeStep(out)
                match (e.message.stopReason) {
                    case StopReason.ToolUse => this.stopReason = "tool_use"
                    case StopReason.Length => this.stopReason = "length"
                    case StopReason.Aborted => this.stopReason = "aborted"
                    case StopReason.Error => this.stopReason = "error"
                    case _ => this.stopReason = "end_turn"
                }
                match (e.message.stopReason) {
                    case StopReason.Error =>
                        // provider 失败：以 RUN_ERROR 收尾，之后不再发 RUN_FINISHED
                        this.finished = true
                        out.add(RunErrorEvent(this.errorText(e.message), "provider_error"))
                    case _ => ()
                }
            case _: AgentEndEvent =>
                this.closeText(out)
                this.closeStep(out)
                this.finished = true
                out.add(RunFinishedEvent(this.threadId, this.runId, this.stopReason, this.turn))
            case _ => ()
        }
        out
    }

    private func ensureTextStart(out: ArrayList<AgUiEvent>): Unit {
        if (!this.textStarted) {
            if (this.textMessageId == "") { this.newMessageId() }
            this.textStarted = true
            out.add(TextMessageStartEvent(this.textMessageId, "assistant"))
        }
    }

    private func newMessageId(): Unit {
        this.msgSeq++
        this.textMessageId = this.runId + "-m" + this.msgSeq.toString()
        this.textStarted = false
    }

    private func closeText(out: ArrayList<AgUiEvent>): Unit {
        if (this.textStarted) {
            this.textStarted = false
            out.add(TextMessageEndEvent(this.textMessageId))
        }
    }

    private func closeStep(out: ArrayList<AgUiEvent>): Unit {
        if (this.stepOpen) {
            this.stepOpen = false
            out.add(StepFinishedEvent("turn-" + this.turn.toString()))
        }
    }

    // 工具调用参数：从 assistant 消息的 tool call 块里取（执行开始时事件里拿不到）
    private func rememberToolArgs(am: AssistantMessage): Unit {
        for (tc in am.toolCalls()) {
            this.toolArgs[tc.id] = toJsonString(tc.args)
        }
    }

    // 思维链：独立 message id，正文与思维链不共用 id 空间
    private func emitReasoning(out: ArrayList<AgUiEvent>, am: AssistantMessage, baseId: String): Unit {
        if (am.reasoningContent == "") { return }
        let rid = if (baseId == "") { this.runId + "-r" + am.reasoningContent.size.toString() } else { baseId + "-r" }
        out.add(ReasoningStartEvent(rid))
        out.add(ReasoningMessageStartEvent(rid))
        out.add(ReasoningMessageContentEvent(rid, am.reasoningContent))
        out.add(ReasoningMessageEndEvent(rid))
        out.add(ReasoningEndEvent(rid))
    }

    private func resultMessageId(): String {
        if (this.lastAssistantId != "") { return this.lastAssistantId }
        this.runId + "-m0"
    }

    // 失败回合：优先用已被截断/失败的正文，空则给出可读的兜底文本
    private func errorText(am: AssistantMessage): String {
        let text = toText(am.content)
        if (text != "") { return text }
        "provider error (stop_reason=error)"
    }
}
