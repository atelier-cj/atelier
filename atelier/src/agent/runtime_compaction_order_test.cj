package atelier.agent

/*
 * 压缩的**时机**与**计价模型**。
 *
 * 两条契约：
 *
 * ① 压缩跑在 `beforeTurn` 钩子**之后**。钩子是这个回合最后的历史改写点：
 *    压完再被它整体替换回长历史，等于白压（括弧与台账记的还是一份没人用的历史）；
 *    反过来，钩子改写后的 messages 才是本次请求的真实输入，压缩必须针对它判定。
 *
 * ② 压缩阈值按**本次请求实际路由到的模型**算窗口。钩子可以改 `ChatRequest.model`，
 *    路由到小窗口模型后仍按原模型算，压缩就永远不触发 —— 直到请求被判超长，而那条
 *    恢复路径的代价是整个回合多一次失败往返。
 *
 * 复用 runtime_test.cj 的压缩助手（compactionRuntimeConfig / smallWindowCompaction /
 * DEFAULT_PROMPT_TEMPLATE）与 StubProvider。
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

// 记录主请求（chatStreaming）与摘要子调用（chat）的请求体
class CompactionOrderProvider <: Provider {
    public var mainReqs = ArrayList<ChatRequest>()
    public var summaryReqs = ArrayList<ChatRequest>()
    public func name(): String { "order-probe" }
    public func chat(req: ChatRequest): ChatResponse {
        this.summaryReqs.add(req)
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.mainReqs.add(req)
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        stream.emit(ChatDelta("", "", Some(msg.stopReason)))
        stream.setResult(msg)
        stream
    }
}

// 把请求改写成一整段超长历史（模拟宿主钩子在回合前注入大段上下文）
class InflateHistoryHook <: Hook {
    public var seenMessageCount: Int64 = -1
    private let filler: String
    public init(filler: String) { this.filler = filler }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        this.seenMessageCount = Int64(request.messages.size)
        let rewritten = ArrayList<Message>()
        // 保留原历史（第一条用户消息），再追加一条超长消息
        for (m in request.messages) { rewritten.add(m) }
        rewritten.add(UserMessage(ContentList.ofText(this.filler), 0))
        TurnDecision.Continue(ChatRequest(request.model, rewritten, request.temperature,
            request.maxTokens, request.reasoningEffort, request.tools, request.extra,
            systemPrompt: request.systemPrompt))
    }
}

// 把请求路由到另一个模型（模拟宿主按任务类型改投）
class RouteToModelHook <: Hook {
    private let target: String
    public init(target: String) { this.target = target }
    public override func beforeTurn(ctx: HookContext, request: ChatRequest): TurnDecision {
        TurnDecision.Continue(ChatRequest(this.target, request.messages, request.temperature,
            request.maxTokens, request.reasoningEffort, request.tools, request.extra,
            systemPrompt: request.systemPrompt))
    }
}

func bigFiller(size: Int64): String {
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < size) { sb.append("z"); i++ }
    sb.toString()
}

func makeB2Runtime(cfg: AgentConfig, provider: Provider,
    hooks: ArrayList<Hook>, models!: ModelContextRegistry = ModelContextRegistry()): AgentRuntime {
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, MemorySessionStore(), McpManager()).withHooks(hooks).withModels(models)
    AgentRuntime(spec, cfg)
}

// ① 顺序：钩子改写的历史才是压缩的判定对象，且压缩结果必须进入**发出去的请求**。
// 反面（旧行为）：压缩跑在钩子之前，压的是钩子改写前的那份历史，钩子再来把长历史塞回来
// → 请求体里是没压过的长历史（摘要一次都不发生，或压完又被打回原形）。
@Test
func runtime_compaction_runsAfterBeforeTurnHook() {
    let provider = CompactionOrderProvider()
    // 窗口 8192 / 完成预算 4096 / 阈值 0.8 → threshold 6553；retain 4
    // 钩子注入 ~16000 码点 ≈ 4000 tokens，叠加原有消息后越过阈值
    let inflate = InflateHistoryHook(bigFiller(16000))
    let hooks = ArrayList<Hook>()
    hooks.add(inflate)
    let runtime = makeB2Runtime(compactionRuntimeConfig(true, smallWindowCompaction(retainTokens: 4)),
        provider, hooks)

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("给我写点东西"), 0))
    // 先垫一段用量锚，让压力估算有基准
    let result = runtime.chat(msgs).result()

    // 钩子确实跑了（改写生效）
    @Expect(inflate.seenMessageCount, Int64(1))
    // 压缩发生了：至少一次摘要子调用
    @Expect(provider.summaryReqs.size >= 1, true)
    // 发出去的主请求历史里带着压缩检查点 —— 说明压缩结果进了请求（而不是被钩子覆盖/漏用）
    @Expect(provider.mainReqs.size >= 1, true)
    var requestHasCheckpoint = false
    for (m in provider.mainReqs[0].messages) {
        match (m) {
            case _: CompactionMessage => requestHasCheckpoint = true
            case _ => ()
        }
    }
    @Expect(requestHasCheckpoint, true)
}

// ② 计价模型：钩子把请求路由到小窗口模型后，压缩必须按**路由后**的模型算窗口。
// 模型 A（配置声明）窗口很大 → 按它算永远不该压；模型 B（路由目标）窗口很小 → 应当压。
@Test
func runtime_compaction_usesRoutedModelWindow() {
    let provider = CompactionOrderProvider()
    let route = RouteToModelHook("small-model")
    let hooks = ArrayList<Hook>()
    hooks.add(route)

    // 配置声明的模型窗口 100000（按它算阈值 80000，本用例的历史远不到）——
    // 路由到的 small-model 窗口只有 4096（阈值 3276），同一份历史越过阈值
    let models = ModelContextRegistry()
    models.register("big-model", ModelInfo(100000, 4096))
    models.register("small-model", ModelInfo(4096, 1024))

    let cfg = AgentConfig("t", None, "", None, "big-model", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(1024), None,
        true, smallWindowCompaction(retainTokens: 4),
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let runtime = makeB2Runtime(cfg, provider, hooks, models: models)

    // ~8000 码点 ≈ 2000 tokens：big-model 阈值 80000 远不到，small-model 阈值 3276 ...
    // 需要越过 3276，取 ~20000 码点 ≈ 5000 tokens
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigFiller(20000)), 0))
    runtime.chat(msgs).result()

    // 按路由后的模型判定了压力 → 摘要确实发生
    @Expect(provider.summaryReqs.size >= 1, true)
    // 摘要请求走的是路由后的模型（不是配置声明的那个）
    @Expect(provider.summaryReqs[0].model, "small-model")
    // 主请求也发给路由后的模型
    @Expect(provider.mainReqs[0].model, "small-model")
}

// 反向锚点：不路由时，大窗口模型下同一份历史不该触发压缩。
// （锁住"按路由后的模型算"这条不是靠"总是压"来满足的）
@Test
func runtime_compaction_bigWindowModelDoesNotCompact() {
    let provider = CompactionOrderProvider()
    let models = ModelContextRegistry()
    models.register("big-model", ModelInfo(100000, 4096))
    let cfg = AgentConfig("t", None, "", None, "big-model", None,
        ArrayList<String>(), ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(1024), None,
        true, smallWindowCompaction(retainTokens: 4),
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let runtime = makeB2Runtime(cfg, provider, ArrayList<Hook>(), models: models)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(bigFiller(20000)), 0))
    runtime.chat(msgs).result()

    // 同一份历史、同一个压缩配置：窗口大 → 不压
    @Expect(provider.summaryReqs.size, Int64(0))
    var hasCheckpoint = false
    for (m in provider.mainReqs[0].messages) {
        match (m) {
            case _: CompactionMessage => hasCheckpoint = true
            case _ => ()
        }
    }
    @Expect(hasCheckpoint, false)
}
