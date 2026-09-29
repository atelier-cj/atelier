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
    let runtime = AgentRuntime(config, provider, toolReg, sessionStore, trustMgr,
        skillReg, agentReg, providerReg, ArrayList<Hook>(), { q => "" }, McpManager())
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
