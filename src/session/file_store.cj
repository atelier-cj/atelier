package atelier.session

import bstorm.*
import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

@Model
public class SessionRecord <: Model<SessionRecord> {
    @Id
    public var id: String = ""
    public var headerJson: String = ""
    public var entriesJson: String = ""
    public var updatedAt: Int64 = 0
    public init() {}
}

public class StormSessionStore <: SessionStore {
    private let db: Storm

    public init(path: String) {
        this.db = Storm.open(path)
    }

    public func close(): Unit { this.db.close() }

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        let record = SessionRecord()
        record.id = id
        record.headerJson = toJsonString(header)
        record.entriesJson = serializeMessages(messages)
        this.db.save(record)
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let existing = deserializeEntries(record.entriesJson)
        var parentId: Option<String> = Some(parentLeafId)
        var leaf = parentLeafId
        var idx = existing.size
        for (msg in messages) {
            let eid = "be${idx}"
            existing.add(Entry(eid, parentId, 0, msg))
            parentId = Some(eid); leaf = eid; idx++
        }
        record.entriesJson = serializeEntries(existing)
        this.db.save(record)
        leaf
    }

    public func load(id: String): ArrayList<Message> {
        let record = this.db.get<SessionRecord>(id)
        let r = match (record) { case Some(v) => v; case None => throw Exception("not found") }
        deserializeMessages(r.entriesJson)
    }

    public func loadEntries(id: String): SessionData {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r; case None => throw Exception("not found")
        }
        SessionData(fromJsonString<SessionHeader>(record.headerJson), deserializeEntries(record.entriesJson))
    }

    public func list(): ArrayList<SessionHeader> {
        let result = ArrayList<SessionHeader>()
        for (r in this.db.all<SessionRecord>()) { result.add(fromJsonString<SessionHeader>(r.headerJson)) }
        result
    }

    public func delete(id: String): Unit {
        let r = SessionRecord(); r.id = id; this.db.delete(r)
    }

    public func fork(sourceId: String, leafId: String): SessionData {
        let data = this.loadEntries(sourceId)
        SessionData(data.header, pathToLeaf(data.entries, leafId))
    }
}

func serializeMessages(msgs: ArrayList<Message>): String {
    let parts = ArrayList<String>()
    for (m in msgs) {
        let role = match (m) { case UserMessage => "user"; case AssistantMessage => "assistant"; case ToolResultMessage => "tool"; case CompactionMessage => "compaction"; case _ => "unknown" }
        parts.add(role)
    }
    parts.toString()
}

func deserializeMessages(s: String): ArrayList<Message> { ArrayList<Message>() }
func serializeEntries(entries: ArrayList<Entry>): String { entries.size.toString() }
func deserializeEntries(s: String): ArrayList<Entry> { ArrayList<Entry>() }
