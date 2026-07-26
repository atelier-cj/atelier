package atelier.session

import atelier.message.*
import stdx.encoding.json.stream.*
import std.io.ByteBuffer
import std.collection.*

public func entriesToJson(entries: ArrayList<Entry>): String {
    let buf = ByteBuffer()
    let w = JsonWriter(buf)
    w.startArray()
    for (e in entries) {
        w.startObject()
        w.writeName("id").writeValue(e.id)
        match (e.parentId) {
            case Some(p) => w.writeName("parentId").writeValue(p)
            case None => ()
        }
        w.writeName("timestamp").writeValue(e.timestamp)
        w.writeName("message")
        writeMessage(w, e.message)
        w.endObject()
    }
    w.endArray()
    w.flush()
    String.fromUtf8(buf.bytes())
}

public func entriesFromJson(json: String): ArrayList<Entry> {
    let buf = ByteBuffer(json.toArray())
    let r = JsonReader(buf)
    let result = ArrayList<Entry>()
    try {
        r.startArray()
        while (r.peek() != EndArray) {
            var id = ""; var parentId: Option<String> = None; var ts = Int64(0); var msg = Option<Message>.None
            r.startObject()
            while (r.peek() != EndObject) {
                match (r.readName()) {
                    case "id" => id = r.readValue<String>()
                    case "parentId" => parentId = r.readValue<Option<String>>()
                    case "timestamp" => ts = r.readValue<Int64>()
                    case "message" => msg = readMessage(r)
                    case _ => r.skip()
                }
            }
            r.endObject()
            if (id != "") {
                match (msg) {
                    case Some(m) => result.add(Entry(id, parentId, ts, m))
                    case None => ()
                }
            }
        }
        r.endArray()
    } catch (_) { () }
    result
}

func writeMessage(w: JsonWriter, m: Message): Unit {
    w.startObject()
    match (m) {
        case um: UserMessage =>
            w.writeName("role").writeValue("user")
            w.writeName("content").writeValue(textFrom(um.content))
            w.writeName("timestamp").writeValue(um.timestamp)
        case am: AssistantMessage =>
            w.writeName("role").writeValue("assistant")
            w.writeName("content").writeValue(textFrom(am.content))
            w.writeName("model").writeValue(am.model)
            w.writeName("timestamp").writeValue(am.timestamp)
        case tm: ToolResultMessage =>
            w.writeName("role").writeValue("tool")
            w.writeName("content").writeValue(textFrom(tm.content))
            w.writeName("toolCallId").writeValue(tm.toolCallId)
            w.writeName("toolName").writeValue(tm.toolName)
            w.writeName("isError").writeValue(tm.isError)
            w.writeName("timestamp").writeValue(tm.timestamp)
        case cm: CompactionMessage =>
            w.writeName("role").writeValue("compaction")
            w.writeName("summary").writeValue(cm.summary)
            w.writeName("tokensBefore").writeValue(cm.tokensBefore)
            w.writeName("timestamp").writeValue(cm.timestamp)
        case _ => ()
    }
    w.endObject()
}

func readMessage(r: JsonReader): Message {
    var role = ""; var content = ""; var ts = Int64(0)
    var model = ""
    var toolCallId = ""; var toolName = ""; var isError = false
    var summary = ""; var tokensBefore = Int64(0)
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
