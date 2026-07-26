package atelier.server

import atelier.message.*
import stdx.encoding.json.stream.*
import std.collection.*

public struct ChatRequestDTO <: JsonSerializable & JsonDeserializable<ChatRequestDTO> {
    public let agent: String
    public let messages: ArrayList<MessageDTO>
    public let stream: Bool

    public init(agent: String, messages: ArrayList<MessageDTO>, stream: Bool) {
        this.agent = agent; this.messages = messages; this.stream = stream
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("agent").writeValue(this.agent)
        w.writeName("messages").writeValue(this.messages)
        w.writeName("stream").writeValue(this.stream)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ChatRequestDTO {
        var agent = ""; var msgs = ArrayList<MessageDTO>(); var stream = false
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "agent" => agent = r.readValue<String>()
                case "messages" => msgs = r.readValue<ArrayList<MessageDTO>>()
                case "stream" => stream = r.readValue<Bool>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ChatRequestDTO(agent, msgs, stream)
    }
}

public struct MessageDTO <: JsonSerializable & JsonDeserializable<MessageDTO> {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        this.role = role; this.content = content
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue(this.role)
        w.writeName("content").writeValue(this.content)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): MessageDTO {
        var role = ""; var content = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => role = r.readValue<String>()
                case "content" => content = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        MessageDTO(role, content)
    }
}

public struct AgentConfigDTO <: JsonDeserializable<AgentConfigDTO> {
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

    public static func fromJson(r: JsonReader): AgentConfigDTO {
        var name = ""; var desc: Option<String> = None; var sp = ""
        var model = ""; var prov: Option<String> = None
        var tools = ArrayList<String>(); var skills = ArrayList<String>()
        var mt = Int64(20); var temp = Float64(0.7)
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "description" => desc = r.readValue<Option<String>>()
                case "systemPrompt" => sp = r.readValue<String>()
                case "model" => model = r.readValue<String>()
                case "provider" => prov = r.readValue<Option<String>>()
                case "tools" => tools = r.readValue<ArrayList<String>>()
                case "skills" => skills = r.readValue<ArrayList<String>>()
                case "maxTurns" => mt = r.readValue<Int64>()
                case "temperature" => temp = r.readValue<Float64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgentConfigDTO(name, desc, sp, model, prov, tools, skills, mt, temp)
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

public struct TrustRequestDTO <: JsonDeserializable<TrustRequestDTO> {
    public let action: String
    public let path: String
    public let trust: String

    public init(action: String, path: String, trust: String) {
        this.action = action; this.path = path; this.trust = trust
    }

    public static func fromJson(r: JsonReader): TrustRequestDTO {
        var action = "get"; var path = "."; var trust = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "action" => action = r.readValue<String>()
                case "path" => path = r.readValue<String>()
                case "trust" => trust = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        TrustRequestDTO(action, path, trust)
    }
}

public struct SessionForkDTO <: JsonDeserializable<SessionForkDTO> {
    public let sourceId: String
    public let leafId: String

    public init(sourceId: String, leafId: String) {
        this.sourceId = sourceId; this.leafId = leafId
    }

    public static func fromJson(r: JsonReader): SessionForkDTO {
        var sourceId = ""; var leafId = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "sourceId" => sourceId = r.readValue<String>()
                case "leafId" => leafId = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionForkDTO(sourceId, leafId)
    }
}

public struct StatusResponse <: JsonSerializable {
    public let status: String

    public init(status: String) { this.status = status }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue(this.status)
        w.endObject()
    }
}

public struct ErrorResponse <: JsonSerializable {
    public let error: String

    public init(error: String) { this.error = error }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("error").writeValue(this.error)
        w.endObject()
    }
}

public struct ContentResponse <: JsonSerializable {
    public let content: String

    public init(content: String) { this.content = content }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("content").writeValue(this.content)
        w.endObject()
    }
}

public struct TrustResponse <: JsonSerializable {
    public let path: String
    public let trust: String
    public let status: String

    public init(path: String, trust: String, status: String) {
        this.path = path; this.trust = trust; this.status = status
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("path").writeValue(this.path)
        w.writeName("trust").writeValue(this.trust)
        if (this.status != "") { w.writeName("status").writeValue(this.status) }
        w.endObject()
    }
}

public struct SessionItem <: JsonSerializable {
    public let id: String
    public let model: String

    public init(id: String, model: String) { this.id = id; this.model = model }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("model").writeValue(this.model)
        w.endObject()
    }
}

public struct SessionListResponse <: JsonSerializable {
    public let sessions: ArrayList<SessionItem>

    public init(sessions: ArrayList<SessionItem>) { this.sessions = sessions }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("sessions").writeValue(this.sessions)
        w.endObject()
    }
}

public struct ForkResponse <: JsonSerializable {
    public let status: String
    public let entries: Int64

    public init(status: String, entries: Int64) { this.status = status; this.entries = entries }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("status").writeValue(this.status)
        w.writeName("entries").writeValue(this.entries)
        w.endObject()
    }
}

public struct SessionSaveDTO <: JsonDeserializable<SessionSaveDTO> {
    public let sessionId: String
    public let header: String
    public let messages: ArrayList<MessageItemDTO>

    public init(sessionId: String, header: String, messages: ArrayList<MessageItemDTO>) {
        this.sessionId = sessionId; this.header = header; this.messages = messages
    }

    public static func fromJson(r: JsonReader): SessionSaveDTO {
        var sessionId = ""; var header = ""; var messages = ArrayList<MessageItemDTO>()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "sessionId" => sessionId = r.readValue<String>()
                case "header" => header = r.readValue<String>()
                case "messages" => messages = r.readValue<ArrayList<MessageItemDTO>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionSaveDTO(sessionId, header, messages)
    }
}

public struct SessionLoadDTO <: JsonDeserializable<SessionLoadDTO> {
    public let sessionId: String

    public init(sessionId: String) { this.sessionId = sessionId }

    public static func fromJson(r: JsonReader): SessionLoadDTO {
        var sessionId = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "sessionId" => sessionId = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionLoadDTO(sessionId)
    }
}

public struct MessageItemDTO <: JsonDeserializable<MessageItemDTO> {
    public let role: String
    public let content: String

    public init(role: String, content: String) { this.role = role; this.content = content }

    public static func fromJson(r: JsonReader): MessageItemDTO {
        var role = ""; var content = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => role = r.readValue<String>()
                case "content" => content = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        MessageItemDTO(role, content)
    }
}

public struct SessionExportDTO <: JsonDeserializable<SessionExportDTO> {
    public let sessionId: String
    public let format: String

    public init(sessionId: String, format: String) { this.sessionId = sessionId; this.format = format }

    public static func fromJson(r: JsonReader): SessionExportDTO {
        var sessionId = ""; var format = "jsonl"
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "sessionId" => sessionId = r.readValue<String>()
                case "format" => format = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionExportDTO(sessionId, format)
    }
}

public struct AgentListResponse <: JsonSerializable {
    public let agents: ArrayList<String>

    public init(agents: ArrayList<String>) { this.agents = agents }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("agents").writeValue(this.agents)
        w.endObject()
    }
}

public struct SessionInputDTO <: JsonDeserializable<SessionInputDTO> {
    public let sessionId: String
    public let answer: String

    public init(sessionId: String, answer: String) { this.sessionId = sessionId; this.answer = answer }

    public static func fromJson(r: JsonReader): SessionInputDTO {
        var sessionId = ""; var answer = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "sessionId" => sessionId = r.readValue<String>()
                case "answer" => answer = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionInputDTO(sessionId, answer)
    }
}
