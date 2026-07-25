package atelier.session

import atelier.message.*
import std.collection.*

public class SessionData {
    public let header: SessionHeader
    public let entries: ArrayList<Entry>
    public init(header: SessionHeader, entries: ArrayList<Entry>) {
        this.header = header; this.entries = entries
    }
}

public interface SessionStore {
    func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit
    func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String
    func load(id: String): ArrayList<Message>
    func loadEntries(id: String): SessionData
    func list(): ArrayList<SessionHeader>
    func delete(id: String): Unit
    func fork(sourceId: String, leafId: String): SessionData
}
