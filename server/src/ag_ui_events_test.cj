package server

import std.collection.*
import jsonvalue.*
import atelier.util.toJsonString

// AG-UI 事件序列化：帧格式与字段名是**对外契约**，改动等同于破坏协议，
// 所以这里既验 SSE 帧形状，也验字段（含 timestamp 这类动态字段存在但不比对具体值）。

func frameBody(ev: AgUiEvent): String {
    let frame = sseFrame(ev)
    @Expect(frame.startsWith("data: "), true)
    @Expect(frame.endsWith("\n\n"), true)
    frame[6..frame.size - 2]
}

func fieldOf(body: String, name: String): String {
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get(name)) {
                case Some(JsonValue.String(s)) => s
                case Some(other) => toJsonString(other)
                case None => ""
            }
        case _ => ""
    }
}

@Test
func events_frameIsSseDataLineWithParseableJson() {
    let body = frameBody(RunStartedEvent("t1", "r1"))
    // 帧体必须是合法 JSON（NaN/未转义引号这类问题由解析器当裁判）
    match (JsonValue.parse(body)) {
        case JsonValue.Map(_) => ()
        case _ => @Fail("帧体应当是 JSON 对象")
    }
    @Expect(fieldOf(body, "type"), "RUN_STARTED")
    @Expect(fieldOf(body, "threadId"), "t1")
    @Expect(fieldOf(body, "runId"), "r1")
    // timestamp 是动态值，只要求存在且为正
    @Expect(body.contains("\"timestamp\":"), true)
}

@Test
func events_textContentKeepsNastyTextIntact() {
    let nasty = "line1\nline2 \"q\" back\\slash \u{1} 中文"
    let body = frameBody(TextMessageContentEvent("m1", nasty))
    @Expect(fieldOf(body, "type"), "TEXT_MESSAGE_CONTENT")
    @Expect(fieldOf(body, "messageId"), "m1")
    // 转义必须可逆：反解回来与原文逐字节一致
    @Expect(fieldOf(body, "delta"), nasty)
    @Expect(body.contains("\n"), false)
}

@Test
func events_textMessageStartCarriesRole() {
    let body = frameBody(TextMessageStartEvent("m1", "assistant"))
    @Expect(fieldOf(body, "type"), "TEXT_MESSAGE_START")
    @Expect(fieldOf(body, "role"), "assistant")
}

@Test
func events_toolCallStartOmitsEmptyParentMessageId() {
    let bare = frameBody(ToolCallStartEvent("c1", "bash", ""))
    @Expect(bare.contains("parentMessageId"), false)
    let withParent = frameBody(ToolCallStartEvent("c1", "bash", "m1"))
    @Expect(fieldOf(withParent, "parentMessageId"), "m1")
}

@Test
func events_toolCallResultCarriesToolRole() {
    let body = frameBody(ToolCallResultEvent("m1", "c1", "ok", "tool"))
    @Expect(fieldOf(body, "type"), "TOOL_CALL_RESULT")
    @Expect(fieldOf(body, "toolCallId"), "c1")
    @Expect(fieldOf(body, "content"), "ok")
    @Expect(fieldOf(body, "role"), "tool")
}

@Test
func events_runFinishedHasOutcomeAndResult() {
    let body = frameBody(RunFinishedEvent("t1", "r1", "end_turn", 3))
    @Expect(fieldOf(body, "type"), "RUN_FINISHED")
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get("outcome")) {
                case Some(JsonValue.Map(o)) =>
                    match (o.get("type")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "success")
                        case _ => @Fail("outcome.type 必须是 success")
                    }
                case _ => @Fail("必须带 outcome")
            }
            match (m.get("result")) {
                case Some(JsonValue.Map(r)) =>
                    match (r.get("stopReason")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "end_turn")
                        case _ => @Fail("result.stopReason 缺失")
                    }
                    match (r.get("turns")) {
                        case Some(JsonValue.Number(n)) => @Expect(n, 3.0)
                        case _ => @Fail("result.turns 缺失")
                    }
                case _ => @Fail("必须带 result")
            }
        case _ => @Fail("帧体应当是 JSON 对象")
    }
}

@Test
func events_runErrorOmitsEmptyCode() {
    let bare = frameBody(RunErrorEvent("boom", ""))
    @Expect(fieldOf(bare, "message"), "boom")
    @Expect(bare.contains("\"code\""), false)
    let coded = frameBody(RunErrorEvent("boom", "provider_error"))
    @Expect(fieldOf(coded, "code"), "provider_error")
}

@Test
func events_stateSnapshotCarriesOpaqueState() {
    let state = JsonValue.Map(HashMap<String, JsonValue>([("k", JsonValue.String("v"))]))
    let snap = AgUiStateSnapshot("a1", "m1", "s1", "/tmp/w", Some(state))
    let body = frameBody(StateSnapshotEvent(JsonValue.fromObject(snap)))
    @Expect(fieldOf(body, "type"), "STATE_SNAPSHOT")
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get("snapshot")) {
                case Some(JsonValue.Map(s)) =>
                    @Expect(fieldOf(toJsonString(JsonValue.Map(s)), "agent"), "a1")
                    @Expect(fieldOf(toJsonString(JsonValue.Map(s)), "sessionId"), "s1")
                    // 客户端传进来的 state 原样回显（服务端不解释、不合并）
                    match (s.get("state")) {
                        case Some(JsonValue.Map(_)) => ()
                        case _ => @Fail("state 应当原样回显")
                    }
                case _ => @Fail("snapshot 缺失")
            }
        case _ => @Fail("帧体应当是 JSON 对象")
    }
}

@Test
func events_stateSnapshotOmitsAbsentState() {
    let snap = AgUiStateSnapshot("a1", "m1", "s1", "", None)
    let body = frameBody(StateSnapshotEvent(JsonValue.fromObject(snap)))
    @Expect(body.contains("\"state\""), false)
}

@Test
func events_customCarriesNameAndValue() {
    let payload = AgUiToolProgressPayload("c1", "50%")
    let body = frameBody(CustomEvent("tool_progress", JsonValue.fromObject(payload)))
    @Expect(fieldOf(body, "type"), "CUSTOM")
    @Expect(fieldOf(body, "name"), "tool_progress")
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get("value")) {
                case Some(JsonValue.Map(val)) =>
                    @Expect(fieldOf(toJsonString(JsonValue.Map(val)), "toolCallId"), "c1")
                    @Expect(fieldOf(toJsonString(JsonValue.Map(val)), "progress"), "50%")
                case _ => @Fail("value 缺失")
            }
        case _ => @Fail("帧体应当是 JSON 对象")
    }
}

@Test
func events_reasoningUsesOwnMessageId() {
    let body = frameBody(ReasoningMessageStartEvent("m1-r"))
    @Expect(fieldOf(body, "type"), "REASONING_MESSAGE_START")
    @Expect(fieldOf(body, "role"), "reasoning")
    @Expect(body.contains("m1-r"), true)
}

// 中断收尾：outcome.type=interrupt 且 interrupts 非空（协议规则 2/3 的载体）
@Test
func events_runFinishedInterruptOutcome() {
    let ints = ArrayList<AgUiInterrupt>()
    ints.add(AgUiInterrupt("int-c1", "tool_call", "客户端需执行 get_weather", "c1"))
    let body = frameBody(RunFinishedEvent("t1", "r1", "tool_use", 1, interrupts: ints))
    @Expect(fieldOf(body, "type"), "RUN_FINISHED")
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get("outcome")) {
                case Some(JsonValue.Map(o)) =>
                    match (o.get("type")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "interrupt")
                        case _ => @Fail("outcome.type 必须是 interrupt")
                    }
                    match (o.get("interrupts")) {
                        case Some(JsonValue.Array(arr)) =>
                            @Expect(arr.size, 1)
                            let one = toJsonString(arr[0])
                            @Expect(fieldOf(one, "id"), "int-c1")
                            @Expect(fieldOf(one, "reason"), "tool_call")
                            @Expect(fieldOf(one, "toolCallId"), "c1")
                        case _ => @Fail("interrupts 必须是非空数组")
                    }
                case _ => @Fail("必须带 outcome")
            }
        case _ => @Fail("帧体应当是 JSON 对象")
    }
}

@Test
func events_interruptOmitsEmptyToolCallId() {
    let ints = ArrayList<AgUiInterrupt>()
    ints.add(AgUiInterrupt("int-1", "input_required", "请补充信息", ""))
    let body = frameBody(RunFinishedEvent("t1", "r1", "end_turn", 1, interrupts: ints))
    @Expect(body.contains("toolCallId"), false)
    @Expect(fieldOf(body, "threadId"), "t1")
}

// 没有答复契约时整段省略：不发一个空对象，免得前端以为「有 schema 但啥也不要求」
@Test
func events_interruptOmitsAbsentResponseSchema() {
    let ints = ArrayList<AgUiInterrupt>()
    ints.add(AgUiInterrupt("int-c1", "tool_call", "客户端需执行工具", "c1"))
    let body = frameBody(RunFinishedEvent("t1", "r1", "tool_use", 1, interrupts: ints))
    @Expect(body.contains("responseSchema"), false)
}

// 消息快照：中断边界上交给客户端重建上下文所需的一切
@Test
func events_messagesSnapshotShape() {
    let calls = ArrayList<AgUiToolCallDTO>()
    calls.add(AgUiToolCallDTO("c1", AgUiFunctionDTO("get_weather", "{\"city\":\"北京\"}")))
    let msgs = ArrayList<AgUiOutMessage>()
    msgs.add(AgUiOutMessage("m1", "user", "查天气", "", ArrayList<AgUiToolCallDTO>()))
    msgs.add(AgUiOutMessage("m2", "assistant", "", "", calls))
    msgs.add(AgUiOutMessage("m3", "tool", "晴", "c1", ArrayList<AgUiToolCallDTO>()))
    let body = frameBody(MessagesSnapshotEvent(msgs))
    @Expect(fieldOf(body, "type"), "MESSAGES_SNAPSHOT")
    let v = JsonValue.parse(body)
    match (v) {
        case JsonValue.Map(m) =>
            match (m.get("messages")) {
                case Some(JsonValue.Array(arr)) =>
                    @Expect(arr.size, 3)
                    let asst = toJsonString(arr[1])
                    @Expect(asst.contains("\"toolCalls\""), true)
                    @Expect(asst.contains("get_weather"), true)
                    let tool = toJsonString(arr[2])
                    @Expect(fieldOf(tool, "toolCallId"), "c1")
                    // 无工具调用的消息不该出现空 toolCalls 字段
                    @Expect(toJsonString(arr[0]).contains("toolCalls"), false)
                case _ => @Fail("messages 缺失")
            }
        case _ => @Fail("帧体应当是 JSON 对象")
    }
}
