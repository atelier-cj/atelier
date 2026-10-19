package atelier.agent

/*
 * 交还历史前的收口（[AgentRuntime.settleHistory]）。
 *
 * 契约：`result()` / 事件流交还的历史，必须满足「每个 tool_call 恰好一条配对结果」
 * （见 history_invariant.cj）。发请求前的那次收口只覆盖"下一次请求"，而循环的**最后
 * 一次迭代之后**没有请求了 —— 那一轮写下的历史直接交还给宿主落库，中间的脏会永久留存。
 *
 * 因此交还点（正常收尾与异常收尾）各收口一次。这里盯的是**交还出来的东西**，
 * 而不是某条具体写入路径：新增路径不必记得这条规则。
 *
 * 例外是挂起：历史刻意停在 `assistant(tool_calls)`、结果等下一次 run 带回，
 * 此时补占位结果不是修历史而是伪造（见 [RunScope.suspended]）。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.interaction.*
import atelier.event.EventStream
import jsonvalue.*

// 交还历史里"未配对的 tool_call 数"：0 = 历史合法
func unpairedAtReturn(messages: ArrayList<Message>): Int64 {
    let copy = ArrayList<Message>()
    for (m in messages) { copy.add(m) }
    ensureToolCallResults(copy)
}

func countEmptyIdResults(messages: ArrayList<Message>): Int64 {
    var n: Int64 = 0
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage => if (tr.toolCallId == "") { n++ }
            case _ => ()
        }
    }
    n
}

// 最后一条是否是带调用的 assistant（挂起锚点的形状）
func endsWithAssistantToolCalls(messages: ArrayList<Message>): Bool {
    if (messages.size == 0) { return false }
    match (messages[messages.size - 1]) {
        case am: AssistantMessage => return am.toolCalls().size > 0
        case _ => false
    }
}

func emptyHistoryRuntime(cfg: AgentConfig, provider: Provider,
    toolReg: ToolRegistry): AgentRuntime {
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    testRuntime(cfg, provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), McpManager())
}

// 最后一轮因预算耗尽收尾：那一轮写下的历史上没有下一次请求来救它，
// 交还时必须已经是合法历史。
@Test
func runtime_settleHistory_budgetExhaustedOnLastTurn() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("x2", "noop"))
    calls.add(("x3", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("第一批", "noop", "x1"))
    responses.add(assistantWithCalls("第二批", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let runtime = emptyHistoryRuntime(withMaxToolCalls(AgentConfig.default(), 1), provider, toolReg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let history = runtime.chat(msgs).result()

    @Expect(unpairedAtReturn(history), Int64(0))
    @Expect(countEmptyIdResults(history), Int64(0))
}

// 非工具回合（EndTurn）却带着 tool_call：这些调用没有执行，但必须有配对结果。
// 该轮是最后一轮 → 只有交还点的收口能救。
@Test
func runtime_settleHistory_endTurnWithToolCallsOnLastTurn() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("g1", "noop"))
    calls.add(("g2", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCallsRaw("这条消息带着调用却报了回合结束", calls, StopReason.EndTurn))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let runtime = emptyHistoryRuntime(AgentConfig.default(), provider, toolReg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let history = runtime.chat(msgs).result()

    @Expect(unpairedAtReturn(history), Int64(0))
    @Expect(countEmptyIdResults(history), Int64(0))
    // 两个孤儿调用都要有各自的占位结果
    var g1 = false
    var g2 = false
    for (m in history) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolCallId == "g1") { g1 = true }
                if (tr.toolCallId == "g2") { g2 = true }
            case _ => ()
        }
    }
    @Expect(g1, true)
    @Expect(g2, true)
}

// 交还点在**异常路径**上同样生效：run 因异常提前收敛，抛出前写下的历史必须已经合法。
// 用"钩子抛异常导致 run 中途收敛"不好构造，这里改用 provider 失败：
// 失败消息写进历史后 run 直接收尾，那一轮若带着 tool_calls 就只有交还点能兜住。
@Test
func runtime_settleHistory_providerFailureOnLastTurn() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("f1", "noop"))
    // provider 报工具回合，但下一轮调用直接失败
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCallsRaw("调用被截断", calls, StopReason.Length))
    let provider = FailingAfterFirstProvider(responses)
    let runtime = emptyHistoryRuntime(AgentConfig.default(), provider, toolReg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let history = runtime.chat(msgs).result()

    // 交还的历史必须合法：无论中途哪一步失败
    @Expect(unpairedAtReturn(history), Int64(0))
    @Expect(countEmptyIdResults(history), Int64(0))
}

// 首次正常、之后抛异常的 provider
class FailingAfterFirstProvider <: Provider {
    public var calls: Int64 = 0
    private let responses: ArrayList<AssistantMessage>
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "failing" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls++
        if (this.calls > 1) { throw Exception("boom") }
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = this.responses[0]
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// 挂起：历史**刻意**停在 assistant(tool_calls)、不写结果（结果由下一次 run 带回）。
// 收口必须认这个状态 —— 补占位结果等于伪造，恢复时会多出一条与本调用不对应的结果。
@Test
func runtime_settleHistory_suspendKeepsHistoryOpen() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(suspendToolUseMsg("ext", "call_1"))
    let provider = SuspendProbeProvider(responses)
    let store = MemorySessionStore()
    let events = chatWith(provider, ArrayList<Tool>([ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)]), "s_settle")
    @Expect(eventKinds(events).contains("suspend"), true)
    let history = store.load("s_settle")

    // 没有结果消息，且历史停在 assistant(tool_calls)
    var toolResults = 0
    for (m in history) {
        match (m) {
            case _: ToolResultMessage => toolResults++
            case _ => ()
        }
    }
    @Expect(toolResults, Int64(0))
    @Expect(endsWithAssistantToolCalls(history), true)
}
