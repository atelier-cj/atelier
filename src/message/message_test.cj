package atelier.message

import std.collection.*
import jsonvalue.*

func makeTextContent(text: String): ContentList {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    return ContentList(blocks)
}

@Test
func userMessage_role() {
    let msg = UserMessage(makeTextContent("hi"), 1000)
    match (msg.role()) {
        case MessageRole.User => ()
        case _ => @Fail("expected User role")
    }
}

@Test
func userMessage_content() {
    let content = makeTextContent("hello")
    let msg = UserMessage(content, 1000)
    match (msg.content.blocks()[0]) {
        case TextBlock(text) => @Expect(text, "hello")
        case _ => @Fail("expected TextBlock")
    }
    @Expect(msg.timestamp, 1000)
}

@Test
func assistantMessage_role() {
    let usage = TokenUsage(10, 20)
    let msg = AssistantMessage(makeTextContent("hi"), "gpt-4", "openai", StopReason.EndTurn, usage, 1000)
    match (msg.role()) {
        case MessageRole.Assistant => ()
        case _ => @Fail("expected Assistant role")
    }
}

@Test
func assistantMessage_allFields() {
    let usage = TokenUsage(10, 20)
    let msg = AssistantMessage(makeTextContent("hi"), "gpt-4", "openai", StopReason.EndTurn, usage, 1000)
    @Expect(msg.model, "gpt-4")
    @Expect(msg.provider, "openai")
    @Expect(msg.usage.inputTokens, 10)
    @Expect(msg.usage.outputTokens, 20)
    @Expect(msg.timestamp, 1000)
    match (msg.stopReason) {
        case StopReason.EndTurn => ()
        case _ => @Fail("expected EndTurn stop reason")
    }
}

@Test
func assistantMessage_toolCalls_empty() {
    let usage = TokenUsage(0, 0)
    let msg = AssistantMessage(makeTextContent("hi"), "gpt-4", "openai", StopReason.EndTurn, usage, 1000)
    let calls = msg.toolCalls()
    @Expect(calls.size, 0)
}

@Test
func assistantMessage_toolCalls_delegates() {
    let tc = ToolCallBlock("call_1", "get_weather", JsonValue.String("{}"))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(tc))
    let content = ContentList(blocks)
    let usage = TokenUsage(0, 0)
    let msg = AssistantMessage(content, "gpt-4", "openai", StopReason.ToolUse, usage, 1000)
    let calls = msg.toolCalls()
    @Expect(calls.size, 1)
    @Expect(calls[0].id, "call_1")
}

@Test
func toolResultMessage_role() {
    let msg = ToolResultMessage("call_1", "get_weather", makeTextContent("sunny"), false, 1000)
    match (msg.role()) {
        case MessageRole.ToolResult => ()
        case _ => @Fail("expected ToolResult role")
    }
}

@Test
func toolResultMessage_allFields() {
    let msg = ToolResultMessage("call_1", "get_weather", makeTextContent("sunny"), true, 2000)
    @Expect(msg.toolCallId, "call_1")
    @Expect(msg.toolName, "get_weather")
    @Expect(msg.isError, true)
    @Expect(msg.timestamp, 2000)
}

@Test
func compactionMessage_role() {
    let msg = CompactionMessage("chat summary", 500, 1000)
    match (msg.role()) {
        case MessageRole.Compaction => ()
        case _ => @Fail("expected Compaction role")
    }
}

@Test
func compactionMessage_allFields() {
    let msg = CompactionMessage("chat summary", 500, 2000)
    @Expect(msg.summary, "chat summary")
    @Expect(msg.tokensBefore, 500)
    @Expect(msg.timestamp, 2000)
}

@Test
func messagePolymorphism() {
    let messages = ArrayList<Message>()
    messages.add(UserMessage(makeTextContent("u"), 1))
    let usage = TokenUsage(0, 0)
    messages.add(AssistantMessage(makeTextContent("a"), "m", "p", StopReason.EndTurn, usage, 2))
    messages.add(ToolResultMessage("c", "t", makeTextContent("r"), false, 3))
    messages.add(CompactionMessage("s", 100, 4))
    @Expect(messages.size, 4)
    match (messages[0].role()) {
        case MessageRole.User => ()
        case _ => @Fail("expected User")
    }
    match (messages[1].role()) {
        case MessageRole.Assistant => ()
        case _ => @Fail("expected Assistant")
    }
    match (messages[2].role()) {
        case MessageRole.ToolResult => ()
        case _ => @Fail("expected ToolResult")
    }
    match (messages[3].role()) {
        case MessageRole.Compaction => ()
        case _ => @Fail("expected Compaction")
    }
}

@Test
func tokenUsage_struct() {
    let usage = TokenUsage(100, 50)
    @Expect(usage.inputTokens, 100)
    @Expect(usage.outputTokens, 50)
}

@Test
func stopReason_values_construct() {
    let reason = StopReason.EndTurn
    match (reason) {
        case StopReason.EndTurn => ()
        case _ => @Fail("expected EndTurn")
    }
}
