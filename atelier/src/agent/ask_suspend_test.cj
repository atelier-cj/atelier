package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.interaction.*
import atelier.event.EventStream

// 结构化提问（可选升级）的接线：宿主提供 ask 实现后，
// ① 审批走它（优先于审批桥与字符串适配器）；
// ② 它能返回 Pending —— 这是"挂起"的唯一来源，字符串通道表达不了。
// 挂起本体（结束 run + 落盘已完成结果）在下一步，这里先锁"接线正确 + Pending 不被当拒绝"。

class GatedTool <: Tool {
    public var executed: Int64 = 0
    public func name(): String { "gated" }
    public func description(): String { "需要审批的工具" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.executed++
        ToolResult("done", None, false, false)
    }
    // 必须是 Sequential：Parallel 工具按设计恒定放行（不过信任闸门）
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

class GateProvider <: Provider {
    public let responses: ArrayList<AssistantMessage>
    public var callCount: Int64 = 0
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "fake" }
    public func chat(req: ChatRequest): ChatResponse {
        let i = this.callCount % this.responses.size
        this.callCount++
        ChatResponse(this.responses[Int64(i)])
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let s = EventStream<ChatDelta, AssistantMessage>()
        let i = this.callCount % this.responses.size
        this.callCount++
        let m = this.responses[Int64(i)]
        s.emit(ChatDelta("", "", Some(m.stopReason)))
        s.setResult(m)
        s
    }
}

func gateEndTurn(text: String): AssistantMessage {
    AssistantMessage(ContentList.ofText(text), "m", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

func gatedToolUse(): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_g", "gated",
        JsonValue.Map(HashMap<String, JsonValue>()))))
    AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

func runGate(askAnswer: Option<UserAnswer>): (ArrayList<AgentEvent>, GatedTool) {
    let tool = GatedTool()
    let reg = ToolRegistry()
    reg.register(tool)
    let provider = GateProvider(ArrayList<AssistantMessage>([gatedToolUse(), gateEndTurn("好了")]))
    let preg = ProviderRegistry()
    preg.register("default", provider)
    // 工具所在目录未受信 → 会走审批
    let trust = TrustManager()
    // 宿主必须回显请求 id：runtime 侧 validateAnswer 会校验 requestId 一致
    // （编一个 id 的答复会被判为无效并当拒绝处理 —— 这是刻意的防线）
    let askImpl: Option<AskFn> = match (askAnswer) {
        case Some(a) => Some({ req: UserRequest =>
            UserAnswer(req.id, a.status, selected: a.selected, text: a.text,
                values: a.values, editedArgs: a.editedArgs)
        })
        case None => None
    }
    let runtime = AgentRuntime(AgentConfig.default(), provider, reg, MemorySessionStore(), trust,
        SkillRegistry(), AgentRegistry(), preg, ArrayList<Hook>(), { q => "" }, McpManager(),
        ask: askImpl)
    let stream = runtime.chat(ArrayList<Message>([UserMessage(ContentList.ofText("跑一下"), 0)]))
    let events = ArrayList<AgentEvent>()
    var done = false
    while (!done) {
        match (stream.receive(30 * Duration.second)) {
            case Some(ev) =>
                events.add(ev)
                match (ev) { case _: AgentEndEvent => done = true; case _ => () }
            case None => done = true
        }
    }
    (events, tool)
}

@Test
func askSuspend_hostAnswerAllowsTool() {
    // 宿主结构化答复"允许一次" → 工具执行
    let allow = UserAnswer("ask::1:call_g:approval", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    let (_, tool) = runGate(Some(allow))
    @Expect(tool.executed, 1)
}

@Test
func askSuspend_pendingIsNotADenial() {
    // Pending 是"挂起"，不是"拒绝"：这一步先保证接线正确（挂起本体在下一步落地）。
    // 关键不变量：Pending 绝不能被当成 allow（否则没经用户同意就执行了工具）
    let pending = UserAnswer("ask::1:call_g:approval", UserAnswerStatus.Pending)
    let (_, tool) = runGate(Some(pending))
    @Expect(tool.executed, 0)
}

@Test
func askSuspend_denyBlocksTool() {
    let deny = UserAnswer("ask::1:call_g:approval", UserAnswerStatus.Answered,
        selected: ArrayList<String>(["deny"]))
    let (_, tool) = runGate(Some(deny))
    @Expect(tool.executed, 0)
}
