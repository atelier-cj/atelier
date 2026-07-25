package atelier.provider

import atelier.message.*
import std.collection.*

@Test
func openai_syncChat() {
    let provider = OpenAIProvider(
        "test-openai",
        "http://192.168.3.6:8089",
        "524dc2ca-17c8-11f1-8b4e-6f93fd1a458a")
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("Say hello in one word"), 0))
    let req = ChatRequest("qwen3.5-2b", msgs, 0.7, 100)
    let resp = provider.chat(req)
    @Expect(resp.message.content.blocks().size > 0, true)
}

@Test
func openai_streamingChat() {
    let provider = OpenAIProvider(
        "test-openai",
        "http://192.168.3.6:8089",
        "524dc2ca-17c8-11f1-8b4e-6f93fd1a458a")
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("Count to 3"), 0))
    let req = ChatRequest("qwen3.5-2b", msgs, 0.7, 200)
    let stream = provider.chatStreaming(req)
    var full = StringBuilder()
    while (true) {
        match (stream.receive(5 * Duration.second)) {
            case Some(delta) =>
                full.append(delta.delta)
                match (delta.finishReason) {
                    case Some(_) => break
                    case None => ()
                }
            case None => break
        }
    }
    let result = stream.result()
    @Expect(full.size > 0, true)
    @Expect(result.content.blocks().size > 0, true)
}
