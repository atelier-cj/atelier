package atelier.agent

/*
 * 压缩期间的取消检查点。
 *
 * 压缩内部是一次**同步**摘要子调用（provider 往返，几十秒量级），期间没有任何检查点。
 * 取消的语义是「在当前检查点尽快收敛」，若压缩不检查，用户按下取消后仍要等完整一轮
 * 摘要往返才收尾 —— 表现为「取消没反应」。
 *
 * 检查点有两个：
 * - 进入压缩前：已取消就整段跳过（连摘要都不发，省一次计费往返）；
 * - 摘要返回后：被取消则**不把压缩结果写回历史**（历史保持原样）。
 *
 * 断言用「摘要子调用次数」：它是确定性的，不必靠计时（计时断言在慢机器上会假红）。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.context.{DEFAULT_PROMPT_TEMPLATE, CompactionConfig, ModelContextRegistry}
import atelier.provider.ModelInfo
import atelier.event.EventStream
import jsonvalue.*

// 记录主请求与摘要子调用的 provider（chat = 摘要通道）
class CancelProbeProvider <: Provider {
    public var mainCalls: Int64 = 0
    public var summaryCalls: Int64 = 0
    public var onSummary: () -> Unit = { => () }
    public func name(): String { "cancel-probe" }
    public func chat(req: ChatRequest): ChatResponse {
        this.summaryCalls++
        this.onSummary()
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.mainCalls++
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

func bigFillerForCancel(size: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < size) { sb.append("z"); i++ }
    sb.toString()
}

// 小窗口压缩配置：窗口 8192 / 完成预算 1024
// → messageBudget = 7168、pressureBudget = 7168 - 1024(headroom) = 6144
// → threshold = min(8192 * 0.8, 6144) = 6144；retain 4
// 因此历史要 > 6144 tokens（约 24600 码点），下面用 40000 码点 ≈ 10000 tokens
func cancelProbeCompaction(): Option<CompactionConfig> {
    Some(CompactionConfig(true, 0.8, 1024, 0.16, Some(Int64(4)), 1,
        DEFAULT_PROMPT_TEMPLATE, None, None))
}

// 核心：取消发生在压缩开始之前 → **一次摘要子调用都不发**。
//
// 构造方式：beforeTurn 钩子里调 cancelSession。钩子跑在压缩之前（B2 之后压缩紧跟钩子），
// 因此压缩入口的取消检查会命中。
// 取消必须在**被测的那个 runtime** 上触发：`cancelSession` 按实例维护 cancels 表，
// 在另一个 runtime 上取消等于什么都没做（这是写这条用例时踩到的）。
// 因此钩子在 beforeTurn 里从槽位取当前 runtime 再取消。
class RuntimeSlot {
    public var target: Option<AgentRuntime> = None
}

class CancelRequestHook <: Hook {
    public var fired: Bool = false
    private let slot: RuntimeSlot
    private let sid: String
    public init(slot: RuntimeSlot, sid: String) {
        this.slot = slot
        this.sid = sid
    }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.fired = true
        match (this.slot.target) {
            case Some(rt) => rt.cancelSession(this.sid)
            case None => ()
        }
        TurnDecision.Continue(request)
    }
}

func cancelProbeConfig(): AgentConfig {
    AgentConfig("t", None, "", None, "m", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(1024), None,
        true, cancelProbeCompaction(),
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

func cancelProbeModels(): ModelContextRegistry {
    let models = ModelContextRegistry()
    models.register("m", ModelInfo(8192, 1024))
    models
}

@Test
func runtime_compaction_skipsSummaryWhenAlreadyCancelled() {
    let provider = CancelProbeProvider()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let slot = RuntimeSlot()
    let hook = CancelRequestHook(slot, "sess_cancel_probe")
    let hooks = ArrayList<Hook>()
    hooks.add(hook)
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, MemorySessionStore(), McpManager()).withModels(cancelProbeModels())
        .withHooks(hooks)
    let runtime = AgentRuntime(spec, cancelProbeConfig())
    slot.target = Some(runtime)

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigFillerForCancel(40000)), 0))
    let _ = runtime.chatWithSessionId("sess_cancel_probe", msgs, SessionEnvironment()).result()

    @Expect(hook.fired, true)
    // 关键：取消后不再发起摘要往返（不取消时对照用例 >= 1）
    @Expect(provider.summaryCalls, Int64(0))
}

// 对照：不取消时同一份历史**会**触发压缩（证明上一条的 0 次不是"本来就不会压"）
@Test
func runtime_compaction_doesCompactWithoutCancel() {
    let provider = CancelProbeProvider()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let models = ModelContextRegistry()
    models.register("m", ModelInfo(8192, 1024))
    let cfg = AgentConfig("t", None, "", None, "m", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(1024), None,
        true, cancelProbeCompaction(),
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, MemorySessionStore(), McpManager()).withModels(models)
    let runtime = AgentRuntime(spec, cfg)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigFillerForCancel(40000)), 0))
    let _ = runtime.chat(msgs).result()
    @Expect(provider.summaryCalls >= 1, true)
}
