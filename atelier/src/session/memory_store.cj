package atelier.session

import atelier.message.*
import std.collection.*

public class MemorySessionStore <: SessionStore {
    private let sessions = HashMap<String, SessionData>()

    public init() {}

    // 压缩台账：按会话存（内存实现同样保留语义，测试与进程内审计可用）
    private let compactions = HashMap<String, ArrayList<CompactionRecord>>()

    public func appendCompaction(record: CompactionRecord): Unit {
        match (this.compactions.get(record.sessionId)) {
            case Some(list) => list.add(record)
            case None =>
                let list = ArrayList<CompactionRecord>()
                list.add(record)
                this.compactions[record.sessionId] = list
        }
    }

    public func loadCompactions(sessionId: String): ArrayList<CompactionRecord> {
        match (this.compactions.get(sessionId)) {
            case Some(list) =>
                let out = ArrayList<CompactionRecord>()
                for (r in list) { out.add(r) }
                out
            case None => ArrayList<CompactionRecord>()
        }
    }

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        var entries = ArrayList<Entry>()
        var parentId: Option<String> = None
        var entryId: Int64 = 0
        for (msg in messages) {
            let eid = "e${entryId}"
            entries.add(Entry(eid, parentId, header.updatedAt, msg))
            parentId = Some(eid); entryId++
        }
        this.sessions[id] = SessionData(header, entries)
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        let data = match (this.sessions.get(id)) {
            case Some(v) => v
            case None => throw Exception("Session not found: ${id}")
        }
        var entries = ArrayList<Entry>(data.entries)
        var parentId: Option<String> = Some(parentLeafId)
        var leaf = parentLeafId
        for (msg in messages) {
            let eid = "e${entries.size}"
            entries.add(Entry(eid, parentId, data.header.updatedAt, msg))
            parentId = Some(eid); leaf = eid
        }
        this.sessions[id] = SessionData(data.header, entries)
        leaf
    }

    public func load(id: String): ArrayList<Message> {
        let data = match (this.sessions.get(id)) {
            case Some(v) => v
            case None => throw Exception("Session not found: ${id}")
        }
        let msgs = ArrayList<Message>()
        for (e in data.entries) { msgs.add(e.message) }
        msgs
    }

    public func loadEntries(id: String): SessionData {
        match (this.sessions.get(id)) {
            case Some(v) => v
            case None => throw Exception("Session not found: ${id}")
        }
    }

    public func list(): ArrayList<SessionHeader> {
        let result = ArrayList<SessionHeader>()
        for ((_, v) in this.sessions) { result.add(v.header) }
        result
    }

    public func delete(id: String): Unit {
        this.sessions.remove(id)
    }

    public func fork(sourceId: String, leafId: String): SessionData {
        let data = match (this.sessions.get(sourceId)) {
            case Some(v) => v
            case None => throw Exception("Session not found: ${sourceId}")
        }
        let path = pathToLeaf(data.entries, leafId)
        SessionData(data.header, path)
    }
}
