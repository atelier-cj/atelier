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

func runGate(askAnswer: Option<UserAnswer>, sessionId!: String = "s1",
    extra!: ArrayList<Message> = ArrayList()): (ArrayList<AgentEvent>, GatedTool) {
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
        SkillRegistry(), AgentRegistry(), preg, ArrayList<Hook>(), McpManager(),
        ask: askImpl)
    let input = ArrayList<Message>()
    input.add(UserMessage(ContentList.ofText("跑一下"), 0))
    for (m in extra) { input.add(m) }
    // 指定 sessionId：闸门请求 id 里含 sessionId/turn，两趟必须一致才对得上
    let stream = runtime.chatWithSessionId(sessionId, input, SessionEnvironment())
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


func kindsOf(events: ArrayList<AgentEvent>): String {
    let parts = ArrayList<String>()
    for (e in events) { parts.add(e.eventType()) }
    String.join(parts.toArray(), delimiter: ",")
}

func suspendRequestIds(events: ArrayList<AgentEvent>): ArrayList<String> {
    let out = ArrayList<String>()
    for (e in events) {
        match (e) {
            case se: SuspendEvent =>
                for (r in se.requests) { out.add(r.id) }
            case _ => ()
        }
    }
    out
}

@Test
func askSuspend_pendingSuspendsRunWithoutExecuting() {
    // 第一趟：宿主返回 Pending → 发 SuspendEvent、本轮工具一个都不执行
    let pending = UserAnswer("ignored", UserAnswerStatus.Pending)
    let (events, tool) = runGate(Some(pending))
    @Expect(tool.executed, 0)
    @Expect(kindsOf(events).contains("suspend"), true)
    let ids = suspendRequestIds(events)
    @Expect(ids.size, 1)
    // 请求 id 带 kind 后缀，且以 approval 结尾（审批 = confirmation 语义）
    @Expect(ids[0].contains("call_g"), true)
    @Expect(ids[0].endsWith("approval"), true)
}

@Test
func askSuspend_resumeWithAnswerExecutesOnce() {
    // 第二趟（同 session、同回合 → 请求 id 不变）：答复随消息带回 → 工具执行一次
    let pending = UserAnswer("ignored", UserAnswerStatus.Pending)
    let (_, tool1) = runGate(Some(pending))
    @Expect(tool1.executed, 0)
    // 先拿到第一趟的请求 id（宿主就是这么知道要回哪个 id 的）
    let (events1, _) = runGate(Some(pending))
    let ids = suspendRequestIds(events1)
    @Expect(ids.size, 1)

    // 第二趟：把答复挂进消息元数据（真实路径：AG-UI 的 resume[].payload → 消息）
    let answer = UserAnswer(ids[0], UserAnswerStatus.Answered,
        selected: ArrayList<String>(["allow_once"]))
    let extra = ArrayList<Message>()
    extra.add(UserMessage(ContentList.ofText("同意"), 0, metadata: encodeAnswer(answer)))
    // 这一趟宿主"没有"结构化 ask（None）也应当能恢复：答复优先于任何提问通道
    let (events2, tool2) = runGate(None, extra: extra)
    @Expect(tool2.executed, 1)
    @Expect(kindsOf(events2).contains("suspend"), false)
}
