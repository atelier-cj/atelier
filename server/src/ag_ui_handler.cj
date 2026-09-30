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
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import atelier.tool.*
import atelier.trust.*
import atelier.util.{toJsonString, fromJsonString}

// AG-UI 端点（对外前端协议）：
//   POST /ag-ui/agent  RunAgentInput → text/event-stream（AG-UI 事件）
//   POST /ag-ui/input  回传 askUser 的回答或客户端工具的执行结果
//
// 与既有 /agent/stream 并存：那条是 atelier 私有事件格式（TUI 在用），这条遵守公开协议。
// 设计见 docs/plans/2026-09-30-ag-ui-endpoint.md。

// ── 外部输入通道 ────────────────────────────────────────────────────────────

// 每个等待中的外部请求一个队列：askUser 用键 "user"，客户端工具用键 "tool:<toolCallId>"。
// 分开按键，避免并行工具调用时互相偷走对方的回答。
class AgUiRunChannels {
    private let queues = ConcurrentHashMap<String, LinkedBlockingQueue<AgUiInputDTO>>()

    public func register(key: String): LinkedBlockingQueue<AgUiInputDTO> {
        let q = LinkedBlockingQueue<AgUiInputDTO>(1)
        this.queues.add(key, q)
        q
    }

    public func deliver(key: String, dto: AgUiInputDTO): Bool {
        match (this.queues.get(key)) {
            case Some(q) => q.tryAdd(dto)
            case None => false
        }
    }

    public func discard(key: String): Unit { this.queues.remove(key) }
}

// ── SSE 写出端 ──────────────────────────────────────────────────────────────

// 运行线程（工具执行、askUser 回调）与消费循环都会写同一个 response body，
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
    private let runId: String
    private let channels: AgUiRunChannels

    public init(toolName: String, desc: String, schema: JsonValue, runId: String,
        channels: AgUiRunChannels) {
        this.toolName = toolName; this.desc = desc; this.toolSchema = schema
        this.runId = runId; this.channels = channels
    }

    public func name(): String { this.toolName }
    public func description(): String { this.desc }
    public func schema(): JsonValue { this.toolSchema }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let callId = ctx.toolCallId
        if (callId == "") {
            // 拿不到调用 id 就没法把结果对上，只能明确失败，不能假装成功
            return ToolResult("client tool ${this.toolName} invoked without a tool call id", None, true, false)
        }
        // 请求事件由翻译器按固定顺序发出（见 AgUiTranslator），这里只等结果：
        // 工具线程自己写 SSE 会与消费循环抢顺序，前端可能先看到请求、后看到 TOOL_CALL_START
        let key = "tool:" + callId
        let queue = this.channels.register(key)
        let answer = queue.remove()
        this.channels.discard(key)
        ToolResult(answer.result, None, answer.isError, false)
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
    private let runs = ConcurrentHashMap<String, AgUiRunChannels>()

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
        distributor.register("/ag-ui/input", { ctx => h.handleInput(ctx) })
    }

    public func handleInput(ctx: HttpContext): Unit {
        let body = readBody(ctx)
        let dto = try { fromJsonString<AgUiInputDTO>(body) } catch (_) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("invalid JSON"))); return
        }
        let key = inputKey(dto)
        if (key == "") {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("kind must be user_input or tool_result"))); return
        }
        let channels = match (this.runs.get(dto.runId)) {
            case Some(c) => c
            case None =>
                jsonResponse(ctx, 404, toJsonString(ErrorResponse("unknown run: ${dto.runId}"))); return
        }
        if (channels.deliver(key, dto)) {
            jsonResponse(ctx, 200, toJsonString(ErrorResponse("")))
        } else {
            // 没有在等的请求：多半是重复回传或 runId 写错，明确回报，别静默丢弃
            jsonResponse(ctx, 404, toJsonString(ErrorResponse("no pending request for ${key}")))
        }
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
        var hasHistory = false
        try { hasHistory = this.sessionStore.load(threadId).size > 0 } catch (_) { hasHistory = false }
        let msgs = agUiMessagesToAtelier(input.messages, hasHistory)
        if (msgs.size == 0) {
            jsonResponse(ctx, 400, toJsonString(ErrorResponse("no user message in RunAgentInput"))); return
        }

        let b = ctx.responseBuilder
        b.status(UInt16(200))
        b.header("content-type", "text/event-stream")
        b.header("cache-control", "no-cache")
        b.header("connection", "keep-alive")
        b.header("transfer-encoding", "chunked")

        let sink = AgUiSseSink(HttpResponseWriter(ctx))
        let channels = AgUiRunChannels()
        this.runs.add(runId, channels)

        let provider = this.resolveProvider()
        let runtime = AgentRuntime(cfg, provider, this.clientToolRegistry(input.tools, runId, channels),
            this.sessionStore, this.trustManager, this.skillRegistry, this.agentRegistry,
            this.providerRegistry, ArrayList<Hook>(), { q =>
                // 等外部输入：先告诉前端，再阻塞等 /ag-ui/input
                let key = "user"
                let queue = channels.register(key)
                sink.send(CustomEvent("user_input_request",
                    JsonValue.fromObject(AgUiUserInputPayload(q))))
                let answer = queue.remove()
                channels.discard(key)
                answer.text
            }, SessionEnvironment(), this.mcpManager,
            promptContributors: this.contributorsFor(input))

        let translator = AgUiTranslator(threadId, runId, clientTools: clientToolNames)
        let snapshot = AgUiStateSnapshot(agentName, cfg.model, threadId,
            sessionEnvWorkDir(), input.state)
        for (ev in translator.start(snapshot)) { sink.send(ev) }

        let eventStream = runtime.chatWithSessionId(threadId, msgs, SessionEnvironment())
        streamAgUiEvents(eventStream, translator, sink)
        this.runs.remove(runId)
    }

    // 客户端工具进 run 作用域注册表：base 工具 ∪ 本次客户端工具（run 结束即弃，不污染全局）
    private func clientToolRegistry(tools: ArrayList<AgUiToolDTO>, runId: String,
        channels: AgUiRunChannels): ToolRegistry {
        let reg = ToolRegistry()
        for (t in this.toolRegistry.list()) { reg.register(t) }
        for (t in tools) {
            let schema = match (t.parameters) {
                case Some(p) => p
                case None => JsonValue.Map(HashMap<String, JsonValue>())
            }
            // 同名工具以客户端为准：前端声明的工具语义由前端实现
            if (reg.has(t.name)) { reg.remove(t.name) }
            reg.register(ClientToolShim(t.name, t.description, schema, runId, channels))
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
func streamAgUiEvents(eventStream: LoopEventStream, translator: AgUiTranslator, sink: AgUiSseSink): Unit {
    let log = getGlobalLogger([("name", "AgUi")])
    var done = false
    while (!done) {
        match (eventStream.receive(30 * Duration.second)) {
            case Some(ev) =>
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
    log.info("ag-ui run finished", Array<Attr>())
}

// 输入通道的键：askUser 的回答与客户端工具结果分键，互不干扰
func inputKey(dto: AgUiInputDTO): String {
    match (dto.kind) {
        case "user_input" => "user"
        case "tool_result" => if (dto.toolCallId != "") { "tool:" + dto.toolCallId } else { "" }
        case _ => ""
    }
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
