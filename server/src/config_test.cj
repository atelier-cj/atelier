package server

import jsonvalue.*
import std.collection.*
import stdx.serialization.serialization.*
import std.fs.*
import tomlcj.*
import atelier.provider.*
import atelier.context.CompactionConfig

func makeTomlProvider(extra: DataModel): TomlProvider {
    let tp = TomlProvider()
    tp.name = "test"
    tp.providerType = "openai"
    tp.baseURL = "http://x"
    tp.apiKey = "key"
    tp.extra = extra
    tp
}

@Test
func toProviderConfig_extraStringMap() {
    // TOML: extra = { reasoning_effort = "high" }
    let extra = DataModelStruct()
        .add(field<String>("reasoning_effort", "high"))
    let tp = makeTomlProvider(extra)
    let cfg = toProviderConfig(tp)
    match (cfg.extra.get("reasoning_effort")) {
        case Some(JsonValue.String(s)) => @Expect(s, "high")
        case _ => @Fail("extra not converted")
    }
}

@Test
func toProviderConfig_extraNestedAndNumber() {
    // TOML: extra = { top_p = 0.9, response_format = { type = "json" } }
    let nested = DataModelStruct()
        .add(field<String>("type", "json"))
    let extra = DataModelStruct()
        .add(field<Float64>("top_p", 0.9))
        .add(Field("response_format", nested))
    let tp = makeTomlProvider(extra)
    let cfg = toProviderConfig(tp)
    match (cfg.extra.get("top_p")) {
        case Some(JsonValue.Number(n)) => @Expect(n, 0.9)
        case _ => @Fail("number not preserved")
    }
    match (cfg.extra.get("response_format")) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("type")) {
                case Some(JsonValue.String(s)) => @Expect(s, "json")
                case _ => @Fail("nested value missing")
            }
        case _ => @Fail("nested object not converted")
    }
}

@Test
func toProviderConfig_missingExtra_returnsEmpty() {
    // 无 extra 字段 → DataModelNull → 空 map
    let tp = makeTomlProvider(DataModelNull())
    let cfg = toProviderConfig(tp)
    @Expect(cfg.extra.size, 0)
}

@Test
func toProviderConfig_fieldsCarried() {
    let tp = makeTomlProvider(DataModelNull())
    let cfg = toProviderConfig(tp)
    @Expect(cfg.`type`, "openai")
    @Expect(cfg.name, "test")
    @Expect(cfg.baseURL, "http://x")
    @Expect(cfg.apiKey, "key")
}

@Test
func tomlProvider_serializeDeserializeRoundTrip() {
    let extra = DataModelStruct()
        .add(field<Int64>("max_tokens", 100))
        .add(field<String>("reasoning_effort", "high"))
    let tp = makeTomlProvider(extra)

    // serialize → deserialize round-trip
    let dm = tp.serialize()
    let tp2 = TomlProvider.deserialize(dm)
    match (tp2.extra) {
        case dms: DataModelStruct =>
            match (dms.get("max_tokens")) {
                case di: DataModelInt => @Expect(di.getValue(), 100)
                case _ => @Fail("max_tokens lost")
            }
            match (dms.get("reasoning_effort")) {
                case ds: DataModelString => @Expect(ds.getValue(), "high")
                case _ => @Fail("reasoning_effort lost")
            }
        case _ => @Fail("extra not preserved as DataModelStruct")
    }
}

var tempFileSeq: Int64 = 0

func writeTomlTemp(content: String): String {
    tempFileSeq++
    let path = "/tmp/atelier_config_test_${tempFileSeq}.toml"
    if (exists(Path(path))) { remove(Path(path)) }
    let f = File(Path(path), Write)
    f.write(content.toArray())
    f.close()
    path
}

@Test
func tomlAgent_compactionParse() {
    // TOML 文本：[[agent]] + [agent.compaction] 嵌套表（文档示例格式，单行 \n 转义模板）
    let content = "[[agent]]\nname = \"test\"\nmodel = \"gpt-4o\"\n\n[agent.compaction]\nenabled = false\nreserveTokens = 4096\nkeepRecentTokens = 8000\npromptTemplate = \"压缩以下对话：\\n{{conversation}}\"\nsummaryModel = \"deepseek-chat\"\n\n[agent.compaction.outputSchema]\nrequired = [\"goal\"]\ntypes = { goal = \"string\" }\n"
    let path = writeTomlTemp(content)
    let cfg = unmarshal<TomlConfig>(path)
    remove(Path(path))

    @Expect(cfg.agent.size, 1)
    match (cfg.agent[0].compaction) {
        case Some(tc) =>
            match (tc.enabled) {
                case Some(b) => @Expect(b, false)
                case None => @Fail("enabled missing")
            }
            match (tc.reserveTokens) {
                case Some(v) => @Expect(v, 4096)
                case None => @Fail("reserveTokens missing")
            }
            match (tc.keepRecentTokens) {
                case Some(v) => @Expect(v, 8000)
                case None => @Fail("keepRecentTokens missing")
            }
            match (tc.promptTemplate) {
                case Some(s) =>
                    @Expect(s.contains("压缩以下对话"), true)
                    @Expect(s.contains("{{conversation}}"), true)
                case None => @Fail("promptTemplate missing")
            }
            match (tc.summaryModel) {
                case Some(s) => @Expect(s, "deepseek-chat")
                case None => @Fail("summaryModel missing")
            }
            match (tc.outputSchema) {
                case dms: DataModelStruct =>
                    match (dms.get("required")) {
                        case seq: DataModelSeq =>
                            @Expect(seq.getItems().size, 1)
                            match (seq.getItems()[0]) {
                                case s: DataModelString => @Expect(s.getValue(), "goal")
                                case _ => @Fail("required element not string")
                            }
                        case _ => @Fail("required missing")
                    }
                    match (dms.get("types")) {
                        case types: DataModelStruct =>
                            match (types.get("goal")) {
                                case s: DataModelString => @Expect(s.getValue(), "string")
                                case _ => @Fail("types.goal missing")
                            }
                        case _ => @Fail("types missing")
                    }
                case _ => @Fail("outputSchema not parsed as struct")
            }
        case None => @Fail("compaction not parsed")
    }
}

@Test
func tomlAgent_compactionParseMultiline() {
    // 多行字符串模板（ASCII 行尾；tomlcj 1.0.0 对中文行尾的多行字符串有 utf8 缺陷，见记忆）
    let content = "[[agent]]\nname = \"multi\"\n\n[agent.compaction]\npromptTemplate = \"\"\"\nSummarize:\n{{conversation}}\n\"\"\"\n"
    let path = writeTomlTemp(content)
    let cfg = unmarshal<TomlConfig>(path)
    remove(Path(path))

    match (cfg.agent[0].compaction) {
        case Some(tc) =>
            match (tc.promptTemplate) {
                case Some(s) =>
                    @Expect(s.contains("Summarize:"), true)
                    @Expect(s.contains("{{conversation}}"), true)
                case None => @Fail("promptTemplate missing")
            }
        case None => @Fail("compaction not parsed")
    }
}

@Test
func tomlAgent_compactionSerializeRoundTrip() {
    // serialize → deserialize 往返不丢失 compaction 字段
    let ta = TomlAgent()
    ta.name = "rt"
    let tc = TomlCompaction()
    tc.enabled = Some(true)
    tc.reserveTokens = Some(Int64(2048))
    ta.compaction = Some(tc)
    let dm = ta.serialize()
    let back = TomlAgent.deserialize(dm)
    match (back.compaction) {
        case Some(c) =>
            match (c.enabled) {
                case Some(b) => @Expect(b, true)
                case None => @Fail("enabled lost")
            }
            match (c.reserveTokens) {
                case Some(v) => @Expect(v, 2048)
                case None => @Fail("reserveTokens lost")
            }
        case None => @Fail("compaction lost in round-trip")
    }
}

@Test
func agentConfigFrom_compactionMapping() {
    // TomlCompaction 全部字段 → AgentConfig.compaction 映射（含 outputSchema DataModel→JsonValue）
    let ta = TomlAgent()
    ta.name = "t1"
    ta.model = "gpt-4o"
    let tc = TomlCompaction()
    tc.enabled = Some(false)
    tc.reserveTokens = Some(Int64(4096))
    tc.keepRecentTokens = Some(Int64(8000))
    tc.promptTemplate = Some("自定义压缩模板")
    tc.summaryModel = Some("deepseek-chat")
    let schema = DataModelStruct()
        .add(field<String>("type", "object"))
        .add(field<Bool>("additionalProperties", false))
    tc.outputSchema = schema
    ta.compaction = Some(tc)

    let cfg = agentConfigFrom(ta)
    match (cfg.compaction) {
        case Some(c) =>
            @Expect(c.enabled, false)
            @Expect(c.reserveTokens, 4096)
            @Expect(c.keepRecentTokens, 8000)
            @Expect(c.promptTemplate, "自定义压缩模板")
            match (c.summaryModel) {
                case Some(s) => @Expect(s, "deepseek-chat")
                case None => @Fail("summaryModel missing")
            }
            match (c.outputSchema) {
                case Some(JsonValue.Map(m)) =>
                    match (m.get("type")) {
                        case Some(JsonValue.String(s)) => @Expect(s, "object")
                        case _ => @Fail("schema type missing")
                    }
                    match (m.get("additionalProperties")) {
                        case Some(JsonValue.Boolean(b)) => @Expect(b, false)
                        case _ => @Fail("schema bool missing")
                    }
                case _ => @Fail("outputSchema not converted to JsonValue")
            }
        case None => @Fail("compaction not mapped")
    }
}

@Test
func agentConfigFrom_compactionPartialDefaults() {
    // 只配 enabled，其余字段回落 CompactionConfig 默认值
    let ta = TomlAgent()
    ta.name = "t2"
    let tc = TomlCompaction()
    tc.enabled = Some(true)
    ta.compaction = Some(tc)

    let cfg = agentConfigFrom(ta)
    let def = CompactionConfig()
    match (cfg.compaction) {
        case Some(c) =>
            @Expect(c.enabled, true)
            @Expect(c.reserveTokens, def.reserveTokens)
            @Expect(c.keepRecentTokens, def.keepRecentTokens)
            @Expect(c.promptTemplate, def.promptTemplate)
            match (c.outputSchema) {
                case None => ()
                case Some(_) => @Fail("expected outputSchema to be None")
            }
            @Expect(c.summaryModel, None)
        case None => @Fail("compaction not mapped")
    }
}

@Test
func agentConfigFrom_noCompactionNone() {
    let ta = TomlAgent()
    ta.name = "t3"
    let cfg = agentConfigFrom(ta)
    match (cfg.compaction) {
        case None => ()
        case Some(_) => @Fail("expected compaction to be None")
    }
}

// TOML mcpServer env（数组字符串 "K=V"）→ McpServerConfig.env
@Test
public func config_mcpServerEnvParsing() {
    let t = TomlMcpServer()
    t.name = "svc"
    t.transport = "stdio"
    t.command = "server-tool"
    t.envList.add("API_TOKEN=secret")
    t.envList.add("EMPTY_KEY=")      // 空值保留空串
    t.envList.add("no-separator")    // 无分隔符跳过
    let cfg = t.toMcpServerConfig()
    @Expect(cfg.env.size, 2)
    match (cfg.env.get("API_TOKEN")) {
        case Some(v) => @Expect(v, "secret")
        case None => @Fail("env API_TOKEN lost")
    }
    match (cfg.env.get("EMPTY_KEY")) {
        case Some(v) => @Expect(v, "")
        case None => @Fail("env EMPTY_KEY lost")
    }
    @Expect(cfg.env.get("no-separator").isNone(), true)
    // headers 不受影响
    @Expect(cfg.headers.size, 0)
}

// ═══════ PTC 配置：TOML → AgentConfig 的传递链 ═══════════════════════════
// 这条链有三段（TomlAgent 反序列化 → agentConfigFrom → runtime），任何一段漏字段
// 都会表现为「配置写了但不生效」，且不会报错——因此逐段都要有用例守住。

@Test
func tomlAgent_ptcFieldsRoundTrip() {
    let a = TomlAgent()
    a.name = "coder"
    a.toolPresentation = "ptc"
    a.ptcTimeoutSeconds = 45
    a.ptcMaxSubCalls = 12
    a.toolTimeout = 7

    let dm = a.serialize()
    // 往返即可覆盖「serialize 漏字段」：漏了 deserialize 会落回默认值，下面的断言会失败
    let back = TomlAgent.deserialize(dm)
    @Expect(back.toolPresentation, "ptc")
    @Expect(back.ptcTimeoutSeconds, Int64(45))
    @Expect(back.ptcMaxSubCalls, Int64(12))
    @Expect(back.toolTimeout, Int64(7))
}

@Test
func tomlAgent_missingPtcFieldsUseDefaults() {
    // 旧配置没有这三个字段：必须照常加载并落到与字段声明一致的默认值
    let dm = DataModelStruct()
        .add(field<String>("name", "legacy"))
        .add(field<String>("model", "gpt-4o"))
    let a = TomlAgent.deserialize(dm)
    @Expect(a.name, "legacy")
    @Expect(a.toolPresentation, "native")
    @Expect(a.ptcTimeoutSeconds, Int64(30))
    @Expect(a.ptcMaxSubCalls, Int64(64))
    @Expect(a.toolTimeout, Int64(30))
}

@Test
func agentConfigFrom_carriesPtcFields() {
    let a = TomlAgent()
    a.name = "coder"
    a.toolPresentation = "ptc"
    a.ptcTimeoutSeconds = 45
    a.ptcMaxSubCalls = 12

    let cfg = agentConfigFrom(a)
    @Expect(cfg.toolPresentation.toString(), "ptc")
    @Expect(cfg.ptcTimeoutSeconds, UInt32(45))
    @Expect(cfg.ptcMaxSubCalls, UInt32(12))
}

@Test
func agentConfigFrom_carriesToolTimeout() {
    let a = TomlAgent()
    a.toolTimeout = 7
    @Expect(agentConfigFrom(a).toolTimeout, UInt32(7))
}

@Test
func agentConfigFrom_zeroToolTimeoutMeansUnbounded() {
    // 0 = 不限时是使用者的显式选择，不能被「像笔误就回落默认」的规则改掉
    let a = TomlAgent()
    a.toolTimeout = 0
    @Expect(agentConfigFrom(a).toolTimeout, UInt32(0))
}

@Test
func agentConfigFrom_negativeToolTimeoutFallsBack() {
    let a = TomlAgent()
    a.toolTimeout = -5
    @Expect(agentConfigFrom(a).toolTimeout, UInt32(30))
}

@Test
func agentConfigFrom_defaultsStayNative() {
    let cfg = agentConfigFrom(TomlAgent())
    // 缺省必须保持现网行为
    @Expect(cfg.toolPresentation.toString(), "native")
    @Expect(cfg.ptcTimeoutSeconds, UInt32(30))
    @Expect(cfg.ptcMaxSubCalls, UInt32(64))
}

@Test
func agentConfigFrom_unknownPresentationFallsBackToNative() {
    let a = TomlAgent()
    a.toolPresentation = "PTC"          // 大小写写错
    @Expect(agentConfigFrom(a).toolPresentation.toString(), "native")

    let b = TomlAgent()
    b.toolPresentation = "nonsense"
    @Expect(agentConfigFrom(b).toolPresentation.toString(), "native")

    let c = TomlAgent()
    c.toolPresentation = "both"
    @Expect(agentConfigFrom(c).toolPresentation.toString(), "both")
}

@Test
func ptcBudget_clampsInvalidValues() {
    // 配置笔误应退化为默认值，而不是让构造抛异常把整个 Agent 拖垮
    @Expect(ptcBudget(45, UInt32(30)), UInt32(45))
    @Expect(ptcBudget(0, UInt32(30)), UInt32(30))
    @Expect(ptcBudget(-5, UInt32(30)), UInt32(30))
    @Expect(ptcBudget(4294967296, UInt32(30)), UInt32(30))
}

@Test
func agentConfigFrom_invalidBudgetsFallBack() {
    let a = TomlAgent()
    a.ptcTimeoutSeconds = 0
    a.ptcMaxSubCalls = -1
    let cfg = agentConfigFrom(a)
    @Expect(cfg.ptcTimeoutSeconds, UInt32(30))
    @Expect(cfg.ptcMaxSubCalls, UInt32(64))
}
