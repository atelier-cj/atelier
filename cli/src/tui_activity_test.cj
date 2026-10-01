package cli

import std.collection.*
import std.sync.*
import std.time.*
import jsonvalue.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream
import ystyle::xisp.terminal.*

/**
 * 回合进行中的实时活动：
 *
 * 不消费事件流的 TUI 只把事件当「有动静」的滴答用，界面上就只剩一个读秒——
 * 「工具卡住」与「模型在思考」长得一模一样，用户看到的是「跑了几分钟什么都没发生」。
 */

/** 阻塞到闸门放行的工具（Parallel：信任闸门直接放行，测试里不会弹审批）。 */
class SlowVisibleTool <: Tool {
    private let gate: AtomicBool
    private let toolName: String

    init(name: String, gate: AtomicBool) {
        this.toolName = name
        this.gate = gate
    }

    public func name(): String { this.toolName }
    public func description(): String { "blocks until released" }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        var waited: Int64 = 0
        while (waited < 30000 && !this.gate.load()) {
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        ToolResult("slow-done", None, false, false)
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

/** 首回合发一次工具调用，次回合收尾。 */
class ToolCallProvider <: Provider {
    private var calls: Int64 = 0
    private let toolName: String

    init(toolName: String) { this.toolName = toolName }
    public func name(): String { "tool-call-provider" }

    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("done"), "", "",
            StopReason.EndTurn, TokenUsage(0, 0), 0))
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls = this.calls + 1
        let stream = EventStream<ChatDelta, AssistantMessage>()
        if (this.calls == Int64(1)) {
            let blocks = ArrayList<ContentBlock>()
            blocks.add(ContentBlock.ToolCall(
                ToolCallBlock("call_1", this.toolName, JsonValue.Map(HashMap<String, JsonValue>()))))
            let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        } else {
            let msg = AssistantMessage(ContentList.ofText("done"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        }
        stream
    }
}

/** 配置：只暴露一个工具（可见性由配置的 tools 模式决定）。 */
func activityTestConfig(toolName: String): AgentConfig {
    let tools = ArrayList<String>()
    tools.add(toolName)
    AgentConfig("tui-activity", None, "", None, "m", None, tools, ArrayList<String>(), Int64(0),
        UInt32(3), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList<String>(), None, Int64(0), Int64(0))
}

func makeActivityTui(tool: Tool, provider: Provider, toolName: String): ChatTui {
    let reg = ToolRegistry()
    reg.register(tool)
    let trustMgr = TrustManager()
    ChatTui("default", SlashCommandRegistry(trustMgr), activityTestConfig(toolName),
        cliTestSpec(reg, MemorySessionStore(), trustMgr, SkillRegistry(), AgentRegistry(), ProviderRegistry(), McpManager(), provider),
        "sess_activity", "/tmp/atelier-tui-test")
}

/** 轮询直到消息区出现某片段（活动块由后台回合线程写入）。 */
func waitForLine(tui: ChatTui, needle: String, width: Int64): Bool {
    var guard = 0
    while (guard < 200) {
        if (hasLine(tui.messageLines(width), needle)) {
            return true
        }
        sleep(Duration.millisecond * 20)
        guard = guard + 1
    }
    false
}

@Test
func chatTui_showsLiveActivityWhileToolRuns() {
    let gate = AtomicBool(false)
    let tool = SlowVisibleTool("slow_tool", gate)
    let tui = makeActivityTui(tool, ToolCallProvider("slow_tool"), "slow_tool")
    let fake = FakeTerminal(ArrayList<KeyEvent>())

    tui.input = toRunes("go")
    tui.submit(fake)
    // 回合在后台跑：工具卡在闸门上，此时消息区必须已经能看到「谁在跑」
    @Assert(waitForLine(tui, "▶ slow_tool", 80))
    @Assert(waitForLine(tui, "进行中 1", 80))

    gate.store(true)
    waitTurn(tui)

    // 回合结束后活动块必须消失（会话区这时已有完整的 tool→/tool← 记录）
    let after = tui.messageLines(80)
    @Assert(!hasLine(after, "▶ slow_tool"))
    @Assert(hasLine(after, "slow_tool"))
}

@Test
func chatTui_activityDisappearsOnIdle() {
    // 未提交任何东西时消息区不该有空活动块
    let tui = makeActivityTui(SlowVisibleTool("slow_tool", AtomicBool(false)),
        ToolCallProvider("slow_tool"), "slow_tool")
    @Assert(!hasLine(tui.messageLines(80), "进行中"))
}
