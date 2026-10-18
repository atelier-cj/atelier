package server

import atelier.message.*
import atelier.interaction.*
import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.*

public struct ChatRequestDTO <: JsonSerializable & JsonDeserializable<ChatRequestDTO> {
    public let agent: String
    public let messages: ArrayList<MessageDTO>
    public let stream: Bool
    public let sessionId: Option<String>

    public init(agent: String, messages: ArrayList<MessageDTO>, stream: Bool, sessionId: Option<String>) {
        this.agent = agent; this.messages = messages; this.stream = stream
        this.sessionId = sessionId
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("agent").writeValue(this.agent)
        w.writeName("messages").writeValue(this.messages)
        w.writeName("stream").writeValue(this.stream)
        w.writeName("sessionId").writeValue(this.sessionId)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ChatRequestDTO {
        var agent = ""; var msgs = ArrayList<MessageDTO>(); var stream = false
        var sessionId: Option<String> = None
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "agent" => agent = r.readValue<String>()
                case "messages" => msgs = r.readValue<ArrayList<MessageDTO>>()
                case "stream" => stream = r.readValue<Bool>()
                case "sessionId" => sessionId = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ChatRequestDTO(agent, msgs, stream, sessionId)
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
    public let mcpCooldownTurns: Int64
    public init(name: String, description: Option<String>, systemPrompt: String,
        model: String, provider: Option<String>, tools: ArrayList<String>,
        skills: ArrayList<String>, maxTurns: Int64, temperature: Float64,
        mcpCooldownTurns: Int64) {
        this.name = name; this.description = description; this.systemPrompt = systemPrompt
        this.model = model; this.provider = provider; this.tools = tools
        this.skills = skills; this.maxTurns = maxTurns; this.temperature = temperature
        this.mcpCooldownTurns = mcpCooldownTurns
    }

    public static func fromJson(r: JsonReader): AgentConfigDTO {
        var name = ""; var desc: Option<String> = None; var sp = ""
        var model = ""; var prov: Option<String> = None
        var tools = ArrayList<String>(); var skills = ArrayList<String>()
        var mt = Int64(20); var temp = Float64(0.7); var cooldown = Int64(0)
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
                case "mcpCooldownTurns" => cooldown = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        AgentConfigDTO(name, desc, sp, model, prov, tools, skills, mt, temp, cooldown)
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

public struct DeleteAgentDTO <: JsonDeserializable<DeleteAgentDTO> {
    public let name: String

    public init(name: String) { this.name = name }

    public static func fromJson(r: JsonReader): DeleteAgentDTO {
        var name = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        DeleteAgentDTO(name)
    }
}

public struct AgentItem <: JsonSerializable {
    public let name: String
    public let model: String
    public let systemPrompt: String

    public init(name: String, model: String, systemPrompt: String) {
        this.name = name; this.model = model; this.systemPrompt = systemPrompt
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("model").writeValue(this.model)
        w.writeName("systemPrompt").writeValue(this.systemPrompt)
        w.endObject()
    }
}

public struct AgentConfigListResponse <: JsonSerializable {
    public let agents: ArrayList<AgentItem>

    public init(agents: ArrayList<AgentItem>) { this.agents = agents }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("agents").writeValue(this.agents)
        w.endObject()
    }
}

// OpenAI /v1/chat/completions DTOs

public struct ChatCompletionRequest <: JsonDeserializable<ChatCompletionRequest> {
    public let model: String
    public let messages: ArrayList<ChatCompletionMessage>
    public let stream: Bool
    public let temperature: Float64
    public let maxTokens: Int64
    public let sessionId: Option<String>

    public init(model: String, messages: ArrayList<ChatCompletionMessage>,
        stream: Bool, temperature: Float64, maxTokens: Int64, sessionId: Option<String>) {
        this.model = model; this.messages = messages; this.stream = stream
        this.temperature = temperature; this.maxTokens = maxTokens
        this.sessionId = sessionId
    }

    public static func fromJson(r: JsonReader): ChatCompletionRequest {
        var model = ""; var messages = ArrayList<ChatCompletionMessage>()
        var stream = false; var temperature = Float64(0.7); var maxTokens = Int64(4096)
        var sessionId: Option<String> = None
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "model" => model = r.readValue<String>()
                case "messages" => messages = r.readValue<ArrayList<ChatCompletionMessage>>()
                case "stream" => stream = r.readValue<Bool>()
                case "temperature" => temperature = r.readValue<Float64>()
                case "max_tokens" => maxTokens = r.readValue<Int64>()
                case "sessionId" => sessionId = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ChatCompletionRequest(model, messages, stream, temperature, maxTokens, sessionId)
    }
}

public struct ChatCompletionMessage <: JsonDeserializable<ChatCompletionMessage> {
    public let role: String
    public let content: String

    public init(role: String, content: String) { this.role = role; this.content = content }

    public static func fromJson(r: JsonReader): ChatCompletionMessage {
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
        ChatCompletionMessage(role, content)
    }
}

public struct ChatCompletionResponse <: JsonSerializable {
    public let id: String
    public let object: String
    public let created: Int64
    public let model: String
    public let choices: ArrayList<Choice>
    public let usage: Usage

    public init(id: String, object: String, created: Int64, model: String,
        choices: ArrayList<Choice>, usage: Usage) {
        this.id = id; this.object = object; this.created = created
        this.model = model; this.choices = choices; this.usage = usage
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("object").writeValue(this.object)
        w.writeName("created").writeValue(this.created)
        w.writeName("model").writeValue(this.model)
        w.writeName("choices").writeValue(this.choices)
        w.writeName("usage").writeValue(this.usage)
        w.endObject()
    }
}

public struct Choice <: JsonSerializable {
    public let index: Int64
    public let message: ChatCompletionResponseMessage
    public let finishReason: String

    public init(index: Int64, message: ChatCompletionResponseMessage, finishReason: String) {
        this.index = index; this.message = message; this.finishReason = finishReason
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("index").writeValue(this.index)
        w.writeName("message").writeValue(this.message)
        w.writeName("finish_reason").writeValue(this.finishReason)
        w.endObject()
    }
}

public struct ChatCompletionResponseMessage <: JsonSerializable {
    public let role: String
    public let content: String

    public init(role: String, content: String) { this.role = role; this.content = content }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue(this.role)
        w.writeName("content").writeValue(this.content)
        w.endObject()
    }
}

public struct Usage <: JsonSerializable {
    public let promptTokens: Int64
    public let completionTokens: Int64
    public let totalTokens: Int64

    public init(promptTokens: Int64, completionTokens: Int64, totalTokens: Int64) {
        this.promptTokens = promptTokens; this.completionTokens = completionTokens
        this.totalTokens = totalTokens
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("prompt_tokens").writeValue(this.promptTokens)
        w.writeName("completion_tokens").writeValue(this.completionTokens)
        w.writeName("total_tokens").writeValue(this.totalTokens)
        w.endObject()
    }
}

// /agent/input 回传体：按 requestId 精确对上一条待答提问（提问 id 确定性，见 UserRequest.id）。
//
// 旧契约把 answer 投给"任意一条等待中的提问"：并发请求下第一个等待者会拿到别人的答案。
// 答复在这里按字段类型包装（multi_select → 数组、bool → 布尔），但合法性仍由 validateAnswer
// 统一把关 —— 非法答复在边界处被打回，而不是让用户填完整张表才在 runtime 报错。
public struct SessionInputDTO <: JsonDeserializable<SessionInputDTO> {
    public let requestId: String
    public let status: String                    // answered（缺省）/ cancelled / timed_out / pending
    public let selected: ArrayList<String>       // 审批、选择：选项 id（多选按顺序）
    public let text: String                      // 自由文本
    public let values: HashMap<String, String>   // 表单：字段名 → 文本值（multi_select 逗号分隔）

    public init(requestId: String, status!: String = "answered",
        selected!: ArrayList<String> = ArrayList(), text!: String = "",
        values!: HashMap<String, String> = HashMap()) {
        this.requestId = requestId
        this.status = status
        this.selected = selected
        this.text = text
        this.values = values
    }

    /** 转成结构化答复。请求 id 用提问本体的 id：回传体是照着它取的，两者必然一致。 */
    public func toAnswer(req: UserRequest): UserAnswer {
        let st = match (this.status) {
            case "cancelled" => UserAnswerStatus.Cancelled
            case "timed_out" => UserAnswerStatus.TimedOut
            case "pending" => UserAnswerStatus.Pending
            case _ => UserAnswerStatus.Answered
        }
        let vals = HashMap<String, JsonValue>()
        for (f in req.fields) {
            match (this.values.get(f.name)) {
                case Some(raw) => vals[f.name] = fieldValueOf(f, raw)
                case None => ()
            }
        }
        UserAnswer(req.id, st, selected: this.selected, text: this.text, values: vals)
    }

    public static func fromJson(r: JsonReader): SessionInputDTO {
        var requestId = ""
        var status = "answered"
        var text = ""
        let selected = ArrayList<String>()
        let values = HashMap<String, String>()
        r.startObject()
        while (r.peek() != JsonToken.EndObject) {
            match (r.readName()) {
                case "requestId" => requestId = r.readValue<String>()
                case "status" => status = r.readValue<String>()
                case "text" => text = r.readValue<String>()
                case "selected" => readStringArray(r, selected)
                case "values" => readStringMap(r, values)
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionInputDTO(requestId, status: status, selected: selected, text: text, values: values)
    }
}

// /agent/stream 的提问帧：整条 UserRequest 原样交给客户端（选项/字段/toolCallId 都在里面），
// 客户端据此渲染，再用同一个 id 回传答复。
public class UserRequestFrame <: JsonSerializable {
    public let request: UserRequest

    public init(request: UserRequest) { this.request = request }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("user_request")
        w.writeName("request").writeValue(this.request)
        w.endObject()
    }
}

func readStringArray(r: JsonReader, out: ArrayList<String>): Unit {
    r.startArray()
    while (r.peek() != JsonToken.EndArray) {
        out.add(r.readValue<String>())
    }
    r.endArray()
}

func readStringMap(r: JsonReader, out: HashMap<String, String>): Unit {
    r.startObject()
    while (r.peek() != JsonToken.EndObject) {
        let k = r.readName()
        out[k] = r.readValue<String>()
    }
    r.endObject()
}

// 表单字段值按声明类型包装：否则 bool/multi_select 会被校验按"类型不符"打回
func fieldValueOf(f: UserField, raw: String): JsonValue {
    match (f.fieldType) {
        case UserFieldType.MultiSelect =>
            let arr = ArrayList<JsonValue>()
            for (part in raw.split(",")) {
                let t = part.trimAscii()
                if (t != "") { arr.add(JsonValue.String(t)) }
            }
            JsonValue.Array(arr)
        case UserFieldType.Boolean => JsonValue.Boolean(raw == "true" || raw == "yes")
        case _ => JsonValue.String(raw)
    }
}

/**
 * 单个会话的运行时状态。
 *
 * 为什么单独给一个端点而不是塞进 `/sessions`：`/sessions` 是**落库的会话列表**
 * （持久事实，机器重启后仍在），而状态是**内存中的瞬时事实**（重启即回到 Idle）。
 * 混在一起会让客户端误以为"落盘了但显示运行中"是异常。
 */
public struct SessionStatusItem <: JsonSerializable {
    public let id: String
    /** `running` / `idle` */
    public let status: String

    public init(id: String, status: String) { this.id = id; this.status = status }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("status").writeValue(this.status)
        w.endObject()
    }
}

/** 一批会话的运行时状态（只含**当前在跑**的会话）。 */
public struct SessionStatusResponse <: JsonSerializable {
    public let running: ArrayList<SessionStatusItem>

    public init(running: ArrayList<SessionStatusItem>) { this.running = running }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("running").writeValue(this.running)
        w.endObject()
    }
}
