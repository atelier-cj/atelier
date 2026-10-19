package atelier.agent

/*
 * 工具批次收尾的三种语义（[ToolBatchOutcome]）。
 *
 * 三条走向都发 `TurnEndEvent` 结束当前回合，但**对历史与对宿主的意义完全不同**：
 *
 * - ContinueRun：本批做完，接着下一轮。
 * - SuspendedForExternal：有调用在**等外部输入**。历史刻意停在 `assistant(tool_calls)`、
 *   不写结果（结果由下一次 run 随宿主答复带回），并发 `SuspendEvent` 让宿主知道
 *   "这次不是跑完了，是在等你"。这是唯一允许历史不配对的收尾方式。
 * - BatchFailed：整批执行抛了异常，已为每个 call 补齐错误结果。历史是**完整**的，
 *   既不该发 `SuspendEvent`（宿主会一直等一个不会来的输入），也不该让收尾收口跳过
 *   （那会在历史里留下真正的漏洞）。
 *
 * 这两条"停止本次 run 但不是挂起"的路径共用一个枚举值时，上述两件事都会被做错 ——
 * 因此本文件分别锁住它们的**事件形状**与**历史配对**。
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

// 执行时抛异常的工具。
//
// `executeTool` 加上单工具异常隔离之后，**两种预算配置下**异常都会变成一条 isError
// 结果（此前无预算时会被直通到批次层）。所以本工具现在无论怎么配都走"回合继续"，
// 不再是"整批失败"的构造手段 —— 那个状态改由框架层异常触发
// （见 tool/executor_isolation_test.cj 的元数据异常用例）。
// 两类预算置 0 的配置保留着：它锁的正是"无预算分支也被隔离"这一点。
class ExplodingTool <: Tool {
    public func name(): String { "boom" }
    public func description(): String { "always throws" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        throw Exception("tool exploded")
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

// 审批一律放行：本文件关注的是"批次执行"的形状，不是信任闸门。
// （默认 TrustManager 是未决状态 → 工具会走审批；没有 ask 通道时按拒绝处理，
//   工具根本不会执行，观察不到批次收尾路径。这是实测踩到的。）
func allowAllAsk(): AskFn {
    { req: UserRequest =>
        let sel = ArrayList<String>()
        sel.add("allow_always")
        UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
    }
}

func nameListAttr(names: Array<String>): ArrayList<String> {
    let l = ArrayList<String>()
    for (n in names) { l.add(n) }
    l
}

// 收集流里所有事件，按类型名判断形状
func drainEventTypes(stream: EventStream<AgentEvent, ArrayList<Message>>): ArrayList<String> {
    let kinds = ArrayList<String>()
    var done = false
    while (!done) {
        match (stream.receive(50 * Duration.millisecond)) {
            case Some(ev) => kinds.add(ev.eventType())
            case None => if (stream.isClosed()) { done = true }
        }
    }
    kinds
}

func hasEventKind(kinds: ArrayList<String>, kind: String): Bool {
    for (k in kinds) {
        if (k == kind) { return true }
    }
    false
}

// 工具执行抛异常 → **回合继续**（不是整批失败收尾），每 call 仍各有结果。
//
// 这条此前断言"整批失败后收尾、不再发第二次请求"。`executeTool` 加上单工具异常隔离
// 之后，工具抛错只是一条 isError 结果，回合照常往下走 —— 正好是想要的行为
// （与 pi 一致：单工具失败不该让整轮作废）。
//
// 保留它原有的配对断言（历史完整、收口补 0 条），只把终点从"整批失败收尾"
// 改成"继续下一轮"。`BatchFailed` 此后只由**框架层**异常触发（见
// executor_isolation_test.cj 的元数据异常用例）。
@Test
func runtime_toolExceptionKeepsTurnGoing() {
    let responses = ArrayList<AssistantMessage>()
    let calls = ArrayList<(String, String)>()
    calls.add(("b1", "boom"))
    calls.add(("b2", "boom"))
    responses.add(assistantWithCalls("跑两个", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let toolReg = ToolRegistry()
    toolReg.register(ExplodingTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = testRuntime(AgentConfig("t", None, "", None, "m", None,
        nameListAttr(["boom"]), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0)),
        provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), McpManager(),
        ask: Some(allowAllAsk()))

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let stream = runtime.chat(msgs)
    let kinds = drainEventTypes(stream)
    let history = stream.result()

    // 不挂起：宿主不该收到"在等你输入"的信号
    @Expect(hasEventKind(kinds, "suspend"), false)
    // 工具失败**不中断回合**：脚本化 provider 的第二次响应被请求到
    @Expect(provider.callCount, Int64(2))
    // 历史必须完整：两个调用各有结果，且收口无需再补
    @Expect(ensureToolCallResults(history), Int64(0))
    var b1 = false
    var b2 = false
    for (m in history) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolCallId == "b1") { b1 = true }
                if (tr.toolCallId == "b2") { b2 = true }
                // 整批失败补的是错误结果（与"工具执行失败"同样标记 isError），
                // 且正文带上异常信息 —— 证明确实走了 executeBatch 的异常兜底，
                // 而不是"工具被拒 / 超时"那两条不相干的路
                @Expect(tr.isError, true)
                @Expect(textOfMsg(tr).contains("tool exploded"), true)
            case _ => ()
        }
    }
    @Expect(b1, true)
    @Expect(b2, true)
}

// 对照：真正的挂起（等外部输入）必须发 SuspendEvent，且历史停在 assistant(tool_calls)。
// 与上一条并排，锁住"两条路径不再共用一个枚举值"这件事。
@Test
func runtime_externalSuspend_emitsSuspendAndLeavesHistoryOpen() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(suspendToolUseMsg("ext", "call_1"))
    let provider = SuspendProbeProvider(responses)
    let store = MemorySessionStore()
    let events = chatWith(provider, ArrayList<Tool>([ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)]), "s_b4_suspend")
    @Expect(eventKinds(events).contains("suspend"), true)
    let history = store.load("s_b4_suspend")
    // 历史停在 assistant(tool_calls)：结果等下一次 run 带回，因此没有结果消息
    var toolResults: Int64 = 0
    for (m in history) {
        match (m) {
            case _: ToolResultMessage => toolResults++
            case _ => ()
        }
    }
    @Expect(toolResults, Int64(0))
    // 且最后一条是带调用的 assistant（恢复锚点）
    var lastIsAssistantWithCalls = false
    if (history.size > 0) {
        match (history[history.size - 1]) {
            case am: AssistantMessage => lastIsAssistantWithCalls = am.toolCalls().size == 1
            case _ => ()
        }
    }
    @Expect(lastIsAssistantWithCalls, true)
}

// 任意错误码之外的一个额外形状断言：整批失败路径的 TurnEnd 一定发过
// （三条走向都要闭合回合，不能被"不是挂起"理解成"什么都不发"）
@Test
func runtime_batchFailure_stillClosesTurn() {
    let responses = ArrayList<AssistantMessage>()
    let calls = ArrayList<(String, String)>()
    calls.add(("b1", "boom"))
    responses.add(assistantWithCalls("跑一个", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = ScriptedMsgProvider(responses)
    let toolReg = ToolRegistry()
    toolReg.register(ExplodingTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let runtime = testRuntime(AgentConfig("t", None, "", None, "m", None,
        nameListAttr(["boom"]), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0)),
        provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), McpManager(),
        ask: Some(allowAllAsk()))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let stream = runtime.chat(msgs)
    let kinds = drainEventTypes(stream)
    let _ = stream.result()
    @Expect(hasEventKind(kinds, "turn_end"), true)
    @Expect(hasEventKind(kinds, "agent_end"), true)
}
