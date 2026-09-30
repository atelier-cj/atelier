package server

import std.collection.*
import std.collection.concurrent.*
import std.sync.{AtomicBool, Mutex}
import std.core.Duration
import std.time.DateTime
import std.env.{getVariable, getWorkingDirectory}
import stdx.net.http.*
import stdx.encoding.json.stream.*
import stdx.log.*
import jsonvalue.JsonValue
import atelier.agent.*
import atelier.context.PromptSegmentContributor
import atelier.message.*
import atelier.interaction.*
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import atelier.tool.*
import atelier.trust.*
import atelier.util.{toJsonString, fromJsonString}

// AG-UI 端点（对外前端协议）：
//   POST /ag-ui/agent  RunAgentInput → text/event-stream（AG-UI 事件）
//
// 提问不另开端点：以 RUN_FINISHED{outcome:interrupt} 结束本次 run，客户端在下一次
// RunAgentInput.resume[] 里带回答复（同一 threadId，覆盖全部未决中断）。
// 与既有 /agent/stream 并存：那条是 atelier 私有事件格式，这条遵守公开协议。
// 设计见 docs/plans/2026-09-30-ag-ui-endpoint.md。

// ── SSE 写出端 ──────────────────────────────────────────────────────────────

// 运行线程（工具执行、提问回调）与消费循环都会写同一个 response body，
// 并发写会交错成非法帧 → 全部经这里串行化。写坏一次即置位，后续事件直接丢。
class AgUiSseSink {
    private let writer: HttpResponseWriter
    private let lock = Mutex()
    private let broken = AtomicBool(false)

    public init(writer: HttpResponseWriter) { this.writer = writer }

    public func send(ev: AgUiEvent): Unit {
        if (this.broken.load()) { return }
        synchronized(this.lock) {
            try {
                this.writer.write(sseFrame(ev).toArray())
            } catch (e: Exception) {
                this.broken.store(true)
                eprintln("[atelier] ag-ui SSE write failed: ${e.toString()}")
            }
        }
    }

    public func isBroken(): Bool { this.broken.load() }
}

// ── 客户端工具 ──────────────────────────────────────────────────────────────

// AG-UI 的 tools 是**前端实现**的工具：模型调用它时，服务端把请求转给前端，
// 阻塞等前端把执行结果回传（同 run 内等待；中断-恢复模型见计划文档 §六）。
// 调用 id 取自本次调用的 ToolContext.toolCallId —— 并行调用也不会串。
class ClientToolShim <: Tool {
    private let toolName: String
    private let desc: String
    private let toolSchema: JsonValue
    public init(toolName: String, desc: String, schema: JsonValue) {
        this.toolName = toolName; this.desc = desc; this.toolSchema = schema
    }

    public func name(): String { this.toolName }
    public func description(): String { this.desc }
    public func schema(): JsonValue { this.toolSchema }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let callId = ctx.toolCallId
        if (callId == "") {
            // 拿不到调用 id 就无法把之后的结果对上，只能明确失败
            return ToolResult("client tool ${this.toolName} invoked without a tool call id", None, true, false)
        }
        // 交给外部执行：本次 run 挂起（历史停在 assistant(tool_calls)），
        // 客户端执行完在下一次 run 的 resume 里带回结果（AG-UI 的中断-恢复模型）
        ToolResult("", None, false, false,
            external: Some(ExternalRequest("int-" + callId, "tool_call",
                "客户端需执行工具 ${this.toolName}", toolCallId: callId)))
    }
}

// ── 系统提示注入 ────────────────────────────────────────────────────────────

// AG-UI 的 system / developer 角色消息与 context 条目是"本轮指令"，
// 不是对话历史：走系统提示通道（atelier 里系统提示与消息历史分离）。
class AgUiInstructionsContributor <: PromptSegmentContributor {
    private let text: String
    public init(text: String) { this.text = text }
    public func render(env: SessionEnvironment): String { this.text }
}

// ── 处理器 ──────────────────────────────────────────────────────────────────

public class AgUiHandler {
    private let agentRegistry: AgentRegistry
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private let skillRegistry: SkillRegistry
    private let providerRegistry: ProviderRegistry
    private let mcpManager: McpManager
    // threadId → 未决中断（内存态：单进程服务；跨重启无法关联时按协议回 RunError）
    private let openInterrupts = ConcurrentHashMap<String, ArrayList<AgUiInterrupt>>()

    public init(agentRegistry: AgentRegistry, toolRegistry: ToolRegistry,
        sessionStore: SessionStore, trustManager: TrustManager,
        skillRegistry: SkillRegistry, providerRegistry: ProviderRegistry,
        mcpManager: McpManager) {
        this.agentRegistry = agentRegistry
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.skillRegistry = skillRegistry
        this.providerRegistry = providerRegistry
        this.mcpManager = mcpManager
    }

    public func registerRoutes(distributor: HttpRequestDistributor): Unit {
        let h = this
        distributor.register("/ag-ui/agent", { ctx => h.handleAgent(ctx) })
    }

    // 不合规输入（缺 resume / resume 对不上）也要走事件流：协议规定以 RUN_ERROR 回应，
    // 而不是 HTTP 4xx（客户端只解析流里的错误）
    private func emitRunErrorOnly(ctx: HttpContext, threadId: String, runId: String,
        message: String, code: String): Unit {
        let b = ctx.responseBuilder
        b.status(UInt16(200))
        b.header("content-type", "text/event-stream")
        b.header("cache-control", "no-cache")
        b.header("connection", "keep-alive")
        // 与正常路径一致：SSE 必须声明分块，否则写出直接报
        // HttpException: Either Content-Length or chunked must be set.（客户端只会看到空流）
        b.header("transfer-encoding", "chunked")
        let sink = AgUiSseSink(HttpResponseWriter(ctx))
        sink.send(RunStartedEvent(threadId, runId))
        sink.send(RunErrorEvent(message, code))
    }

    public func handleAgent(ctx: HttpContext): Unit {
        let body = readBody(ctx)
        let input = try { fromJsonString<RunAgentInput>(body) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid RunAgentInput"))); return
        }
        let agentName = match (input.agentName()) {
            case Some(n) => n
            case None => this.defaultAgentName()
        }
        if (agentName == "") {
            jsonResponse(ctx, 404, toJsonString(ErrorResponse("no agent available"))); return
        }
        let baseCfg = match (this.agentRegistry.get(agentName)) {
            case Some(c) => c
            case None =>
                jsonResponse(ctx, 404, toJsonString(ErrorResponse("agent not found: ${agentName}"))); return
        }
        // 客户端工具要能被模型看到：它们的名字必须进本次 run 的可见工具列表
        // （工具可见性由配置决定），因此按请求派生配置，不动共享的那份
        let clientToolNames = ArrayList<String>()
        for (t in input.tools) { clientToolNames.add(t.name) }
        let cfg = baseCfg.withTools(clientToolNames)
        let threadId = if (input.threadId != "") { input.threadId } else { newId("thread") }
        let runId = if (input.runId != "") { input.runId } else { newId("run") }

        // 会话不存在时 load 会抛（新 thread 的首次请求就是这条路），按"无历史"处理：
        // 运行时会创建该会话，threadId 因此成为跨 run 的会话 id
        var oldLoaded = ArrayList<Message>()
        try { oldLoaded = this.sessionStore.load(threadId) } catch (_) { oldLoaded = ArrayList<Message>() }
        let hasHistory = oldLoaded.size > 0

        // 中断-恢复：有未决中断时必须带 resume，且必须覆盖全部（协议规则 3/4）
        let open = match (this.openInterrupts.get(threadId)) {
            case Some(list) => list
            case None => ArrayList<AgUiInterrupt>()
        }
        var msgs = ArrayList<Message>()
        var resumeResults = ArrayList<ToolResultMessage>()
        if (open.size == 0 && input.resume.size > 0) {
            this.emitRunErrorOnly(ctx, threadId, runId,
                "resume provided but this thread has no unresolved interrupt", "invalid_resume")
            return
        }
        if (open.size > 0) {
            if (input.resume.size == 0) {
                this.emitRunErrorOnly(ctx, threadId, runId,
                    "thread has ${open.size} unresolved interrupt(s); RunAgentInput.resume is required",
                    "interrupt_required")
                return
            }
            let (resumeMsgs, err) = agUiResumeToMessages(oldLoaded, open, input.resume)
            match (err) {
                case Some(msg) =>
                    this.emitRunErrorOnly(ctx, threadId, runId, msg, "invalid_resume")
                    return
                case None => ()
            }
            msgs = ArrayList<Message>(oldLoaded)
            for (m in resumeMsgs) {
                msgs.add(m)
                match (m) {
                    case tr: ToolResultMessage => resumeResults.add(tr)
                    case _ => ()
                }
            }
            this.openInterrupts.remove(threadId)
        } else {
            msgs = agUiMessagesToAtelier(input.messages, hasHistory)
            if (msgs.size == 0) {
                jsonResponse(ctx, 400, toJsonString(ErrorResponse("no user message in RunAgentInput"))); return
            }
        }

        let b = ctx.responseBuilder
        b.status(UInt16(200))
        b.header("content-type", "text/event-stream")
        b.header("cache-control", "no-cache")
        b.header("connection", "keep-alive")
        b.header("transfer-encoding", "chunked")

        let sink = AgUiSseSink(HttpResponseWriter(ctx))

        let provider = this.resolveProvider()
        let runtime = AgentRuntime(cfg, provider, this.clientToolRegistry(input.tools),
            this.sessionStore, this.trustManager, this.skillRegistry, this.agentRegistry,
            this.providerRegistry, ArrayList<Hook>(), SessionEnvironment(), this.mcpManager,
            ask: Some({ req: UserRequest => UserAnswer.pending(req.id) }),
            promptContributors: this.contributorsFor(input))

        let translator = AgUiTranslator(threadId, runId, clientTools: clientToolNames)
        let snapshot = AgUiStateSnapshot(agentName, cfg.model, threadId,
            sessionEnvWorkDir(), input.state)
        for (ev in translator.start(snapshot)) { sink.send(ev) }

        // 恢复带来的结果按协议补发 TOOL_CALL_RESULT（绑定原先的 toolCallId），
        // 客户端的时间线才完整：它不必猜"我提交的结果有没有被采用"
        for (tr in resumeResults) {
            sink.send(ToolCallResultEvent(tr.toolCallId + "-result", tr.toolCallId,
                toText(tr.content), "tool"))
        }

        let eventStream = runtime.chatWithSessionId(threadId, msgs, SessionEnvironment())
        streamAgUiEvents(eventStream, translator, sink, oldLoaded)

        // 挂起 → 登记未决中断（下一次 run 的 resume 要覆盖它们）
        let pending = translator.pendingInterrupts()
        if (pending.size > 0) { this.openInterrupts.add(threadId, pending) }

        // 落库：运行时不落库，由宿主统一追加（挂起那轮同样要落 —— 历史停在
        // assistant(tool_calls) 才是恢复的锚点）。取回全量消息失败时退回追加已知输入。
        let all = try { eventStream.result() } catch (_) { msgs }
        match (persistAppend(this.sessionStore, threadId, oldLoaded, all)) {
            case Some(err) =>
                let log = getGlobalLogger([("name", "AgUi")])
                log.warn("session persist failed: ${err}", Array<Attr>())
            case None => ()
        }
    }

    // 客户端工具进 run 作用域注册表：base 工具 ∪ 本次客户端工具（run 结束即弃，不污染全局）
    private func clientToolRegistry(tools: ArrayList<AgUiToolDTO>): ToolRegistry {
        let reg = ToolRegistry()
        for (t in this.toolRegistry.list()) { reg.register(t) }
        for (t in tools) {
            let schema = match (t.parameters) {
                case Some(p) => p
                case None => JsonValue.Map(HashMap<String, JsonValue>())
            }
            // 同名工具以客户端为准：前端声明的工具语义由前端实现
            if (reg.has(t.name)) { reg.remove(t.name) }
            reg.register(ClientToolShim(t.name, t.description, schema))
        }
        reg
    }

    private func contributorsFor(input: RunAgentInput): ArrayList<PromptSegmentContributor> {
        let out = ArrayList<PromptSegmentContributor>()
        let text = agUiInstructionText(input)
        if (text != "") { out.add(AgUiInstructionsContributor(text)) }
        out
    }

    private func defaultAgentName(): String {
        let all = this.agentRegistry.list()
        for (item in all) {
            let (name, _) = item
            if (name == "default") { return name }
        }
        if (all.size > 0) {
            let (first, _) = all[0]
            return first
        }
        ""
    }

    private func resolveProvider(): Provider {
        match (this.providerRegistry.get("default")) {
            case Some(p) => p
            case None =>
                let p = OpenAIProvider("default", "http://localhost:8089", "")
                this.providerRegistry.register("default", p)
                p
        }
    }
}

// 消费循环：翻译 + 写出，直到 AgentEnd / provider 失败 / 客户端断开
func streamAgUiEvents(eventStream: LoopEventStream, translator: AgUiTranslator, sink: AgUiSseSink,
    oldLoaded: ArrayList<Message>): ArrayList<Message> {
    let log = getGlobalLogger([("name", "AgUi")])
    var done = false
    // 挂起那一刻的助手消息（TurnEnd 先于 Suspend 到达）：快照要用它补全"停在 assistant(tool_calls)"
    var pendingAssistant: Option<AssistantMessage> = None
    var suspended = false
    var all = oldLoaded
    while (!done) {
        match (eventStream.receive(30 * Duration.second)) {
            case Some(ev) =>
                match (ev) {
                    case te: TurnEndEvent => pendingAssistant = Some(te.message)
                    case se: SuspendEvent =>
                        // 协议要求：恢复所需状态必须在 RUN_FINISHED 之前发出
                        suspended = true
                        let snapshotMsgs = ArrayList<Message>(oldLoaded)
                        match (pendingAssistant) {
                            case Some(am) => snapshotMsgs.add(am)
                            case None => ()
                        }
                        sink.send(MessagesSnapshotEvent(agUiOutMessages(snapshotMsgs)))
                    case _ => ()
                }
                for (out in translator.translate(ev)) { sink.send(out) }
                match (ev) {
                    case _: AgentEndEvent => done = true
                    case te: TurnEndEvent =>
                        match (te.message.stopReason) {
                            case StopReason.Error => done = true
                            case _ => ()
                        }
                    case _ => ()
                }
                if (sink.isBroken()) { done = true }
            case None => done = true
        }
    }
    match (suspended) {
        case true => log.info("ag-ui run suspended", Array<Attr>())
        case false => log.info("ag-ui run finished", Array<Attr>())
    }
    all
}

// RunAgentInput.messages → atelier 消息。
// 会话已有历史时只取"最后一条 assistant 之后"的尾部（历史在服务端会话里，重发会重复）；
// 会话为空时全量转换，前端可以带着完整上下文开一个新 thread。
func agUiMessagesToAtelier(msgs: ArrayList<AgUiMessageDTO>, sessionHasHistory: Bool): ArrayList<Message> {
    var start = 0
    if (sessionHasHistory) {
        for (i in 0..msgs.size) {
            if (msgs[Int64(i)].role == "assistant") { start = i + 1 }
        }
    }
    // 尾部（最后一条 assistant 之后）必须含用户输入或工具结果，否则本次 run 无事可做：
    // 只带历史/只带 assistant 的请求回空，由调用方明确报 400，而不是空跑一轮。
    var actionable = false
    for (i in start..msgs.size) {
        let role = msgs[Int64(i)].role
        if (role == "user" || role == "tool") { actionable = true }
    }
    if (!actionable) { return ArrayList<Message>() }
    let out = ArrayList<Message>()
    for (i in start..msgs.size) {
        let m = msgs[Int64(i)]
        match (m.role) {
            case "user" => out.add(UserMessage(ContentList.ofText(m.content), nowMillis()))
            case "assistant" =>
                let blocks = ArrayList<ContentBlock>()
                if (m.content != "") { blocks.add(ContentBlock.TextBlock(m.content)) }
                for (tc in m.toolCalls) {
                    blocks.add(ContentBlock.ToolCall(ToolCallBlock(tc.id, tc.function.name,
                        parseArgs(tc.function.arguments))))
                }
                let stop = if (m.toolCalls.size > 0) { StopReason.ToolUse } else { StopReason.EndTurn }
                out.add(AssistantMessage(ContentList(blocks), "", "", stop,
                    TokenUsage(0, 0), nowMillis(), ""))
            case "tool" =>
                out.add(ToolResultMessage(m.toolCallId, "", ContentList.ofText(m.content),
                    false, nowMillis()))
            case _ => ()   // system / developer 走系统提示通道（见 agUiInstructionText）
        }
    }
    out
}

// system / developer 消息 + context 条目 + forwardedProps.systemPrompt → 本轮系统提示附加段
func agUiInstructionText(input: RunAgentInput): String {
    let sb = StringBuilder()
    for (m in input.messages) {
        if (m.role == "system" || m.role == "developer") {
            if (m.content != "") { sb.append(m.content + "\n\n") }
        }
    }
    match (input.systemPromptOverride()) {
        case Some(s) => if (s != "") { sb.append(s + "\n\n") }
        case None => ()
    }
    for (c in input.context) {
        if (c.value != "") {
            if (c.description != "") {
                sb.append(c.description + ":\n" + c.value + "\n\n")
            } else {
                sb.append(c.value + "\n\n")
            }
        }
    }
    // 尾部多余空行去掉：系统提示是逐段拼接的，别留尾
    var text = sb.toString()
    while (text.endsWith("\n")) { text = text[0..text.size - 1] }
    text
}

func parseArgs(raw: String): JsonValue {
    let empty = JsonValue.Map(HashMap<String, JsonValue>())
    if (raw == "") { return empty }
    // 工具参数在协议里就是 JSON 对象，因此**以 { 开头**才认为是结构化参数。
    // 不能只靠 try/catch：stdx 的 reader 会把裸 token（如 `not json`）当字符串收下，
    // 那会把「参数根本不是 JSON」伪装成「参数是字符串」。
    var text = raw
    while (text.startsWith(" ") || text.startsWith("\n") || text.startsWith("\t")) {
        text = text[1..text.size]
    }
    if (!text.startsWith("{")) { return JsonValue.String(raw) }
    try {
        fromJsonString<JsonValue>(raw)
    } catch (_) {
        // 参数不是合法 JSON 时保留原文，工具自己能给出更好的报错
        JsonValue.String(raw)
    }
}

// ── 中断-恢复的消息换算 ──────────────────────────────────────────────────────

// 会话消息 → AG-UI 出站消息（MESSAGES_SNAPSHOT 用）。
// 内部标记（压缩/归档）不外发：它们是上下文管理的实现细节，客户端无法理解也无从渲染。
func agUiOutMessages(msgs: ArrayList<Message>): ArrayList<AgUiOutMessage> {
    let out = ArrayList<AgUiOutMessage>()
    var idx: Int64 = 0
    for (m in msgs) {
        idx++
        let id = "m" + idx.toString()
        match (m) {
            case um: UserMessage =>
                out.add(AgUiOutMessage(id, "user", toText(um.content), "", ArrayList<AgUiToolCallDTO>()))
            case am: AssistantMessage =>
                let calls = ArrayList<AgUiToolCallDTO>()
                for (tc in am.toolCalls()) {
                    calls.add(AgUiToolCallDTO(tc.id, AgUiFunctionDTO(tc.name, toJsonString(tc.args))))
                }
                out.add(AgUiOutMessage(id, "assistant", toText(am.content), "", calls))
            case tm: ToolResultMessage =>
                out.add(AgUiOutMessage(id, "tool", toText(tm.content), tm.toolCallId,
                    ArrayList<AgUiToolCallDTO>()))
            case _ => ()
        }
    }
    out
}

// 载荷 → 结果文本：字符串载荷原样用（客户端最常发字符串），其它按 JSON 序列化
func payloadText(payload: Option<JsonValue>): String {
    match (payload) {
        case Some(JsonValue.String(s)) => s
        case Some(v) => toJsonString(v)
        case None => ""
    }
}

// 载荷里明确拒绝（{approved:false}）＝ 不执行该调用，但仍要给它一条结果消息保持配对
func payloadDenied(payload: Option<JsonValue>): Bool {
    match (payload) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("approved")) {
                case Some(JsonValue.Boolean(b)) => !b
                case _ => false
            }
        case _ => false
    }
}

// 历史里找回某个工具调用的名字（恢复时只拿得到 toolCallId）
func toolNameOf(msgs: ArrayList<Message>, toolCallId: String): String {
    for (m in msgs) {
        match (m) {
            case am: AssistantMessage =>
                for (tc in am.toolCalls()) {
                    if (tc.id == toolCallId) { return tc.name }
                }
            case _ => ()
        }
    }
    ""
}

// 中断 + 客户端的 resume 条目 → 结构化答复。
// 载荷约定（与 AG-UI 生态习惯一致，两种都收）：
//   {approved: true|false}                → 审批结论（allow_once / deny）
//   {selected:[...]} / {text:"..."} / {values:{...}} → 选择 / 文本 / 表单
//   其它标量或对象                         → 当作纯文本（保留原文，别丢信息）
func resumeAnswerOf(intr: AgUiInterrupt, entry: AgUiResumeDTO): UserAnswer {
    if (entry.isCancelled()) {
        return UserAnswer(intr.id, UserAnswerStatus.Cancelled)
    }
    var selected = ArrayList<String>()
    var text = ""
    let values = HashMap<String, JsonValue>()
    match (entry.payload) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("approved")) {
                case Some(JsonValue.Boolean(b)) =>
                    selected.add(if (b) { "allow_once" } else { "deny" })
                case _ => ()
            }
            match (m.get("selected")) {
                case Some(JsonValue.Array(items)) =>
                    for (item in items) {
                        match (item) {
                            case JsonValue.String(s) => selected.add(s)
                            case _ => ()
                        }
                    }
                case Some(JsonValue.String(s)) => selected.add(s)
                case _ => ()
            }
            match (m.get("text")) {
                case Some(JsonValue.String(s)) => text = s
                case _ => ()
            }
            match (m.get("values")) {
                case Some(JsonValue.Map(vs)) =>
                    for (k in vs.keys()) {
                        match (vs.get(k)) {
                            case Some(v) => values[k] = v
                            case None => ()
                        }
                    }
                case _ => ()
            }
            if (selected.size == 0 && text == "" && values.size == 0) {
                text = payloadText(entry.payload)
            }
        case Some(_) => text = payloadText(entry.payload)
        case None => ()
    }
    UserAnswer(intr.id, UserAnswerStatus.Answered,
        selected: selected, text: text, values: values)
}

// resume[] → 本次 run 的输入消息。返回 (消息, 错误)：错误非空即回 RUN_ERROR（协议规则 3/6/7）。
// 每个未决中断都必须被覆盖（部分恢复不支持）；引用未知中断 id 同样报错。
func agUiResumeToMessages(history: ArrayList<Message>, open: ArrayList<AgUiInterrupt>,
    resume: ArrayList<AgUiResumeDTO>): (ArrayList<Message>, Option<String>) {
    let byId = HashMap<String, AgUiResumeDTO>()
    for (r in resume) { byId[r.interruptId] = r }
    for (r in resume) {
        var known = false
        for (i in open) {
            if (i.id == r.interruptId) { known = true }
        }
        if (!known) {
            return (ArrayList<Message>(), Some("cannot correlate interruptId: ${r.interruptId}"))
        }
    }
    let msgs = ArrayList<Message>()
    for (i in open) {
        let entry = match (byId.get(i.id)) {
            case Some(r) => r
            case None => return (ArrayList<Message>(),
                Some("resume must address every open interrupt; missing: ${i.id}"))
        }
        if (i.reason == "tool_call" && i.toolCallId != "") {
            let cancelled = entry.isCancelled()
            let denied = payloadDenied(entry.payload)
            let text = if (cancelled) {
                "[cancelled by user]"
            } else if (denied) {
                "[denied by user]"
            } else {
                payloadText(entry.payload)
            }
            msgs.add(ToolResultMessage(i.toolCallId, toolNameOf(history, i.toolCallId),
                ContentList.ofText(text), cancelled || denied, nowMillis()))
        } else {
            // 审批 / 要输入类中断：答复必须回到**同一个提问**上（重放那一回合时按 requestId 命中），
            // 所以编码进消息元数据，而不是当成一句普通用户消息
            let ans = resumeAnswerOf(i, entry)
            msgs.add(UserMessage(ContentList.ofText(ans.text), nowMillis(),
                metadata: encodeAnswer(ans)))
        }
    }
    (msgs, None)
}

func nowMillis(): Int64 {
    DateTime.now().toUnixTimeStamp().toMilliseconds()
}

func newId(prefix: String): String {
    prefix + "-" + nowMillis().toString()
}

// 状态快照里的 cwd：AG-UI 客户端用它显示工作目录。
// 优先用显式声明的 ATELIER_WORKDIR（与会话环境一致），否则退回进程工作目录。
func sessionEnvWorkDir(): String {
    match (getVariable("ATELIER_WORKDIR")) {
        case Some(v) => if (v != "") { return v }
        case None => ()
    }
    try {
        getWorkingDirectory().toString()
    } catch (_) {
        ""
    }
}
