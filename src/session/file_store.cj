package atelier.session

import atelier.message.*
import std.collection.*

public class StormSessionStore <: SessionStore {
    public init(path: String) {}
    public func close(): Unit {}

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func load(id: String): ArrayList<Message> {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func loadEntries(id: String): SessionData {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func list(): ArrayList<SessionHeader> {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func delete(id: String): Unit {
        throw Exception("StormSessionStore not yet implemented")
    }

    public func fork(sourceId: String, leafId: String): SessionData {
        throw Exception("StormSessionStore not yet implemented")
    }
}
