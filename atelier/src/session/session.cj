package atelier.session

import atelier.message.*
import stdx.encoding.json.stream.*
import std.collection.*

public struct SessionEnvironment {
    public let directory: String
    public let context: HashMap<String, String>

    public init() {
        this.directory = ""; this.context = HashMap()
    }

    public init(directory: String, context: HashMap<String, String>) {
        this.directory = directory; this.context = context
    }
}

public struct SessionHeader <: JsonSerializable & JsonDeserializable<SessionHeader> {
    public let version: Int32
    public let id: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let model: String
    public let provider: String
    public let systemPrompt: String
    public let parentSession: Option<String>
    public let env: SessionEnvironment

    public init(version: Int32, id: String, createdAt: Int64, updatedAt: Int64,
        model: String, provider: String, systemPrompt: String,
        parentSession: Option<String>) {
        this.version = version; this.id = id; this.createdAt = createdAt
        this.updatedAt = updatedAt; this.model = model; this.provider = provider
        this.systemPrompt = systemPrompt; this.parentSession = parentSession
        this.env = SessionEnvironment()
    }

    public init(version: Int32, id: String, createdAt: Int64, updatedAt: Int64,
        model: String, provider: String, systemPrompt: String,
        parentSession: Option<String>, env: SessionEnvironment) {
        this.version = version; this.id = id; this.createdAt = createdAt
        this.updatedAt = updatedAt; this.model = model; this.provider = provider
        this.systemPrompt = systemPrompt; this.parentSession = parentSession
        this.env = env
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
        w.writeName("env").startObject()
        w.writeName("directory").writeValue(this.env.directory)
        w.writeName("context").writeValue(this.env.context)
        w.endObject()
        w.endObject()
    }

    public static func fromJson(r: JsonReader): SessionHeader {
        var version = Int32(0); var id = ""; var createdAt = Int64(0); var updatedAt = Int64(0)
        var model = ""; var provider = ""; var systemPrompt = ""; var parentSession: Option<String> = None
        var directory = ""; var context = HashMap<String, String>()
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
                case "env" =>
                    r.startObject()
                    while (r.peek() != EndObject) {
                        match (r.readName()) {
                            case "directory" => directory = r.readValue<String>()
                            case "context" => context = r.readValue<HashMap<String, String>>()
                            case _ => r.skip()
                        }
                    }
                    r.endObject()
                case _ => r.skip()
            }
        }
        r.endObject()
        SessionHeader(version, id, createdAt, updatedAt, model, provider, systemPrompt, parentSession,
            SessionEnvironment(directory, context))
    }
}

public struct Entry <: JsonSerializable & JsonDeserializable<Entry> {
    public let id: String
    public let parentId: Option<String>
    public let timestamp: Int64
    public let message: Message

    public init(id: String, parentId: Option<String>, timestamp: Int64, message: Message) {
        this.id = id; this.parentId = parentId; this.timestamp = timestamp; this.message = message
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        match (this.parentId) {
            case Some(p) => w.writeName("parentId").writeValue(p)
            case None => ()
        }
        w.writeName("timestamp").writeValue(this.timestamp)
        w.writeName("message")
        match (this.message) {
            case um: UserMessage => w.writeValue(um)
            case am: AssistantMessage => w.writeValue(am)
            case tm: ToolResultMessage => w.writeValue(tm)
            case cm: CompactionMessage => w.writeValue(cm)
            case am: ArchiveMessage => w.writeValue(am)
            case _ => w.writeNullValue()
        }
        w.endObject()
    }

    public static func fromJson(r: JsonReader): Entry {
        var id = ""; var parentId: Option<String> = None; var ts = Int64(0); var msg: Message = UserMessage(ContentList.ofText(""), 0)
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "id" => id = r.readValue<String>()
                case "parentId" => parentId = r.readValue<Option<String>>()
                case "timestamp" => ts = r.readValue<Int64>()
                case "message" => msg = readMessageFromJson(r)
                case _ => r.skip()
            }
        }
        r.endObject()
        Entry(id, parentId, ts, msg)
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
