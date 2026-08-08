package atelier.message

import stdx.encoding.json.stream.*
import std.collection.*

extend UserMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("user")
        w.writeName("content").writeValue(textFrom(this.content))
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}

extend AssistantMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("assistant")
        w.writeName("content").writeValue(textFrom(this.content))
        w.writeName("model").writeValue(this.model)
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}

extend ToolResultMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("tool")
        w.writeName("content").writeValue(textFrom(this.content))
        w.writeName("toolCallId").writeValue(this.toolCallId)
        w.writeName("toolName").writeValue(this.toolName)
        w.writeName("isError").writeValue(this.isError)
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}

extend CompactionMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("compaction")
        w.writeName("summary").writeValue(this.summary)
        w.writeName("tokensBefore").writeValue(this.tokensBefore)
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}

extend ArchiveMessage <: JsonSerializable {
    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("role").writeValue("archive")
        w.writeName("startIndex").writeValue(this.startIndex)
        w.writeName("endIndex").writeValue(this.endIndex)
        w.writeName("summary").writeValue(this.summary)
        w.writeName("timestamp").writeValue(this.timestamp)
        w.endObject()
    }
}

public func readMessageFromJson(r: JsonReader): Message {
    var role = ""; var content = ""; var ts = Int64(0)
    var model = ""
    var toolCallId = ""; var toolName = ""; var isError = false
    var summary = ""; var tokensBefore = Int64(0)
    var startIndex = Int64(0); var endIndex = Int64(0)
    try {
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "role" => role = r.readValue<String>()
                case "content" => content = r.readValue<String>()
                case "timestamp" => ts = r.readValue<Int64>()
                case "model" => model = r.readValue<String>()
                case "toolCallId" => toolCallId = r.readValue<String>()
                case "toolName" => toolName = r.readValue<String>()
                case "isError" => isError = r.readValue<Bool>()
                case "summary" => summary = r.readValue<String>()
                case "tokensBefore" => tokensBefore = r.readValue<Int64>()
                case "startIndex" => startIndex = r.readValue<Int64>()
                case "endIndex" => endIndex = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
    } catch (_) { () }
    match (role) {
        case "user" => UserMessage(ContentList.ofText(content), ts)
        case "assistant" => AssistantMessage(ContentList.ofText(content), model, "", StopReason.EndTurn, TokenUsage(0, 0), ts)
        case "tool" => ToolResultMessage(toolCallId, toolName, ContentList.ofText(content), isError, ts)
        case "compaction" => CompactionMessage(summary, tokensBefore, ts)
        case "archive" => ArchiveMessage(startIndex, endIndex, summary, ts)
        case _ => UserMessage(ContentList.ofText(content), ts)
    }
}

func textFrom(cl: ContentList): String {
    let sb = StringBuilder()
    for (b in cl.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}
