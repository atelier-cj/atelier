package atelier.session

import bstorm.*
import bstorm.macros.Model
import bstorm.macros.Id
import stdx.encoding.json.stream.*
import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

@Model
public class SessionRecord {
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
        var entries = ArrayList<Entry>()
        var parentId: Option<String> = None
        for (i in 0..messages.size) {
            let msg = messages[Int64(i)]
            let eid = id + "_" + i.toString()
            entries.add(Entry(eid, parentId, 0, msg))
            parentId = Some(eid)
        }
        let record = SessionRecord()
        record.id = id
        record.headerJson = toJsonString(header)
        record.entriesJson = entriesToJson(entries)
        this.db.save(record)
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let existing = entriesFromJson(record.entriesJson)
        var parentId: Option<String> = Some(parentLeafId)
        var leaf = parentLeafId
        var idx = existing.size
        for (m in messages) {
            let eid = id + "_" + idx.toString()
            existing.add(Entry(eid, parentId, 0, m))
            parentId = Some(eid); leaf = eid; idx++
        }
        record.entriesJson = entriesToJson(existing)
        this.db.save(record)
        leaf
    }

    public func load(id: String): ArrayList<Message> {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let entries = entriesFromJson(record.entriesJson)
        let msgs = ArrayList<Message>()
        for (e in entries) { msgs.add(e.message) }
        msgs
    }

    public func loadEntries(id: String): SessionData {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let header = fromJsonString<SessionHeader>(record.headerJson)
        let entries = entriesFromJson(record.entriesJson)
        SessionData(header, entries)
    }

    public func list(): ArrayList<SessionHeader> {
        let records = this.db.all<SessionRecord>()
        let result = ArrayList<SessionHeader>()
        for (r in records) {
            result.add(fromJsonString<SessionHeader>(r.headerJson))
        }
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
