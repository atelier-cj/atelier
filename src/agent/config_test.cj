package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.util.{toJsonString, fromJsonString}
import atelier.context.CompactionConfig

@Test
func config_createWithAllFields() {
    let tools = ArrayList<String>()
    tools.add("read_file"); tools.add("write_file"); tools.add("bash")
    let skills = ArrayList<String>(); skills.add("data_cleaning"); skills.add("analysis")
    let tags = ArrayList<String>(); tags.add("production"); tags.add("v1")

    let cfg = AgentConfig(
        "data-assistant", Some("帮助分析业务数据的智能助手"),
        "你是一个数据分析专家", Some("用户的问题是：{{query}}"),
        "gpt-4o", Some("openai"),
        tools, skills, Int64(0),
        UInt32(10), Float32(0.3), UInt32(8192), Some("low"),
        true, UInt32(20000), UInt32(30000), None, UInt32(30), UInt32(30), UInt32(0),
        tags, Some("admin"), Int64(1000), Int64(2000))

    @Expect(cfg.name, "data-assistant")
    @Expect(cfg.description, Some("帮助分析业务数据的智能助手"))
    @Expect(cfg.systemPrompt, "你是一个数据分析专家")
    @Expect(cfg.userPromptTemplate, Some("用户的问题是：{{query}}"))
    @Expect(cfg.model, "gpt-4o"); @Expect(cfg.provider, Some("openai"))
    @Expect(cfg.tools.size, 3); @Expect(cfg.maxTurns, UInt32(10))
    @Expect(cfg.temperature, Float32(0.3)); @Expect(cfg.maxOutputTokens, UInt32(8192))
    @Expect(cfg.thinkingLevel, Some("low"))
    @Expect(cfg.compactionEnabled, true)
    @Expect(cfg.compactionReserveTokens, UInt32(20000))
    @Expect(cfg.keepRecentTokens, UInt32(30000))
    @Expect(cfg.maxToolCalls, UInt32(30))
    @Expect(cfg.toolTimeout, UInt32(30))
    @Expect(cfg.minToolInterval, UInt32(0))
    @Expect(cfg.tags.size, 2); @Expect(cfg.createdBy, Some("admin"))
    @Expect(cfg.createdAt, Int64(1000)); @Expect(cfg.updatedAt, Int64(2000))
}

@Test
func config_withOptionalsNone() {
    let cfg = AgentConfig(
        "minimal", None, "Be helpful", None,
        "claude-3-haiku", None,
        ArrayList(), ArrayList(), Int64(0),
        UInt32(5), Float32(1.0), UInt32(2048), None,
        false, UInt32(8192), UInt32(10000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))

    @Expect(cfg.name, "minimal"); @Expect(cfg.description, None)
    @Expect(cfg.systemPrompt, "Be helpful"); @Expect(cfg.userPromptTemplate, None)
    @Expect(cfg.model, "claude-3-haiku"); @Expect(cfg.provider, None)
    @Expect(cfg.tools.size, 0); @Expect(cfg.maxTurns, UInt32(5))
    @Expect(cfg.temperature, Float32(1.0)); @Expect(cfg.maxOutputTokens, UInt32(2048))
    @Expect(cfg.thinkingLevel, None)
    @Expect(cfg.compactionEnabled, false)
    @Expect(cfg.compactionReserveTokens, UInt32(8192))
    @Expect(cfg.keepRecentTokens, UInt32(10000))
    @Expect(cfg.maxToolCalls, UInt32(50))
    @Expect(cfg.toolTimeout, UInt32(30))
    @Expect(cfg.minToolInterval, UInt32(0))
    @Expect(cfg.tags.size, 0); @Expect(cfg.createdBy, None)
}

@Test
func config_defaultValues() {
    let cfg = AgentConfig.default()
    @Expect(cfg.name, ""); @Expect(cfg.description, None)
    @Expect(cfg.systemPrompt, ""); @Expect(cfg.userPromptTemplate, None)
    @Expect(cfg.model, ""); @Expect(cfg.provider, None)
    @Expect(cfg.tools.size, 0); @Expect(cfg.maxTurns, UInt32(20))
    @Expect(cfg.temperature, Float32(0.7)); @Expect(cfg.maxOutputTokens, UInt32(4096))
    @Expect(cfg.thinkingLevel, None)
    @Expect(cfg.compactionEnabled, true)
    @Expect(cfg.compactionReserveTokens, UInt32(16384))
    @Expect(cfg.keepRecentTokens, UInt32(20000))
    @Expect(cfg.maxToolCalls, UInt32(50))
    @Expect(cfg.toolTimeout, UInt32(30))
    @Expect(cfg.minToolInterval, UInt32(0))
    @Expect(cfg.tags.size, 0); @Expect(cfg.createdBy, None)
    @Expect(cfg.createdAt, Int64(0)); @Expect(cfg.updatedAt, Int64(0))
}

@Test
func config_jsonRoundTrip_allFields() {
    let tools = ArrayList<String>(); tools.add("read_file"); tools.add("bash")
    let skills = ArrayList<String>(); skills.add("data_cleaning")
    let tags = ArrayList<String>(); tags.add("test")

    let original = AgentConfig(
        "json-test", Some("JSON round-trip test"),
        "You are a test agent", Some("User query: {{input}}"),
        "gpt-4o-mini", Some("openai"),
        tools, skills, Int64(7),
        UInt32(15), Float32(0.5), UInt32(2048), Some("medium"),
        true, UInt32(16384), UInt32(25000), None, UInt32(50), UInt32(30), UInt32(0),
        tags, Some("tester"), Int64(100), Int64(200))

    let v = JsonValue.fromObject(original)
    let restored = JsonValue.toObject<AgentConfig>(v)

    @Expect(restored.name, original.name)
    @Expect(restored.description, original.description)
    @Expect(restored.systemPrompt, original.systemPrompt)
    @Expect(restored.userPromptTemplate, original.userPromptTemplate)
    @Expect(restored.model, original.model)
    @Expect(restored.provider, original.provider)
    @Expect(restored.tools[0], original.tools[0]); @Expect(restored.tools[1], original.tools[1])
    @Expect(restored.skills[0], original.skills[0])
    @Expect(restored.mcpCooldownTurns, original.mcpCooldownTurns)
    @Expect(restored.maxTurns, original.maxTurns)
    @Expect(restored.temperature, original.temperature)
    @Expect(restored.maxOutputTokens, original.maxOutputTokens)
    @Expect(restored.thinkingLevel, original.thinkingLevel)
    @Expect(restored.compactionEnabled, original.compactionEnabled)
    @Expect(restored.compactionReserveTokens, original.compactionReserveTokens)
    @Expect(restored.keepRecentTokens, original.keepRecentTokens)
    @Expect(restored.tags[0], original.tags[0])
    @Expect(restored.createdBy, original.createdBy)
    @Expect(restored.createdAt, original.createdAt); @Expect(restored.updatedAt, original.updatedAt)
}

@Test
func config_jsonRoundTrip_minimal() {
    let original = AgentConfig.default()
    let v = JsonValue.fromObject(original)
    let restored = JsonValue.toObject<AgentConfig>(v)

    @Expect(restored.name, ""); @Expect(restored.model, "")
    @Expect(restored.maxTurns, UInt32(20))
    @Expect(restored.temperature, Float32(0.7))
    @Expect(restored.maxOutputTokens, UInt32(4096))
    @Expect(restored.compactionEnabled, true)
    @Expect(restored.compactionReserveTokens, UInt32(16384))
    @Expect(restored.keepRecentTokens, UInt32(20000))
    @Expect(restored.tools.size, 0)
    @Expect(restored.description, None)
    @Expect(restored.provider, None); @Expect(restored.thinkingLevel, None)
}

@Test
func config_jsonRoundTrip_withOptionals() {
    let original = AgentConfig(
        "optionals-test", None, "System prompt here", None,
        "deepseek-chat", None,
        ArrayList(), ArrayList(), Int64(0),
        UInt32(5), Float32(1.0), UInt32(1024), None,
        false, UInt32(4096), UInt32(8000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))

    let v = JsonValue.fromObject(original)
    let restored = JsonValue.toObject<AgentConfig>(v)

    @Expect(restored.name, "optionals-test")
    @Expect(restored.systemPrompt, "System prompt here")
    @Expect(restored.model, "deepseek-chat")
    @Expect(restored.maxTurns, UInt32(5))
    @Expect(restored.compactionEnabled, false)
    @Expect(restored.description, None)
    @Expect(restored.userPromptTemplate, None)
    @Expect(restored.provider, None); @Expect(restored.thinkingLevel, None)
    @Expect(restored.createdBy, None)
}

@Test
func config_toString_containsName() {
    let cfg = AgentConfig.default()
    @Expect(cfg.toString().contains("AgentConfig"), true)
}

@Test
func config_mcpCooldownDefaultZero() {
    let cfg = AgentConfig.default()
    @Expect(cfg.mcpCooldownTurns, Int64(0))
}

@Test
func config_mcpCooldownRoundTrip() {
    let cfg = AgentConfig("a", None, "", None, "", None,
        ArrayList(), ArrayList(), Int64(5),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let v = JsonValue.fromObject(cfg)
    let back = JsonValue.toObject<AgentConfig>(v)
    @Expect(back.mcpCooldownTurns, Int64(5))
}

@Test
func config_mcpCooldownFromJsonMissingFieldDefaultsZero() {
    let v = JsonValue.fromObject(AgentConfig.default())
    let obj = match (v) {
        case JsonValue.Map(m) => m
        case _ => HashMap<String, JsonValue>()
    }
    obj.remove("mcpCooldownTurns")
    let back = JsonValue.toObject<AgentConfig>(JsonValue.Map(obj))
    @Expect(back.mcpCooldownTurns, Int64(0))
}

@Test
func config_compactionDefaultNone() {
    let cfg = AgentConfig.default()
    match (cfg.compaction) {
        case None => ()
        case Some(_) => @Fail("expected compaction to be None")
    }
}

@Test
func config_compactionRoundTrip() {
    let opts = HashMap<String, JsonValue>()
    let required = ArrayList<JsonValue>()
    required.add(JsonValue.String("goal"))
    opts["required"] = JsonValue.Array(required)
    let cc = CompactionConfig(false, 8192, 5000, "自定义模板", Some(JsonValue.Map(opts)), Some("summary-model"))
    let cfg = AgentConfig("comp-test", None, "", None, "m", None,
        ArrayList(), ArrayList(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        true, UInt32(16384), UInt32(20000), Some(cc), UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let json = toJsonString(cfg)
    let back = fromJsonString<AgentConfig>(json)
    match (back.compaction) {
        case Some(c) =>
            @Expect(c.enabled, false)
            @Expect(c.reserveTokens, 8192)
            @Expect(c.keepRecentTokens, 5000)
            @Expect(c.promptTemplate, "自定义模板")
            @Expect(c.summaryModel, Some("summary-model"))
            match (c.outputSchema) {
                case Some(JsonValue.Map(m)) =>
                    match (m.get("required")) {
                        case Some(JsonValue.Array(items)) => @Expect(items.size, 1)
                        case _ => @Fail("expected required array")
                    }
                case _ => @Fail("expected outputSchema preserved")
            }
        case None => @Fail("expected compaction config")
    }
}

@Test
func config_compactionMissingFieldDefaultsNone() {
    let json = "{\"name\":\"x\",\"systemPrompt\":\"\",\"model\":\"m\",\"maxTurns\":20,\"temperature\":0.7,\"maxOutputTokens\":4096,\"compactionEnabled\":true,\"compactionReserveTokens\":16384,\"keepRecentTokens\":20000,\"maxToolCalls\":50,\"toolTimeout\":30,\"minToolInterval\":0,\"createdAt\":0,\"updatedAt\":0,\"tools\":[],\"skills\":[],\"tags\":[]}"
    let back = fromJsonString<AgentConfig>(json)
    match (back.compaction) {
        case None => ()
        case Some(_) => @Fail("expected compaction to be None")
    }
    @Expect(back.compactionEnabled, true)
}
