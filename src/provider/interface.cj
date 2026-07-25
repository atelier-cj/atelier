package atelier.provider

import std.collection.*
import atelier.message.*
import atelier.event.EventStream

public struct ChatRequest {
    public let model: String
    public let messages: ArrayList<Message>
    public let temperature: Float64
    public let maxTokens: Int64

    public init(model: String, messages: ArrayList<Message>, temperature: Float64, maxTokens: Int64) {
        this.model = model; this.messages = messages
        this.temperature = temperature; this.maxTokens = maxTokens
    }
}

public struct ChatResponse {
    public let message: AssistantMessage

    public init(message: AssistantMessage) {
        this.message = message
    }
}

public interface Provider {
    func name(): String
    func chat(req: ChatRequest): ChatResponse
    func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage>
}

public struct ChatDelta {
    public let delta: String
    public let finishReason: Option<StopReason>

    public init(delta: String, finishReason: Option<StopReason>) {
        this.delta = delta; this.finishReason = finishReason
    }
}
