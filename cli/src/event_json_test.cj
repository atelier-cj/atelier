package cli

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.agent.*

// 机器可读运行日志（`run --json-events`）的用例：JSONL 只有在**严格合法**时才有意义
// —— 消费方按行解析，一行坏掉整条记录就废了，所以转义与控制字符是重点。

func asstMsg(text: String, stop: StopReason, usage: TokenUsage): AssistantMessage {
    AssistantMessage(ContentList.ofText(text), "m", "fake", stop, usage, 0)
}

func lastLine(ev: AgentEvent): String {
    let lines = jsonLinesFromEvent(ev)
    @Expect(lines.size >= 1, true)
    lines[lines.size - 1]
}

// 文本里的引号/反斜杠/换行必须仍然是**合法 JSON**：消费方按行 JSON.parse，一行坏掉整条废掉。
// 这里直接拿 JsonValue 反解回验证，等于用官方解析器当裁判（而不是比对我自己拼的转义串）。
@Test
func jsonLines_textStaysParseable() {
    let nasty = "line1\nline2 \"q\" back\\slash \u{1} ctrl \u{1f} 中文 ok"
    let line = lastLine(MessageEndEvent(asstMsg(nasty, StopReason.EndTurn, TokenUsage(1, 2))))
    @Expect(line.contains("\n"), false)
    let parsed = JsonValue.parse(line)
    match (parsed) {
        case JsonValue.Map(m) =>
            match (m.get("text")) {
                case Some(JsonValue.String(s)) => @Expect(s, nasty)
                case _ => @Fail("text 字段应当能原样取回")
            }
        case _ => @Fail("整行应当是 JSON 对象")
    }
}

// 消息行带停因与 token 用量：评测要看「一轮花了多少 token、怎么结束的」
@Test
func jsonLines_messageCarriesStopReasonAndUsage() {
    let line = lastLine(MessageEndEvent(asstMsg("done", StopReason.EndTurn, TokenUsage(123, 45))))
    @Expect(line, "{\"type\":\"message\",\"role\":\"assistant\",\"text\":\"done\"," +
        "\"stopReason\":\"end_turn\",\"usage\":{\"input\":123,\"output\":45," +
        "\"cacheRead\":0,\"cacheWrite\":0}}")
}

// 带工具调用的消息展开成「1 条 message + N 条 tool_call」，且 args 原样是 JSON
@Test
func jsonLines_messageWithToolCallsExpands() {
    let args = JsonValue.Map(HashMap<String, JsonValue>([("command", JsonValue.String("ls -la"))]))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("先看一眼"))
    blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_1", "bash", args)))
    let msg = AssistantMessage(ContentList(blocks), "m", "fake", StopReason.ToolUse, TokenUsage(10, 2), 0)
    let lines = jsonLinesFromEvent(MessageEndEvent(msg))
    @Expect(lines.size, 2)
    @Expect(lines[1].contains("\"type\":\"tool_call\""), true)
    @Expect(lines[1].contains("\"id\":\"call_1\""), true)
    @Expect(lines[1].contains("\"name\":\"bash\""), true)
    @Expect(lines[1].contains("ls -la"), true)
}

// 工具执行事件：实际执行的开始/结束（与 tool_call 区分开）
@Test
func jsonLines_toolExecution() {
    @Expect(lastLine(ToolExecutionStartEvent("call_1", "bash")),
        "{\"type\":\"tool_start\",\"id\":\"call_1\",\"name\":\"bash\"}")
    @Expect(lastLine(ToolExecutionEndEvent("call_1", "output", false)),
        "{\"type\":\"tool_result\",\"id\":\"call_1\",\"ok\":true,\"bytes\":6}")
    @Expect(lastLine(ToolExecutionEndEvent("call_1", "boom", true)),
        "{\"type\":\"tool_result\",\"id\":\"call_1\",\"ok\":false,\"bytes\":4}")
}

// 回合与压缩事件：压缩是评测关心的行为（触发时机与前后 token）
@Test
func jsonLines_turnAndCompaction() {
    @Expect(lastLine(TurnEndEvent(asstMsg("x", StopReason.ToolUse, TokenUsage(5, 6)), ArrayList<ToolResultMessage>())),
        "{\"type\":\"turn_end\",\"stopReason\":\"tool_use\"," +
        "\"usage\":{\"input\":5,\"output\":6,\"cacheRead\":0,\"cacheWrite\":0}}")
    @Expect(lastLine(CompactionEvent("usage", 1000, 200)),
        "{\"type\":\"compaction\",\"reason\":\"usage\",\"tokensBefore\":1000,\"tokensAfter\":200}")
}

// 收尾与开始事件
@Test
func jsonLines_startAndEnd() {
    @Expect(lastLine(AgentStartEvent("sess_1")),
        "{\"type\":\"agent_start\",\"sessionId\":\"sess_1\"}")
    @Expect(lastLine(AgentEndEvent(ArrayList<Message>())), "{\"type\":\"agent_end\"}")
    @Expect(lastLine(TurnStartEvent()), "{\"type\":\"turn_start\"}")
}

// 增量事件不进 JSONL：实时呈现归 stderr，JSONL 只留可核算的事实
@Test
func jsonLines_deltasAreNotEmitted() {
    @Expect(jsonLinesFromEvent(MessageUpdateEvent(asstMsg("a", StopReason.EndTurn, TokenUsage(0, 0)), "a")).size, 0)
}

// 缓存命中量必须出现在 usage 里：否则消费方无法区分「真没命中」与「没上报」
@Test
func jsonLines_usageCarriesCacheTokens() {
    let msg = AssistantMessage(ContentList.ofText("x"), "m", "fake", StopReason.EndTurn,
        TokenUsage(1000, 20, cacheReadTokens: 896, cacheWriteTokens: 0), 0)
    let line = lastLine(MessageEndEvent(msg))
    @Expect(line.contains("\"cacheRead\":896"), true)
    @Expect(line.contains("\"cacheWrite\":0"), true)
    let parsed = JsonValue.parse(line)
    match (parsed) {
        case JsonValue.Map(m) =>
            match (m.get("usage")) {
                case Some(JsonValue.Map(u)) =>
                    // jsonvalue 的数字统一是 Number(Float64)
                    match (u.get("cacheRead")) {
                        case Some(JsonValue.Number(v)) => @Expect(Int64(v), 896)
                        case _ => @Fail("usage.cacheRead 应当是数字")
                    }
                case _ => @Fail("usage 应当是对象")
            }
        case _ => @Fail("整行应当是 JSON 对象")
    }
}
