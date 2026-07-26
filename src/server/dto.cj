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
