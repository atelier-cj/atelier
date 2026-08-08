package atelier.provider

import atelier.message.*
import jsonvalue.*
import std.collection.*
import std.env.getVariable

@Test
@Tag[Integration]
public class ProviderIntegrationTest {
    @TestCase
    func anthropic_syncChat() {
        let provider = AnthropicProvider("test-anthropic",
            "https://api.deepseek.com/anthropic",
            match (getVariable("DEEPSEEK_API_KEY")) { case Some(k) => k; case None => "" })
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Say hello in one word"), 0))
        let req = ChatRequest("deepseek-chat", msgs, 0.7, 100, None, ArrayList<OpenAITool>())
        let resp = provider.chat(req)
        @Expect(resp.message.content.blocks().size > 0, true)
    }

    @TestCase
    func ollama_toolCall() {
        let provider = OllamaProvider("test-ollama", "http://192.168.3.6:11434")
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Run ls /tmp"), 0))
        let tools = ArrayList<OpenAITool>()
        tools.add(OpenAITool("bash", "Run shell commands", JsonValue.Map(HashMap<String, JsonValue>())))
        let req = ChatRequest("qwen3.5:2b", msgs, 0.7, 200, None, tools)
        let resp = provider.chat(req)
        let isToolUse = match (resp.message.stopReason) { case StopReason.ToolUse => true; case _ => false }
        @Expect(isToolUse, true)
        let tcs = resp.message.toolCalls()
        @Expect(tcs.size > 0, true)
        @Expect(tcs[0].name, "bash")
    }

    @TestCase
    func ollama_syncChat() {
        let provider = OllamaProvider("test-ollama", "http://192.168.3.6:11434")
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Say hello in one word"), 0))
        let req = ChatRequest("qwen3.5:2b", msgs, 0.7, 100, None, ArrayList<OpenAITool>())
        let resp = provider.chat(req)
        @Expect(resp.message.content.blocks().size > 0, true)
    }

    @TestCase
    func ollama_streamingChat() {
        let provider = OllamaProvider("test-ollama", "http://192.168.3.6:11434")
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Count to 3 slowly"), 0))
        let req = ChatRequest("qwen3.5:2b", msgs, 0.7, 200, None, ArrayList<OpenAITool>())
        let stream = provider.chatStreaming(req)
        var deltaCount: Int64 = 0
        while (true) {
            match (stream.receive(60 * Duration.second)) {
                case Some(delta) =>
                    deltaCount++
                    match (delta.finishReason) {
                        case Some(_) => break
                        case None => ()
                    }
                case None => break
            }
        }
        let result = stream.result()
        @Expect(deltaCount > 0, true)
        @Expect(result.content.blocks().size > 0, true)
    }

    @TestCase
    func openai_syncChat() {
        let provider = OpenAIProvider(
            "test-openai",
            "http://192.168.3.6:8089",
            "524dc2ca-17c8-11f1-8b4e-6f93fd1a458a")
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Say hello in one word"), 0))
        let req = ChatRequest("qwen3.5-2b", msgs, 0.7, 100, None, ArrayList<OpenAITool>())
        let resp = provider.chat(req)
        @Expect(resp.message.content.blocks().size > 0, true)
    }

    @TestCase
    func openai_streamingChat() {
        let provider = OpenAIProvider(
            "test-openai",
            "http://192.168.3.6:8089",
            "524dc2ca-17c8-11f1-8b4e-6f93fd1a458a")
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText("Count to 3"), 0))
        let req = ChatRequest("qwen3.5-2b", msgs, 0.7, 200, None, ArrayList<OpenAITool>())
        let stream = provider.chatStreaming(req)
        var deltaCount: Int64 = 0
        while (true) {
            match (stream.receive(10 * Duration.second)) {
                case Some(delta) =>
                    deltaCount++
                    match (delta.finishReason) {
                        case Some(_) => break
                        case None => ()
                    }
                case None => break
            }
        }
        let result = stream.result()
        @Expect(deltaCount > 0, true)
        @Expect(result.content.blocks().size > 0 || result.reasoningContent.size > 0, true)
    }
}
