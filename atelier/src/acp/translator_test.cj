package atelier.acp

import std.collection.*
import jsonvalue.*
import atelier.agent.*
import atelier.message.*

// ---------- 辅助构造 ----------

func assistantMsg(content: ContentList, stopReason: StopReason, usage: TokenUsage): AssistantMessage {
    AssistantMessage(content, "", "", stopReason, usage, 0)
}

func textDeltaEvent(delta: String): MessageUpdateEvent {
    MessageUpdateEvent(assistantMsg(ContentList.ofText(delta), StopReason.EndTurn, TokenUsage(0, 0)), delta)
}

func toolCallMsg(callId: String, name: String, args: JsonValue, usage: TokenUsage): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(ToolCallBlock(callId, name, args)))
    assistantMsg(ContentList(blocks), StopReason.ToolUse, usage)
}

func argsObject(): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["cmd"] = JsonValue.String("ls -la")
    JsonValue.Map(m)
}

// ---------- 文本增量 → agent_message_chunk ----------

@Test
func translator_textDeltaEmitsAgentMessageChunk() {
    let t = AcpTranslator()
    let out = t.translate(textDeltaEvent("你好"))
    @Expect(out.size, 1)
    @Expect(out[0].sessionUpdate, "agent_message_chunk")
    match (out[0].content) {
        case Some(c) =>
            match (c.text) {
                case Some(v) => @Expect(v, "你好")
                case None => @Fail("missing content text")
            }
        case None => @Fail("missing content")
    }
}

// 同回合连续增量 → 同一 messageId；回合切换 → 新 messageId
@Test
func translator_textChunksShareMessageIdWithinTurn() {
    let t = AcpTranslator()
    t.translate(TurnStartEvent())
    let out1 = t.translate(textDeltaEvent("你"))
    let out2 = t.translate(textDeltaEvent("好"))
    let id1 = out1[0].messageId
    let id2 = out2[0].messageId
    match (id1) {
        case Some(a) =>
            match (id2) {
                case Some(b) => @Expect(a == b, true)
                case None => @Fail("second chunk missing messageId")
            }
        case None => @Fail("first chunk missing messageId")
    }
    // 下一回合：新 id
    t.translate(TurnStartEvent())
    let out3 = t.translate(textDeltaEvent("哈"))
    match (out3[0].messageId) {
        case Some(c) =>
            match (id1) {
                case Some(a) => @Expect(a != c, true)
                case None => ()
            }
        case None => @Fail("third chunk missing messageId")
    }
}

// 空 delta 不产生更新
@Test
func translator_emptyDeltaNoop() {
    let t = AcpTranslator()
    @Expect(t.translate(TurnStartEvent()).size, 0)
    @Expect(t.translate(textDeltaEvent("")).size, 0)
    @Expect(t.translate(AgentStartEvent("sess_1")).size, 0)
    @Expect(t.translate(TurnEndEvent(assistantMsg(ContentList.ofText("ok"), StopReason.EndTurn, TokenUsage(0, 0)), ArrayList<ToolResultMessage>())).size, 0)
}

// ---------- 工具调用 → tool_call / tool_call_update ----------

// assistant 携带 tool call → tool_call（pending + kind 映射 + rawInput）
@Test
func translator_toolCallDeclaredOnMessageEnd() {
    let t = AcpTranslator()
    let msg = toolCallMsg("call_1", "bash", argsObject(), TokenUsage(0, 0))
    let out = t.translate(MessageEndEvent(msg))
    @Expect(out.size, 1)
    @Expect(out[0].sessionUpdate, "tool_call")
    match (out[0].toolCallId) {
        case Some(v) => @Expect(v, "call_1")
        case None => @Fail("missing toolCallId")
    }
    match (out[0].title) {
        case Some(v) => @Expect(v, "bash")
        case None => @Fail("missing title")
    }
    match (out[0].kind) {
        case Some(v) => @Expect(v, "execute")
        case None => @Fail("missing kind")
    }
    match (out[0].status) {
        case Some(v) => @Expect(v, "pending")
        case None => @Fail("missing status")
    }
    match (out[0].rawInput) {
        case Some(v) =>
            match (v["cmd"]) {
                case Some(JsonValue.String(s)) => @Expect(s, "ls -la")
                case _ => @Fail("rawInput.cmd mismatch")
            }
        case None => @Fail("missing rawInput")
    }
}

// 多工具调用 → 每条一个 tool_call
@Test
func translator_multipleToolCallsDeclared() {
    let t = AcpTranslator()
    let b1 = ArrayList<ContentBlock>()
    b1.add(ContentBlock.ToolCall(ToolCallBlock("c1", "bash", argsObject())))
    b1.add(ContentBlock.ToolCall(ToolCallBlock("c2", "read_file", argsObject())))
    let msg = assistantMsg(ContentList(b1), StopReason.ToolUse, TokenUsage(0, 0))
    let out = t.translate(MessageEndEvent(msg))
    @Expect(out.size, 2)
    @Expect(out[0].sessionUpdate, "tool_call")
    @Expect(out[1].sessionUpdate, "tool_call")
    match (out[0].kind) {
        case Some(v) => @Expect(v, "execute")
        case None => @Fail("c1 kind")
    }
    match (out[1].kind) {
        case Some(v) => @Expect(v, "read")
        case None => @Fail("c2 kind")
    }
}

// 执行开始 → in_progress；结束成功 → completed + 结果文本；失败 → failed
@Test
func translator_toolExecutionLifecycleUpdates() {
    let t = AcpTranslator()
    let s = t.translate(ToolExecutionStartEvent("call_1", "bash"))
    @Expect(s.size, 1)
    @Expect(s[0].sessionUpdate, "tool_call_update")
    match (s[0].status) {
        case Some(v) => @Expect(v, "in_progress")
        case None => @Fail("start status")
    }
    let e1 = t.translate(ToolExecutionEndEvent("call_1", "done output", false))
    @Expect(e1.size, 1)
    match (e1[0].status) {
        case Some(v) => @Expect(v, "completed")
        case None => @Fail("end status")
    }
    match (e1[0].toolContent) {
        case Some(items) =>
            @Expect(items.size, 1)
            match (items[0].content) {
                case Some(c) =>
                    match (c.text) {
                        case Some(v) => @Expect(v, "done output")
                        case None => @Fail("result text")
                    }
                case None => @Fail("tool content missing")
            }
        case None => @Fail("missing toolContent")
    }
    let e2 = t.translate(ToolExecutionEndEvent("call_1", "boom", true))
    match (e2[0].status) {
        case Some(v) => @Expect(v, "failed")
        case None => @Fail("failed status")
    }
}

// 工具进度 → content 文本
@Test
func translator_toolProgressBecomesContent() {
    let t = AcpTranslator()
    let s = t.translate(ToolExecutionUpdateEvent("call_1", "processing..."))
    @Expect(s.size, 1)
    @Expect(s[0].sessionUpdate, "tool_call_update")
    match (s[0].toolContent) {
        case Some(items) =>
            @Expect(items.size, 1)
            match (items[0].content) {
                case Some(c) =>
                    match (c.text) {
                        case Some(v) => @Expect(v, "processing...")
                        case None => @Fail("progress text")
                    }
                case None => @Fail("progress content missing")
            }
        case None => @Fail("missing toolContent")
    }
}

// 无文本块的 assistant 结束（纯 tool call）→ 不发 agent_message_chunk，仍发 tool_call
@Test
func translator_pureToolCallNoTextChunk() {
    let t = AcpTranslator()
    t.translate(TurnStartEvent())
    let out = t.translate(MessageEndEvent(toolCallMsg("c9", "bash", argsObject(), TokenUsage(0, 0))))
    @Expect(out.size, 1)
    @Expect(out[0].sessionUpdate, "tool_call")
}

// ---------- kind 映射 ----------

@Test
func translator_toolKindMapping() {
    @Expect(toolKindFor("bash"), "execute")
    @Expect(toolKindFor("run_script"), "execute")
    @Expect(toolKindFor("read_file"), "read")
    @Expect(toolKindFor("grep"), "search")
    @Expect(toolKindFor("glob"), "search")
    @Expect(toolKindFor("write_file"), "edit")
    @Expect(toolKindFor("edit_file"), "edit")
    @Expect(toolKindFor("fetch_url"), "fetch")
    @Expect(toolKindFor("delete_node"), "delete")
    @Expect(toolKindFor("mcp_playwright_click"), "other")
    @Expect(toolKindFor("todo"), "other")
    @Expect(toolKindFor("custom_thing"), "other")
}

// ---------- 组合场景：回合内文本 + 工具 ----------

@Test
func translator_turnWithTextThenTools() {
    let t = AcpTranslator()
    t.translate(TurnStartEvent())
    let chunks = t.translate(textDeltaEvent("我来查一下"))
    @Expect(chunks[0].sessionUpdate, "agent_message_chunk")
    let msg = toolCallMsg("call_2", "glob", argsObject(), TokenUsage(0, 0))
    let calls = t.translate(MessageEndEvent(msg))
    @Expect(calls.size, 1)
    @Expect(calls[0].sessionUpdate, "tool_call")
}

// 异常回合（provider 报错）必须把失败文本作为可见消息推给宿主：
// 否则 ACP 侧只看到一个无理由的 stopReason: refusal，评测/日志都无从定位。
@Test
func translator_errorTurnEmitsVisibleFailureText() {
    let tr = AcpTranslator()
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("[provider error] HTTP 429"))
    let failed = AssistantMessage(ContentList(blocks), "", "", StopReason.Error, TokenUsage(0, 0), 0)
    let ups = tr.translate(TurnEndEvent(failed, ArrayList<ToolResultMessage>()))
    @Expect(ups.size, 1)
}

// 正常回合不重复推送（文本增量已经逐条发过）。
@Test
func translator_normalTurnEndEmitsNothing() {
    let tr = AcpTranslator()
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("正常回答"))
    let ok = AssistantMessage(ContentList(blocks), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
    @Expect(tr.translate(TurnEndEvent(ok, ArrayList<ToolResultMessage>())).size, 0)
}
