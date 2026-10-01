package server

import jsonvalue.*
import std.collection.*
import stdx.serialization.serialization.*
import std.fs.*
import tomlcj.*
import atelier.provider.*
import atelier.context.CompactionConfig
import atelier.agent.HarnessSpec

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

// 默认不跳过 TLS 校验：新增字段不得把既有配置悄悄降级成不校验
@Test
func toProviderConfig_skipTlsVerifyDefaultOff() {
    let tp = makeTomlProvider(DataModelNull())
    @Expect(toProviderConfig(tp).skipTlsVerify, false)
}

@Test
func toProviderConfig_skipTlsVerifyCarried() {
    let tp = makeTomlProvider(DataModelNull())
    tp.skipTlsVerify = true
    @Expect(toProviderConfig(tp).skipTlsVerify, true)
}

@Test
func tomlProvider_skipTlsVerifyRoundTrip() {
    let tp = makeTomlProvider(DataModelNull())
    tp.skipTlsVerify = true
    @Expect(TomlProvider.deserialize(tp.serialize()).skipTlsVerify, true)
}

// 配置文件路径：[[provider]] skipTlsVerify = true 必须一路走到 ProviderConfig
@Test
func tomlConfig_skipTlsVerifyFromTomlText() {
    let content = "[[provider]]\nname = \"win\"\ntype = \"openai\"\n" +
        "baseURL = \"https://api.deepseek.com\"\napiKey = \"k\"\nskipTlsVerify = true\n"
    let path = writeTomlTemp(content)
    let cfg = unmarshal<TomlConfig>(path)
    remove(Path(path))
    @Expect(cfg.provider.size, 1)
    @Expect(cfg.provider[0].skipTlsVerify, true)
    @Expect(toProviderConfig(cfg.provider[0]).skipTlsVerify, true)
}

// 配置文件里没写该字段 → 保持系统 CA 校验
@Test
func tomlConfig_skipTlsVerifyAbsentStaysOff() {
    let content = "[[provider]]\nname = \"linux\"\ntype = \"openai\"\n" +
        "baseURL = \"https://api.deepseek.com\"\napiKey = \"k\"\n"
    let path = writeTomlTemp(content)
    let cfg = unmarshal<TomlConfig>(path)
    remove(Path(path))
    @Expect(cfg.provider.size, 1)
    @Expect(cfg.provider[0].skipTlsVerify, false)
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
func agentConfigFrom_carriesSideEffectToolTimeout() {
    let a = TomlAgent()
    a.sideEffectToolTimeout = 45
    @Expect(agentConfigFrom(a).sideEffectToolTimeout, UInt32(45))
}

@Test
func agentConfigFrom_zeroSideEffectTimeoutMeansUnbounded() {
    // 0 = 该类不限时，同样是显式选择
    let a = TomlAgent()
    a.sideEffectToolTimeout = 0
    @Expect(agentConfigFrom(a).sideEffectToolTimeout, UInt32(0))
}

@Test
func agentConfigFrom_defaultSideEffectTimeoutIsWiderThanReadOnly() {
    // 有副作用那一类默认宽一个量级：构建/安装这类正常耗时本就长，
    // 且这一类的超时意味着「结果未知」，代价比读类大
    let cfg = agentConfigFrom(TomlAgent())
    @Expect(cfg.toolTimeout, UInt32(30))
    @Expect(cfg.sideEffectToolTimeout, UInt32(300))
}

@Test
func tomlAgent_sideEffectToolTimeoutRoundTrip() {
    let a = TomlAgent()
    a.sideEffectToolTimeout = 45
    @Expect(TomlAgent.deserialize(a.serialize()).sideEffectToolTimeout, Int64(45))
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

// 回合/输出预算从 TOML 配置读取（此前硬编码 20 轮 / 4096 token，长任务被截断却调不了）；
// maxLengthContinuations 允许显式 0（= 截断即结束），负数与越界回落默认值。
@Test
func agentConfigFrom_turnAndOutputBudgets() {
    let ta = TomlAgent()
    ta.name = "budget"
    ta.model = "deepseek-chat"
    ta.maxTurns = 60
    ta.maxOutputTokens = 8192
    ta.maxLengthContinuations = 5

    let cfg = agentConfigFrom(ta)
    @Expect(cfg.maxTurns, UInt32(60))
    @Expect(cfg.maxOutputTokens, UInt32(8192))
    @Expect(cfg.maxLengthContinuations, UInt32(5))

    // 默认值：未配置时保持 20 轮 / 4096 token / 续跑 3 次
    let def = agentConfigFrom(TomlAgent())
    @Expect(def.maxTurns, UInt32(20))
    @Expect(def.maxOutputTokens, UInt32(4096))
    @Expect(def.maxLengthContinuations, UInt32(3))

    // 显式 0：不续跑
    let off = TomlAgent()
    off.maxLengthContinuations = 0
    @Expect(agentConfigFrom(off).maxLengthContinuations, UInt32(0))

    // 笔误（负数）回落默认值，不让 Agent 起不来
    let bad = TomlAgent()
    bad.maxTurns = -1
    bad.maxOutputTokens = 0
    bad.maxLengthContinuations = -3
    let fixed = agentConfigFrom(bad)
    @Expect(fixed.maxTurns, UInt32(20))
    @Expect(fixed.maxOutputTokens, UInt32(4096))
    @Expect(fixed.maxLengthContinuations, UInt32(3))
}

// 温度从 TOML 读取（此前硬编码 0.7）：允许 0（确定性），越界回落默认值。
@Test
func agentConfigFrom_temperature() {
    let ta = TomlAgent()
    ta.temperature = 0.2
    @Expect(agentConfigFrom(ta).temperature, Float32(0.2))

    let zero = TomlAgent()
    zero.temperature = 0.0
    @Expect(agentConfigFrom(zero).temperature, Float32(0.0))

    let bad = TomlAgent()
    bad.temperature = 3.5
    @Expect(agentConfigFrom(bad).temperature, Float32(0.7))
}

// 收尾前自验：TOML 可配（0 = 关闭，负数回落 0）。
@Test
func agentConfigFrom_verifyPasses() {
    let ta = TomlAgent()
    ta.maxVerifyPasses = 2
    @Expect(agentConfigFrom(ta).maxVerifyPasses, UInt32(2))

    @Expect(agentConfigFrom(TomlAgent()).maxVerifyPasses, UInt32(0))

    let bad = TomlAgent()
    bad.maxVerifyPasses = -1
    @Expect(agentConfigFrom(bad).maxVerifyPasses, UInt32(0))
}

// ---------- 上下文窗口：[[model]] 与 agent 级声明 ----------

@Test
func agentConfigFrom_contextWindow() {
    let ta = TomlAgent()
    ta.model = "vendor-model"
    ta.contextWindow = 262144
    @Expect(agentConfigFrom(ta).contextWindow, Some(262144))

    // 未声明（0）= 交给装配束的模型表；写成 0/负数不该被当成窗口
    @Expect(agentConfigFrom(TomlAgent()).contextWindow, None)

    let zero = TomlAgent()
    zero.contextWindow = 0
    @Expect(agentConfigFrom(zero).contextWindow, None)
}

@Test
func tomlModel_roundTrip() {
    // 用户是在配置文件里写 [[model]] 的：读路径必须真的认它
    let file = writeTempToml("""
[[model]]
name = "vendor-model"
contextWindow = 262144
""")
    let cfg = unmarshal<TomlConfig>(file)
    @Expect(cfg.model.size, 1)
    @Expect(cfg.model[0].name, "vendor-model")
    @Expect(cfg.model[0].contextWindow, 262144)

    // 写路径也要带上（不然改配置再存回就丢声明）
    let text = String.fromUtf8(marshal(cfg))
    @Expect(text.contains("[[model]]"), true)
    @Expect(text.contains("262144"), true)
}

func writeTempToml(body: String): String {
    let dir = "/tmp/atelier-cfg-test-model-window"
    try { Directory.create(Path(dir), recursive: true) } catch (_) { () }
    let file = dir + "/config.toml"
    let f = File(file, OpenMode.Write)
    f.write(body.toArray())
    f.close()
    file
}

@Test
func withTomlModels_appliesDeclaredWindows() {
    var models = ArrayList<TomlModel>()
    let declared = TomlModel()
    declared.name = "vendor-model"
    declared.contextWindow = 262144
    models.add(declared)
    // 声明的窗口 <= 0 = 未声明，不该覆盖内置表
    let bogus = TomlModel()
    bogus.name = "gpt-4o"
    bogus.contextWindow = 0
    models.add(bogus)

    let spec = withTomlModels(HarnessSpec(), models)
    @Expect(spec.models.has("vendor-model"), true)
    @Expect(spec.models.get("vendor-model"), 262144)
    // 内置表没被 0 覆盖
    @Expect(spec.models.get("gpt-4o"), 128000)
    // 原装配束（未调用 withTomlModels 的）不受影响
    @Expect(HarnessSpec().models.has("vendor-model"), false)
}
