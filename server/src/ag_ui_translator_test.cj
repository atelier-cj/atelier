package server

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.agent.*
import atelier.tool.ExternalRequest

// 翻译器：AgentEvent → AG-UI 事件序列。这里锁的是「生命周期必须自洽」——
// 开了的消息要关、工具三次事件要成组、RUN_ERROR 之后不能再来 RUN_FINISHED，
// 因为这些一旦错，前端状态机就卡死或错乱（而不是少显示一点东西）。

func asstMsg(text: String, stop: StopReason): AssistantMessage {
    AssistantMessage(ContentList.ofText(text), "m", "fake", stop, TokenUsage(0, 0), 0)
}

func asstWithTool(id: String, name: String, args: JsonValue): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(ToolCallBlock(id, name, args)))
    return AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0)
}

func kinds(evs: ArrayList<AgUiEvent>): String {
    let parts = ArrayList<String>()
    for (e in evs) { parts.add(e.eventType()) }
    String.join(parts.toArray(), delimiter: ",")
}

func newTranslator(): AgUiTranslator { AgUiTranslator("t1", "r1") }

func startEvents(): ArrayList<AgUiEvent> {
    newTranslator().start(AgUiStateSnapshot("a", "m", "t1", "/w", None))
}

@Test
func translator_startEmitsRunStartedAndSnapshot() {
    @Expect(kinds(startEvents()), "RUN_STARTED,STATE_SNAPSHOT")
}

@Test
func translator_streamingTextOpensAndClosesOncePerMessage() {
    let tr = newTranslator()
    let msg = asstMsg("hello", StopReason.EndTurn)
    var out = tr.translate(MessageStartEvent(msg))
    @Expect(kinds(out), "")
    out = tr.translate(MessageUpdateEvent(msg, "he"))
    @Expect(kinds(out), "TEXT_MESSAGE_START,TEXT_MESSAGE_CONTENT")
    out = tr.translate(MessageUpdateEvent(msg, "llo"))
    @Expect(kinds(out), "TEXT_MESSAGE_CONTENT")   // 只开一次
    out = tr.translate(MessageEndEvent(msg))
    @Expect(kinds(out), "TEXT_MESSAGE_END")
    // 同一个消息 id 贯穿增量与结束
    let ids = ArrayList<String>()
    for (e in tr.translate(MessageUpdateEvent(msg, "x"))) { () }
    let tr2 = newTranslator()
    let first = tr2.translate(MessageUpdateEvent(msg, "a"))
    let last = tr2.translate(MessageEndEvent(msg))
    match (first[0]) {
        case e: TextMessageStartEvent => ids.add(e.messageId)
        case _ => @Fail("首条应当是 TEXT_MESSAGE_START")
    }
    match (last[0]) {
        case e: TextMessageEndEvent => ids.add(e.messageId)
        case _ => @Fail("末条应当是 TEXT_MESSAGE_END")
    }
    @Expect(ids[0], ids[1])
}

@Test
func translator_messageIdAllocatedWithoutStartEvent() {
    // 真实运行时通常**不发** assistant 的 MessageStartEvent，只在有内容时才发增量/结束事件：
    // 消息 id 必须在这条路径上也能拿到，否则前端收到 messageId="" 的消息（无法归并增量）
    let tr = newTranslator()
    let msg = asstMsg("收到", StopReason.EndTurn)
    let out = tr.translate(MessageUpdateEvent(msg, "收到"))
    @Expect(kinds(out), "TEXT_MESSAGE_START,TEXT_MESSAGE_CONTENT")
    match (out[0]) {
        case e: TextMessageStartEvent => @Expect(e.messageId != "", true)
        case _ => @Fail("首条应当是 TEXT_MESSAGE_START")
    }
    let end = tr.translate(MessageEndEvent(msg))
    @Expect(kinds(end), "TEXT_MESSAGE_END")
    match (end[0]) {
        case e: TextMessageEndEvent => @Expect(e.messageId != "", true)
        case _ => @Fail("应当是 TEXT_MESSAGE_END")
    }
}

@Test
func translator_distinctMessagesGetDistinctIds() {
    // 一次 run 里可以有多条 assistant 消息（每个回合一条），id 不能复用
    let tr = newTranslator()
    let first = tr.translate(MessageUpdateEvent(asstMsg("一", StopReason.ToolUse), "一"))
    tr.translate(MessageEndEvent(asstMsg("一", StopReason.ToolUse)))
    let second = tr.translate(MessageUpdateEvent(asstMsg("二", StopReason.EndTurn), "二"))
    var id1 = ""
    var id2 = ""
    match (first[0]) {
        case e: TextMessageStartEvent => id1 = e.messageId
        case _ => @Fail("首条应当是 TEXT_MESSAGE_START")
    }
    match (second[0]) {
        case e: TextMessageStartEvent => id2 = e.messageId
        case _ => @Fail("首条应当是 TEXT_MESSAGE_START")
    }
    @Expect(id1 != id2, true)
}

@Test
func translator_emptyDeltaDoesNotOpenMessage() {
    let tr = newTranslator()
    let msg = asstMsg("x", StopReason.EndTurn)
    @Expect(kinds(tr.translate(MessageStartEvent(msg))), "")
    @Expect(kinds(tr.translate(MessageUpdateEvent(msg, ""))), "")
}

@Test
func translator_nonStreamingTextIsEmittedAtEnd() {
    // 非流式 provider：整段文本在 MessageEnd 才拿到，也必须补发完整三段
    let tr = newTranslator()
    let msg = asstMsg("整段文本", StopReason.EndTurn)
    tr.translate(MessageStartEvent(msg))
    let out = tr.translate(MessageEndEvent(msg))
    @Expect(kinds(out), "TEXT_MESSAGE_START,TEXT_MESSAGE_CONTENT,TEXT_MESSAGE_END")
    match (out[1]) {
        case e: TextMessageContentEvent => @Expect(e.delta, "整段文本")
        case _ => @Fail("第二条应当是内容")
    }
}

@Test
func translator_toolOnlyTurnEmitsNoTextEvents() {
    let tr = newTranslator()
    let msg = asstWithTool("c1", "bash", JsonValue.Map(HashMap<String, JsonValue>()))
    tr.translate(MessageStartEvent(msg))
    let out = tr.translate(MessageEndEvent(msg))
    @Expect(kinds(out), "")
}

@Test
func translator_toolCallTriadCarriesRememberedArgs() {
    let tr = newTranslator()
    let args = JsonValue.Map(HashMap<String, JsonValue>([
        ("command", JsonValue.String("ls -la"))]))
    let msg = asstWithTool("c1", "bash", args)
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageEndEvent(msg))
    let out = tr.translate(ToolExecutionStartEvent("c1", "bash"))
    @Expect(kinds(out), "TOOL_CALL_START,TOOL_CALL_ARGS,TOOL_CALL_END")
    match (out[1]) {
        case e: ToolCallArgsEvent =>
            @Expect(e.toolCallId, "c1")
            // 参数是 JsonValue 序列化后的原文，前端按 JSON 解析
            @Expect(e.delta.contains("ls -la"), true)
        case _ => @Fail("第二条应当是参数")
    }
}

@Test
func translator_clientToolRequestFollowsTriadInOrder() {
    // 前端工具：TOOL_CALL_* 之后**紧接着**请前端执行（顺序确定，不能与消费循环抢）
    let clientTools = ArrayList<String>(["get_weather"])
    let tr = AgUiTranslator("t1", "r1", clientTools: clientTools)
    let args = JsonValue.Map(HashMap<String, JsonValue>([("city", JsonValue.String("北京"))]))
    let msg = asstWithTool("c1", "get_weather", args)
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageEndEvent(msg))
    let out = tr.translate(ToolExecutionStartEvent("c1", "get_weather"))
    @Expect(kinds(out), "TOOL_CALL_START,TOOL_CALL_ARGS,TOOL_CALL_END,CUSTOM")
    match (out[3]) {
        case e: CustomEvent => @Expect(e.name, "client_tool_request")
        case _ => @Fail("末条应当是 client_tool_request")
    }
}

@Test
func translator_serverToolDoesNotAskClient() {
    // 服务端自己实现的工具不该请前端执行
    let tr = AgUiTranslator("t1", "r1", clientTools: ArrayList<String>(["get_weather"]))
    let msg = asstWithTool("c1", "bash", JsonValue.Map(HashMap<String, JsonValue>()))
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageEndEvent(msg))
    @Expect(kinds(tr.translate(ToolExecutionStartEvent("c1", "bash"))),
        "TOOL_CALL_START,TOOL_CALL_ARGS,TOOL_CALL_END")
}

@Test
func translator_toolCallWithoutRememberedArgsFallsBackToEmptyObject() {
    let tr = newTranslator()
    let out = tr.translate(ToolExecutionStartEvent("c9", "bash"))
    @Expect(kinds(out), "TOOL_CALL_START,TOOL_CALL_ARGS,TOOL_CALL_END")
    match (out[1]) {
        case e: ToolCallArgsEvent => @Expect(e.delta, "{}")
        case _ => @Fail("第二条应当是参数")
    }
}

@Test
func translator_toolResultUsesParentMessageId() {
    let tr = newTranslator()
    let msg = asstWithTool("c1", "bash", JsonValue.Map(HashMap<String, JsonValue>()))
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageEndEvent(msg))
    let out = tr.translate(ToolExecutionEndEvent("c1", "a.txt", false))
    @Expect(kinds(out), "TOOL_CALL_RESULT")
    match (out[0]) {
        case e: ToolCallResultEvent =>
            @Expect(e.content, "a.txt")
            @Expect(e.role, "tool")
            @Expect(e.toolCallId, "c1")
            @Expect(e.messageId != "", true)
        case _ => @Fail("应当是工具结果")
    }
}

@Test
func translator_reasoningEmitsOwnIdSpace() {
    let tr = newTranslator()
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("答"))
    let msg = AssistantMessage(ContentList(blocks), "m", "fake", StopReason.EndTurn,
        TokenUsage(0, 0), 0, "想了一会儿")
    tr.translate(MessageStartEvent(msg))
    let out = tr.translate(MessageEndEvent(msg))
    @Expect(kinds(out),
        "TEXT_MESSAGE_START,TEXT_MESSAGE_CONTENT,TEXT_MESSAGE_END," +
        "REASONING_START,REASONING_MESSAGE_START,REASONING_MESSAGE_CONTENT," +
        "REASONING_MESSAGE_END,REASONING_END")
}

@Test
func translator_turnLifecycleEmitsStepEvents() {
    let tr = newTranslator()
    @Expect(kinds(tr.translate(TurnStartEvent())), "STEP_STARTED")
    let msg = asstMsg("done", StopReason.EndTurn)
    @Expect(kinds(tr.translate(TurnEndEvent(msg, ArrayList<ToolResultMessage>()))), "STEP_FINISHED")
    let out = tr.translate(AgentEndEvent(ArrayList<Message>()))
    @Expect(kinds(out), "RUN_FINISHED")
    match (out[0]) {
        case e: RunFinishedEvent =>
            @Expect(e.stopReason, "end_turn")
            @Expect(e.turns, 1)
        case _ => @Fail("应当是 RUN_FINISHED")
    }
}

@Test
func translator_providerErrorEndsRunWithoutFinished() {
    let tr = newTranslator()
    tr.translate(TurnStartEvent())
    let failed = asstMsg("", StopReason.Error)
    let out = tr.translate(TurnEndEvent(failed, ArrayList<ToolResultMessage>()))
    @Expect(kinds(out), "STEP_FINISHED,RUN_ERROR")
    match (out[1]) {
        case e: RunErrorEvent => @Expect(e.code, "provider_error")
        case _ => @Fail("应当是 RUN_ERROR")
    }
    // 失败已收尾：AgentEnd 不能再发 RUN_FINISHED（否则前端等两次结束）
    @Expect(kinds(tr.translate(AgentEndEvent(ArrayList<Message>()))), "")
}

@Test
func translator_eventsAfterFinishAreDropped() {
    let tr = newTranslator()
    tr.translate(AgentEndEvent(ArrayList<Message>()))
    @Expect(kinds(tr.translate(TurnStartEvent())), "")
    @Expect(kinds(tr.translate(MessageUpdateEvent(asstMsg("x", StopReason.EndTurn), "x"))), "")
}

@Test
func translator_compactionBecomesCustomEvent() {
    let tr = newTranslator()
    let out = tr.translate(CompactionEvent("threshold", 100, 20))
    @Expect(kinds(out), "CUSTOM")
    match (out[0]) {
        case e: CustomEvent =>
            @Expect(e.name, "compaction")
        case _ => @Fail("应当是 CUSTOM")
    }
}

@Test
func translator_toolProgressBecomesCustomEvent() {
    let tr = newTranslator()
    let out = tr.translate(ToolExecutionUpdateEvent("c1", "3/10"))
    @Expect(kinds(out), "CUSTOM")
    match (out[0]) {
        case e: CustomEvent => @Expect(e.name, "tool_progress")
        case _ => @Fail("应当是 CUSTOM")
    }
}

@Test
func translator_newTurnClosesOpenTextAndStep() {
    // 模型在同一回合里既说了话又调工具：下一个回合开始时，上一段文本必须先闭合
    let tr = newTranslator()
    tr.translate(TurnStartEvent())
    let msg = asstMsg("说一句", StopReason.ToolUse)
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageUpdateEvent(msg, "说一句"))
    let out = tr.translate(TurnStartEvent())
    @Expect(kinds(out), "TEXT_MESSAGE_END,STEP_FINISHED,STEP_STARTED")
}

@Test
func translator_userInputRequestIsCustom() {
    let tr = newTranslator()
    let ev = tr.userInputRequest("要继续吗？")
    @Expect(ev.eventType(), "CUSTOM")
    match (ev) {
        case e: CustomEvent => @Expect(e.name, "user_input_request")
        case _ => @Fail("应当是 CUSTOM")
    }
}

@Test
func translator_clientToolRequestCarriesCallIdentity() {
    let tr = newTranslator()
    let ev = tr.clientToolRequest("c1", "client_tool", "{\"x\":1}")
    match (ev) {
        case e: CustomEvent => @Expect(e.name, "client_tool_request")
        case _ => @Fail("应当是 CUSTOM")
    }
}

// 挂起：RUN_FINISHED 必须换成 interrupt 结果，且 interrupts 交给 handler 去登记
@Test
func translator_suspendEndsWithInterruptOutcome() {
    let tr = newTranslator()
    tr.translate(TurnStartEvent())
    let msg = asstWithTool("c1", "get_weather", JsonValue.Map(HashMap<String, JsonValue>()))
    tr.translate(MessageStartEvent(msg))
    tr.translate(MessageEndEvent(msg))
    tr.translate(ToolExecutionStartEvent("c1", "get_weather"))
    let reqs = ArrayList<ExternalRequest>()
    reqs.add(ExternalRequest("int-c1", "tool_call", "客户端需执行 get_weather", toolCallId: "c1"))
    tr.translate(TurnEndEvent(asstWithTool("c1", "get_weather",
        JsonValue.Map(HashMap<String, JsonValue>())), ArrayList<ToolResultMessage>()))
    @Expect(kinds(tr.translate(SuspendEvent(reqs))), "")
    let out = tr.translate(AgentEndEvent(ArrayList<Message>()))
    @Expect(kinds(out), "RUN_FINISHED")
    match (out[0]) {
        case e: RunFinishedEvent =>
            @Expect(e.interrupts.size, 1)
            @Expect(e.interrupts[0].id, "int-c1")
            @Expect(e.interrupts[0].toolCallId, "c1")
        case _ => @Fail("应当是 RUN_FINISHED")
    }
    @Expect(tr.pendingInterrupts().size, 1)
}

// 没挂起时仍是 success 结果（旧客户端行为不变）
@Test
func translator_noSuspendKeepsSuccessOutcome() {
    let tr = newTranslator()
    let out = tr.translate(AgentEndEvent(ArrayList<Message>()))
    match (out[0]) {
        case e: RunFinishedEvent => @Expect(e.interrupts.size, 0)
        case _ => @Fail("应当是 RUN_FINISHED")
    }
    @Expect(tr.pendingInterrupts().size, 0)
}
