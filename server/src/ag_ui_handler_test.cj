package server

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.interaction.*
import atelier.util.fromJsonString

// 入站转换的几个纯函数：消息历史取舍（重复上下文最伤——会话里已有还再塞一遍，
// 模型会看到两份）、系统指令拼接、输入通道分键、参数解析兜底。

func userMsg(id: String, text: String): AgUiMessageDTO {
    AgUiMessageDTO(id, "user", text, "", ArrayList<AgUiToolCallDTO>())
}

func asstTextMsg(id: String, text: String): AgUiMessageDTO {
    AgUiMessageDTO(id, "assistant", text, "", ArrayList<AgUiToolCallDTO>())
}

func toolMsg(id: String, callId: String, text: String): AgUiMessageDTO {
    AgUiMessageDTO(id, "tool", text, callId, ArrayList<AgUiToolCallDTO>())
}

func inputOf(msgs: ArrayList<AgUiMessageDTO>): RunAgentInput {
    RunAgentInput("t", "r", None, msgs, ArrayList<AgUiToolDTO>(),
        ArrayList<AgUiContextDTO>(), None)
}

@Test
func handler_sessionWithHistoryTakesOnlyTrailingInput() {
    // 会话已有历史：只取最后一条 assistant 之后的用户输入，避免历史塞两遍
    let msgs = ArrayList<AgUiMessageDTO>([userMsg("m1", "第一问"), asstTextMsg("m2", "第一答"),
        userMsg("m3", "第二问")])
    let out = agUiMessagesToAtelier(msgs, true)
    @Expect(out.size, 1)
    match (out[0]) {
        case m: UserMessage => @Expect(toText(m.content), "第二问")
        case _ => @Fail("应当是用户消息")
    }
}

@Test
func handler_emptySessionConvertsFullContext() {
    // 新 thread：前端带完整上下文时全量转换，模型才看得到前文
    let msgs = ArrayList<AgUiMessageDTO>([userMsg("m1", "问"), asstTextMsg("m2", "答"),
        toolMsg("m3", "c1", "结果"), userMsg("m4", "再问")])
    let out = agUiMessagesToAtelier(msgs, false)
    @Expect(out.size, 4)
    match (out[1]) {
        case _: AssistantMessage => ()
        case _ => @Fail("第二条应当是 assistant")
    }
    match (out[2]) {
        case m: ToolResultMessage =>
            @Expect(m.toolCallId, "c1")
            @Expect(toText(m.content), "结果")
        case _ => @Fail("第三条应当是工具结果")
    }
}

@Test
func handler_assistantWithToolCallsBecomesToolUseTurn() {
    let calls = ArrayList<AgUiToolCallDTO>()
    calls.add(AgUiToolCallDTO("c1", AgUiFunctionDTO("bash", "{\"command\":\"ls\"}")))
    let msgs = ArrayList<AgUiMessageDTO>([
        AgUiMessageDTO("m1", "assistant", "看一下", "", calls),
        userMsg("m2", "继续")])
    let out = agUiMessagesToAtelier(msgs, false)
    @Expect(out.size, 2)
    match (out[0]) {
        case m: AssistantMessage =>
            // 仓颉枚举不支持 ==，用 match 判别（与核心库测试同款写法）
            let isToolUse = match (m.stopReason) {
                case StopReason.ToolUse => true
                case _ => false
            }
            @Expect(isToolUse, true)
            @Expect(m.toolCalls().size, 1)
            @Expect(m.toolCalls()[0].name, "bash")
            // 参数原文解析成 JSON，工具按结构化参数用
            match (m.toolCalls()[0].args) {
                case JsonValue.Map(v) =>
                    match (v.get("command")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "ls")
                        case _ => @Fail("command 应当解析出来")
                    }
                case _ => @Fail("args 应当是 JSON 对象")
            }
        case _ => @Fail("应当是 assistant 消息")
    }
}

@Test
func handler_systemAndDeveloperMessagesAreNotHistory() {
    // system/developer 走系统提示通道，不能混进消息历史（否则每轮都重复一遍）
    let msgs = ArrayList<AgUiMessageDTO>([
        AgUiMessageDTO("m0", "system", "你是助手", "", ArrayList<AgUiToolCallDTO>()),
        AgUiMessageDTO("m0b", "developer", "用中文", "", ArrayList<AgUiToolCallDTO>()),
        userMsg("m1", "你好")])
    let out = agUiMessagesToAtelier(msgs, false)
    @Expect(out.size, 1)
    match (out[0]) {
        case m: UserMessage => @Expect(toText(m.content), "你好")
        case _ => @Fail("只应保留用户消息")
    }
}

@Test
func handler_instructionTextJoinsSystemOverrideAndContext() {
    let context = ArrayList<AgUiContextDTO>()
    context.add(AgUiContextDTO("当前页面", "/settings"))
    context.add(AgUiContextDTO("", "裸值"))
    let input = RunAgentInput("t", "r", None,
        ArrayList<AgUiMessageDTO>([
            AgUiMessageDTO("m0", "system", "你是助手", "", ArrayList<AgUiToolCallDTO>()),
            AgUiMessageDTO("m0b", "developer", "用中文", "", ArrayList<AgUiToolCallDTO>()),
            userMsg("m1", "你好")]),
        ArrayList<AgUiToolDTO>(), context,
        Some(JsonValue.Map(HashMap<String, JsonValue>([("systemPrompt", JsonValue.String("简洁"))]))))
    let text = agUiInstructionText(input)
    @Expect(text.contains("你是助手"), true)
    @Expect(text.contains("用中文"), true)
    @Expect(text.contains("简洁"), true)
    @Expect(text.contains("当前页面:\n/settings"), true)
    @Expect(text.contains("裸值"), true)
    // 尾部不留空行（系统提示是逐段拼的）
    @Expect(text.endsWith("\n"), false)
}

@Test
func handler_instructionTextEmptyWhenNothingProvided() {
    let input = inputOf(ArrayList<AgUiMessageDTO>([userMsg("m1", "你好")]))
    @Expect(agUiInstructionText(input), "")
}

@Test
func handler_parseArgsFallsBackToRawText() {
    match (parseArgs("{\"a\":1}")) {
        case JsonValue.Map(m) =>
            match (m.get("a")) {
                case Some(JsonValue.Number(n)) => @Expect(n, 1.0)
                case _ => @Fail("a 应当是数字")
            }
        case _ => @Fail("合法 JSON 应当解析成对象")
    }
    match (parseArgs("")) {
        case JsonValue.Map(m) => @Expect(m.size, 0)
        case _ => @Fail("空参数应当是空对象")
    }
    // 非 JSON 参数：保留原文，让工具给出更准确的报错，而不是丢掉信息
    match (parseArgs("not json")) {
        case JsonValue.String(s) => @Expect(s, "not json")
        case _ => @Fail("非法参数应当原样保留")
    }
}

@Test
func handler_messagesWithoutUserYieldNothing() {
    // 只有 assistant/tool 的输入没有可执行内容 → 转换结果为空，调用方回 400
    let msgs = ArrayList<AgUiMessageDTO>([asstTextMsg("m1", "自说自话")])
    @Expect(agUiMessagesToAtelier(msgs, false).size, 0)
}

@Test
func handler_fullRunAgentInputParsesThroughHelpers() {
    // 端到端形态：一段真实感的 RunAgentInput 走完解析 → 消息转换 → 指令拼接
    let json = """
{"threadId":"t1","runId":"r1","messages":[
   {"id":"m0","role":"system","content":"你是运维助手"},
   {"id":"m1","role":"user","content":"查一下磁盘"}],
 "context":[{"description":"集群","value":"prod"}],
 "forwardedProps":{"agent":"ops"}}
"""
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.agentName(), Some("ops"))
    @Expect(agUiMessagesToAtelier(input.messages, false).size, 1)
    let text = agUiInstructionText(input)
    @Expect(text.contains("你是运维助手"), true)
    @Expect(text.contains("prod"), true)
}

// ── 中断-恢复的消息换算 ─────────────────────────────────────────────────────

func openOf(id: String, reason: String, toolCallId: String): AgUiInterrupt {
    AgUiInterrupt(id, reason, "需要外部处理", toolCallId)
}

func resumeOf(interruptId: String, status: String, payload: Option<JsonValue>): AgUiResumeDTO {
    AgUiResumeDTO(interruptId, status, payload)
}

func historyWithToolCall(): ArrayList<Message> {
    let calls = ArrayList<ContentBlock>()
    calls.add(ContentBlock.ToolCall(ToolCallBlock("c1", "get_weather",
        JsonValue.Map(HashMap<String, JsonValue>()))))
    let out = ArrayList<Message>()
    out.add(UserMessage(ContentList.ofText("查天气"), 0))
    out.add(AssistantMessage(ContentList(calls), "m", "fake", StopReason.ToolUse, TokenUsage(0, 0), 0))
    out
}

@Test
func handler_resumeResolvedBecomesToolResult() {
    let open = ArrayList<AgUiInterrupt>([openOf("int-c1", "tool_call", "c1")])
    let resume = ArrayList<AgUiResumeDTO>([
        resumeOf("int-c1", "resolved", Some(JsonValue.String("北京晴")))])
    let (msgs, err) = agUiResumeToMessages(historyWithToolCall(), open, resume)
    @Expect(err.isNone(), true)
    @Expect(msgs.size, 1)
    match (msgs[0]) {
        case tr: ToolResultMessage =>
            @Expect(tr.toolCallId, "c1")
            @Expect(toText(tr.content), "北京晴")
            @Expect(tr.isError, false)
            // 工具名从历史里配对找回（恢复时只有 toolCallId）
            @Expect(tr.toolName, "get_weather")
        case _ => @Fail("应当是工具结果")
    }
}

@Test
func handler_resumeCancelledIsErrorResult() {
    let open = ArrayList<AgUiInterrupt>([openOf("int-c1", "tool_call", "c1")])
    let resume = ArrayList<AgUiResumeDTO>([resumeOf("int-c1", "cancelled", None)])
    let (msgs, err) = agUiResumeToMessages(historyWithToolCall(), open, resume)
    @Expect(err.isNone(), true)
    match (msgs[0]) {
        case tr: ToolResultMessage =>
            @Expect(tr.isError, true)
            @Expect(toText(tr.content), "[cancelled by user]")
        case _ => @Fail("应当是工具结果")
    }
}

@Test
func handler_resumeDeniedPayloadIsErrorResult() {
    let denied = JsonValue.Map(HashMap<String, JsonValue>([("approved", JsonValue.Boolean(false))]))
    let open = ArrayList<AgUiInterrupt>([openOf("int-c1", "tool_call", "c1")])
    let resume = ArrayList<AgUiResumeDTO>([resumeOf("int-c1", "resolved", Some(denied))])
    let (msgs, err) = agUiResumeToMessages(historyWithToolCall(), open, resume)
    @Expect(err.isNone(), true)
    match (msgs[0]) {
        case tr: ToolResultMessage =>
            @Expect(tr.isError, true)
            @Expect(toText(tr.content), "[denied by user]")
        case _ => @Fail("应当是工具结果")
    }
}

@Test
func handler_resumePartialIsRejected() {
    // 规则 3：一次 resume 必须覆盖全部未决中断，部分恢复不支持
    let open = ArrayList<AgUiInterrupt>([
        openOf("int-c1", "tool_call", "c1"), openOf("int-c2", "tool_call", "c2")])
    let resume = ArrayList<AgUiResumeDTO>([resumeOf("int-c1", "resolved", None)])
    let (msgs, err) = agUiResumeToMessages(historyWithToolCall(), open, resume)
    @Expect(msgs.size, 0)
    match (err) {
        case Some(msg) => @Expect(msg.contains("int-c2"), true)
        case None => @Fail("部分恢复必须报错")
    }
}

@Test
func handler_resumeUnknownInterruptIsRejected() {
    let open = ArrayList<AgUiInterrupt>([openOf("int-c1", "tool_call", "c1")])
    let resume = ArrayList<AgUiResumeDTO>([
        resumeOf("int-other", "resolved", None), resumeOf("int-c1", "resolved", None)])
    let (_, err) = agUiResumeToMessages(historyWithToolCall(), open, resume)
    match (err) {
        case Some(msg) => @Expect(msg.contains("int-other"), true)
        case None => @Fail("未知中断 id 必须报错")
    }
}

// Message 是接口：测试里取元数据要按角色匹配
func metaOf(m: Message): HashMap<String, String> {
    match (m) {
        case um: UserMessage => um.metadata
        case am: AssistantMessage => am.metadata
        case tm: ToolResultMessage => tm.metadata
        case cm: CompactionMessage => cm.metadata
        case am: ArchiveMessage => am.metadata
        case _ => HashMap<String, String>()
    }
}

@Test
func handler_resumeInputRequiredCarriesAnswerMetadata() {
    // 审批/要输入类中断的答复必须能回到**同一个提问**上（重放时按 requestId 命中），
    // 所以带答复元数据，而不是一句普通用户消息
    let open = ArrayList<AgUiInterrupt>([openOf("int-q", "input_required", "")])
    let payload = JsonValue.Map(HashMap<String, JsonValue>([
        ("values", JsonValue.Map(HashMap<String, JsonValue>([("city", JsonValue.String("北京"))])))]))
    let resume = ArrayList<AgUiResumeDTO>([resumeOf("int-q", "resolved", Some(payload))])
    let (msgs, err) = agUiResumeToMessages(ArrayList<Message>(), open, resume)
    @Expect(err.isNone(), true)
    @Expect(msgs.size, 1)
    match (msgs[0]) {
        case um: UserMessage =>
            @Expect(isAnswerMetadata(um.metadata), true)
            match (decodeAnswer(um.metadata)) {
                case Some(a) =>
                    @Expect(a.requestId, "int-q")
                    match (a.values.get("city")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "北京")
                        case _ => @Fail("表单值应当编码进答复")
                    }
                case None => @Fail("应当能解码出答复")
            }
        case _ => @Fail("应当是承载答复的消息")
    }
}

@Test
func handler_resumeApprovedPayloadBecomesAllowOnce() {
    // {approved:true} 是最常见的审批载荷：映射成 allow_once，而不是当成一段文本
    let open = ArrayList<AgUiInterrupt>([openOf("int-a", "confirmation", "call_1")])
    let payload = JsonValue.Map(HashMap<String, JsonValue>([("approved", JsonValue.Boolean(true))]))
    let resume = ArrayList<AgUiResumeDTO>([resumeOf("int-a", "resolved", Some(payload))])
    let (msgs, _) = agUiResumeToMessages(ArrayList<Message>(), open, resume)
    match (decodeAnswer(metaOf(msgs[0]))) {
        case Some(a) => @Expect(a.isAllowOnce(), true)
        case None => @Fail("应当能解码出答复")
    }
    let denied = JsonValue.Map(HashMap<String, JsonValue>([("approved", JsonValue.Boolean(false))]))
    let resume2 = ArrayList<AgUiResumeDTO>([resumeOf("int-a", "resolved", Some(denied))])
    let (msgs2, _) = agUiResumeToMessages(ArrayList<Message>(), open, resume2)
    match (decodeAnswer(metaOf(msgs2[0]))) {
        case Some(a) => @Expect(a.isDenied(), true)
        case None => @Fail("应当能解码出答复")
    }
}
@Test
func handler_outMessagesSkipInternalMarkers() {
    let msgs = historyWithToolCall()
    msgs.add(ToolResultMessage("c1", "get_weather", ContentList.ofText("晴"), false, 0))
    msgs.add(CompactionMessage("早前摘要", 10, 2))
    let out = agUiOutMessages(msgs)
    // 压缩标记不外发（客户端无从渲染，也不该看到内部上下文管理细节）
    @Expect(out.size, 3)
    @Expect(out[0].role, "user")
    @Expect(out[1].role, "assistant")
    @Expect(out[1].toolCalls.size, 1)
    @Expect(out[2].role, "tool")
    @Expect(out[2].toolCallId, "c1")
}

@Test
func handler_payloadTextPrefersPlainString() {
    @Expect(payloadText(Some(JsonValue.String("晴"))), "晴")
    // 数字按 jsonvalue 的序列化口径（1.0 → "1"）
    @Expect(payloadText(Some(JsonValue.Number(1.0))), "1")
    @Expect(payloadText(None), "")
}
