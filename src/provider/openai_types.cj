package atelier.provider

import stdx.encoding.json.stream.*
import std.collection.*
import jsonvalue.*

public struct OpenAIRequest <: JsonSerializable {
    public let model: String
    public let messages: ArrayList<OpenAIMessage>
    public let stream: Bool
    public let temperature: Float64
    public let maxTokens: Int64
    public let reasoningEffort: Option<String>
    public let tools: ArrayList<OpenAITool>

    public init(model: String, messages: ArrayList<OpenAIMessage>,
        stream: Bool, temperature: Float64, maxTokens: Int64,
        reasoningEffort: Option<String>,
        tools: ArrayList<OpenAITool>) {
        this.model = model; this.messages = messages; this.stream = stream
        this.temperature = temperature; this.maxTokens = maxTokens
        this.reasoningEffort = reasoningEffort
        this.tools = tools
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("model").writeValue(this.model)
        w.writeName("messages").writeValue(this.messages)
        w.writeName("stream").writeValue(this.stream)
        w.writeName("max_tokens").writeValue(Int64(this.maxTokens))
        match (this.reasoningEffort) {
            case Some(v) =>
                w.writeName("reasoning_effort").writeValue(v)
                w.writeName("thinking").startObject()
                w.writeName("type").writeValue("enabled")
                w.endObject()
            case None => w.writeName("temperature").writeValue(this.temperature)
        }
        if (this.tools.size > 0) {
            w.writeName("tools").writeValue(this.tools)
        }
        w.endObject()
    }
}

public struct OpenAITool <: JsonSerializable {
    public let name: String
    public let description: String
    public let parameters: JsonValue

    public init(name: String, description: String, parameters: JsonValue) {
        this.name = name; this.description = description; this.parameters = parameters
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("type").writeValue("function")
        w.writeName("function").startObject()
        w.writeName("name").writeValue(this.name)
        if (this.description != "") {
            w.writeName("description").writeValue(this.description)
        }
        w.writeName("parameters").writeValue(this.parameters)
        w.endObject()
        w.endObject()
    }
}

public struct OpenAIMessage <: JsonSerializable {
    public let role: String
    public let content: String
    public let reasoningContent: Option<String>
    public let toolCallId: String
    public let toolCalls: ArrayList<JsonValue>

    public init(role: String, content: String, reasoningContent: Option<String>,
        toolCallId: String, toolCalls: ArrayList<JsonValue>) {
        this.role = role; this.content = content; this.reasoningContent = reasoningContent
        this.toolCallId = toolCallId; this.toolCalls = toolCalls
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue(this.role)
        if (this.role == "tool") {
            w.writeName("tool_call_id").writeValue(this.toolCallId)
        }
        if (this.content == "" && this.role == "assistant" && this.toolCalls.size > 0) {
            w.writeName("content").writeNullValue()
        } else {
            w.writeName("content").writeValue(this.content)
        }
        match (this.reasoningContent) {
            case Some(v) => w.writeName("reasoning_content").writeValue(v)
            case None => if (this.role == "assistant" && this.toolCalls.size > 0) {
                w.writeName("reasoning_content").writeNullValue()
            }
        }
        if (this.role == "assistant" && this.toolCalls.size > 0) {
            w.writeName("tool_calls").writeValue(this.toolCalls)
        }
        w.endObject()
    }
}

public struct OpenAIResponse <: JsonDeserializable<OpenAIResponse> {
    public var choices: ArrayList<OpenAIChoice> = ArrayList()
    public var usage: OpenAIUsage = OpenAIUsage()

    public static func fromJson(r: JsonReader): OpenAIResponse {
        var res = OpenAIResponse()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "choices" => res.choices = r.readValue<ArrayList<OpenAIChoice>>()
                case "usage" => res.usage = r.readValue<OpenAIUsage>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIChoice <: JsonDeserializable<OpenAIChoice> {
    public var message: OpenAIMessageData = OpenAIMessageData()
    public var finishReason: String = ""

    public static func fromJson(r: JsonReader): OpenAIChoice {
        var res = OpenAIChoice()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "message" => res.message = r.readValue<OpenAIMessageData>()
                case "finish_reason" => res.finishReason = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIMessageData <: JsonDeserializable<OpenAIMessageData> {
    public var role: String = ""
    public var content: String = ""
    public var reasoningContent: String = ""
    public var toolCalls: ArrayList<JsonValue> = ArrayList()

    public static func fromJson(r: JsonReader): OpenAIMessageData {
        var res = OpenAIMessageData()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => res.role = r.readValue<String>()
                case "content" => res.content = if (r.peek() != JsonNull) { r.readValue<String>() } else { r.skip(); "" }
                case "reasoning_content" => res.reasoningContent = r.readValue<String>()
                case "tool_calls" =>
                    match (r.readValue<JsonValue>()) {
                        case JsonValue.Array(arr) => res.toolCalls = arr
                        case _ => r.skip()
                    }
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIUsage <: JsonDeserializable<OpenAIUsage> {
    public var promptTokens: Int64 = 0
    public var completionTokens: Int64 = 0
    public var reasoningTokens: Int64 = 0

    public static func fromJson(r: JsonReader): OpenAIUsage {
        var res = OpenAIUsage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "prompt_tokens" => res.promptTokens = r.readValue<Int64>()
                case "completion_tokens" => res.completionTokens = r.readValue<Int64>()
                case "reasoning_tokens" => res.reasoningTokens = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIStreamChunk <: JsonDeserializable<OpenAIStreamChunk> {
    public var choices: ArrayList<OpenAIStreamChoice> = ArrayList()

    public static func fromJson(r: JsonReader): OpenAIStreamChunk {
        var res = OpenAIStreamChunk()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "choices" => res.choices = r.readValue<ArrayList<OpenAIStreamChoice>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIStreamChoice <: JsonDeserializable<OpenAIStreamChoice> {
    public var delta: OpenAIDelta = OpenAIDelta()
    public var finishReason: Option<String> = None

    public static func fromJson(r: JsonReader): OpenAIStreamChoice {
        var res = OpenAIStreamChoice()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "delta" => res.delta = r.readValue<OpenAIDelta>()
                case "finish_reason" => res.finishReason = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIDelta <: JsonDeserializable<OpenAIDelta> {
    public var content: String = ""
    public var reasoningContent: String = ""
    public var role: String = ""
    public var toolCalls: ArrayList<JsonValue> = ArrayList()

    public static func fromJson(r: JsonReader): OpenAIDelta {
        var res = OpenAIDelta()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "content" => res.content = if (r.peek() != Some(JsonNull)) { r.readValue<String>() } else { r.skip(); "" }
                case "reasoning_content" => res.reasoningContent = r.readValue<String>()
                case "role" => res.role = r.readValue<String>()
                case "tool_calls" =>
                    match (r.readValue<JsonValue>()) {
                        case JsonValue.Array(arr) => res.toolCalls = arr
                        case _ => r.skip()
                    }
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}
