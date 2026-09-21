package atelier.agent

import std.collection.*
import stdx.encoding.json.stream.*
import atelier.context.CompactionConfig
import atelier.ptc.ToolPresentationMode

public struct AgentConfig <: JsonSerializable & JsonDeserializable<AgentConfig> {
    public let name: String
    public let description: Option<String>
    public let systemPrompt: String
    public let userPromptTemplate: Option<String>
    public let model: String
    public let provider: Option<String>
    public let tools: ArrayList<String>
    public let skills: ArrayList<String>
    public let mcpCooldownTurns: Int64
    public let maxTurns: UInt32
    public let temperature: Float32
    public let maxOutputTokens: UInt32
    public let thinkingLevel: Option<String>
    public let compactionEnabled: Bool
    public let compactionReserveTokens: UInt32
    public let keepRecentTokens: UInt32
    public let compaction: Option<CompactionConfig>
    public let maxToolCalls: UInt32
    public let toolTimeout: UInt32
    public let minToolInterval: UInt32
    public let tags: ArrayList<String>
    public let createdBy: Option<String>
    public let createdAt: Int64
    public let updatedAt: Int64
    // 模型能力：是否支持图片输入（多模态）。默认 false；发图前据此检查/路由
    public let supportsVision: Bool
    // 工具呈现模式：native（默认，逐次 JSON Schema）/ ptc（只暴露 run_xisp）/ both
    public let toolPresentation: ToolPresentationMode
    // PTC 程序的经过时间预算（秒）
    public let ptcTimeoutSeconds: UInt32
    // PTC 单次程序允许的子调用上限
    public let ptcMaxSubCalls: UInt32

    public init(
        name: String, description: Option<String>,
        systemPrompt: String, userPromptTemplate: Option<String>,
        model: String, provider: Option<String>,
        tools: ArrayList<String>, skills: ArrayList<String>,
        mcpCooldownTurns: Int64,
        maxTurns: UInt32, temperature: Float32, maxOutputTokens: UInt32,
        thinkingLevel: Option<String>,
        compactionEnabled: Bool, compactionReserveTokens: UInt32, keepRecentTokens: UInt32,
        compaction: Option<CompactionConfig>,
        maxToolCalls: UInt32, toolTimeout: UInt32, minToolInterval: UInt32,
        tags: ArrayList<String>,
        createdBy: Option<String>, createdAt: Int64, updatedAt: Int64,
        supportsVision!: Bool = false,
        toolPresentation!: ToolPresentationMode = ToolPresentationMode.Native,
        ptcTimeoutSeconds!: UInt32 = 30,
        ptcMaxSubCalls!: UInt32 = 64
    ) {
        this.name = name; this.description = description
        this.systemPrompt = systemPrompt; this.userPromptTemplate = userPromptTemplate
        this.model = model; this.provider = provider
        this.tools = tools; this.skills = skills
        this.mcpCooldownTurns = mcpCooldownTurns
        this.maxTurns = maxTurns; this.temperature = temperature; this.maxOutputTokens = maxOutputTokens
        this.thinkingLevel = thinkingLevel
        this.compactionEnabled = compactionEnabled
        this.compactionReserveTokens = compactionReserveTokens; this.keepRecentTokens = keepRecentTokens
        this.compaction = compaction
        this.maxToolCalls = maxToolCalls
        this.toolTimeout = toolTimeout
        this.minToolInterval = minToolInterval
        this.tags = tags
        this.createdBy = createdBy; this.createdAt = createdAt; this.updatedAt = updatedAt
        this.supportsVision = supportsVision
        this.toolPresentation = toolPresentation
        this.ptcTimeoutSeconds = ptcTimeoutSeconds
        this.ptcMaxSubCalls = ptcMaxSubCalls
    }

    public static func default(): AgentConfig {
        AgentConfig(
            "", None, "", None, "", None,
            ArrayList(), ArrayList(), Int64(0),
            UInt32(20), Float32(0.7), UInt32(4096), None,
            true, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
            ArrayList(), None, Int64(0), Int64(0))
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("systemPrompt").writeValue(this.systemPrompt)
        w.writeName("model").writeValue(this.model)
        w.writeName("maxTurns").writeValue(Int64(this.maxTurns))
        w.writeName("temperature").writeValue(Float64(this.temperature))
        w.writeName("maxOutputTokens").writeValue(Int64(this.maxOutputTokens))
        w.writeName("compactionEnabled").writeValue(this.compactionEnabled)
        w.writeName("compactionReserveTokens").writeValue(Int64(this.compactionReserveTokens))
        w.writeName("keepRecentTokens").writeValue(Int64(this.keepRecentTokens))
        w.writeName("compaction").writeValue(this.compaction)
        w.writeName("maxToolCalls").writeValue(Int64(this.maxToolCalls))
        w.writeName("toolTimeout").writeValue(Int64(this.toolTimeout))
        w.writeName("minToolInterval").writeValue(Int64(this.minToolInterval))
        w.writeName("createdAt").writeValue(this.createdAt)
        w.writeName("updatedAt").writeValue(this.updatedAt)
        w.writeName("description").writeValue(this.description)
        w.writeName("userPromptTemplate").writeValue(this.userPromptTemplate)
        w.writeName("provider").writeValue(this.provider)
        w.writeName("thinkingLevel").writeValue(this.thinkingLevel)
        w.writeName("createdBy").writeValue(this.createdBy)
        w.writeName("tools").writeValue(this.tools)
        w.writeName("skills").writeValue(this.skills)
        w.writeName("mcpCooldownTurns").writeValue(this.mcpCooldownTurns)
        w.writeName("tags").writeValue(this.tags)
        w.writeName("supportsVision").writeValue(this.supportsVision)
        w.writeName("toolPresentation").writeValue(this.toolPresentation.toString())
        w.writeName("ptcTimeoutSeconds").writeValue(Int64(this.ptcTimeoutSeconds))
        w.writeName("ptcMaxSubCalls").writeValue(Int64(this.ptcMaxSubCalls))
        w.endObject()
    }

    public static func fromJson(r: JsonReader): AgentConfig {
        var name = ""; var description: Option<String> = None
        var systemPrompt = ""; var userPromptTemplate: Option<String> = None
        var model = ""; var provider: Option<String> = None
        var tools = ArrayList<String>(); var skills = ArrayList<String>()
        var mcpCooldownTurns = Int64(0)
        var maxTurns = UInt32(20); var temperature = Float32(0.7); var maxOutputTokens = UInt32(4096)
        var thinkingLevel: Option<String> = None
        var compactionEnabled = true
        var compactionReserveTokens = UInt32(16384); var keepRecentTokens = UInt32(20000)
        var compaction: Option<CompactionConfig> = None
        var maxToolCalls = UInt32(50)
        var toolTimeout = UInt32(30)
        var minToolInterval = UInt32(0)
        var tags = ArrayList<String>()
        var createdBy: Option<String> = None; var createdAt = Int64(0); var updatedAt = Int64(0)
        var supportsVision = false
        var toolPresentation = ToolPresentationMode.Native
        var ptcTimeoutSeconds = UInt32(30)
        var ptcMaxSubCalls = UInt32(64)

        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "name" => name = r.readValue<String>()
                case "description" => description = r.readValue<Option<String>>()
                case "systemPrompt" => systemPrompt = r.readValue<String>()
                case "userPromptTemplate" => userPromptTemplate = r.readValue<Option<String>>()
                case "model" => model = r.readValue<String>()
                case "provider" => provider = r.readValue<Option<String>>()
                case "tools" => tools = r.readValue<ArrayList<String>>()
                case "skills" => skills = r.readValue<ArrayList<String>>()
                case "mcpCooldownTurns" => mcpCooldownTurns = r.readValue<Int64>()
                case "maxTurns" => maxTurns = UInt32(r.readValue<Int64>())
                case "temperature" => temperature = Float32(r.readValue<Float64>())
                case "maxOutputTokens" => maxOutputTokens = UInt32(r.readValue<Int64>())
                case "thinkingLevel" => thinkingLevel = r.readValue<Option<String>>()
                case "compactionEnabled" => compactionEnabled = r.readValue<Bool>()
                case "compactionReserveTokens" => compactionReserveTokens = UInt32(r.readValue<Int64>())
                case "keepRecentTokens" => keepRecentTokens = UInt32(r.readValue<Int64>())
                case "compaction" => compaction = r.readValue<Option<CompactionConfig>>()
                case "maxToolCalls" => maxToolCalls = UInt32(r.readValue<Int64>())
                case "toolTimeout" => toolTimeout = UInt32(r.readValue<Int64>())
                case "minToolInterval" => minToolInterval = UInt32(r.readValue<Int64>())
                case "tags" => tags = r.readValue<ArrayList<String>>()
                case "createdBy" => createdBy = r.readValue<Option<String>>()
                case "createdAt" => createdAt = r.readValue<Int64>()
                case "updatedAt" => updatedAt = r.readValue<Int64>()
                case "supportsVision" => supportsVision = r.readValue<Bool>()
                case "toolPresentation" => toolPresentation = ToolPresentationMode.fromString(r.readValue<String>())
                case "ptcTimeoutSeconds" => ptcTimeoutSeconds = UInt32(r.readValue<Int64>())
                case "ptcMaxSubCalls" => ptcMaxSubCalls = UInt32(r.readValue<Int64>())
                case _ => r.skip()
            }
        }
        r.endObject()

        AgentConfig(name, description, systemPrompt, userPromptTemplate,
            model, provider, tools, skills, mcpCooldownTurns,
            maxTurns, temperature, maxOutputTokens, thinkingLevel,
            compactionEnabled, compactionReserveTokens, keepRecentTokens, compaction,
            maxToolCalls, toolTimeout, minToolInterval,
            tags, createdBy, createdAt, updatedAt, supportsVision: supportsVision,
            toolPresentation: toolPresentation,
            ptcTimeoutSeconds: ptcTimeoutSeconds,
            ptcMaxSubCalls: ptcMaxSubCalls)
    }

    public func toString(): String {
        "AgentConfig{name: ${this.name}, model: ${this.model}, tools: ${this.tools.size}}"
    }
}
