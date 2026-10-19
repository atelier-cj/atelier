package atelier.agent

/*
 * run 作用域工具的隔离。
 *
 * 契约：run 期按需创建的工具实例（`run_xisp` / `agent_<name>`）只落在**本次 run 的
 * 派生视图**（[RunScope.tools]）里，绝不写进 `HarnessSpec.tools` 那张根表。
 *
 * 为什么这是硬要求而不是整洁度问题：这些实例的构造参数绑着**这一次 run** 的上下文
 * （`RunXispTool.env` 里的 workDir / sessionId / cancelFlag / authorizer）。根表由同一份
 * 装配束下的多个 runtime 共享，一旦把实例挂上去，并发的另一个会话按名字分发时就会命中它：
 * 按别人的 workDir 过信任闸门、按别人的取消标志判中断 —— 信任判定的键与请求来源脱节。
 *
 * 同一份装配束可以被多个 runtime 复用（`HarnessSpec.createLoop` 是宿主侧的常规入口），
 * 因此隔离必须在 runtime 内部完成，不能寄望每个宿主都记得先派生视图。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.ptc.ToolPresentationMode
import jsonvalue.*

// 记录自己被调用时看到的 workDir —— 用来判断分发命中的是不是本次 run 的上下文
class WorkDirProbeTool <: Tool {
    public var seenWorkDir: String = ""
    public func name(): String { "probe_tool" }
    public func description(): String { "probe" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.seenWorkDir = ctx.workDir
        ToolResult("ok", None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 捕获 beforeTurn 里可见的工具名（钩子拿到的必须是 run 视图）
class CaptureToolNamesHook <: Hook {
    public var names = ArrayList<String>()
    public var registry: Option<ToolRegistry> = None
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.registry = Some(ctx.toolRegistry)
        for (t in request.tools) { this.names.add(t.name) }
        TurnDecision.Continue(request)
    }
}

func ptcProbeConfig(toolNames: ArrayList<String>): AgentConfig {
    AgentConfig("ptc", None, "", None, "m", None, toolNames, ArrayList<String>(), 3,
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0),
        toolPresentation: ToolPresentationMode.Ptc)
}

func nameList(names: Array<String>): ArrayList<String> {
    let l = ArrayList<String>()
    for (n in names) { l.add(n) }
    l
}

// 根表里的工具名（含重复计数，用于发现"后注册覆盖前注册"这类残留）
func rootToolNames(reg: ToolRegistry): ArrayList<String> {
    let names = ArrayList<String>()
    for (t in reg.list()) { names.add(t.name()) }
    names
}

// AgentLoop 的公开入口只有 drive/cancel/steer/status：装一组消息跑一次即可
func runOnce(loop: AgentLoop, text: String,
    sessionEnv!: SessionEnvironment = SessionEnvironment()): ArrayList<Message> {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(text), 0))
    loop.drive(RunInput(msgs, env: sessionEnv)).result()
}

// 核心断言：PTC 模式跑完后，run_xisp 不得留在跨 runtime 共享的根表里
@Test
func runtime_runScopedToolsDoNotLeakIntoSharedRootTable() {
    let toolReg = ToolRegistry()
    toolReg.register(WorkDirProbeTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let spec = HarnessSpec(tools: toolReg, store: MemorySessionStore(),
        trust: TrustManager(), skills: SkillRegistry(), agents: AgentRegistry(),
        providers: providerReg, mcp: McpManager())
    let cfg = ptcProbeConfig(nameList(["probe_tool"]))

    let rtA = spec.createLoop(cfg)
    runOnce(rtA, "a")
    @Expect(rootToolNames(toolReg).contains("run_xisp"), false)

    // 第二个 runtime 用同一份 spec 再跑：根表依然干净
    let rtB = spec.createLoop(cfg)
    runOnce(rtB, "b")
    @Expect(rootToolNames(toolReg).contains("run_xisp"), false)
    // 根表只剩宿主自己注册的那一个工具
    @Expect(rootToolNames(toolReg).size, Int64(1))
    @Expect(rootToolNames(toolReg)[0], "probe_tool")
}

// 两个 runtime 各自的 run_xisp 实例互不覆盖：各自视图里的实例都绑定本次 run 的 workDir。
// 用 run_xisp 的可见工具集间接验证 —— 视图是每个 run 新建的，父表始终是同一张根表。
@Test
func runtime_runScopedToolViewsArePerRun() {
    let toolReg = ToolRegistry()
    toolReg.register(WorkDirProbeTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let spec = HarnessSpec(tools: toolReg, store: MemorySessionStore(),
        trust: TrustManager(), skills: SkillRegistry(), agents: AgentRegistry(),
        providers: providerReg, mcp: McpManager())
    let cfg = ptcProbeConfig(nameList(["probe_tool"]))

    let hookA = CaptureToolNamesHook()
    let hooksA = ArrayList<Hook>()
    hooksA.add(hookA)
    let rtA = spec.withHooks(hooksA).createLoop(cfg)
    runOnce(rtA, "a")

    let hookB = CaptureToolNamesHook()
    let hooksB = ArrayList<Hook>()
    hooksB.add(hookB)
    let rtB = spec.withHooks(hooksB).createLoop(cfg)
    runOnce(rtB, "b")

    // 两次 run 各自看得到 run_xisp（视图里有），根表里没有
    @Expect(hookA.names.contains("run_xisp"), true)
    @Expect(hookB.names.contains("run_xisp"), true)
    @Expect(rootToolNames(toolReg).contains("run_xisp"), false)

    // 钩子拿到的是**本次 run 的视图**：它查得到 run_xisp，但视图的父表是根表
    match (hookA.registry) {
        case Some(reg) => @Expect(reg.has("run_xisp"), true)
        case None => @Fail("beforeTurn 应当拿到工具表")
    }
}

// 执行器必须用 run 视图：run 期注册进视图的工具在这一轮**能被分发到**，
// 且 run 结束后不留在根表。
// （若执行器仍持有构造期那张根表，注册进视图的工具会"查不到"而回 Tool not found。）
@Test
func runtime_runScopedExecutorSeesRunRegisteredTools() {
    let toolReg = ToolRegistry()
    let providerReg = ProviderRegistry()
    // 唯一一个 provider 响应：调一个 run 期间才注册的工具
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("调 run 期工具", "probe_tool", "c1"))
    responses.add(endTurnMsg("收尾"))
    providerReg.register("default", ScriptedMsgProvider(responses))
    let spec = HarnessSpec(tools: toolReg, store: MemorySessionStore(),
        trust: TrustManager(), skills: SkillRegistry(), agents: AgentRegistry(),
        providers: providerReg, mcp: McpManager())

    // probe_tool 只在 beforeRun 里注册进**钩子拿到的视图**，根表从来没有它
    let seedHook = RegisterToolHook()
    let hooks = ArrayList<Hook>()
    hooks.add(seedHook)
    let cfg = AgentConfig("t", None, "", None, "m", None, nameList(["probe_tool"]),
        ArrayList<String>(), 3, UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let loop = spec.withHooks(hooks).createLoop(cfg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑点东西"), 0))
    let result = loop.chat(msgs).result()

    var executed = false
    for (m in result) {
        match (m) {
            case tr: ToolResultMessage where tr.toolCallId == "c1" =>
                // 查不到会写成 "Tool not found: probe_tool"
                @Expect(textOfMsg(tr).contains("Tool not found"), false)
                executed = true
            case _ => ()
        }
    }
    @Expect(executed, true)
    // run 期注册的工具不留在共享根表
    @Expect(rootToolNames(toolReg).contains("probe_tool"), false)
    @Expect(rootToolNames(toolReg).size, Int64(0))
}

// beforeRun 里往**拿到的视图**注册工具：它属于本次 run，根表不受影响
class RegisterToolHook <: Hook {
    public override func beforeRun(ctx: HookContext): Unit {
        ctx.toolRegistry.register(WorkDirProbeTool())
    }
}
