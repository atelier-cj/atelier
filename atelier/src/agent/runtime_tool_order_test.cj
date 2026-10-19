package atelier.agent

/*
 * 可见工具顺序的**字节稳定性**。
 *
 * 工具声明（native 投影的 schema 逐条列出、PTC 投影的 SDK 段）都是提示词前缀的一部分。
 * provider 的前缀缓存按「前缀单元完整匹配」计价，因此**同一批工具必须是同一个顺序**：
 * 顺序抖动哪怕只发生在中间，从第一个工具起前缀就不同，整段按未命中计价。
 *
 * 顺序为什么会抖：`resolveVisibleTools` 的通配分支（`prefix_*`）遍历工具注册表，
 * 而注册表底层是 HashMap —— 迭代顺序取决于**插入历史**。运行中按需注册 MCP 工具、
 * 或不同会话先加载了不同的工具集，都会改变插入历史。
 *
 * 每轮重算本身是对的（MCP 冷却要随回合推进），错的是「重算结果没有确定的顺序」。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.ptc.*
import jsonvalue.*

class SortProbeTool <: Tool {
    private let n: String
    public init(n: String) { this.n = n }
    public func name(): String { this.n }
    public func description(): String { "probe" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 捕获本轮的可见工具名顺序（钩子拿到的 request.tools 就是最终投影）
class CaptureOrderHook <: Hook {
    public var names = ArrayList<String>()
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        for (t in request.tools) { this.names.add(t.name) }
        TurnDecision.Continue(request)
    }
}

func sortConfig(pattern: String, mode!: ToolPresentationMode = ToolPresentationMode.Native): AgentConfig {
    let tools = ArrayList<String>()
    tools.add(pattern)
    AgentConfig("sort", None, "", None, "m", None, tools, ArrayList<String>(), 3,
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0),
        toolPresentation: mode)
}

// 按给定注册顺序建一份 runtime 并跑一轮，返回本轮投影出的工具名顺序
func orderFor(registrationOrder: Array<String>, mode!: ToolPresentationMode = ToolPresentationMode.Native): ArrayList<String> {
    let toolReg = ToolRegistry()
    for (n in registrationOrder) { toolReg.register(SortProbeTool(n)) }
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let hook = CaptureOrderHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let runtime = testRuntime(sortConfig("probe_*", mode: mode), StubProvider(), toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    hook.names
}

// 核心：注册顺序不同、可见集合相同 → 投影顺序必须一致
@Test
func runtime_visibleToolOrderIndependentOfRegistrationOrder() {
    let a = orderFor(["probe_b", "probe_a", "probe_c"])
    let b = orderFor(["probe_c", "probe_b", "probe_a"])
    let c = orderFor(["probe_a", "probe_b", "probe_c"])
    @Expect(a, b)
    @Expect(b, c)
    // 且应当是名字升序（确定性顺序，任何人重放都得到同一结果）
    @Expect(a, ArrayList<String>(["probe_a", "probe_b", "probe_c"]))
}

// 混入运行中注册的工具（模拟按需加载的 MCP 工具）后，已有工具的相对顺序不变
@Test
func runtime_visibleToolOrderStableAfterLateRegistration() {
    let toolReg = ToolRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let hook = CaptureOrderHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let runtime = testRuntime(sortConfig("probe_*"), StubProvider(), toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, McpManager())
    // 先注册后两个，跑一轮
    toolReg.register(SortProbeTool("probe_y"))
    toolReg.register(SortProbeTool("probe_z"))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    let first = ArrayList<String>(hook.names)

    // 运行中再注册一个（插在字典序中间）：新一轮的顺序应当是同一份升序，而不是"追加在后面"
    toolReg.register(SortProbeTool("probe_m"))
    hook.names.clear()
    runtime.chat(msgs).result()
    let second = ArrayList<String>(hook.names)

    @Expect(first, ArrayList<String>(["probe_y", "probe_z"]))
    @Expect(second, ArrayList<String>(["probe_m", "probe_y", "probe_z"]))
}

// PTC 投影的 SDK 段同样必须是稳定顺序（它是系统提示词的组成部分）。
//
// 注意这条守的是**结果**而不是**本处修复**：`PtcSdkRenderer.render` 内部本来就按名字
// 排序（见其 sortByName），所以即使去掉 `resolveVisibleTools` 出口的排序，这条也照样
// 通过。留着它的价值是锁住「SDK 段字节稳定」这个对外契约 —— 将来谁把渲染器内的排序
// 去掉，这里会红；而 native 投影的顺序由前两条用例负责。
@Test
func runtime_ptcSdkSectionOrderStable() {
    let a = ptcSdkSectionFor(["probe_b", "probe_a"])
    let b = ptcSdkSectionFor(["probe_a", "probe_b"])
    @Expect(a, b)
    // probe_a 的签名出现在 probe_b 之前
    let ia = a.indexOf("probe_a") ?? Int64(-1)
    let ib = a.indexOf("probe_b") ?? Int64(-1)
    @Expect(ia >= 0, true)
    @Expect(ib >= 0, true)
    @Expect(ia < ib, true)
}

func ptcSdkSectionFor(registrationOrder: Array<String>): String {
    let toolReg = ToolRegistry()
    for (n in registrationOrder) { toolReg.register(SortProbeTool(n)) }
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let hook = CapturePromptHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let runtime = testRuntime(sortConfig("probe_*", mode: ToolPresentationMode.Ptc),
        StubProvider(), toolReg, MemorySessionStore(), TrustManager(), SkillRegistry(),
        AgentRegistry(), providerReg, hooks, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    hook.systemPrompt
}

class CapturePromptHook <: Hook {
    public var systemPrompt: String = ""
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.systemPrompt = request.systemPrompt
        TurnDecision.Continue(request)
    }
}
