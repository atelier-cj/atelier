package atelier.session

import atelier.message.*
import stdx.encoding.json.stream.*
import std.collection.*

public struct SessionHeader <: JsonSerializable & JsonDeserializable<SessionHeader> {
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

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("version").writeValue(Int64(this.version))
        w.writeName("id").writeValue(this.id)
        w.writeName("createdAt").writeValue(this.createdAt)
        w.writeName("updatedAt").writeValue(this.updatedAt)
        w.writeName("model").writeValue(this.model)
        w.writeName("provider").writeValue(this.provider)
        w.writeName("systemPrompt").writeValue(this.systemPrompt)
        w.writeName("parentSession").writeValue(this.parentSession)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): SessionHeader {
        var version = Int32(0); var id = ""; var createdAt = Int64(0); var updatedAt = Int64(0)
        var model = ""; var provider = ""; var systemPrompt = ""; var parentSession: Option<String> = None
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "version" => version = Int32(r.readValue<Int64>())
                case "id" => id = r.readValue<String>()
                case "createdAt" => createdAt = r.readValue<Int64>()
                case "updatedAt" => updatedAt = r.readValue<Int64>()
                case "model" => model = r.readValue<String>()
                case "provider" => provider = r.readValue<String>()
                case "systemPrompt" => systemPrompt = r.readValue<String>()
                case "parentSession" => parentSession = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionHeader(version, id, createdAt, updatedAt, model, provider, systemPrompt, parentSession)
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
