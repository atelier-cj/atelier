package atelier.agent

/*
 * `TurnEndEvent.reason` 的事实性。
 *
 * 契约：每条 `TurnEndEvent` 都必须带**真实**的结束原因，不能一律 `Completed`。
 * 这个字段存在的意义就是让消费端区分「模型自然收尾」与「任务被预算/钩子/宿主/取消/失败
 * 掐断」—— 后者若显示成"已完成"，用户会以为任务做完了。
 *
 * 与 `StopReason` 的分工：`StopReason` 说的是**模型这一条回复**怎么停的，
 * `reason` 说的是**这个回合**为什么收尾。两者可以不一致
 * （例如模型回复正常结束、但回合因预算耗尽而收尾）。
 *
 * 本文件为每个变体各锁一条能触发它的真实路径。
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

// 收集事件流里所有 TurnEndEvent 的 reason
func collectTurnEndReasons(stream: EventStream<AgentEvent, ArrayList<Message>>): ArrayList<TurnEndReason> {
    let reasons = ArrayList<TurnEndReason>()
    var done = false
    while (!done) {
        match (stream.receive(50 * Duration.millisecond)) {
            case Some(ev) =>
                match (ev) {
                    case te: TurnEndEvent => reasons.add(te.reason)
                    case _ => ()
                }
            case None => if (stream.isClosed()) { done = true }
        }
    }
    reasons
}

func reasonRuntime(provider: Provider, toolReg: ToolRegistry,
    hooks!: ArrayList<Hook> = ArrayList(),
    cfg!: AgentConfig = AgentConfig.default()): AgentRuntime {
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    testRuntime(cfg, provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, hooks, McpManager(),
        ask: Some({ req: UserRequest =>
            let sel = ArrayList<String>()
            sel.add("allow_always")
            UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
        }))
}

func namesOfTools(names: Array<String>): ArrayList<String> {
    let l = ArrayList<String>()
    for (n in names) { l.add(n) }
    l
}

func reasonConfig(names: Array<String>,
    maxToolCalls!: UInt32 = UInt32(50)): AgentConfig {
    AgentConfig("reason-probe", None, "", None, "m", None, namesOfTools(names),
        ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, maxToolCalls, UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0))
}

// Completed：模型自然收尾
@Test
func turnEndReason_completedOnNaturalEnd() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("做完了"))
    let runtime = reasonRuntime(ScriptedMsgProvider(responses), ToolRegistry())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))
    @Expect(reasons.size, Int64(1))
    match (reasons[0]) {
        case TurnEndReason.Completed => ()
        case _ => @Fail("自然结束应当是 Completed")
    }
}

// ToolBudgetExhausted：预算耗尽收尾（不是"模型正常结束"）
@Test
func turnEndReason_toolBudgetExhausted() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("x1", "noop"))
    let responses = ArrayList<AssistantMessage>()
    // 第一回合就请求 1 个调用，maxToolCalls=0 → 立刻耗尽
    responses.add(assistantWithCalls("想调工具", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let runtime = reasonRuntime(ScriptedMsgProvider(responses), toolReg,
        cfg: reasonConfig(["noop"], maxToolCalls: UInt32(0)))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))
    @Expect(reasons.size, Int64(1))
    match (reasons[0]) {
        case TurnEndReason.ToolBudgetExhausted => ()
        case _ => @Fail("预算耗尽应当是 ToolBudgetExhausted")
    }
}

// BlockedByHook：beforeTurn 钩子短路整个 run
class BlockingTurnHook <: Hook {
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        TurnDecision.ShortCircuit("blocked by policy")
    }
}

@Test
func turnEndReason_blockedByHook() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("不应该被请求"))
    let hooks = ArrayList<Hook>()
    hooks.add(BlockingTurnHook())
    let runtime = reasonRuntime(ScriptedMsgProvider(responses), ToolRegistry(),
        hooks: hooks)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))
    @Expect(reasons.size, Int64(1))
    match (reasons[0]) {
        case TurnEndReason.BlockedByHook => ()
        case _ => @Fail("钩子短路应当是 BlockedByHook")
    }
}

// BlockedByHook（另一条来源）：afterTurn 钩子短路
class BlockingAfterTurnHook <: Hook {
    public override func afterTurn(ctx: HookContext): AfterTurnUpdate {
        AfterTurnUpdate(None, true)
    }
}

@Test
func turnEndReason_blockedByAfterTurnHook() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("做完了"))
    let hooks = ArrayList<Hook>()
    hooks.add(BlockingAfterTurnHook())
    let runtime = reasonRuntime(ScriptedMsgProvider(responses), ToolRegistry(),
        hooks: hooks)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))
    @Expect(reasons.size, Int64(1))
    match (reasons[0]) {
        case TurnEndReason.BlockedByHook => ()
        case _ => @Fail("afterTurn 短路应当是 BlockedByHook")
    }
}

// Cancelled：调用方在工具边界取消
@Test
func turnEndReason_cancelled() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("c1", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCalls("要调工具", calls))
    responses.add(endTurnMsg("不应该被请求"))
    // 在 beforeTurn 钩子里取消：进入循环后立刻命中取消检查
    let slot = RuntimeSlot2()
    let hooks = ArrayList<Hook>()
    let cancelHook = CancelRuntimeHook2(slot, "sess_reason_cancel")
    hooks.add(cancelHook)
    let rt = reasonRuntime(ScriptedMsgProvider(responses), toolReg, hooks: hooks,
        cfg: reasonConfig(["noop"]))
    slot.target = Some(rt)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let stream = rt.chatWithSessionId("sess_reason_cancel", msgs, SessionEnvironment())
    let reasons = collectTurnEndReasons(stream)
    // 取消后收尾：最后一条回合结束原因应当是 Cancelled
    @Expect(reasons.size >= 1, true)
    var sawCancelled = false
    for (r in reasons) {
        match (r) {
            case TurnEndReason.Cancelled => sawCancelled = true
            case _ => ()
        }
    }
    @Expect(sawCancelled, true)
}

class RuntimeSlot2 {
    public var target: Option<AgentRuntime> = None
}

class CancelRuntimeHook2 <: Hook {
    private let slot: RuntimeSlot2
    private let sid: String
    public init(slot: RuntimeSlot2, sid: String) {
        this.slot = slot
        this.sid = sid
    }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        match (this.slot.target) {
            case Some(rt) => rt.cancelSession(this.sid)
            case None => ()
        }
        TurnDecision.Continue(request)
    }
}

// Failed：provider 不可恢复错误
class AlwaysFailingProvider <: Provider {
    public func name(): String { "always-failing" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        throw Exception("provider exploded")
    }
}

@Test
func turnEndReason_failedOnProviderError() {
    let runtime = reasonRuntime(AlwaysFailingProvider(), ToolRegistry())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))
    @Expect(reasons.size, Int64(1))
    match (reasons[0]) {
        case TurnEndReason.Failed => ()
        case _ => @Fail("provider 失败应当是 Failed")
    }
}

// Suspended：宿主要求先确认 → 历史停在 assistant(tool_calls)，等下次 run 带回结果。
// 用挂起测试的现成构造（同包 helper）。
@Test
func turnEndReason_suspended() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(suspendToolUseMsg("ext", "call_1"))
    let provider = SuspendProbeProvider(responses)
    let store = MemorySessionStore()
    let events = chatWith(provider, ArrayList<Tool>([ExternalTool()]), store,
        ArrayList<Message>([UserMessage(ContentList.ofText("查天气"), 0)]), "s_reason_suspend")
    // eventKinds 只返回类型名，这里需要 reason → 直接用挂起事件的存在性 + 单独取 TurnEnd
    @Expect(eventKinds(events).contains("suspend"), true)
    var sawSuspended = false
    for (e in events) {
        match (e) {
            case te: TurnEndEvent =>
                match (te.reason) {
                    case TurnEndReason.Suspended => sawSuspended = true
                    case _ => ()
                }
            case _ => ()
        }
    }
    @Expect(sawSuspended, true)
}

// MaxTurnsReached：回合数用尽 → 这条路径原本**不发** TurnEndEvent，
// 消费端只看到 AgentEnd，误以为任务跑完了。现在补发一条并带正确原因。
@Test
func turnEndReason_maxTurnsReached() {
    // maxTurns=1：第一回合调工具（ToolUse → 继续循环），第二回合循环条件
    // turnCount(1) < maxTurns(1) 为假 → 退出且循环体内没有置位任何 reason
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("m1", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCalls("第一回合调工具", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let cfg = AgentConfig("max-turns-probe", None, "", None, "m", None,
        namesOfTools(["noop"]), ArrayList<String>(), Int64(0),
        UInt32(1), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0))
    let provider = ScriptedMsgProvider(responses)
    let runtime = reasonRuntime(provider, toolReg, cfg: cfg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let reasons = collectTurnEndReasons(runtime.chat(msgs))

    // 补发了一条带 MaxTurnsReached 的事件
    var sawMaxTurns = false
    for (r in reasons) {
        match (r) {
            case TurnEndReason.MaxTurnsReached => sawMaxTurns = true
            case _ => ()
        }
    }
    @Expect(sawMaxTurns, true)
}

// 补发的事件必须复用**最后一条真实 assistant 消息**，不能伪造新的模型产出。
@Test
func turnEndReason_maxTurnsReusesLastAssistant() {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let calls = ArrayList<(String, String)>()
    calls.add(("m1", "noop"))
    let responses = ArrayList<AssistantMessage>()
    responses.add(assistantWithCalls("第一回合的产出文本", calls))
    responses.add(endTurnMsg("不应该被请求"))
    let cfg = AgentConfig("max-turns-probe2", None, "", None, "m", None,
        namesOfTools(["noop"]), ArrayList<String>(), Int64(0),
        UInt32(1), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0))
    let runtime = reasonRuntime(ScriptedMsgProvider(responses), toolReg, cfg: cfg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let stream = runtime.chat(msgs)

    var maxTurnsMsg: Option<AssistantMessage> = None
    var done = false
    while (!done) {
        match (stream.receive(50 * Duration.millisecond)) {
            case Some(ev) =>
                match (ev) {
                    case te: TurnEndEvent =>
                        match (te.reason) {
                            case TurnEndReason.MaxTurnsReached => maxTurnsMsg = Some(te.message)
                            case _ => ()
                        }
                    case _ => ()
                }
            case None => if (stream.isClosed()) { done = true }
        }
    }
    match (maxTurnsMsg) {
        case Some(m) =>
            // 复用的是第一回合那条真实回复，不是新造的占位
            @Expect(textOfMsg(m).contains("第一回合的产出文本"), true)
        case None => @Fail("maxTurns 收尾应当补发一条 MaxTurnsReached 事件")
    }
}
