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

// 输出被 provider 的 token 上限截断：stopReason = Length，内容只是「没写完」。
func lengthPartialMsg(text: String): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.Length, TokenUsage(0, 0), 0)
}

func endTurnMsg(text: String): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

// StopReason.ToolUse：让 run 进入下一回合（EndTurn 会直接收尾）
func toolUseMsg(text: String, tool: String, id: String): AssistantMessage {
    let tc = ToolCallBlock(id, tool, JsonValue.Map(HashMap<String, JsonValue>()))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    blocks.add(ContentBlock.ToolCall(tc))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

class NoopTool <: Tool {
    public func name(): String { "noop" }
    public func description(): String { "noop" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

class ScriptedMsgProvider <: Provider {
    public var responses: ArrayList<AssistantMessage>
    public var callCount: Int64 = 0
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse {
        let idx = this.callCount % this.responses.size
        this.callCount++
        ChatResponse(this.responses[idx])
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let idx = this.callCount % this.responses.size
        this.callCount++
        let msg = this.responses[idx]
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func withVerify(base: AgentConfig, n: UInt32): AgentConfig {
    AgentConfig(base.name, base.description, base.systemPrompt, base.userPromptTemplate,
        base.model, base.provider, base.tools, base.skills, base.mcpCooldownTurns,
        base.maxTurns, base.temperature, base.maxOutputTokens, base.thinkingLevel,
        base.compactionEnabled, base.compactionReserveTokens, base.keepRecentTokens,
        base.compaction, base.maxToolCalls, base.toolTimeout, base.minToolInterval,
        base.tags, base.createdBy, base.createdAt, base.updatedAt,
        maxVerifyPasses: n)
}

func withContinuations(base: AgentConfig, n: UInt32): AgentConfig {
    AgentConfig(base.name, base.description, base.systemPrompt, base.userPromptTemplate,
        base.model, base.provider, base.tools, base.skills, base.mcpCooldownTurns,
        base.maxTurns, base.temperature, base.maxOutputTokens, base.thinkingLevel,
        base.compactionEnabled, base.compactionReserveTokens, base.keepRecentTokens,
        base.compaction, base.maxToolCalls, base.toolTimeout, base.minToolInterval,
        base.tags, base.createdBy, base.createdAt, base.updatedAt,
        maxLengthContinuations: n)
}

func runScripted(config: AgentConfig, provider: Provider): ArrayList<Message> {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let sessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = testRuntime(config, provider, toolReg, sessionStore, trustMgr,
        skillReg, agentReg, providerReg, ArrayList<Hook>(), McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("把大文件写完"), 0))
    runtime.chat(msgs).result()
}

// 被截断不是回合结束：同一回合内应当再请求一次，把内容接着写完。
@Test
func runtime_lengthStop_continuesInSameTurn() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("前半段"))
    responses.add(endTurnMsg("后半段"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(AgentConfig.default(), provider)
    @Expect(provider.callCount, 2)
    // 用户 + 半截回复 + 续跑提示 + 续跑回复
    @Expect(result.size, 4)
}

// 续跑预算 0 = 保持旧行为（截断即回合结束），用于需要严格「一问一答」的场景。
@Test
func runtime_lengthStop_zeroBudgetEndsTurn() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("半截"))
    responses.add(endTurnMsg("本来可以续跑"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(withContinuations(AgentConfig.default(), 0), provider)
    @Expect(provider.callCount, 1)
    @Expect(result.size, 2)
}

// 预算用尽后必须收尾，不能无限续跑。
@Test
func runtime_lengthStop_budgetExhaustedStops() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("截断1"))
    responses.add(lengthPartialMsg("截断2"))
    responses.add(endTurnMsg("永远不会被请求"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(withContinuations(AgentConfig.default(), 1), provider)
    // 首次 + 1 次续跑 = 2；第二次仍被截断但预算已尽 → 收尾
    @Expect(provider.callCount, 2)
    // 用户 + 截断1 + 续跑提示 + 截断2
    @Expect(result.size, 4)
}

// 续跑预算按回合重置：第 1 回合用掉 1 次（截断 → 续跑 → 调工具）后，
// 第 2 回合仍应有 1 次可用（再截断 → 再续跑 → 收尾）。
@Test
func runtime_lengthStop_budgetResetsEachTurn() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("t1 截断"))
    responses.add(toolUseMsg("t1 续跑后调工具", "noop", "call_1"))
    responses.add(lengthPartialMsg("t2 截断"))
    responses.add(endTurnMsg("t2 续跑结束"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(withContinuations(AgentConfig.default(), 1), provider)
    @Expect(provider.callCount, 4)
    @Expect(result.size >= 5, true)
}

// 收尾前自验：模型在「做过事且宣布完成」的回合里，先被要求实操核对再收尾。
@Test
func runtime_verifyBeforeFinish_injectsOnePass() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("先做点事", "noop", "call_1"))
    responses.add(endTurnMsg("我完成了"))
    responses.add(endTurnMsg("核对后确认完成"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(withVerify(AgentConfig.default(), 1), provider)
    // 首回合调工具 + 宣布完成 + 自验回合 = 3 次请求
    @Expect(provider.callCount, 3)
}

// 默认关闭（0）：交互场景不会被自动追问打扰。
@Test
func runtime_verifyBeforeFinish_disabledByDefault() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("做点事", "noop", "call_1"))
    responses.add(endTurnMsg("完成"))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(AgentConfig.default(), provider)
    @Expect(provider.callCount, 2)
}

// 没做过任何事（直接聊天式回答）时不触发自验。
@Test
func runtime_verifyBeforeFinish_skipsWhenNoWork() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("你好"))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let result = runScripted(withVerify(AgentConfig.default(), 1), provider)
    @Expect(provider.callCount, 1)
}

// ---- 历史的 tool_call 配对（provider 判 400 的那条不变式）----
//
// 记录每次请求真正发出去的历史：消息对象会被后续回合改写，故按值快照一份。
class RecordingMsgProvider <: Provider {
    public var responses: ArrayList<AssistantMessage>
    public var callCount: Int64 = 0
    public var requests: ArrayList<ArrayList<Message>> = ArrayList<ArrayList<Message>>()
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse { ChatResponse(this.responses[0]) }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let snapshot = ArrayList<Message>()
        for (m in req.messages) { snapshot.add(m) }
        this.requests.add(snapshot)
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let idx = this.callCount % this.responses.size
        this.callCount++
        let msg = this.responses[idx]
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func runRecording(config: AgentConfig, provider: Provider): ArrayList<Message> {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = testRuntime(config, provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("把大文件写完"), 0))
    runtime.chat(msgs).result()
}

// 截断（Length）的回复里可能已经带上完整 tool_call：这条消息不是纯工具回合，
// 但它带的调用**必须**有配对结果，否则下一次请求被判 400，整轮作废。
@Test
func runtime_truncatedWithToolCalls_sendsOnlyPairedHistory() {
    let calls = ArrayList<(String, String)>()
    calls.add(("c1", "noop"))
    calls.add(("c2", "noop"))
    let truncated = assistantWithCallsRaw("我打算跑两个命令", calls, StopReason.Length)
    let responses = ArrayList<AssistantMessage>()
    responses.add(truncated)
    responses.add(endTurnMsg("续跑后收尾"))
    let provider = RecordingMsgProvider(responses)
    runRecording(withContinuations(AgentConfig.default(), 1), provider)
    @Expect(provider.callCount, 2)
    // 第二次请求发出的历史里，两个调用都要有结果
    let sent = provider.requests[1]
    var gotC1 = false
    var gotC2 = false
    for (m in sent) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolCallId == "c1") { gotC1 = true }
                if (tr.toolCallId == "c2") { gotC2 = true }
            case _ => ()
        }
    }
    @Expect(gotC1, true)
    @Expect(gotC2, true)
}

// 终止原因缺失被 provider 归成 EndTurn、却带了 tool_call：同样不能漏配对结果。
// 场景对齐真实失败：前面回合调过工具（toolCallCount > 0），这一条带着调用报回合结束，
// 自验把回合续下去 —— 续下去的那次请求必须已经补好配对结果。
@Test
func runtime_endTurnWithToolCalls_sendsOnlyPairedHistory() {
    let calls = ArrayList<(String, String)>()
    calls.add(("d1", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("先做点事", "noop", "call_1"))
    responses.add(assistantWithCallsRaw("这条消息带着调用却报了回合结束", calls, StopReason.EndTurn))
    responses.add(endTurnMsg("收尾"))
    let provider = RecordingMsgProvider(responses)
    runRecording(withVerify(AgentConfig.default(), 1), provider)
    @Expect(provider.callCount, 3)
    var gotD1 = false
    for (m in provider.requests[2]) {
        match (m) {
            case tr: ToolResultMessage => if (tr.toolCallId == "d1") { gotD1 = true }
            case _ => ()
        }
    }
    @Expect(gotD1, true)
}

// provider 报了工具回合却没给任何调用：不能空转（每轮请求都一样会把回合预算烧光）
@Test
func runtime_toolUseWithoutCalls_endsTurnInsteadOfSpinning() {
    let empty = assistantWithCallsRaw("忘了放调用", ArrayList<(String, String)>(), StopReason.ToolUse)
    let responses = ArrayList<AssistantMessage>()
    responses.add(empty)
    responses.add(endTurnMsg("不应该被请求"))
    let provider = RecordingMsgProvider(responses)
    runRecording(AgentConfig.default(), provider)
    @Expect(provider.callCount, 1)
}
