package atelier.provider

import atelier.message.*
import atelier.event.EventStream
import jsonvalue.*
import std.collection.*

public class OpenAIProvider <: Provider {
    private let provName: String
    private let baseURL: String
    private let apiKey: String

    public init(name: String, baseURL: String, apiKey: String) {
        this.provName = name
        this.baseURL = baseURL
        this.apiKey = apiKey
    }

    public func name(): String { this.provName }

    public func chat(req: ChatRequest): ChatResponse {
        // TODO: implement synchronous chat via HTTP POST
        throw Exception("OpenAI sync chat not yet implemented")
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        // TODO: implement streaming chat via HTTP POST + SSE
        throw Exception("OpenAI streaming chat not yet implemented")
    }
}
