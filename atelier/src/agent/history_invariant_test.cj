package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*

// 历史不变式：assistant 带 tool_calls 后必须跟齐每个 call 的结果。
// 违反者会被 OpenAI 兼容接口判 400（且 400 不可重试）→ 整轮作废。

func assistantWithCallsRaw(text: String, calls: ArrayList<(String, String)>,
    stop: StopReason): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    for ((id, name) in calls) {
        blocks.add(ContentBlock.ToolCall(ToolCallBlock(id, name, JsonValue.Map(HashMap<String, JsonValue>()))))
    }
    AssistantMessage(ContentList(blocks), "m", "fake", stop, TokenUsage(0, 0), 0)
}

func assistantWithCalls(text: String, calls: ArrayList<(String, String)>): AssistantMessage {
    assistantWithCallsRaw(text, calls, StopReason.ToolUse)
}

func toolResult(id: String, name: String): ToolResultMessage {
    ToolResultMessage(id, name, ContentList.ofText("ok"), false, 0)
}

func toolCallIds(messages: ArrayList<Message>): ArrayList<String> {
    let ids = ArrayList<String>()
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage => ids.add(tr.toolCallId)
            case _ => ()
        }
    }
    ids
}

func mixedCalls(pairs: Array<(String, String)>): ArrayList<(String, String)> {
    let l = ArrayList<(String, String)>()
    for (p in pairs) { l.add(p) }
    l
}

// 缺结果 → 按调用顺序补齐，且补在已有结果之后（顺序错位会让 provider 认不出配对）
@Test
func invariant_fillsMissingResultsInCallOrder() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑两个命令"), 0))
    msgs.add(assistantWithCalls("", mixedCalls([("c1", "bash"), ("c2", "read_file")])))
    msgs.add(toolResult("c1", "bash"))
    let inserted = ensureToolCallResults(msgs)
    @Expect(inserted, 1)
    @Expect(msgs.size, 4)
    @Expect(toolCallIds(msgs), ArrayList<String>(["c1", "c2"]))
    match (msgs[3]) {
        case tr: ToolResultMessage =>
            @Expect(tr.toolCallId, "c2")
            @Expect(tr.toolName, "read_file")
            @Expect(tr.isError, true)
        case _ => @Fail("第 4 条应当是补出来的工具结果")
    }
}

// 结果已经齐了 → 一条都不补（幂等的另一半：不误伤正常历史）
@Test
func invariant_keepsCompleteHistory() {
    let msgs = ArrayList<Message>()
    msgs.add(assistantWithCalls("", mixedCalls([("c1", "bash"), ("c2", "bash")])))
    msgs.add(toolResult("c1", "bash"))
    msgs.add(toolResult("c2", "bash"))
    @Expect(ensureToolCallResults(msgs), 0)
    @Expect(msgs.size, 3)
}

// 截断/异常终止原因下，assistant 之后直接跟了 user 消息（续跑提示、自验提示）
// → 占位结果必须插在两者之间，不能追加到 user 之后
@Test
func invariant_insertsBetweenAssistantAndUser() {
    let msgs = ArrayList<Message>()
    msgs.add(assistantWithCalls("", mixedCalls([("c1", "bash")])))
    msgs.add(UserMessage(ContentList.ofText("继续"), 0))
    @Expect(ensureToolCallResults(msgs), 1)
    @Expect(msgs.size, 3)
    match (msgs[1]) {
        case tr: ToolResultMessage => @Expect(tr.toolCallId, "c1")
        case _ => @Fail("占位结果应当插在 assistant 与 user 之间")
    }
    match (msgs[2]) {
        case um: UserMessage => ()
        case _ => @Fail("原来的 user 消息应当被挤到最后")
    }
}

// 幂等：补齐后再跑一次不再插入（发请求前会反复调用）
@Test
func invariant_isIdempotent() {
    let msgs = ArrayList<Message>()
    msgs.add(assistantWithCalls("", mixedCalls([("c1", "bash"), ("c2", "bash")])))
    msgs.add(UserMessage(ContentList.ofText("继续"), 0))
    @Expect(ensureToolCallResults(msgs), 2)
    @Expect(ensureToolCallResults(msgs), 0)
    @Expect(msgs.size, 4)
}

// 多回合：只有坏的那一回合被补，好的回合不受影响
@Test
func invariant_onlyPatchesBrokenTurn() {
    let msgs = ArrayList<Message>()
    msgs.add(assistantWithCalls("", mixedCalls([("a1", "bash")])))
    msgs.add(toolResult("a1", "bash"))
    msgs.add(assistantWithCalls("", mixedCalls([("b1", "bash"), ("b2", "bash")])))
    msgs.add(toolResult("b1", "bash"))
    @Expect(ensureToolCallResults(msgs), 1)
    @Expect(toolCallIds(msgs), ArrayList<String>(["a1", "b1", "b2"]))
}

// 纯文本历史（没有工具调用）→ 不动
@Test
func invariant_ignoresPlainTextHistory() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("你好"), 0))
    msgs.add(AssistantMessage(ContentList.ofText("你好"), "m", "fake", StopReason.EndTurn, TokenUsage(0, 0), 0))
    @Expect(ensureToolCallResults(msgs), 0)
    @Expect(msgs.size, 2)
}

// 同一条 assistant 里重复的 call id 只补一次（否则会插出多余结果，provider 仍会拒）
@Test
func invariant_ignoresAnsweredDuplicateIds() {
    let msgs = ArrayList<Message>()
    msgs.add(assistantWithCalls("", mixedCalls([("c1", "bash"), ("c1", "bash")])))
    msgs.add(toolResult("c1", "bash"))
    @Expect(ensureToolCallResults(msgs), 0)
}
