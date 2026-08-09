package atelier.agent

import jsonvalue.*
import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

// 复刻 hook_test.cj 的 FakeProvider：chat 返回固定 end_turn 回复，不真连网络
class StubProvider <: Provider {
    public func name(): String { "stub" }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// 简易 mcp 风格工具（名字带 mcp_ 前缀；read_file 模拟非 mcp 工具）
class McpStyleTool <: Tool {
    private let toolName: String
    public init(name: String) { this.toolName = name }
    public func name(): String { this.toolName }
    public func description(): String { "fake mcp tool" }
    public func schema(): JsonValue { JsonValue.Map(HashMap()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// mcpCooldownTurns=3：激活后 3 轮内活跃，之后进入冷却
// read_* 前缀模式走 `_*` 分支，验证非 mcp 工具不受冷却过滤
func mcpRuntimeConfig(): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("mcp_*")
    tools.add("read_*")
    let skills = ArrayList<String>()
    AgentConfig("t", None, "", None, "m", None, tools, skills, 3,
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

func makeMcpRuntime(provider: Provider, hooks: ArrayList<Hook>, mcpManager: McpManager): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(McpStyleTool("mcp_github_search_repos"))
    toolReg.register(McpStyleTool("read_file"))
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    AgentRuntime(mcpRuntimeConfig(), provider, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, hooks, { q => "" }, mcpManager)
}

// beforeTurn hook 捕获 tools 列表
class CaptureToolsHook <: Hook {
    public var seen: ArrayList<OpenAITool> = ArrayList()
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.seen = request.tools
        TurnDecision.Continue(request)
    }
}

func runAndCaptureSeen(mcpManager: McpManager): (Bool, Bool) {
    let hook = CaptureToolsHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let runtime = makeMcpRuntime(StubProvider(), hooks, mcpManager)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    var foundMcp = false
    var foundPlain = false
    for (t in hook.seen) {
        if (t.name.startsWith("mcp_")) { foundMcp = true }
        if (t.name == "read_file") { foundPlain = true }
    }
    (foundMcp, foundPlain)
}

@Test
func runtime_mcpToolsFilteredWhenInactive() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, false)
    @Expect(foundPlain, true)
}

@Test
func runtime_mcpToolsVisibleAfterActivate() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    mcpManager.activate("github")
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, true)
    @Expect(foundPlain, true)
}

@Test
func runtime_mcpToolsCooldownExpired() {
    let mcpManager = McpManager()
    mcpManager.registerServer(McpServerConfig("github", "stdio", "echo", ""))
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "desc"))
    mcpManager.cacheServerTools("github", tools)
    mcpManager.activate("github")
    var i: Int64 = 0
    while (i < 4) { mcpManager.advanceTurn(); i++ }  // config.mcpCooldownTurns = 3
    let (foundMcp, foundPlain) = runAndCaptureSeen(mcpManager)
    @Expect(foundMcp, false)
    @Expect(foundPlain, true)
}
