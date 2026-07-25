package atelier.session

import atelier.message.*
import std.collection.*

public struct SessionHeader {
    public let version: Int32
    public let id: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let model: String
    public let provider: String
    public let systemPrompt: String
    public let parentSession: Option<String>

    public init(version: Int32, id: String, createdAt: Int64, updatedAt: Int64,
        model: String, provider: String, systemPrompt: String,
        parentSession: Option<String>) {
        this.version = version; this.id = id; this.createdAt = createdAt
        this.updatedAt = updatedAt; this.model = model; this.provider = provider
        this.systemPrompt = systemPrompt; this.parentSession = parentSession
    }
}

public struct Entry {
    public let id: String
    public let parentId: Option<String>
    public let timestamp: Int64
    public let message: Message

    public init(id: String, parentId: Option<String>, timestamp: Int64, message: Message) {
        this.id = id; this.parentId = parentId; this.timestamp = timestamp; this.message = message
    }
}

public func pathToLeaf(entries: ArrayList<Entry>, leafId: String): ArrayList<Entry> {
    let byId = HashMap<String, Entry>()
    for (e in entries) { byId[e.id] = e }
    let rev = ArrayList<Entry>()
    var seen = HashSet<String>()
    var current: Option<String> = Some(leafId)
    while (let Some(id) <- current) {
        if (seen.contains(id)) { break }
        seen.add(id)
        match (byId.get(id)) {
            case Some(e) => rev.add(e); current = e.parentId
            case None => break
        }
    }
    let result = ArrayList<Entry>()
    var i = rev.size - 1
    while (i >= 0) {
        result.add(rev[i])
        i--
    }
    result
}
