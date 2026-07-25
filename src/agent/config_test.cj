package atelier.agent

import std.collection.*
import stdx.encoding.json.*

// ── Test 1: AgentConfig creation with all fields ────────────

@Test
func config_createWithAllFields() {
    let tools = ArrayList<String>()
    tools.add("read_file")
    tools.add("write_file")
    tools.add("bash")

    let skills = ArrayList<String>()
    skills.add("data_cleaning")
    skills.add("analysis")

    let tags = ArrayList<String>()
    tags.add("production")
    tags.add("v1")

    let cfg = AgentConfig(
        "data-assistant",
        Some("帮助分析业务数据的智能助手"),
        "你是一个数据分析专家",
        Some("用户的问题是：{{query}}"),
        "gpt-4o",
        Some("openai"),
        tools,
        skills,
        UInt32(10),
        Float32(0.3),
        UInt32(8192),
        Some("low"),
        true,
        UInt32(20000),
        UInt32(30000),
        tags,
        Some("admin"),
        Int64(1000),
        Int64(2000)
    )

    @Expect(cfg.name, "data-assistant")
    match (cfg.description) {
        case Some(v) => @Expect(v, "帮助分析业务数据的智能助手")
        case None => @Fail("description should be Some")
    }
    @Expect(cfg.systemPrompt, "你是一个数据分析专家")
    match (cfg.userPromptTemplate) {
        case Some(v) => @Expect(v, "用户的问题是：{{query}}")
        case None => @Fail("userPromptTemplate should be Some")
    }
    @Expect(cfg.model, "gpt-4o")
    match (cfg.provider) {
        case Some(v) => @Expect(v, "openai")
        case None => @Fail("provider should be Some")
    }
    @Expect(cfg.tools.size, 3)
    @Expect(cfg.tools[0], "read_file")
    @Expect(cfg.tools[1], "write_file")
    @Expect(cfg.tools[2], "bash")
    @Expect(cfg.skills.size, 2)
    @Expect(cfg.skills[0], "data_cleaning")
    @Expect(cfg.skills[1], "analysis")
    @Expect(cfg.maxTurns, UInt32(10))
    @Expect(cfg.temperature, Float32(0.3))
    @Expect(cfg.maxOutputTokens, UInt32(8192))
    match (cfg.thinkingLevel) {
        case Some(v) => @Expect(v, "low")
        case None => @Fail("thinkingLevel should be Some")
    }
    @Expect(cfg.compactionEnabled, true)
    @Expect(cfg.compactionReserveTokens, UInt32(20000))
    @Expect(cfg.keepRecentTokens, UInt32(30000))
    @Expect(cfg.tags.size, 2)
    @Expect(cfg.tags[0], "production")
    @Expect(cfg.tags[1], "v1")
    match (cfg.createdBy) {
        case Some(v) => @Expect(v, "admin")
        case None => @Fail("createdBy should be Some")
    }
    @Expect(cfg.createdAt, Int64(1000))
    @Expect(cfg.updatedAt, Int64(2000))
}

// ── Test 2: AgentConfig with optional fields set to None ──

@Test
func config_withOptionalsNone() {
    let cfg = AgentConfig(
        "minimal",
        None,
        "Be helpful",
        None,
        "claude-3-haiku",
        None,
        ArrayList<String>(),
        ArrayList<String>(),
        UInt32(5),
        Float32(1.0),
        UInt32(2048),
        None,
        false,
        UInt32(8192),
        UInt32(10000),
        ArrayList<String>(),
        None,
        Int64(0),
        Int64(0)
    )

    @Expect(cfg.name, "minimal")
    match (cfg.description) {
        case None => ()
        case Some(_) => @Fail("description should be None")
    }
    @Expect(cfg.systemPrompt, "Be helpful")
    match (cfg.userPromptTemplate) {
        case None => ()
        case Some(_) => @Fail("userPromptTemplate should be None")
    }
    @Expect(cfg.model, "claude-3-haiku")
    match (cfg.provider) {
        case None => ()
        case Some(_) => @Fail("provider should be None")
    }
    @Expect(cfg.tools.size, 0)
    @Expect(cfg.skills.size, 0)
    @Expect(cfg.maxTurns, UInt32(5))
    @Expect(cfg.temperature, Float32(1.0))
    @Expect(cfg.maxOutputTokens, UInt32(2048))
    match (cfg.thinkingLevel) {
        case None => ()
        case Some(_) => @Fail("thinkingLevel should be None")
    }
    @Expect(cfg.compactionEnabled, false)
    @Expect(cfg.compactionReserveTokens, UInt32(8192))
    @Expect(cfg.keepRecentTokens, UInt32(10000))
    @Expect(cfg.tags.size, 0)
    match (cfg.createdBy) {
        case None => ()
        case Some(_) => @Fail("createdBy should be None")
    }
}

// ── Test 3: Default values via static default() method ─────

@Test
func config_defaultValues() {
    let cfg = AgentConfig.default()

    @Expect(cfg.name, "")
    match (cfg.description) {
        case None => ()
        case Some(_) => @Fail("default description should be None")
    }
    @Expect(cfg.systemPrompt, "")
    match (cfg.userPromptTemplate) {
        case None => ()
        case Some(_) => @Fail("default userPromptTemplate should be None")
    }
    @Expect(cfg.model, "")
    match (cfg.provider) {
        case None => ()
        case Some(_) => @Fail("default provider should be None")
    }
    @Expect(cfg.tools.size, 0)
    @Expect(cfg.skills.size, 0)
    @Expect(cfg.maxTurns, UInt32(20))
    @Expect(cfg.temperature, Float32(0.7))
    @Expect(cfg.maxOutputTokens, UInt32(4096))
    match (cfg.thinkingLevel) {
        case None => ()
        case Some(_) => @Fail("default thinkingLevel should be None")
    }
    @Expect(cfg.compactionEnabled, true)
    @Expect(cfg.compactionReserveTokens, UInt32(16384))
    @Expect(cfg.keepRecentTokens, UInt32(20000))
    @Expect(cfg.tags.size, 0)
    match (cfg.createdBy) {
        case None => ()
        case Some(_) => @Fail("default createdBy should be None")
    }
    @Expect(cfg.createdAt, Int64(0))
    @Expect(cfg.updatedAt, Int64(0))
}

// ── Test 4: JSON serialization/deserialization round-trip ──

@Test
func config_jsonRoundTrip_allFields() {
    let tools = ArrayList<String>()
    tools.add("read_file")
    tools.add("bash")

    let skills = ArrayList<String>()
    skills.add("data_cleaning")

    let tags = ArrayList<String>()
    tags.add("test")

    let original = AgentConfig(
        "json-test",
        Some("JSON round-trip test"),
        "You are a test agent",
        Some("User query: {{input}}"),
        "gpt-4o-mini",
        Some("openai"),
        tools,
        skills,
        UInt32(15),
        Float32(0.5),
        UInt32(2048),
        Some("medium"),
        true,
        UInt32(16384),
        UInt32(25000),
        tags,
        Some("tester"),
        Int64(100),
        Int64(200)
    )

    // Serialize
    let json = original.toJson()
    let jsonStr = json.toString()

    // Deserialize
    let parsed = JsonValue.fromStr(jsonStr)
    let restored = AgentConfig.fromJson(parsed)

    // Verify round-trip preserved all fields
    @Expect(restored.name, original.name)
    match (original.description) {
        case Some(ov) =>
            match (restored.description) {
                case Some(rv) => @Expect(rv, ov)
                case None => @Fail("description lost in round-trip")
            }
        case None => @Fail("original description should be Some")
    }
    @Expect(restored.systemPrompt, original.systemPrompt)
    match (original.userPromptTemplate) {
        case Some(ov) =>
            match (restored.userPromptTemplate) {
                case Some(rv) => @Expect(rv, ov)
                case None => @Fail("userPromptTemplate lost in round-trip")
            }
        case None => @Fail("original userPromptTemplate should be Some")
    }
    @Expect(restored.model, original.model)
    match (original.provider) {
        case Some(ov) =>
            match (restored.provider) {
                case Some(rv) => @Expect(rv, ov)
                case None => @Fail("provider lost in round-trip")
            }
        case None => @Fail("original provider should be Some")
    }
    @Expect(restored.tools.size, original.tools.size)
    @Expect(restored.tools[0], original.tools[0])
    @Expect(restored.tools[1], original.tools[1])
    @Expect(restored.skills.size, original.skills.size)
    @Expect(restored.skills[0], original.skills[0])
    @Expect(restored.maxTurns, original.maxTurns)
    @Expect(restored.temperature, original.temperature)
    @Expect(restored.maxOutputTokens, original.maxOutputTokens)
    match (original.thinkingLevel) {
        case Some(ov) =>
            match (restored.thinkingLevel) {
                case Some(rv) => @Expect(rv, ov)
                case None => @Fail("thinkingLevel lost in round-trip")
            }
        case None => @Fail("original thinkingLevel should be Some")
    }
    @Expect(restored.compactionEnabled, original.compactionEnabled)
    @Expect(restored.compactionReserveTokens, original.compactionReserveTokens)
    @Expect(restored.keepRecentTokens, original.keepRecentTokens)
    @Expect(restored.tags.size, original.tags.size)
    @Expect(restored.tags[0], original.tags[0])
    match (original.createdBy) {
        case Some(ov) =>
            match (restored.createdBy) {
                case Some(rv) => @Expect(rv, ov)
                case None => @Fail("createdBy lost in round-trip")
            }
        case None => @Fail("original createdBy should be Some")
    }
    @Expect(restored.createdAt, original.createdAt)
    @Expect(restored.updatedAt, original.updatedAt)
}

@Test
func config_jsonRoundTrip_minimal() {
    let original = AgentConfig.default()

    // Serialize
    let json = original.toJson()
    let jsonStr = json.toString()

    // Deserialize
    let parsed = JsonValue.fromStr(jsonStr)
    let restored = AgentConfig.fromJson(parsed)

    // Verify defaults
    @Expect(restored.name, "")
    @Expect(restored.model, "")
    @Expect(restored.maxTurns, UInt32(20))
    @Expect(restored.temperature, Float32(0.7))
    @Expect(restored.maxOutputTokens, UInt32(4096))
    @Expect(restored.compactionEnabled, true)
    @Expect(restored.compactionReserveTokens, UInt32(16384))
    @Expect(restored.keepRecentTokens, UInt32(20000))
    @Expect(restored.tools.size, 0)
    @Expect(restored.skills.size, 0)
    @Expect(restored.tags.size, 0)

    match (restored.description) {
        case None => ()
        case Some(_) => @Fail("description should be None after round-trip")
    }
    match (restored.provider) {
        case None => ()
        case Some(_) => @Fail("provider should be None after round-trip")
    }
    match (restored.thinkingLevel) {
        case None => ()
        case Some(_) => @Fail("thinkingLevel should be None after round-trip")
    }
}

@Test
func config_jsonRoundTrip_withOptionals() {
    let original = AgentConfig(
        "optionals-test",
        None,
        "System prompt here",
        None,
        "deepseek-chat",
        None,
        ArrayList<String>(),
        ArrayList<String>(),
        UInt32(5),
        Float32(1.0),
        UInt32(1024),
        None,
        false,
        UInt32(4096),
        UInt32(8000),
        ArrayList<String>(),
        None,
        Int64(0),
        Int64(0)
    )

    let json = original.toJson()
    let jsonStr = json.toString()
    let parsed = JsonValue.fromStr(jsonStr)
    let restored = AgentConfig.fromJson(parsed)

    @Expect(restored.name, "optionals-test")
    @Expect(restored.systemPrompt, "System prompt here")
    @Expect(restored.model, "deepseek-chat")
    @Expect(restored.maxTurns, UInt32(5))
    @Expect(restored.temperature, Float32(1.0))
    @Expect(restored.maxOutputTokens, UInt32(1024))
    @Expect(restored.compactionEnabled, false)
    @Expect(restored.compactionReserveTokens, UInt32(4096))
    @Expect(restored.keepRecentTokens, UInt32(8000))

    match (restored.description) {
        case None => ()
        case Some(_) => @Fail("description should be None")
    }
    match (restored.userPromptTemplate) {
        case None => ()
        case Some(_) => @Fail("userPromptTemplate should be None")
    }
    match (restored.provider) {
        case None => ()
        case Some(_) => @Fail("provider should be None")
    }
    match (restored.thinkingLevel) {
        case None => ()
        case Some(_) => @Fail("thinkingLevel should be None")
    }
    match (restored.createdBy) {
        case None => ()
        case Some(_) => @Fail("createdBy should be None")
    }
}

@Test
func config_toString_containsName() {
    let cfg = AgentConfig.default()
    let str = cfg.toString()
    @Expect(str.contains("AgentConfig"), true)
}
