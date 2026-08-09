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

func bigText(): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < 100) { sb.append("x"); i++ }
    sb.toString()
}

// 回归：单条消息即超过 keepRecent 预算时，切点必须落在该消息之后（此前 i-- 过度导致 cutIndex=0 不压缩）
@Test
func compactWithSummary_singleBigMessageTriggersCut() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigText()), 0))  // 30 tokens
    msgs.add(UserMessage(ContentList.ofText("tail"), 0))     // 6 tokens
    let out = compactWithSummary(msgs, 10, "摘要", 36)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(cm.summary, "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
    match (out[1]) {
        case um: UserMessage => @Expect(um.content.blocks().size, 1)
        case _ => @Fail("expected tail user message")
    }
}

// 回归：compactMessages 同样修复（单条大消息达标时替换为摘要）
@Test
func compactMessages_singleBigMessageTriggersCut() {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigText()), 0))  // 30 tokens
    msgs.add(UserMessage(ContentList.ofText("tail"), 0))     // 6 tokens
    // total=36 > reserve=5，threshold=30-5=25 < 36 → 触发压缩
    let out = compactMessages(msgs, 30, 5, 10)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(cm.tokensBefore, 30)
        case _ => @Fail("expected CompactionMessage")
    }
}

// 多消息：累加到从尾数第 2 条时达标，切点在该条之后（尾部保留）
@Test
func compactWithSummary_multiMessageReach() {
    let msgs = ArrayList<Message>()
    for (i in 0..6) { msgs.add(UserMessage(ContentList.ofText("m"), 0)) }  // 每条 5 tokens
    let out = compactWithSummary(msgs, 8, "摘要", 30)
    @Expect(out.size, 2)
    match (out[0]) {
        case cm: CompactionMessage => @Expect(cm.summary, "摘要")
        case _ => @Fail("expected CompactionMessage")
    }
    match (out[1]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t, "m")
                case _ => @Fail("expected text block")
            }
        case _ => @Fail("expected tail user message")
    }
}
