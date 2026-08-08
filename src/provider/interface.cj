package atelier.provider

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.event.EventStream

public struct ChatRequest {
    public let model: String
    public let messages: ArrayList<Message>
    public let temperature: Float64
    public let maxTokens: Int64
    public let reasoningEffort: Option<String>
    public let tools: ArrayList<OpenAITool>
    public let extra: HashMap<String, JsonValue>

    public init(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxTokens: Int64,
        reasoningEffort: Option<String>,
        tools: ArrayList<OpenAITool>,
        extra: HashMap<String, JsonValue>) {
        this.model = model; this.messages = messages
        this.temperature = temperature; this.maxTokens = maxTokens
        this.reasoningEffort = reasoningEffort
        this.tools = tools; this.extra = extra
    }

    public init(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxTokens: Int64,
        reasoningEffort: Option<String>,
        tools: ArrayList<OpenAITool>) {
        this.model = model; this.messages = messages
        this.temperature = temperature; this.maxTokens = maxTokens
        this.reasoningEffort = reasoningEffort
        this.tools = tools; this.extra = HashMap<String, JsonValue>()
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
    public let reasoningDelta: String
    public let finishReason: Option<StopReason>

    public init(delta: String, reasoningDelta: String,
        finishReason: Option<StopReason>) {
        this.delta = delta; this.reasoningDelta = reasoningDelta
        this.finishReason = finishReason
    }
}
