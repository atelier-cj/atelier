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

// ==================== 端到端：模型发 run_xisp → 分发 → 程序内派发工具 ====================

/** 记录调用次数的可见工具；声明 Parallel 以免子调用再触发一次交互审批。 */
class RecordingTool <: Tool {
    private let toolName: String
    public var calls: Int64 = 0

    public init(name: String) { this.toolName = name }
    public func name(): String { this.toolName }
    public func description(): String { "recording tool" }

    public func schema(): JsonValue {
        let pathField = HashMap<String, JsonValue>()
        pathField.add("type", JsonValue.String("string"))
        let props = HashMap<String, JsonValue>()
        props.add("path", JsonValue.Map(pathField))
        let required = ArrayList<JsonValue>()
        required.add(JsonValue.String("path"))
        let m = HashMap<String, JsonValue>()
        m.add("type", JsonValue.String("object"))
        m.add("properties", JsonValue.Map(props))
        m.add("required", JsonValue.Array(required))
        JsonValue.Map(m)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.calls = this.calls + 1
        ToolResult("content-of-a.cj", None, false, false)
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

/** 首回合请求 run_xisp，次回合收尾。 */
class ProgramProvider <: Provider {
    private var calls: Int64 = 0
    private let program: String

    public init(program: String) { this.program = program }
    public func name(): String { "program-provider" }

    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("done"), "", "",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls = this.calls + 1
        let stream = EventStream<ChatDelta, AssistantMessage>()
        if (this.calls == Int64(1)) {
            let args = HashMap<String, JsonValue>()
            args.add("code", JsonValue.String(this.program))
            args.add("description", JsonValue.String("integration"))
            let blocks = ArrayList<ContentBlock>()
            blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_1", "run_xisp", JsonValue.Map(args))))
            let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        } else {
            let msg = AssistantMessage(ContentList.ofText("done"), "", "",
                StopReason.EndTurn, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        }
        stream
    }
}

func textOfContent(list: ContentList): String {
    let sb = StringBuilder()
    for (block in list.blocks()) {
        match (block) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}

func runProgramThroughLoop(program: String): (RecordingTool, ArrayList<Message>) {
    let recorder = RecordingTool("read_file")
    let toolReg = ToolRegistry()
    toolReg.register(recorder)

    let provider = ProgramProvider(program)
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)

    // run_xisp 是 Sequential：workDir 未信任时走交互审批，这里一律放行
    let runtime = AgentRuntime(ptcRuntimeConfig(ToolPresentationMode.Ptc), provider,
        toolReg, MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, ArrayList<Hook>(), { q => "y" }, McpManager())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    (recorder, runtime.chat(msgs).result())
}

@Test
func runtime_ptcEndToEndProgramDispatchesVisibleTool() {
    // 这条覆盖单测覆盖不到的接线：注册表查找 → 分发 → 绑定 → 子调用 → 结果回灌
    let (recorder, messages) = runProgramThroughLoop("(tools::read_file {:path \"a.cj\"})")

    // 程序真的执行了，并且派发了可见工具
    @Assert(recorder.calls == 1)

    // 程序输出作为 run_xisp 的工具结果回到会话
    var sawResult = false
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolName == "run_xisp") {
                    sawResult = true
                    @Assert(!tr.isError)
                    @Assert(textOfContent(tr.content).contains("content-of-a.cj"))
                }
            case _ => ()
        }
    }
    @Assert(sawResult)
}

@Test
func runtime_ptcEndToEndProgramCannotReachInvisibleTool() {
    // 未在 tools 规则里的工具不进环境：程序调用它只会得到未定义函数
    let (recorder, messages) = runProgramThroughLoop("(tools::hidden_tool {})")
    @Assert(recorder.calls == 0)

    var sawError = false
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolName == "run_xisp") {
                    sawError = tr.isError
                }
            case _ => ()
        }
    }
    @Assert(sawError)
}

@Test
func runtime_ptcEndToEndLogsReachModel() {
    let (_, messages) = runProgramThroughLoop("(println \"progress-line\") \"final-value\"")
    var text = ""
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage =>
                if (tr.toolName == "run_xisp") {
                    text = textOfContent(tr.content)
                }
            case _ => ()
        }
    }
    // 日志与完成值都要回到模型：前者是过程，后者是结果
    @Assert(text.contains("progress-line"))
    @Assert(text.contains("final-value"))
}
