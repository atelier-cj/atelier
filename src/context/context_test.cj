package atelier.context

import atelier.message.*
import std.collection.*
import jsonvalue.*

func msg(text: String): Message {
    UserMessage(ContentList.ofText(text), 0)
}

@Test
func estimateText() {
    let t = estimateTextTokens("hello world")
    @Expect(t > 0, true)
}

@Test
func compactLarge() {
    let msgs = ArrayList<Message>()
    for (i in 0..20) { msgs.add(msg("message number ${i}")) }
    let result = compactMessages(msgs, 100, 20, 20)
    @Expect(result.size > 0, true)
}

@Test
func smallFits() {
    let msgs = ArrayList<Message>([msg("hi")])
    let result = compactMessages(msgs, 100, 20, 20)
    @Expect(result.size, 1)
}

@Test
func modelRegistry_knownModel() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("gpt-4o"), 128000)
}

@Test
func modelRegistry_deepseek() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("deepseek-chat"), 65536)
}

@Test
func modelRegistry_unknownModelDefaults() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("unknown-model-123"), reg.defaultContextWindow)
}

@Test
func modelRegistry_claudeSonnet() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("claude-sonnet-4"), 200000)
}

@Test
func modelRegistry_gemini() {
    let reg = ModelContextRegistry()
    @Expect(reg.get("gemini-1.5-pro"), 1048576)
}

@Test
func compactionConfig_defaultTemplateRenders() {
    let cfg = CompactionConfig()
    let out = renderCompactionPrompt(cfg, "对话内容", None, 16384)
    @Expect(out.contains("对话内容"), true)
    @Expect(out.contains("16384"), true)
    @Expect(out.contains("previous_summary"), false)
}

@Test
func compactionConfig_previousSummaryConditional() {
    let cfg = CompactionConfig()
    let out = renderCompactionPrompt(cfg, "对话内容", Some("历史摘要"), 16384)
    @Expect(out.contains("历史摘要"), true)
}

@Test
func compactionConfig_customTemplate() {
    let cfg = CompactionConfig(
        true, 16384, 20000,
        "压缩以下对话：\n{{conversation}}\n{{#previous_summary}}旧摘要：{{previous_summary}}{{/previous_summary}}",
        None, None)
    let out = renderCompactionPrompt(cfg, "对话", Some("旧"), 16384)
    @Expect(out.contains("旧摘要：旧"), true)
    let out2 = renderCompactionPrompt(cfg, "对话", None, 16384)
    @Expect(out2.contains("旧摘要"), false)
}

@Test
func compactionConfig_schemaValid() {
    let cfg = CompactionConfig()
    let schema = JsonValue.parse("{\"required\":[\"goal\"],\"types\":{\"goal\":\"string\"}}")
    match (schema) {
        case JsonValue.Map(m) =>
            @Expect(validateSummary(cfg, m, "{\"goal\":\"完成\"}"), true)
            @Expect(validateSummary(cfg, m, "{\"goal\":123}"), false)
            @Expect(validateSummary(cfg, m, "{\"other\":\"x\"}"), false)
        case _ => @Fail("schema parse failed")
    }
}

@Test
func compactionConfig_summaryReplacesAllWhenKeepZero() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("a"), 0))
    msgs.add(UserMessage(ContentList.ofText("b"), 0))
    let out = compactWithSummary(msgs, 0, "摘要", 10)
    @Expect(out.size, 1)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(cm.summary, "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
}

@Test
func compactionConfig_summaryKeepsRecent() {
    let msgs = ArrayList<Message>()
    for (i in 0..=5) { msgs.add(UserMessage(ContentList.ofText("消息${i}"), 0)) }
    let out = compactWithSummary(msgs, 100000, "摘要", 10)
    @Expect(out.size, 6)
    var hasSummary = false
    for (m in out) {
        match (m) {
            case cm: CompactionMessage => hasSummary = true
            case _ => ()
        }
    }
    @Expect(hasSummary, false)
}
