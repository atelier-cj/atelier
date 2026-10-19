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
        base.compactionEnabled, base.compaction, base.maxToolCalls, base.toolTimeout, base.minToolInterval,
        base.tags, base.createdBy, base.createdAt, base.updatedAt,
        maxVerifyPasses: n)
}

func withContinuations(base: AgentConfig, n: UInt32): AgentConfig {
    AgentConfig(base.name, base.description, base.systemPrompt, base.userPromptTemplate,
        base.model, base.provider, base.tools, base.skills, base.mcpCooldownTurns,
        base.maxTurns, base.temperature, base.maxOutputTokens, base.thinkingLevel,
        base.compactionEnabled, base.compaction, base.maxToolCalls, base.toolTimeout, base.minToolInterval,
        base.tags, base.createdBy, base.createdAt, base.updatedAt,
        maxLengthContinuations: n)
}

// 只改工具调用预算（其余沿用 base），用于构造「预算很小/为 0」的场景
func withMaxToolCalls(base: AgentConfig, n: UInt32): AgentConfig {
    AgentConfig(base.name, base.description, base.systemPrompt, base.userPromptTemplate,
        base.model, base.provider, base.tools, base.skills, base.mcpCooldownTurns,
        base.maxTurns, base.temperature, base.maxOutputTokens, base.thinkingLevel,
        base.compactionEnabled, base.compaction, n, base.toolTimeout, base.minToolInterval,
        base.tags, base.createdBy, base.createdAt, base.updatedAt)
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

// ---- 工具调用预算耗尽（Exhausted）时的历史不变式 ----
//
// 预算用完的裁决发生在**工具批次执行之前**：本批一个调用都不执行，但 assistant 消息里
// 已经带着这些调用。历史里「每个 tool_call 恰好一条配对结果」是发请求的硬前提
// （见 history_invariant.cj），因此这一步也必须为每个调用各回一条结果 —— 而且不能回
// 一条 id 为空的结果：空 id 对不上任何调用，落库后就是永久留存的脏历史。

// 在历史里按调用 id 收集结果正文；同时统计 id 为空的结果条数
func toolResultTexts(messages: ArrayList<Message>): (HashMap<String, String>, Int64) {
    let texts = HashMap<String, String>()
    var emptyIds: Int64 = 0
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolCallId == "") {
                    emptyIds++
                } else {
                    texts[tr.toolCallId] = textOfMsg(tr)
                }
            case _ => ()
        }
    }
    (texts, emptyIds)
}

// 预算在第二批之前就用完（used=1 >= max=1）：第二批的 2 个调用全部不执行，
// 但两个都必须有各自的配对结果，且历史里不能出现 id 为空的结果。
@Test
func runtime_budgetExhausted_pairsEveryToolCall() {
    let calls = ArrayList<(String, String)>()
    calls.add(("c2", "noop"))
    calls.add(("c3", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("第一批", "noop", "c1"))
    responses.add(assistantWithCalls("第二批", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = RecordingMsgProvider(responses)
    let result = runRecording(withMaxToolCalls(AgentConfig.default(), 1), provider)

    // 第一批执行完，第二批因预算耗尽收尾：不再发起第三次请求
    @Expect(provider.callCount, 2)
    let (texts, emptyIds) = toolResultTexts(result)
    @Expect(emptyIds, Int64(0))
    @Expect(texts.size, Int64(3))
    @Expect(texts.contains("c1"), true)
    @Expect(texts.contains("c2"), true)
    @Expect(texts.contains("c3"), true)
    // 被跳过的调用要说明「为什么没跑」，措辞与 Trimmed 分支同一来源
    @Expect(texts["c2"], skippedByToolBudgetNote())
    @Expect(texts["c3"], skippedByToolBudgetNote())
    // 交叉校验：统一收口函数认为历史已经合法（补 0 条）
    @Expect(ensureToolCallResults(result), Int64(0))
}

// 预算为 0：第一批就要耗尽，且这一批里的每个调用同样各有一条配对结果
@Test
func runtime_budgetExhaustedOnFirstBatch_pairsEveryToolCall() {
    let calls = ArrayList<(String, String)>()
    calls.add(("a1", "noop"))
    calls.add(("a2", "noop"))
    calls.add(("a3", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCalls("一次要三个", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = RecordingMsgProvider(responses)
    let result = runRecording(withMaxToolCalls(AgentConfig.default(), 0), provider)

    @Expect(provider.callCount, 1)
    let (texts, emptyIds) = toolResultTexts(result)
    @Expect(emptyIds, Int64(0))
    @Expect(texts.size, Int64(3))
    @Expect(ensureToolCallResults(result), Int64(0))
}

// Trimmed 分支（部分裁剪）与 Exhausted 分支同口径：被裁掉的那部分同样是「预算不足未执行」
@Test
func runtime_budgetTrimmed_pairsTrimmedCallsWithBudgetNote() {
    let calls = ArrayList<(String, String)>()
    calls.add(("c2", "noop"))
    calls.add(("c3", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("第一批", "noop", "c1"))
    responses.add(assistantWithCalls("第二批", calls))
    responses.add(endTurnMsg("收尾"))
    let provider = RecordingMsgProvider(responses)
    // used=1，max=2，本批 2 个 → Trimmed(1)：c2 执行、c3 跳过
    let result = runRecording(withMaxToolCalls(AgentConfig.default(), 2), provider)

    let (texts, emptyIds) = toolResultTexts(result)
    @Expect(emptyIds, Int64(0))
    @Expect(texts.contains("c3"), true)
    @Expect(texts["c3"], skippedByToolBudgetNote())
    @Expect(ensureToolCallResults(result), Int64(0))
    // 裁剪后继续跑：后面还有请求
    @Expect(provider.callCount, 3)
}

// 预算耗尽收尾的那次 TurnEndEvent 也要带着这批结果：消费方按它渲染「本轮工具结果」，
// 给空列表等于结果在事件流里消失（只有从 result() 才看得到）
class TurnEndCollector {
    public let results = ArrayList<ArrayList<ToolResultMessage>>()
    public init(bus: EventBus) {
        bus.subscribe({ ev =>
            match (ev) {
                case e: TurnEndEvent => this.results.add(e.toolResults)
                case _ => ()
            }
        })
    }
}

@Test
func runtime_budgetExhausted_turnEndCarriesSkippedResults() {
    let bus = EventBus()
    let collector = TurnEndCollector(bus)
    let calls = ArrayList<(String, String)>()
    calls.add(("c2", "noop"))
    calls.add(("c3", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("第一批", "noop", "c1"))
    responses.add(assistantWithCalls("第二批", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = RecordingMsgProvider(responses)
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = testRuntime(withMaxToolCalls(AgentConfig.default(), 1), provider,
        toolReg, MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, ArrayList<Hook>(), SessionEnvironment(), McpManager(),
        eventBus: Some(bus))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    runtime.chat(msgs).result()

    // 第一个回合有 1 条结果（c1），第二个回合（预算耗尽）有 2 条
    @Expect(collector.results.size, Int64(2))
    @Expect(collector.results[1].size, Int64(2))
    let ids = ArrayList<String>()
    for (tr in collector.results[1]) { ids.add(tr.toolCallId) }
    @Expect(ids.contains("c2"), true)
    @Expect(ids.contains("c3"), true)
}
