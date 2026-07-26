package atelier.context

import atelier.message.*
import std.collection.*

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
