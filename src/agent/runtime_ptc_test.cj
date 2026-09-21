package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.ptc.*
import atelier.event.EventStream

/**
 * 呈现模式投影测试：本轮暴露的工具与 SDK 段必须来自同一次可见性解析。
 *
 * 复用 runtime_test.cj 的 StubProvider / McpStyleTool（同包）。
 */
class CaptureRequestHook <: Hook {
    public var tools: ArrayList<OpenAITool> = ArrayList()
    public var systemPrompt: String = ""

    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.tools = request.tools
        this.systemPrompt = request.systemPrompt
        TurnDecision.Continue(request)
    }
}

func ptcRuntimeConfig(mode: ToolPresentationMode): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("read_*")
    let skills = ArrayList<String>()
    AgentConfig("ptc-agent", None, "", None, "m", None, tools, skills, 3,
        UInt32(5), Float32(0.7), UInt32(4096), None,
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0),
        toolPresentation: mode)
}

/** 跑一轮并捕获请求；不连网络（StubProvider 直接回 end_turn）。 */
func runAndCaptureRequest(mode: ToolPresentationMode): CaptureRequestHook {
    let hook = CaptureRequestHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)

    let toolReg = ToolRegistry()
    toolReg.register(McpStyleTool("read_file"))
    toolReg.register(McpStyleTool("read_grep"))

    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())

    let runtime = AgentRuntime(ptcRuntimeConfig(mode), StubProvider(), toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, { q => "" }, McpManager())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    hook
}

func toolNames(tools: ArrayList<OpenAITool>): ArrayList<String> {
    let names = ArrayList<String>()
    for (t in tools) {
        names.add(t.name)
    }
    names
}

func containsName(tools: ArrayList<OpenAITool>, name: String): Bool {
    for (t in tools) {
        if (t.name == name) {
            return true
        }
    }
    false
}

@Test
func runtime_nativeModeKeepsNativeSchemaOnly() {
    let hook = runAndCaptureRequest(ToolPresentationMode.Native)
    // 现网行为：可见工具逐个通告，不引入 run_xisp
    @Assert(hook.tools.size == 2)
    @Assert(containsName(hook.tools, "read_file"))
    @Assert(containsName(hook.tools, "read_grep"))
    @Assert(!containsName(hook.tools, "run_xisp"))
    // native 模式不应注入 SDK 段
    @Assert(!hook.systemPrompt.contains("tools::read_file"))
}

@Test
func runtime_ptcModeExposesOnlyRunXisp() {
    let hook = runAndCaptureRequest(ToolPresentationMode.Ptc)
    @Assert(hook.tools.size == 1)
    @Assert(containsName(hook.tools, "run_xisp"))
    @Assert(!containsName(hook.tools, "read_file"))
}

@Test
func runtime_ptcModeInjectsSdkSection() {
    let hook = runAndCaptureRequest(ToolPresentationMode.Ptc)
    // SDK 段必须与可见工具一一对应
    @Assert(hook.systemPrompt.contains("tools::read_file"))
    @Assert(hook.systemPrompt.contains("tools::read_grep"))
    // run_xisp 是入口本身，不该作为绑定出现在 SDK 段里
    @Assert(!hook.systemPrompt.contains("tools::run_xisp"))
    // 固定说明必须带上（含实现期确认的布尔字面量语法）
    @Assert(hook.systemPrompt.contains("#t / #f"))
}

@Test
func runtime_bothModeExposesBothProjections() {
    let hook = runAndCaptureRequest(ToolPresentationMode.Both)
    @Assert(hook.tools.size == 3)
    @Assert(containsName(hook.tools, "read_file"))
    @Assert(containsName(hook.tools, "run_xisp"))
    @Assert(hook.systemPrompt.contains("tools::read_file"))
}

@Test
func runtime_ptcRegistersRunXispForDispatch() {
    // 仅出现在请求里不够：分发链路按名字查注册表，必须真的注册进去
    let hook = CaptureRequestHook()
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let toolReg = ToolRegistry()
    toolReg.register(McpStyleTool("read_file"))
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let runtime = AgentRuntime(ptcRuntimeConfig(ToolPresentationMode.Ptc), StubProvider(),
        toolReg, MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, { q => "" }, McpManager())

    @Assert(toolReg.get("run_xisp").isNone())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()

    @Assert(toolReg.get("run_xisp").isSome())
}
