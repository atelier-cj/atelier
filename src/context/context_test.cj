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
