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
        match (e.message) {
            case um: UserMessage => w.writeValue(um)
            case am: AssistantMessage => w.writeValue(am)
            case tm: ToolResultMessage => w.writeValue(tm)
            case cm: CompactionMessage => w.writeValue(cm)
            case _ => w.writeNullValue()
        }
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
                    case "message" => msg = Some(readMessageFromJson(r))
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
