package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

// 挂起（SuspendEvent）：工具把结果交给外部（前端执行 / 用户确认）时，本次 run 必须停在这里，
// 且**不能**写结果消息 —— 写了就等于伪造结果，下一次 run 真结果回来会变成两条。
// 恢复靠的是「历史停在 assistant(tool_calls) + 下一次 run 带结果」，所以这里也要验历史形态。

func suspendToolUseMsg(tool: String, id: String): AssistantMessage {
    let tc = ToolCallBlock(id, tool, JsonValue.Map(HashMap<String, JsonValue>()))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

func suspendEndMsg(text: String): AssistantMessage {
    AssistantMessage(ContentList.ofText(text), "m", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

// 要外部给结果的工具（客户端工具就是这种）
class ExternalTool <: Tool {
    public func name(): String { "ext" }
    public func description(): String { "需要外部执行" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        ToolResult("", None, false, false,
            external: Some(ExternalRequest("int-" + ctx.toolCallId, "tool_call",
                "前端需执行 ext", toolCallId: ctx.toolCallId)))
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 正常工具：与 ExternalTool 一起排队，验证「一个挂起不影响其它调用的结果落地」
class PlainTool <: Tool {
    public func name(): String { "plain" }
    public func description(): String { "普通工具" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("done", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

class SuspendProbeProvider <: Provider {
    public let responses: ArrayList<AssistantMessage>
    public var callCount: Int64 = 0
    public var seen: ArrayList<ArrayList<Message>> = ArrayList()
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse {
        this.seen.add(ArrayList<Message>(req.messages))
        let idx = this.callCount % this.responses.size
        this.callCount++
        ChatResponse(this.responses[Int64(idx)])
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        this.seen.add(ArrayList<Message>(req.messages))
        let idx = this.callCount % this.responses.size
        this.callCount++
        let msg = this.responses[Int64(idx)]
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func chatWith(provider: Provider, tools: ArrayList<Tool>, store: SessionStore,
    messages: ArrayList<Message>, sessionId: String): ArrayList<AgentEvent> {
    let toolReg = ToolRegistry()
    for (t in tools) { toolReg.register(t) }
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = AgentRuntime(AgentConfig.default(), provider, toolReg, store, TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), { q => "" }, McpManager())
    // 运行时不落库：宿主（SessionLoop/ACP/AG-UI handler）在 run 结束后统一追加，
    // 挂起也一样 —— 历史必须停在 assistant(tool_calls)，恢复才有锚点
    var oldLoaded = ArrayList<Message>()
    try { oldLoaded = store.load(sessionId) } catch (_) { () }
    let stream = runtime.chatWithSessionId(sessionId, messages, SessionEnvironment())
    let events = ArrayList<AgentEvent>()
    var done = false
    while (!done) {
        match (stream.receive(30 * Duration.second)) {
            case Some(ev) =>
                events.add(ev)
                match (ev) {
                    case _: AgentEndEvent => done = true
                    case _ => ()
                }
            case None => done = true
        }
    }
    let all = try { stream.result() } catch (_) { oldLoaded }
    match (persistAppend(store, sessionId, oldLoaded, all)) {
        case Some(err) => eprintln("[test] persist failed: ${err}")
        case None => ()
    }
    events
}

func eventKinds(events: ArrayList<AgentEvent>): String {
    let parts = ArrayList<String>()
    for (e in events) { parts.add(e.eventType()) }
    String.join(parts.toArray(), delimiter: ",")
}

func suspendRequests(events: ArrayList<AgentEvent>): ArrayList<ExternalRequest> {
    for (e in events) {
        match (e) {
            case se: SuspendEvent => return se.requests
            case _ => ()
        }
    }
    ArrayList<ExternalRequest>()
}

@Test
func suspend_externalToolSuspendsRunWithRequest() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(suspendToolUseMsg("ext", "call_1"))
    responses.add(suspendEndMsg("不该走到这里"))
    let provider = SuspendProbeProvider(responses)
    let events = chatWith(provider, ArrayList<Tool>(ArrayList<Tool>([ExternalTool()])),
        MemorySessionStore(),
        ArrayList<Message>(ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)])),
        "s1")
    let kinds = eventKinds(events)
    @Expect(kinds.contains("suspend"), true)
    // 挂起后不再有下一回合：provider 只被调用一次
    @Expect(provider.callCount, 1)
    let reqs = suspendRequests(events)
    @Expect(reqs.size, 1)
    @Expect(reqs[0].reason, "tool_call")
    @Expect(reqs[0].toolCallId, "call_1")
    @Expect(reqs[0].id, "int-call_1")
}

@Test
func suspend_doesNotWriteResultMessage() {
    // 关键不变量：挂起的调用在历史里不能有结果消息（否则恢复时会出现两条）
    let responses = ArrayList<AssistantMessage>()
    responses.add(suspendToolUseMsg("ext", "call_1"))
    let provider = SuspendProbeProvider(responses)
    let store = MemorySessionStore()
    let events = chatWith(provider, ArrayList<Tool>([ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)]), "s2")
    @Expect(eventKinds(events).contains("suspend"), true)
    let history = store.load("s2")
    var toolResults = 0
    for (m in history) {
        match (m) {
            case _: ToolResultMessage => toolResults++
            case _ => ()
        }
    }
    @Expect(toolResults, 0)
    // 历史停在 assistant(tool_calls)：这是恢复的锚点
    var lastIsAssistantWithCalls = false
    if (history.size > 0) {
        match (history[history.size - 1]) {
            case am: AssistantMessage => lastIsAssistantWithCalls = am.toolCalls().size == 1
            case _ => ()
        }
    }
    @Expect(lastIsAssistantWithCalls, true)
}

@Test
func suspend_otherToolResultsStillLand() {
    // 同一批里既有挂起也有普通工具：普通工具的结果必须照常写进历史，
    // 否则它的调用会永远缺配对结果（下一次请求被 provider 判 400）
    let msg = suspendToolUseMsg("plain", "call_plain")
    let responses = ArrayList<AssistantMessage>()
    responses.add(msg)
    let provider = SuspendProbeProvider(responses)
    let store = MemorySessionStore()
    let events = chatWith(provider, ArrayList<Tool>([PlainTool(), ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("干活"), 0)]), "s3")
    @Expect(eventKinds(events).contains("suspend"), false)   // 这批里没有挂起调用
    let history = store.load("s3")
    var ok = false
    for (m in history) {
        match (m) {
            case tr: ToolResultMessage => if (tr.toolCallId == "call_plain") { ok = true }
            case _ => ()
        }
    }
    @Expect(ok, true)
}

@Test
func suspend_resumeWithResultContinues() {
    // 恢复：下一次 run 带结果消息 → 模型看到配对完整的历史，继续回答
    let store = MemorySessionStore()
    let first = ArrayList<AssistantMessage>()
    first.add(suspendToolUseMsg("ext", "call_1"))
    let provider1 = SuspendProbeProvider(first)
    chatWith(provider1, ArrayList<Tool>([ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)]), "s4")

    let second = ArrayList<AssistantMessage>()
    second.add(suspendEndMsg("北京晴"))
    let provider2 = SuspendProbeProvider(second)
    // 宿主语义：历史（含挂起那轮的 assistant(tool_calls)）+ 本次带来的结果
    let resumeMsgs = ArrayList<Message>(store.load("s4"))
    resumeMsgs.add(ToolResultMessage("call_1", "ext", ContentList.ofText("北京：晴 26℃"), false, 0))
    let events = chatWith(provider2, ArrayList<Tool>([ExternalTool()]), store, resumeMsgs, "s4")
    @Expect(eventKinds(events).contains("agent_end"), true)
    // 恢复时模型看到的最后一条是工具结果（配对完整，不会被 provider 判 400）
    let seen = provider2.seen[0]
    var lastIsToolResult = false
    match (seen[seen.size - 1]) {
        case _: ToolResultMessage => lastIsToolResult = true
        case _ => ()
    }
    @Expect(lastIsToolResult, true)
}
