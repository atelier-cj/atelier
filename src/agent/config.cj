package atelier.agent

import std.collection.*
import jsonvalue.*

/**
 * AgentConfig defines what an Agent is: its identity, model, tools,
 * skills, runtime parameters, and compression settings.
 *
 * Used for runtime dynamic agent creation and JSON serialization.
 */
public struct AgentConfig {
    // ── 身份信息 ──────────────────────────────────────────
    public let name: String
    public let description: Option<String>

    // ── 指令 ──────────────────────────────────────────────
    public let systemPrompt: String
    public let userPromptTemplate: Option<String>

    // ── 模型 ──────────────────────────────────────────────
    public let model: String
    public let provider: Option<String>

    // ── 工具与技能 ────────────────────────────────────────
    public let tools: ArrayList<String>
    public let skills: ArrayList<String>

    // ── 运行时参数 ────────────────────────────────────────
    public let maxTurns: UInt32
    public let temperature: Float32
    public let maxOutputTokens: UInt32
    public let thinkingLevel: Option<String>

    // ── 上下文压缩 ────────────────────────────────────────
    public let compactionEnabled: Bool
    public let compactionReserveTokens: UInt32
    public let keepRecentTokens: UInt32

    // ── 元数据 ────────────────────────────────────────────
    public let tags: ArrayList<String>
    public let createdBy: Option<String>
    public let createdAt: Int64
    public let updatedAt: Int64

    /**
     * Full constructor for AgentConfig.
     */
    public init(
        name: String,
        description: Option<String>,
        systemPrompt: String,
        userPromptTemplate: Option<String>,
        model: String,
        provider: Option<String>,
        tools: ArrayList<String>,
        skills: ArrayList<String>,
        maxTurns: UInt32,
        temperature: Float32,
        maxOutputTokens: UInt32,
        thinkingLevel: Option<String>,
        compactionEnabled: Bool,
        compactionReserveTokens: UInt32,
        keepRecentTokens: UInt32,
        tags: ArrayList<String>,
        createdBy: Option<String>,
        createdAt: Int64,
        updatedAt: Int64
    ) {
        this.name = name
        this.description = description
        this.systemPrompt = systemPrompt
        this.userPromptTemplate = userPromptTemplate
        this.model = model
        this.provider = provider
        this.tools = tools
        this.skills = skills
        this.maxTurns = maxTurns
        this.temperature = temperature
        this.maxOutputTokens = maxOutputTokens
        this.thinkingLevel = thinkingLevel
        this.compactionEnabled = compactionEnabled
        this.compactionReserveTokens = compactionReserveTokens
        this.keepRecentTokens = keepRecentTokens
        this.tags = tags
        this.createdBy = createdBy
        this.createdAt = createdAt
        this.updatedAt = updatedAt
    }

    /**
     * Returns an AgentConfig with sensible defaults.
     */
    public static func default(): AgentConfig {
        AgentConfig(
            "",
            None,
            "",
            None,
            "",
            None,
            ArrayList<String>(),
            ArrayList<String>(),
            UInt32(20),
            Float32(0.7),
            UInt32(4096),
            None,
            true,
            UInt32(16384),
            UInt32(20000),
            ArrayList<String>(),
            None,
            Int64(0),
            Int64(0)
        )
    }

    // ── JSON 序列化 ────────────────────────────────────────

    /**
     * Serialize this AgentConfig to a JsonValue.
     */
    public func toJson(): JsonValue {
        let obj = HashMap<String, JsonValue>()

        // String fields
        obj.add("name", JsonValue.String(this.name))
        obj.add("systemPrompt", JsonValue.String(this.systemPrompt))
        obj.add("model", JsonValue.String(this.model))

        // Numeric fields
        obj.add("maxTurns", JsonValue.Number(Float64(this.maxTurns)))
        obj.add("temperature", JsonValue.Number(Float64(this.temperature)))
        obj.add("maxOutputTokens", JsonValue.Number(Float64(this.maxOutputTokens)))
        obj.add("compactionReserveTokens", JsonValue.Number(Float64(this.compactionReserveTokens)))
        obj.add("keepRecentTokens", JsonValue.Number(Float64(this.keepRecentTokens)))
        obj.add("createdAt", JsonValue.Number(Float64(this.createdAt)))
        obj.add("updatedAt", JsonValue.Number(Float64(this.updatedAt)))

        // Bool fields
        obj.add("compactionEnabled", JsonValue.Boolean(this.compactionEnabled))

        // Option<String> fields
        putOptionString(obj, "description", this.description)
        putOptionString(obj, "userPromptTemplate", this.userPromptTemplate)
        putOptionString(obj, "provider", this.provider)
        putOptionString(obj, "thinkingLevel", this.thinkingLevel)
        putOptionString(obj, "createdBy", this.createdBy)

        // ArrayList<String> fields
        obj.add("tools", stringListToJsonArray(this.tools))
        obj.add("skills", stringListToJsonArray(this.skills))
        obj.add("tags", stringListToJsonArray(this.tags))

        return JsonValue.Map(obj)
    }

    /**
     * Deserialize a JsonValue into an AgentConfig.
     */
    public static func fromJson(jv: JsonValue): AgentConfig {
        let obj = match (jv) {
            case JsonValue.Map(m) => m
            case _ => throw Exception("expected object")
        }

        // Required String fields
        let name = getRequiredString(obj, "name")
        let systemPrompt = getRequiredString(obj, "systemPrompt")
        let model = getRequiredString(obj, "model")

        // Required numeric fields
        let maxTurns = UInt32(getRequiredInt(obj, "maxTurns"))
        let temperature = Float32(getNumberAsFloat64(obj, "temperature"))
        let maxOutputTokens = UInt32(getRequiredInt(obj, "maxOutputTokens"))
        let compactionReserveTokens = UInt32(getRequiredInt(obj, "compactionReserveTokens"))
        let keepRecentTokens = UInt32(getRequiredInt(obj, "keepRecentTokens"))
        let createdAt = getRequiredInt(obj, "createdAt")
        let updatedAt = getRequiredInt(obj, "updatedAt")

        // Required Bool fields
        let compactionEnabled = getRequiredBool(obj, "compactionEnabled")

        // Option<String> fields
        let description = getOptionalString(obj, "description")
        let userPromptTemplate = getOptionalString(obj, "userPromptTemplate")
        let provider = getOptionalString(obj, "provider")
        let thinkingLevel = getOptionalString(obj, "thinkingLevel")
        let createdBy = getOptionalString(obj, "createdBy")

        // ArrayList<String> fields
        let tools = jsonArrayToStringList(getRequiredArray(obj, "tools"))
        let skills = jsonArrayToStringList(getRequiredArray(obj, "skills"))
        let tags = jsonArrayToStringList(getRequiredArray(obj, "tags"))

        return AgentConfig(
            name,
            description,
            systemPrompt,
            userPromptTemplate,
            model,
            provider,
            tools,
            skills,
            maxTurns,
            temperature,
            maxOutputTokens,
            thinkingLevel,
            compactionEnabled,
            compactionReserveTokens,
            keepRecentTokens,
            tags,
            createdBy,
            createdAt,
            updatedAt
        )
    }

    /**
     * Human-readable representation for debugging.
     */
    public func toString(): String {
        var desc = "AgentConfig{name: ${this.name}"
        desc += ", model: ${this.model}"
        desc += ", tools: ${this.tools.size}"
        desc += ", maxTurns: ${this.maxTurns}"
        desc += ", compactionEnabled: ${this.compactionEnabled}"
        desc += "}"
        return desc
    }
}


// ── 内部辅助函数 ──────────────────────────────────────────

/**
 * Put an Option<String> into a HashMap, using null for None.
 */
func putOptionString(obj: HashMap<String, JsonValue>, key: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => obj.add(key, JsonValue.String(v))
        case None => obj.add(key, JsonValue.Null)
    }
}

/**
 * Convert an ArrayList<String> to a JsonValue array.
 */
func stringListToJsonArray(list: ArrayList<String>): JsonValue {
    let arr = ArrayList<JsonValue>()
    for (s in list) {
        arr.add(JsonValue.String(s))
    }
    return JsonValue.Array(arr)
}

/**
 * Convert a JsonValue array to an ArrayList<String>.
 */
func jsonArrayToStringList(jv: JsonValue): ArrayList<String> {
    let items = match (jv) {
        case JsonValue.Array(arr) => arr
        case _ => throw Exception("expected array")
    }
    let result = ArrayList<String>()
    for (v in items) {
        match (v) {
            case JsonValue.String(s) => result.add(s)
            case _ => throw Exception("expected string in array")
        }
    }
    return result
}

/**
 * Get a required String field from a HashMap.
 */
func getRequiredString(obj: HashMap<String, JsonValue>, key: String): String {
    match (obj.get(key)) {
        case Some(JsonValue.String(s)) => s
        case Some(_) => throw Exception("${key} must be a string")
        case None => throw Exception("${key} is required")
    }
}

/**
 * Get a required Int64 field from a HashMap.
 */
func getRequiredInt(obj: HashMap<String, JsonValue>, key: String): Int64 {
    match (obj.get(key)) {
        case Some(JsonValue.Number(n)) => Int64(n)
        case Some(_) => throw Exception("${key} must be a number")
        case None => throw Exception("${key} is required")
    }
}

/**
 * Get a required Bool field from a HashMap.
 */
func getRequiredBool(obj: HashMap<String, JsonValue>, key: String): Bool {
    match (obj.get(key)) {
        case Some(JsonValue.Boolean(b)) => b
        case Some(_) => throw Exception("${key} must be a boolean")
        case None => throw Exception("${key} is required")
    }
}

/**
 * Get a required JsonValue array field from a HashMap.
 */
func getRequiredArray(obj: HashMap<String, JsonValue>, key: String): JsonValue {
    match (obj.get(key)) {
        case Some(jv) =>
            match (jv) {
                case JsonValue.Array(_) => jv
                case _ => throw Exception("${key} must be an array")
            }
        case None => throw Exception("${key} is required")
    }
}

/**
 * Get a Float64 value from a HashMap, handling JsonValue.Number.
 */
func getNumberAsFloat64(obj: HashMap<String, JsonValue>, key: String): Float64 {
    match (obj.get(key)) {
        case Some(JsonValue.Number(n)) => n
        case Some(_) => throw Exception("${key} must be a number")
        case None => throw Exception("${key} is required")
    }
}

/**
 * Get an optional String field from a HashMap.
 * Returns None for missing or null fields.
 */
func getOptionalString(obj: HashMap<String, JsonValue>, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(JsonValue.Null) => None
        case Some(JsonValue.String(s)) => Some(s)
        case Some(_) => throw Exception("${key} must be a string or null")
        case None => None
    }
}
