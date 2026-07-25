package atelier.session

import atelier.message.*
import jsonvalue.*
import std.collection.*

public func entriesToJson(entries: ArrayList<Entry>): String {
    let arr = ArrayList<JsonValue>()
    for (e in entries) {
        let obj = HashMap<String, JsonValue>()
        obj.add("id", JsonValue.String(e.id))
        match (e.parentId) {
            case Some(p) => obj.add("parentId", JsonValue.String(p))
            case None => ()
        }
        obj.add("timestamp", JsonValue.Number(Float64(e.timestamp)))
        obj.add("message", messageToJson(e.message))
        arr.add(JsonValue.Map(obj))
    }
    JsonValue.Array(arr).stringify()
}

public func entriesFromJson(json: String): ArrayList<Entry> {
    let v = try { JsonValue.parse(json) } catch (_) { return ArrayList<Entry>() }
    let arr = match (v) { case JsonValue.Array(a) => a; case _ => return ArrayList<Entry>() }
    let result = ArrayList<Entry>()
    for (item in arr) {
        let obj = match (item) { case JsonValue.Map(m) => m; case _ => continue }
        let id = match (obj.get("id")) { case Some(JsonValue.String(s)) => s; case _ => continue }
        let parentId: Option<String> = match (obj.get("parentId")) {
            case Some(JsonValue.String(s)) => Some(s)
            case _ => None
        }
        let ts = match (obj.get("timestamp")) { case Some(JsonValue.Number(n)) => Int64(n); case _ => 0 }
        let msg = match (obj.get("message")) { case Some(m) => messageFromJson(m); case _ => continue }
        result.add(Entry(id, parentId, ts, msg))
    }
    result
}

func messageToJson(m: Message): JsonValue {
    let obj = HashMap<String, JsonValue>()
    match (m) {
        case um: UserMessage =>
            obj.add("role", JsonValue.String("user"))
            obj.add("content", JsonValue.String(textFrom(um.content)))
            obj.add("timestamp", JsonValue.Number(Float64(um.timestamp)))
        case am: AssistantMessage =>
            obj.add("role", JsonValue.String("assistant"))
            obj.add("content", JsonValue.String(textFrom(am.content)))
            obj.add("model", JsonValue.String(am.model))
            obj.add("timestamp", JsonValue.Number(Float64(am.timestamp)))
        case tm: ToolResultMessage =>
            obj.add("role", JsonValue.String("tool"))
            obj.add("content", JsonValue.String(textFrom(tm.content)))
            obj.add("toolCallId", JsonValue.String(tm.toolCallId))
            obj.add("toolName", JsonValue.String(tm.toolName))
            obj.add("isError", JsonValue.Boolean(tm.isError))
            obj.add("timestamp", JsonValue.Number(Float64(tm.timestamp)))
        case cm: CompactionMessage =>
            obj.add("role", JsonValue.String("compaction"))
            obj.add("summary", JsonValue.String(cm.summary))
            obj.add("tokensBefore", JsonValue.Number(Float64(cm.tokensBefore)))
            obj.add("timestamp", JsonValue.Number(Float64(cm.timestamp)))
        case _ => ()
    }
    JsonValue.Map(obj)
}

func messageFromJson(v: JsonValue): Message {
    let obj = match (v) { case JsonValue.Map(m) => m; case _ => return defaultMsg() }
    let role = match (obj.get("role")) { case Some(JsonValue.String(s)) => s; case _ => "user" }
    let content = match (obj.get("content")) { case Some(JsonValue.String(s)) => s; case _ => "" }
    let ts = match (obj.get("timestamp")) { case Some(JsonValue.Number(n)) => Int64(n); case _ => 0 }
    match (role) {
        case "user" => UserMessage(ContentList.ofText(content), ts)
        case "assistant" =>
            let model: String = match (obj.get("model")) { case Some(JsonValue.String(s)) => s; case _ => "" }
            AssistantMessage(ContentList.ofText(content), model, "", StopReason.EndTurn, TokenUsage(0, 0), ts)
        case "tool" =>
            let tid: String = match (obj.get("toolCallId")) { case Some(JsonValue.String(s)) => s; case _ => "" }
            let tn: String = match (obj.get("toolName")) { case Some(JsonValue.String(s)) => s; case _ => "" }
            let isErr: Bool = match (obj.get("isError")) { case Some(JsonValue.Boolean(b)) => b; case _ => false }
            ToolResultMessage(tid, tn, ContentList.ofText(content), isErr, ts)
        case "compaction" =>
            let summary: String = match (obj.get("summary")) { case Some(JsonValue.String(s)) => s; case _ => "" }
            let tb: Int64 = match (obj.get("tokensBefore")) { case Some(JsonValue.Number(n)) => Int64(n); case _ => 0 }
            CompactionMessage(summary, tb, ts)
        case _ => UserMessage(ContentList.ofText(content), ts)
    }
}

func defaultMsg(): Message {
    UserMessage(ContentList.ofText(""), 0)
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
