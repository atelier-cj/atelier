package atelier.agent

/*
 * `run_xisp` 子调用编号的**跨回合唯一性**。
 *
 * 子调用 id 形如 `run_xisp#N:ptc:M`，加载方（ACP / AG-UI / activity 日志）拿它当
 * 唯一键来对应「哪一次脚本执行的第几个子调用」——撞号意味着两个不同的执行在审计与
 * 界面上显示成同一个。
 *
 * `RunXispTool` 实例每轮重建（它绑着本回合的执行环境），所以序号不能放在实例上：
 * 那样每回合第一次 PTC 都会从 1 重新开始，序号跨回合必然重复。
 * 序号的生命周期必须是**一次 run**，存在 RunScope 上（见 PtcRunSeq）。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.ptc.*
import atelier.interaction.*
import atelier.event.EventStream
import jsonvalue.*

// 收集脚本执行期间发出的 PtcEvent（子调用 id 从这里看）
class PtcEventSink {
    public let callIds = ArrayList<String>()
}

// 两个回合各调一次 run_xisp 的 provider
class TwoTurnPtcProvider <: Provider {
    private var calls: Int64 = 0
    private let program: String
    public init(program: String) { this.program = program }
    public func name(): String { "two-turn-ptc" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("done"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls = this.calls + 1
        let stream = EventStream<ChatDelta, AssistantMessage>()
        if (this.calls <= Int64(2)) {
            let args = HashMap<String, JsonValue>()
            args.add("code", JsonValue.String(this.program))
            args.add("description", JsonValue.String("turn" + this.calls.toString()))
            let blocks = ArrayList<ContentBlock>()
            blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_" + this.calls.toString(),
                "run_xisp", JsonValue.Map(args))))
            let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse,
                TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        } else {
            let msg = AssistantMessage(ContentList.ofText("done"), "", "", StopReason.EndTurn,
                TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        }
        stream
    }
}

func ptcTwoTurnConfig(): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("probe_*")
    AgentConfig("ptc-two-turn", None, "", None, "m", None, tools, ArrayList<String>(), 3,
        UInt32(5), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0),
        toolPresentation: ToolPresentationMode.Ptc)
}

// 核心：同一 run 的两个回合各跑一次 run_xisp，两次的 parentCallId 必须不同
@Test
func runtime_ptcRunSeqMonotonicAcrossTurns() {
    let toolReg = ToolRegistry()
    toolReg.register(RecordingTool("probe_read"))
    let providerReg = ProviderRegistry()
    // 程序只调一次子工具，便于观察 parentCallId 前缀
    let program = "(println (tools::probe_read {:path \"a.cj\"}))"
    let provider = TwoTurnPtcProvider(program)
    providerReg.register("default", provider)
    // run_xisp 是 Sequential，workDir 未信任时走交互审批：没有 ask 通道会被按拒绝处理，
    // 工具根本不会执行（现象是拿不到任何子调用 id）
    let runtime = testRuntime(ptcTwoTurnConfig(), provider, toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, McpManager(), ask: Some({ req: UserRequest =>
            let sel = ArrayList<String>()
            sel.add("allow_once")
            UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
        }))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("跑两次"), 0))

    // 从事件流里抓 ToolExecutionStartEvent 的 toolCallId（run_xisp 的子调用 id）
    let stream = runtime.chat(msgs)
    let ids = ArrayList<String>()
    var done = false
    while (!done) {
        match (stream.receive(Duration.second)) {
            case Some(ev) =>
                match (ev) {
                    case e: ToolExecutionStartEvent =>
                        if (e.toolCallId.contains(":ptc:")) { ids.add(e.toolCallId) }
                    case _ => ()
                }
            case None => if (stream.isClosed()) { done = true }
        }
    }
    let _ = stream.result()

    // 两个回合各一次子调用
    @Expect(ids.size >= 2, true)
    // 关键：两次执行的 parentCallId 不同（含 run_xisp#N 前缀）
    let first = ids[0]
    let second = ids[1]
    @Expect(first != second, true)
    // 具体形状：run_xisp#1:ptc:1 与 run_xisp#2:ptc:1（序号跨回合单调，不复位）
    @Expect(first.contains("run_xisp#1"), true)
    @Expect(second.contains("run_xisp#2"), true)
}

// 计数器本身的语义：从 1 开始、单调递增、跨多次取用不重复
@Test
func ptcRunSeq_incrementsMonotonically() {
    let seq = PtcRunSeq()
    @Expect(seq.current(), Int64(0))
    @Expect(seq.next(), Int64(1))
    @Expect(seq.next(), Int64(2))
    @Expect(seq.next(), Int64(3))
    @Expect(seq.current(), Int64(3))
}
