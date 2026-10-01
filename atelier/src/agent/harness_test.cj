package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.tool.*
import atelier.session.*
import atelier.provider.*
import atelier.util.{toJsonString, fromJsonString}

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
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
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

    let narrow = HarnessSpec.forTests(EchoProvider()).withDefaultContextWindow(32768)
    @Expect(AgentRuntime(narrow, cfgOf("totally-unknown-model", None)).contextWindowInUse(), 32768)
}

@Test
func contextWindow_builtinTableStillApplies() {
    let runtime = AgentRuntime(HarnessSpec.forTests(EchoProvider()), cfgOf("deepseek-chat", None))
    @Expect(runtime.contextWindowInUse(), 65536)
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
