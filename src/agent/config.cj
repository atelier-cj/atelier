package atelier.agent

import std.collection.*
import stdx.encoding.json.*

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
        let obj = JsonObject()

        // String fields
        obj.put("name", JsonString(this.name))
        obj.put("systemPrompt", JsonString(this.systemPrompt))
        obj.put("model", JsonString(this.model))

        // Numeric fields
        obj.put("maxTurns", JsonInt(Int64(this.maxTurns)))
        obj.put("temperature", JsonFloat(Float64(this.temperature)))
        obj.put("maxOutputTokens", JsonInt(Int64(this.maxOutputTokens)))
        obj.put("compactionReserveTokens", JsonInt(Int64(this.compactionReserveTokens)))
        obj.put("keepRecentTokens", JsonInt(Int64(this.keepRecentTokens)))
        obj.put("createdAt", JsonInt(this.createdAt))
        obj.put("updatedAt", JsonInt(this.updatedAt))

        // Bool fields
        obj.put("compactionEnabled", JsonBool(this.compactionEnabled))

        // Option<String> fields
        putOptionString(obj, "description", this.description)
        putOptionString(obj, "userPromptTemplate", this.userPromptTemplate)
        putOptionString(obj, "provider", this.provider)
        putOptionString(obj, "thinkingLevel", this.thinkingLevel)
        putOptionString(obj, "createdBy", this.createdBy)

        // ArrayList<String> fields
        obj.put("tools", stringListToJsonArray(this.tools))
        obj.put("skills", stringListToJsonArray(this.skills))
        obj.put("tags", stringListToJsonArray(this.tags))

        return obj
    }

    /**
     * Deserialize a JsonValue into an AgentConfig.
     */
    public static func fromJson(jv: JsonValue): AgentConfig {
        let obj = jv.asObject()

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
 * Put an Option<String> into a JsonObject, using null for None.
 */
func putOptionString(obj: JsonObject, key: String, value: Option<String>): Unit {
    match (value) {
        case Some(v) => obj.put(key, JsonString(v))
        case None => obj.put(key, JsonNull())
    }
}

/**
 * Convert an ArrayList<String> to a JsonArray of JsonString.
 */
func stringListToJsonArray(list: ArrayList<String>): JsonArray {
    let arr = JsonArray()
    for (s in list) {
        arr.add(JsonString(s))
    }
    return arr
}

/**
 * Convert a JsonArray of JsonString to an ArrayList<String>.
 */
func jsonArrayToStringList(arr: JsonArray): ArrayList<String> {
    let items = arr.getItems()
    let result = ArrayList<String>(items.size)
    for (v in items) {
        result.add(v.asString().getValue())
    }
    return result
}

/**
 * Get a required String field from a JsonObject.
 */
func getRequiredString(obj: JsonObject, key: String): String {
    return obj[key].asString().getValue()
}

/**
 * Get a required Int64 field from a JsonObject.
 */
func getRequiredInt(obj: JsonObject, key: String): Int64 {
    return obj[key].asInt().getValue()
}

/**
 * Get a required Bool field from a JsonObject.
 */
func getRequiredBool(obj: JsonObject, key: String): Bool {
    return obj[key].asBool().getValue()
}

/**
 * Get a required JsonArray field from a JsonObject.
 */
func getRequiredArray(obj: JsonObject, key: String): JsonArray {
    return obj[key].asArray()
}

/**
 * Get a Float64 value from a JsonObject field, handling both JsonFloat and JsonInt.
 */
func getNumberAsFloat64(obj: JsonObject, key: String): Float64 {
    let jv = obj[key]
    match (jv.kind()) {
        case JsFloat => jv.asFloat().getValue()
        case JsInt => Float64(jv.asInt().getValue())
        case _ => throw JsonException("${key} must be a number")
    }
}

/**
 * Get an optional String field from a JsonObject.
 * Returns None for missing or null fields.
 */
func getOptionalString(obj: JsonObject, key: String): Option<String> {
    match (obj.get(key)) {
        case Some(jv) =>
            match (jv.kind()) {
                case JsNull => None
                case JsString => Some(jv.asString().getValue())
                case _ => throw JsonException("${key} must be a string or null")
            }
        case None => None
    }
}
