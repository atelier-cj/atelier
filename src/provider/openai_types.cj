package atelier.provider

import stdx.encoding.json.stream.*
import std.collection.*
import std.io.ByteBuffer
import jsonvalue.*

public struct OpenAIRequest <: JsonSerializable {
    public let model: String
    public let messages: ArrayList<OpenAIMessage>
    public let stream: Bool
    public let temperature: Float64
    public let maxTokens: Int64

    public init(model: String, messages: ArrayList<OpenAIMessage>, stream: Bool, temperature: Float64, maxTokens: Int64) {
        this.model = model; this.messages = messages; this.stream = stream
        this.temperature = temperature; this.maxTokens = maxTokens
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("model").writeValue(this.model)
        w.writeName("messages").writeValue(this.messages)
        w.writeName("stream").writeValue(this.stream)
        w.writeName("temperature").writeValue(this.temperature)
        w.writeName("max_tokens").writeValue(Int64(this.maxTokens))
        w.endObject()
    }
}

public struct OpenAIMessage <: JsonSerializable {
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
                case "index" => r.skip()
                case "delta" => r.skip()
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
    public var toolCalls: ArrayList<JsonValue> = ArrayList()

    public static func fromJson(r: JsonReader): OpenAIMessageData {
        var res = OpenAIMessageData()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => res.role = r.readValue<String>()
                case "content" => res.content = if (r.peek() != JsonNull) { r.readValue<String>() } else { r.skip(); "" }
                case "tool_calls" => res.toolCalls = r.readValue<ArrayList<JsonValue>>()
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

    public static func fromJson(r: JsonReader): OpenAIUsage {
        var res = OpenAIUsage()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "prompt_tokens" => res.promptTokens = r.readValue<Int64>()
                case "completion_tokens" => res.completionTokens = r.readValue<Int64>()
                case "total_tokens" => r.skip()
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
                case "index" => r.skip()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}

public struct OpenAIDelta <: JsonDeserializable<OpenAIDelta> {
    public var content: String = ""
    public var role: String = ""

    public static func fromJson(r: JsonReader): OpenAIDelta {
        var res = OpenAIDelta()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "content" => res.content = if (r.peek() != Some(JsonNull)) { r.readValue<String>() } else { r.skip(); "" }
                case "role" => res.role = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}
