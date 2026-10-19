package atelier.agent

/*
 * 截断续跑（length-continuation）与收尾自验（verify）的回合语义差异。
 *
 * 两者看起来"都像在同一轮里再问一次"，但**语义不同，因此处理不对称是有意的**：
 *
 * · 截断续跑：模型正在写的**同一条回复**被输出上限切断 → 仍是同一回合的延续。
 *   不推进 `turnCount`、不重置续跑预算（否则 `maxLengthContinuations` 形同虚设），
 *   由 `resumingSameTurn` 标志表达。
 *
 * · 收尾自验：模型**已经宣布完成**，现在进入核对阶段 → 这是一次新的推理任务
 *   （新提示、新产出目标）→ 按新回合计。于是下一轮正常推进 `turnCount`，
 *   本回合的续跑预算随之重置。
 *
 * 一个直接推论（容易被误读成"预算被刷新"）：**自验之后本回合的续跑预算重置了**。
 * 这是刻意的 —— 核对阶段被截断时任务仍需要完整的续跑额度自救，否则会在收尾阶段
 * 半截；整轮上界由 `maxTurns` 兜住，不会无限延展。
 *
 * 本文件把这些语义**锁死**：它们不是靠 `resumingSameTurn` 一个标志顺带得到的副作用。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.interaction.*
import atelier.event.EventStream
import jsonvalue.*

// 按脚本顺序回放的 provider，并记录每次请求的历史长度（用于判断回合是否推进）
class SequencedProvider <: Provider {
    public var calls: Int64 = 0
    public let seenSizes = ArrayList<Int64>()
    private let responses: ArrayList<AssistantMessage>
    public init(responses: ArrayList<AssistantMessage>) { this.responses = responses }
    public func name(): String { "sequenced" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.seenSizes.add(Int64(req.messages.size))
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let idx = if (this.calls < Int64(this.responses.size)) { this.calls } else { Int64(this.responses.size) - 1 }
        this.calls++
        let msg = this.responses[Int64(idx)]
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func turnSemanticsConfig(maxContinuations!: UInt32 = UInt32(1),
    maxVerify!: UInt32 = UInt32(1)): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("noop")
    AgentConfig("turn-semantics", None, "", None, "m", None, tools, ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0),
        sideEffectToolTimeout: UInt32(0),
        maxLengthContinuations: maxContinuations, maxVerifyPasses: maxVerify)
}

func turnSemanticsRuntime(provider: Provider, cfg: AgentConfig): AgentRuntime {
    let toolReg = ToolRegistry()
    toolReg.register(NoopTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    testRuntime(cfg, provider, toolReg, MemorySessionStore(), TrustManager(),
        SkillRegistry(), AgentRegistry(), providerReg, ArrayList<Hook>(), McpManager(),
        ask: Some({ req: UserRequest =>
            let sel = ArrayList<String>()
            sel.add("allow_always")
            UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
        }))
}

func runTurnSemantics(provider: Provider, cfg: AgentConfig): ArrayList<Message> {
    let runtime = turnSemanticsRuntime(provider, cfg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    runtime.chat(msgs).result()
}

// 锁定：截断续跑**不**推进回合计数。
//
// 观测方式：`resumingSameTurn` 生效时 openTurn 不发 TurnStartEvent。因此
// 「截断 → 续跑」之间不应出现第二条 TurnStart；而自验之后应当出现。
class TurnStartCounter {
    public var starts: Int64 = 0
}

// 截断续跑：同一回合内再请求一次（不发新的 TurnStart）
@Test
func runtime_turnSemantics_truncationStaysInSameTurn() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("半截"))
    responses.add(endTurnMsg("写完"))
    let provider = SequencedProvider(responses)
    let history = runTurnSemantics(provider, turnSemanticsConfig(maxVerify: UInt32(0)))

    // 两次请求：截断 + 续跑
    @Expect(provider.calls, Int64(2))
    // 历史上：user + 半截 + 续跑提示 + 最终回复 = 4（没有额外的回合切换痕迹）
    @Expect(history.size, Int64(4))
    // 续跑提示出现在半截回复之后
    var sawContinuationPrompt = false
    for (m in history) {
        match (m) {
            case um: UserMessage =>
                if (textOfMsg(um) == lengthContinuationPrompt()) { sawContinuationPrompt = true }
            case _ => ()
        }
    }
    @Expect(sawContinuationPrompt, true)
}

// 锁定契约：自验之后，**本回合的续跑预算重置了**（自验按新回合计）。
//
// 要观测到"重置"，必须先让续跑预算**被用掉**，否则重置与否没有区别
// （第一版用例就错在这：预算本来是满的，自验设不设 resumingSameTurn 都一样）。
//
// 场景（maxLengthContinuations=1、maxVerifyPasses=1）：
//   回合1：调工具
//   回合2：被截断 → 用掉唯一一次续跑（lengthContinuations 0→1）
//   回合3（续跑）：宣布完成 → 触发自验 —— 若自验按新回合，此时预算重置为 0
//   回合4（自验回合）：又被截断 → **因为预算已重置**，仍可再续跑一次
//   回合5：续跑后收尾
//
// 若自验也设 resumingSameTurn（不重置预算），回合4 的截断会因预算已尽直接收尾，
// 总请求数少一次 —— 本用例因此能区分两种语义。
@Test
func runtime_verifyStartsNewTurnAndRefreshesContinuationBudget() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("做点事", "noop", "c1"))
    responses.add(lengthPartialMsg("回合2 被截断"))
    responses.add(endTurnMsg("我完成了"))
    responses.add(lengthPartialMsg("自验回合又被截断"))
    responses.add(endTurnMsg("核对后确认完成"))
    let provider = SequencedProvider(responses)
    let history = runTurnSemantics(provider,
        turnSemanticsConfig(maxContinuations: UInt32(1), maxVerify: UInt32(1)))

    // 5 次请求：工具回合 / 截断 / 续跑后宣布完成 / 自验回合截断 / 续跑收尾
    @Expect(provider.calls, Int64(5))
    // 两个续跑提示（回合2 与自验回合各一次）：证明自验后预算确实被重置
    var continuationPrompts: Int64 = 0
    var sawVerifyPrompt = false
    for (m in history) {
        match (m) {
            case um: UserMessage =>
                if (textOfMsg(um) == lengthContinuationPrompt()) { continuationPrompts++ }
                if (textOfMsg(um) == verifyBeforeFinishPrompt()) { sawVerifyPrompt = true }
            case _ => ()
        }
    }
    @Expect(sawVerifyPrompt, true)
    @Expect(continuationPrompts, Int64(2))
}

// 对照：续跑预算用完后，同一回合内不再续跑。
// （与上一条并排，说明"自验后还能续跑"来自预算重置，而不是预算本来就没上限）
@Test
func runtime_turnSemantics_continuationBudgetIsBounded() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(lengthPartialMsg("截断1"))
    responses.add(lengthPartialMsg("截断2"))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = SequencedProvider(responses)
    let history = runTurnSemantics(provider,
        turnSemanticsConfig(maxContinuations: UInt32(1), maxVerify: UInt32(0)))

    // 首次 + 1 次续跑 = 2；第二次仍截断但预算已尽 → 收尾
    @Expect(provider.calls, Int64(2))
}

// 自验预算本身是有界的：用完后不再追问
@Test
func runtime_turnSemantics_verifyBudgetIsBounded() {
    let responses = ArrayList<AssistantMessage>()
    responses.add(toolUseMsg("做点事", "noop", "c1"))
    responses.add(endTurnMsg("完成1"))
    responses.add(endTurnMsg("完成2"))
    responses.add(endTurnMsg("不应该被请求"))
    let provider = SequencedProvider(responses)
    runTurnSemantics(provider,
        turnSemanticsConfig(maxContinuations: UInt32(0), maxVerify: UInt32(1)))
    // 工具回合 / 宣布完成（触发自验）/ 自验回合收尾 = 3
    @Expect(provider.calls, Int64(3))
}
