package atelier.agent

import jsonvalue.*
import std.collection.*
import std.core.Duration
import std.core.sleep
import std.time.MonoTime
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

import atelier.context.CompactionConfig

// 复刻 hook_test.cj 的 FakeProvider：chat 返回固定 end_turn 回复，不真连网络
class StubProvider <: Provider {
    public func name(): String { "stub" }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// 简易 mcp 风格工具（名字带 mcp_ 前缀；read_file 模拟非 mcp 工具）
class McpStyleTool <: Tool {
    private let toolName: String
    public init(name: String) { this.toolName = name }
    public func name(): String { this.toolName }
    public func description(): String { "fake mcp tool" }
    public func schema(): JsonValue { JsonValue.Map(HashMap()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// mcpCooldownTurns=3：激活后 3 轮内活跃，之后进入冷却
// read_* 前缀模式走 `_*` 分支，验证非 mcp 工具不受冷却过滤
func mcpRuntimeConfig(): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("mcp_*")
    tools.add("read_*")
    let skills = ArrayList<String>()
    AgentConfig("t", None, "", None, "m", None, tools, skills, 3,
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

func makeMcpRuntime(provider: Provider, hooks: ArrayList<Hook>, mcpManager: McpManager): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(McpStyleTool("mcp_github_search_repos"))
    toolReg.register(McpStyleTool("read_file"))
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    AgentRuntime(mcpRuntimeConfig(), provider, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, hooks, { q => "" }, mcpManager)
}

// beforeTurn hook 捕获 tools 列表
class CaptureToolsHook <: Hook {
    public var seen: ArrayList<OpenAITool> = ArrayList()
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.seen = request.tools
        TurnDecision.Continue(request)
    }
}

func runAndCaptureSeen(mcpManager: McpManager): (Bool, Bool) {
    let hook = CaptureToolsHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let runtime = makeMcpRuntime(StubProvider(), hooks, mcpManager)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    var foundMcp = false
    var foundPlain = false
    for (t in hook.seen) {
        if (t.name.startsWith("mcp_")) { foundMcp = true }
        if (t.name == "read_file") { foundPlain = true }
    }
    (foundMcp, foundPlain)
}

@Test
func runtime_mcpToolsFilteredWhenInactive() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, false)
    @Expect(foundPlain, true)
}

@Test
func runtime_mcpToolsVisibleAfterActivate() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    mcpManager.activate("github")
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, true)
    @Expect(foundPlain, true)
}

@Test
func runtime_mcpToolsCooldownExpired() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    mcpManager.activate("github")
    var i: Int64 = 0
    while (i < 4) { mcpManager.advanceTurn(); i++ }  // config.mcpCooldownTurns = 3
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, false)
    @Expect(foundPlain, true)
}

// ---------- 压缩增强集成测试 ----------
// 模型 "m" 未知 → contextWindow = 8192；触发条件 total > reserve 且 total > 8192 - reserve

// chat 返回固定摘要文本并记录子调用（次数 + 请求体）
class StubSummaryProvider <: Provider {
    public var chatCalls: Int64 = 0
    public var lastReq: Option<ChatRequest> = None
    private let summaryText: String
    public init(summaryText: String) { this.summaryText = summaryText }

    public func name(): String { "stub-summary" }

    public func chat(req: ChatRequest): ChatResponse {
        this.chatCalls++
        this.lastReq = Some(req)
        let msg = AssistantMessage(ContentList.ofText(this.summaryText), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// 主对话流返回 usage.inputTokens=500000（验证用量优先），chat 返回固定摘要
class StubUsageSummaryProvider <: Provider {
    public var chatCalls: Int64 = 0
    private let summaryText: String
    public init(summaryText: String) { this.summaryText = summaryText }

    public func name(): String { "stub-usage-summary" }

    public func chat(req: ChatRequest): ChatResponse {
        this.chatCalls++
        ChatResponse(AssistantMessage(ContentList.ofText(this.summaryText), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(500000, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// chat 抛异常：验证子调用失败降级为占位符
class StubFailingProvider <: Provider {
    public func name(): String { "stub-failing" }

    public func chat(req: ChatRequest): ChatResponse {
        throw Exception("network down")
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func compactionRuntimeConfig(compactionEnabled: Bool, reserveTokens: UInt32,
    keepRecentTokens: UInt32, compaction: Option<CompactionConfig>): AgentConfig {
    AgentConfig("t", None, "", None, "m", None,
        ArrayList(), ArrayList(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        compactionEnabled, reserveTokens, keepRecentTokens, compaction,
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

func makeCompactionRuntime(config: AgentConfig, provider: Provider): AgentRuntime {
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    AgentRuntime(config, provider, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, McpManager())
}

// 约 18000 字符 ≈ 4505 tokens（+5 固定开销），确保 total > 4096 阈值
func bigUserMessage(): UserMessage {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < 18000) { sb.append("x"); i++ }
    UserMessage(ContentList.ofText(sb.toString()), 0)
}

func requireCompaction(result: ArrayList<Message>): CompactionMessage {
    match (result[0]) {
        case cm: CompactionMessage => cm
        case _ => @Fail("expected CompactionMessage as first message")
    }
}

// 嵌套配置优先：compactionEnabled=false + compaction=Some(cc) 仍启用；
// reserve/keepRecent 取自 cc（4096/2000），触发后 LLM 摘要子调用成功且 schema 校验通过
@Test
func runtime_compactionSummaryViaLLM() {
    let opts = HashMap<String, JsonValue>()
    let required = ArrayList<JsonValue>()
    required.add(JsonValue.String("goal"))
    opts["required"] = JsonValue.Array(required)
    let cc = CompactionConfig(true, Int64(4096), Int64(2000), "Summarize: {{conversation}} {{max_tokens}}",
        Some(JsonValue.Map(opts)), None)
    let summaryText = "{\"goal\":\"test\",\"key_findings\":[]}"
    let provider = StubSummaryProvider(summaryText)
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), Some(cc)), provider)
    let msgs = ArrayList<Message>()
    msgs.add(bigUserMessage())
    let result = runtime.chat(msgs).result()
    @Expect(provider.chatCalls, Int64(1))
    let cm = requireCompaction(result)
    @Expect(cm.summary, summaryText)
    @Expect(cm.tokensBefore, Int64(4510))
    // 子调用请求体：仅一条用户消息（无 system/tools），不污染主对话
    match (provider.lastReq) {
        case Some(req) =>
            @Expect(req.messages.size, 1)
            @Expect(req.tools.size, 0)
        case None => @Fail("summary sub-call not issued")
    }
}

// schema 校验失败（非 JSON 输出）→ 降级为占位符摘要
@Test
func runtime_compactionSchemaValidationFallback() {
    let opts = HashMap<String, JsonValue>()
    let required = ArrayList<JsonValue>()
    required.add(JsonValue.String("goal"))
    opts["required"] = JsonValue.Array(required)
    let cc = CompactionConfig(true, Int64(4096), Int64(2000), "Summarize: {{conversation}} {{max_tokens}}",
        Some(JsonValue.Map(opts)), None)
    let provider = StubSummaryProvider("not-a-json")
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), Some(cc)), provider)
    let msgs = ArrayList<Message>()
    msgs.add(bigUserMessage())
    let result = runtime.chat(msgs).result()
    @Expect(provider.chatCalls, Int64(1))
    let cm = requireCompaction(result)
    @Expect(cm.summary.contains("previous tokens summarized"), true)
}

// 平铺配置路径：compaction=None + compactionEnabled=true，子调用抛异常 → 占位符降级
@Test
func runtime_compactionSubCallFailureFallback() {
    let provider = StubFailingProvider()
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(true, UInt32(4096), UInt32(2000), None), provider)
    let msgs = ArrayList<Message>()
    msgs.add(bigUserMessage())
    let result = runtime.chat(msgs).result()
    let cm = requireCompaction(result)
    @Expect(cm.summary.contains("previous tokens summarized"), true)
}

// 用量优先：provider 报告 inputTokens=500000 → 直接用用量判定（本地估算仅兜底），tokensBefore=500000
@Test
func runtime_compactionUsagePriority() {
    let provider = StubUsageSummaryProvider("{\"goal\":\"test\"}")
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(true, UInt32(4096), UInt32(4), None), provider)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()
    @Expect(provider.chatCalls, Int64(1))
    let cm = requireCompaction(result)
    @Expect(cm.summary, "{\"goal\":\"test\"}")
    @Expect(cm.tokensBefore, Int64(500000))
}

// 不触发：消息远小于阈值 → 消息原样返回（无 CompactionMessage），行为与旧版等价
@Test
func runtime_compactionNoTrigger() {
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(true, UInt32(4096), UInt32(2000), None), StubProvider())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()
    @Expect(result.size, 2)
    match (result[0]) {
        case _: CompactionMessage => @Fail("no compaction expected")
        case _ => ()
    }
}

// 捕获流中第一个 AgentStartEvent 的 sessionId
func firstStartSessionId(stream: EventStream<AgentEvent, ArrayList<Message>>): String {
    let ev = stream.receive(5 * Duration.second)
    match (ev) {
        case Some(e: AgentStartEvent) => e.sessionId
        case _ => ""
    }
}

// chatWithSessionId 显式 sessionId → AgentStartEvent 必须携带该 id（不再硬编码 sess_0）
@Test
func runtime_chatWithSessionId_usesProvidedId() {
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), None), StubProvider())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let stream = runtime.chatWithSessionId("sess_custom_1", msgs, SessionEnvironment())
    @Expect(firstStartSessionId(stream), "sess_custom_1")
    stream.result()
}

// chat() 默认生成 ulid 会话 id（sess_ + ulid），不再使用硬编码 sess_0
@Test
func runtime_chat_defaultSessionIdUlid() {
    let runtime = makeCompactionRuntime(
        compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), None), StubProvider())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let stream = runtime.chat(msgs)
    let id = firstStartSessionId(stream)
    @Expect(id.startsWith("sess_"), true)
    @Expect(id != "sess_0", true)
    @Expect(id.size > "sess_".size, true)
    stream.result()
}

// ========== 会话级取消（阶段 1：供 ACP session/cancel 使用） ==========

// 慢流式 Provider：后台每 100ms 发一个文本 delta，共 40 个（全程约 4s），
// 用于验证取消后 runtime 立即收敛、不等 provider 自然结束
class SlowStreamingProvider <: Provider {
    public var chatStreamCalls: Int64 = 0
    public func name(): String { "stub-slow-stream" }

    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.chatStreamCalls++
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            var i: Int64 = 0
            while (i < 40) {
                sleep(Duration.millisecond * 100)
                if (!stream.emit(ChatDelta("x", "", None))) { break }
                i++
            }
            let msg = AssistantMessage(ContentList.ofText("done"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
            stream.setResult(msg)
        }
        stream
    }
}

// 首回合返回 ToolUse（调 slow_tool），后续回合返回 EndTurn；记录流式调用次数
class ToolTurnProvider <: Provider {
    public var chatStreamCalls: Int64 = 0
    public func name(): String { "stub-tool-turn" }

    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.chatStreamCalls++
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            sleep(Duration.millisecond * 20)
            if (this.chatStreamCalls == Int64(1)) {
                // 首回合：请求工具调用
                let args = JsonValue.Map(HashMap<String, JsonValue>())
                let blocks = ArrayList<ContentBlock>()
                blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_1", "slow_tool", args)))
                let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            } else {
                let msg = AssistantMessage(ContentList.ofText("final"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            }
        }
        stream
    }
}

// 慢执行工具：Parallel 模式直接放行（不过信任闸门），delayMs 模拟耗时给取消留窗口
class SlowTool <: Tool {
    private let delayMs: Int64
    public init(delayMs: Int64) { this.delayMs = delayMs }
    public func name(): String { "slow_tool" }
    public func description(): String { "slow tool for cancel tests" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        sleep(Duration.millisecond * this.delayMs)
        ToolResult("slow done", None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

func makeCancelRuntime(provider: Provider, slowMs: Int64): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(SlowTool(slowMs))
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    AgentRuntime(compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), None), provider,
        toolReg, store, trustMgr, skillReg, agentReg, providerReg, McpManager())
}

// 轮询等待 AgentEndEvent（最多 attempts 次 × pollMs），返回是否在限时内结束
func waitAgentEnd(stream: EventStream<AgentEvent, ArrayList<Message>>, attempts: Int64, pollMs: Int64): Bool {
    var i: Int64 = 0
    while (i < attempts) {
        i++
        match (stream.receive(Duration.millisecond * pollMs)) {
            case Some(_: AgentEndEvent) => return true
            case Some(_) => ()
            case None => ()
        }
    }
    false
}

// 流式阶段取消：慢 provider 全程约 4s，取消后 runtime 应在 2s 内收敛（不等待 provider 自然结束）
@Test
func runtime_cancelSession_stopsStreamingPromptly() {
    let provider = SlowStreamingProvider()
    let runtime = makeCancelRuntime(provider, 0)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let stream = runtime.chat(msgs)
    var sid = ""
    match (stream.receive(Duration.millisecond * 1000)) {
        case Some(e: AgentStartEvent) => sid = e.sessionId
        case Some(_) => @Fail("expected AgentStartEvent first")
        case None => @Fail("timeout waiting AgentStartEvent")
    }
    var gotDelta = false
    var i: Int64 = 0
    while (i < 50 && !gotDelta) {
        i++
        match (stream.receive(Duration.millisecond * 100)) {
            case Some(_: MessageUpdateEvent) => gotDelta = true
            case Some(_) => ()
            case None => ()
        }
    }
    @Expect(gotDelta, true)
    let t0 = MonoTime.now()
    runtime.cancelSession(sid)
    let ended = waitAgentEnd(stream, 50, 100)
    let elapsed = MonoTime.now() - t0
    @Expect(ended, true)
    @Expect(elapsed < Duration.millisecond * 2000, true)
    @Expect(provider.chatStreamCalls, Int64(1))
}

// 工具批执行期间取消：工具完成后不得再发起第二轮 provider 请求
@Test
func runtime_cancelSession_stopsBeforeSecondProviderCall() {
    let provider = ToolTurnProvider()
    let runtime = makeCancelRuntime(provider, 500)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("use tool"), 0))
    let stream = runtime.chat(msgs)
    var sid = ""
    var gotMessageEnd = false
    var i: Int64 = 0
    while (i < 60 && (!gotMessageEnd || sid == "")) {
        i++
        match (stream.receive(Duration.millisecond * 100)) {
            case Some(e: AgentStartEvent) => sid = e.sessionId
            case Some(_: MessageEndEvent) => gotMessageEnd = true
            case Some(_) => ()
            case None => ()
        }
    }
    @Expect(gotMessageEnd, true)
    @Expect(sid != "", true)
    runtime.cancelSession(sid)
    let ended = waitAgentEnd(stream, 50, 100)
    @Expect(ended, true)
    @Expect(provider.chatStreamCalls, Int64(1))
}

// 未知会话 / 已结束会话的 cancel 是 no-op，不影响其它运行
@Test
func runtime_cancelSession_unknownOrFinishedNoop() {
    let runtime = makeCancelRuntime(StubProvider(), 0)
    runtime.cancelSession("sess_unknown")
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()
    @Expect(result.size, 2)
    runtime.cancelSession("sess_unknown")
}

// 工具执行开始/结束事件：批执行前发 ToolExecutionStartEvent、完成后发 ToolExecutionEndEvent
@Test
func runtime_toolExecutionEvents_emittedAroundExecution() {
    let provider = ToolTurnProvider()
    let runtime = makeCancelRuntime(provider, 0)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("use tool"), 0))
    let stream = runtime.chat(msgs)
    var sawStart = false
    var sawEnd = false
    var i: Int64 = 0
    while (i < 100) {
        i++
        match (stream.receive(Duration.millisecond * 100)) {
            case Some(e: ToolExecutionStartEvent) =>
                if (sawEnd) { @Fail("tool start after end") }
                sawStart = true
                @Expect(e.toolCallId, "call_1")
                @Expect(e.toolName, "slow_tool")
            case Some(e: ToolExecutionEndEvent) =>
                if (!sawStart) { @Fail("tool end before start") }
                sawEnd = true
                @Expect(e.toolCallId, "call_1")
                @Expect(e.isError, false)
            case Some(_: AgentEndEvent) => break
            case Some(_) => ()
            case None => ()
        }
    }
    @Expect(sawStart, true)
    @Expect(sawEnd, true)
}

// ---------- 工具级授权回调（toolApprovalFn，ACP 权限桥的挂载点） ----------

// Sequential 慢工具：信任 Undecided → NeedsApproval 走授权回调
class SequentialSlowTool <: Tool {
    public func name(): String { "seq_slow_tool" }
    public func description(): String { "sequential slow tool for approval test" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        ToolResult("approved run done", None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

// 首回合 ToolUse 调 seq_slow_tool，后续回合 EndTurn（防无限工具循环）
class SeqToolTurnProvider <: Provider {
    public var streamCalls: Int64 = 0
    public func name(): String { "stub-seq-tool" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.streamCalls++
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            if (this.streamCalls == Int64(1)) {
                let blocks = ArrayList<ContentBlock>()
                blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_a", "seq_slow_tool", JsonValue.Map(HashMap<String, JsonValue>()))))
                let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            } else {
                let msg = AssistantMessage(ContentList.ofText("final"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            }
        }
        stream
    }
}

func makeApprovalRuntime(provider: Provider, approval: ?(ToolCallBlock, String) -> String): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(SequentialSlowTool())
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let r = AgentRuntime(compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), None), provider,
        toolReg, store, trustMgr, skillReg, agentReg, providerReg, McpManager())
    r.toolApprovalFn = approval
    r
}

func lastAssistantTextOf(result: ArrayList<Message>): String {
    var text = ""
    for (m in result) {
        match (m) {
            case am: AssistantMessage =>
                for (b in am.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) => text = t
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    text
}

// toolApprovalFn 返回 "y"（once）→ 工具执行，回合正常收尾
@Test
func runtime_toolApprovalFn_allowsOnce() {
    let calls = ArrayList<String>()
    let provider = SeqToolTurnProvider()
    let approval: ?(ToolCallBlock, String) -> String = { tc, wd =>
        calls.add(tc.id)
        "y"
    }
    let runtime = makeApprovalRuntime(provider, approval)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let result = runtime.chat(msgs).result()
    @Expect(calls.size, 1)
    @Expect(calls[0], "call_a")
    // 工具结果进入会话消息（第二轮 EndTurn 正常收尾）
    var foundToolResult = false
    for (m in result) {
        match (m) {
            case tr: ToolResultMessage =>
                for (b in tr.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) =>
                            if (t == "approved run done") { foundToolResult = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(foundToolResult, true)
}

// toolApprovalFn 返回 ""（deny）→ 工具不执行，结果消息带拒绝说明
@Test
func runtime_toolApprovalFn_denies() {
    let provider = SeqToolTurnProvider()
    let approval: ?(ToolCallBlock, String) -> String = { tc, wd => "" }
    let runtime = makeApprovalRuntime(provider, approval)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let result = runtime.chat(msgs).result()
    var foundDenied = false
    for (m in result) {
        match (m) {
            case tr: ToolResultMessage =>
                for (b in tr.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) =>
                            if (t.contains("denied approval")) { foundDenied = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(foundDenied, true)
}

// toolApprovalFn 为 None（默认）→ 走文本 askUser（deny：空返回）
// 用 Box 承载可变状态（仓颉限制：lambda 不可捕获可变局部变量）
class AskBox {
    public var asked: Bool = false
    public init() {}
}

@Test
func runtime_toolApprovalFn_defaultFallsBackToAskUser() {
    let box = AskBox()
    let provider = SeqToolTurnProvider()
    let toolReg = ToolRegistry()
    toolReg.register(SequentialSlowTool())
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let rt = AgentRuntime(compactionRuntimeConfig(false, UInt32(16384), UInt32(20000), None), provider,
        toolReg, store, trustMgr, skillReg, agentReg, providerReg,
        ArrayList<Hook>(), { q => box.asked = true; "" }, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let result = rt.chat(msgs).result()
    @Expect(box.asked, true)
    // askUser deny → 工具被跳过（结果含拒绝消息）
    var foundDenied = false
    for (m in result) {
        match (m) {
            case tr: ToolResultMessage =>
                for (b in tr.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) =>
                            if (t.contains("denied approval")) { foundDenied = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(foundDenied, true)
}

// ========== ProviderMiddleware：请求级中间件链（wrap 顺序/透传/零行为变化） ==========

// 计数中间件：wrap 次数 + 委托请求计数（chatStreaming 每请求一次）
class CountingMiddleware <: ProviderMiddleware {
    public var wraps: Int64 = 0
    public var streamCalls: Int64 = 0
    public var chatCalls: Int64 = 0
    public func wrap(provider: Provider): Provider {
        this.wraps++
        CountingWrapper(this, provider)
    }
}

class CountingWrapper <: Provider {
    private let outer: CountingMiddleware
    private let inner: Provider
    public init(outer: CountingMiddleware, inner: Provider) {
        this.outer = outer
        this.inner = inner
    }
    public func name(): String { this.inner.name() }
    public func chat(req: ChatRequest): ChatResponse {
        this.outer.chatCalls++
        this.inner.chat(req)
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.outer.streamCalls++
        this.inner.chatStreaming(req)
    }
}

@Test
public func runtime_middlewaresWrappedInOrderAndApplied() {
    let inner = StubProvider()
    let m1 = CountingMiddleware()
    let m2 = CountingMiddleware()
    let mws = ArrayList<ProviderMiddleware>()
    mws.add(m1)
    mws.add(m2)
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", inner)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let runtime = AgentRuntime(subConfig(), inner, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, ArrayList<Hook>(), { q => "" },
        SessionEnvironment(), mcpMgr, middlewares: mws)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let result = runtime.chat(msgs).result()
    @Expect(result.size >= Int64(1), true)
    // 两个中间件均被 wrap；请求确实穿过包装链
    @Expect(m1.wraps, Int64(1))
    @Expect(m2.wraps, Int64(1))
    @Expect(m1.streamCalls >= Int64(1), true)
    @Expect(m2.streamCalls >= Int64(1), true)
    @Expect(m1.chatCalls >= Int64(0), true)
}

// SessionLoop 下传 middlewares（子 agent/ACP 桥回合生效）
@Test
public func sessionLoop_forwardsMiddlewares() {
    let inner = StubProvider()
    let mw = CountingMiddleware()
    let mws = ArrayList<ProviderMiddleware>()
    mws.add(mw)
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", inner)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr,
        middlewares: mws)
    let cfg = subConfig()
    let outcome = loop.run("sess_mw", "你好", cfg, inner, None, SessionEnvironment(),
        { => false }, { => false })
    @Expect(outcome.messages.size >= Int64(1), true)
    @Expect(mw.wraps, Int64(1))
    @Expect(mw.streamCalls >= Int64(1), true)
}
