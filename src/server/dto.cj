package atelier.server

import jsonvalue.*
import atelier.message.*
import std.collection.*

public struct ChatRequestDTO {
    public let agent: String
    public let messages: ArrayList<MessageDTO>
    public let stream: Bool

    public init(agent: String, messages: ArrayList<MessageDTO>, stream: Bool) {
        this.agent = agent; this.messages = messages; this.stream = stream
    }
}

public struct MessageDTO {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        this.role = role; this.content = content
    }
}

public struct AgentConfigDTO {
    public let name: String
    public let description: Option<String>
    public let systemPrompt: String
    public let model: String
    public let provider: Option<String>
    public let tools: ArrayList<String>
    public let skills: ArrayList<String>
    public let maxTurns: Int64
    public let temperature: Float64

    public init(name: String, description: Option<String>, systemPrompt: String,
        model: String, provider: Option<String>, tools: ArrayList<String>,
        skills: ArrayList<String>, maxTurns: Int64, temperature: Float64) {
        this.name = name; this.description = description; this.systemPrompt = systemPrompt
        this.model = model; this.provider = provider; this.tools = tools
        this.skills = skills; this.maxTurns = maxTurns; this.temperature = temperature
    }
}

public struct SSEEvent {
    public let id: String
    public let event: String
    public let data: String
    public init(id: String, event: String, data: String) {
        this.id = id; this.event = event; this.data = data
    }
}
