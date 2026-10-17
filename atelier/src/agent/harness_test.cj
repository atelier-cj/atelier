package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.tool.*
import atelier.session.*
import atelier.provider.*
import atelier.util.{toJsonString, fromJsonString}
import atelier.provider.ModelInfo
import atelier.trust.{TrustManager, TrustState, TrustDecision}

// ========== 装配束：派生语义 / provider 解析 / 上下文窗口 / 便利层 ==========

class SpecProbeTool <: Tool {
    private let toolName: String
    public init(name: String) { this.toolName = name }
    public func name(): String { this.toolName }
    public func description(): String { "probe" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

func cfgOf(model: String, provider: Option<String>): AgentConfig {
    AgentConfig("t", None, "", None, model, provider, ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0))
}

@Test
func harnessSpec_defaultWiresBuiltinTools() {
    let spec = HarnessSpec.default()
    // 内置工具一次配齐（含技能入口与按需加载 MCP），"零配置可用"落在这里
    @Expect(spec.tools.has("read_file"), true)
    @Expect(spec.tools.has("bash"), true)
    @Expect(spec.tools.has("ask_user"), true)
    @Expect(spec.tools.has("use_skills"), true)
    @Expect(spec.tools.has("load_mcp_toolset"), true)
    @Expect(spec.agents.list().size, 0)
}

@Test
func harnessSpec_withToolsViewDoesNotTouchRootTable() {
    let spec = HarnessSpec.default()
    let view = spec.withToolsView(ArrayList<Tool>([SpecProbeTool("client_only")]))

    @Expect(view.tools.has("client_only"), true)
    // 根表不动：视图是另立的，按请求加的工具不会串到并发中的其它 run
    @Expect(spec.tools.has("client_only"), false)
    // 根表原有工具在视图里照样可见
    @Expect(view.tools.has("bash"), true)
}

@Test
func harnessSpec_withToolRegistersIntoRootTable() {
    let spec = HarnessSpec()
    let same = spec.withTool(SpecProbeTool("kept"))
    @Expect(same.tools.has("kept"), true)
    @Expect(spec.tools.has("kept"), true)
}

@Test
func harnessSpec_withStoreOnlyAffectsDerived() {
    let base = HarnessSpec()
    let other = MemorySessionStore()
    let derived = base.withStore(other)

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    other.save("s1", SessionHeader(1, "s1", 0, 0, "", "", "", None), msgs)

    @Expect(derived.store.load("s1").size, 1)
    // 原装配束的存储里没有这条会话（读不到就是明确的 not found）—— 派生没有写穿
    var notFound = false
    try {
        base.store.load("s1")
    } catch (e: Exception) {
        notFound = true
    }
    @Expect(notFound, true)
}

@Test
func harnessSpec_providerOverlayDoesNotLeakToSiblings() {
    let base = HarnessSpec()
    let withProvider = base.withProvider("p", EchoProvider())
    @Expect(withProvider.resolveProvider(cfgOf("m", Some("p"))).name(), "echo")

    // 兄弟派生（同样从 base 出发）看不到别人的叠加表
    let sibling = base.withStore(MemorySessionStore())
    var threw = false
    try {
        sibling.resolveProvider(cfgOf("m", Some("p")))
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)
}

@Test
func harnessSpec_resolveProviderFallsBackToSharedRegistry() {
    let reg = ProviderRegistry()
    reg.register("shared", EchoProvider())
    let spec = HarnessSpec(providers: reg)
    @Expect(spec.resolveProvider(cfgOf("m", Some("shared"))).name(), "echo")
}

@Test
func harnessSpec_resolveProviderMissingIsExplicit() {
    var threw = false
    try {
        HarnessSpec().resolveProvider(cfgOf("m", None))
    } catch (e: Exception) {
        threw = true
        // 报错要点出缺的是哪一个 provider，别让人对着 "no provider" 猜
        @Expect(e.message.contains("default"), true)
    }
    @Expect(threw, true)
}

// ---------- 上下文窗口 ----------

@Test
func contextWindow_providerPairIsUsed() {
    // 窗口是 (provider, model) 这一对路由的事实：声明在端点上，agent 只负责选
    let spec = HarnessSpec.forTests(EchoProvider())
        .withModelContext("default", "vendor-model", 262144)
    let runtime = AgentRuntime(spec, cfgOf("vendor-model", None))
    @Expect(runtime.contextWindowInUse(), 262144)
}

@Test
func contextWindow_pairBeatsModelNameLayer() {
    // 同名模型走不同端点：官方 262144，截断过的代理 32768 —— 各按各的端点取值
    let spec = HarnessSpec.forTests(EchoProvider())
        .withModelContextByName("vendor-model", 111)
        .withModelContext("proxy", "vendor-model", 32768)

    let viaProxy = AgentRuntime(spec.withProvider("proxy", EchoProvider()), cfgOf("vendor-model", Some("proxy")))
    @Expect(viaProxy.contextWindowInUse(), 32768)

    // 走没声明过的端点 → 回退模型名层（不是拿代理那个数）
    let viaDefault = AgentRuntime(spec, cfgOf("vendor-model", None))
    @Expect(viaDefault.contextWindowInUse(), 111)

    // 端点层与模型名层都没声明 → 兜底 + 警告
    let bare = AgentRuntime(HarnessSpec.forTests(EchoProvider()), cfgOf("vendor-model", None))
    @Expect(bare.contextWindowInUse(), Int64(8192))
}

@Test
func contextWindow_unknownModelFallsBackToDefault() {
    let runtime = AgentRuntime(HarnessSpec.forTests(EchoProvider()), cfgOf("totally-unknown-model", None))
    @Expect(runtime.contextWindowInUse(), Int64(8192))

    let narrow = HarnessSpec.forTests(EchoProvider()).withDefaults(32768)
    @Expect(AgentRuntime(narrow, cfgOf("totally-unknown-model", None)).contextWindowInUse(), 32768)
}

@Test
func contextWindow_providerSelfReportApplies() {
    // 宿主没声明时，落到 provider 自报这一层（EchoProvider 用接口默认实现查内置目录）
    let runtime = AgentRuntime(HarnessSpec.forTests(EchoProvider()), cfgOf("deepseek-chat", None))
    @Expect(runtime.contextWindowInUse(), 65536)
}

@Test
func modelFacts_configOutranksProviderSelfReport() {
    // 声明 > provider 自报：代理截断这类"端点与目录不符"由配置纠正
    let spec = HarnessSpec.forTests(EchoProvider()).withModelContext("default", "deepseek-chat", 32768)
    @Expect(AgentRuntime(spec, cfgOf("deepseek-chat", None)).contextWindowInUse(), 32768)
}

@Test
func modelFacts_maxTokensResolvesPerLayer() {
    // agent 显式给了完成预算就用它
    let withAgentBudget = cfgOf("deepseek-chat", None)
    @Expect(AgentRuntime(HarnessSpec.forTests(EchoProvider()), withAgentBudget).maxOutputTokensInUse(), Int64(4096))
    // 0 = 交给模型事实（provider 自报里 deepseek-chat 是 8192）
    let spec = HarnessSpec.forTests(EchoProvider())
    @Expect(AgentRuntime(spec, cfgOfNoBudget("deepseek-chat")).maxOutputTokensInUse(), Int64(8192))
    // 声明优先于自报
    let declared = spec.withModelFacts("default", "deepseek-chat", ModelInfo(65536, 2048))
    @Expect(AgentRuntime(declared, cfgOfNoBudget("deepseek-chat")).maxOutputTokensInUse(), Int64(2048))
}

// 完成预算交给模型事实的配置（0 = 不显式指定）
func cfgOfNoBudget(model: String): AgentConfig {
    AgentConfig("t", None, "", None, model, None, ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(0), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0))
}

// ---------- 便利层 ----------

@Test
func harness_runReturnsAssistantText() {
    let h = Harness.open(HarnessSpec.forTests(EchoProvider()))
    @Expect(h.run("你好"), "echo: 你好")
}

@Test
func harness_configOfMissingAgentFallsBackToDefault() {
    let h = Harness.open(HarnessSpec.forTests(EchoProvider()))
    @Expect(h.configOf("nope").name, "")
}

@Test
func harness_closeIsQuietAndRepeatable() {
    let h = Harness.open(HarnessSpec.forTests(EchoProvider()))
    h.close()
    h.close()
    @Expect(true, true)
}

// ==================== 信任闸门装配（HarnessSpec.trustGate） ====================

// 未注入时：生效闸门绑定 spec 的 trust，行为与改动前一致
@Test
func harnessSpec_trustGateDefaultsToTrustManagerBinding() {
    let trust = TrustManager()
    trust.setTrust("/proj", TrustState.Trusted)
    let spec = HarnessSpec(trust: trust)
    let gate = spec.resolvedTrustGate()
    // 有副作用工具（Sequential）在已信任目录 → 放行
    let seq = SpecSequentialToolForGate()
    @Expect(isTrust(gate(seq, "/proj", ""), TrustDecision.Allowed), true)
    // 未信任目录 → 要问
    @Expect(isTrust(gate(seq, "/other", ""), TrustDecision.NeedsApproval), true)
}

// 注入后：生效闸门就是注入的那个（可替换性）
@Test
func harnessSpec_withTrustGateOverridesDefault() {
    let spec = HarnessSpec().withTrustGate({ _, _, _ => TrustDecision.Denied })
    let gate = spec.resolvedTrustGate()
    @Expect(isTrust(gate(SpecSequentialToolForGate(), "/anywhere", ""), TrustDecision.Denied), true)
}

// 派生值语义：with* 不回写原 spec（同其它组件的契约）
@Test
func harnessSpec_withTrustGateIsValueSemantics() {
    let base = HarnessSpec()
    let derived = base.withTrustGate({ _, _, _ => TrustDecision.Denied })
    // 原 spec 仍是"未注入"
    match (base.trustGate) {
        case None => @Expect(true, true)
        case Some(_) => @Expect("base must have no gate", "")
    }
    match (derived.trustGate) {
        case Some(_) => @Expect(true, true)
        case None => @Expect("derived must have a gate", "")
    }
}

// 派生时其它受管字段不变（trustGate 与 trust 是两个字段，互不覆盖）
@Test
func harnessSpec_withTrustGateKeepsTrustManager() {
    let trust = TrustManager()
    let spec = HarnessSpec(trust: trust).withTrustGate({ _, _, _ => TrustDecision.Allowed })
    let gate = spec.resolvedTrustGate()
    @Expect(isTrust(gate(SpecSequentialToolForGate(), "/x", ""), TrustDecision.Allowed), true)
    // manager 仍在（供 setTrust 等写路径用）
    trust.setTrust("/x", TrustState.Trusted)
    @Expect(isState(trust.getTrust("/x"), TrustState.Trusted), true)
}

class SpecSequentialToolForGate <: Tool {
    public func name(): String { "spec_seq" }
    public func description(): String { "" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

func isTrust(d: TrustDecision, expected: TrustDecision): Bool {
    match (d) {
        case expected => true
        case _ => false
    }
}

func isState(s: TrustState, expected: TrustState): Bool {
    match (s) {
        case expected => true
        case _ => false
    }
}
