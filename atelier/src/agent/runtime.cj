package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.interaction.*
import atelier.provider.*
import atelier.skill.*
import atelier.session.*
import atelier.trust.*
import atelier.session.CompactionRecord
import std.time.DateTime
import atelier.context.{resolveCompactSpec, CompactSpec, compactFrom, retainedCutIndex,
    lastUserIndex, isContextOverflowError, pruneToolResults, ToolResultPruneConfig,
    checkpointBody, globalCompactionLedger, Compactor, BasicCompactor, CompactRoute,
    CompactDecision, CompactionRuntime, CompactionConfig}
import atelier.context.ContextBuilder
import atelier.context.PromptSegmentContributor
import atelier.context.ModelContextRegistry
import atelier.context.renderCompactionPrompt
import atelier.context.findPreviousSummary
import atelier.context.validateSummary
import atelier.context.compactWithSummary
import atelier.context.estimateTokens
import atelier.context.{summarizeText, plainTextOf}
import atelier.ptc.*
import atelier.event.EventStream
import std.io.InputStream
import jsonvalue.*
import std.collection.*
import std.core.Duration
import std.core.sleep
import std.env.getVariable
import std.fs.{Path, canonicalize}
import std.sync.*
import std.time.MonoTime
import stdx.log.*
import opencj::ulid.nextId

/**
 * 工具预算策略：只读工具用 `toolTimeout`，有副作用工具用 `sideEffectToolTimeout`。
 *
 * 两类分开的理由见 {@link ToolBudgetPolicy}：有副作用的调用被超时后**结果未知**，
 * 代价远大于读类，所以既给更宽的额度，也在超时文本里要求「先核实再重试」。
 * 单项配 0 = 该类不限时（显式选择：同步工具会一直占着回合，只留 Ctrl+C 一条退路）。
 */
func toolBudgetPolicyOf(config: AgentConfig): ToolBudgetPolicy {
    ToolBudgetPolicy(budgetSeconds(config.toolTimeout),
        budgetSeconds(config.sideEffectToolTimeout))
}

/** 秒 → 预算；0 = 不限时。 */
func budgetSeconds(seconds: UInt32): Option<Duration> {
    if (seconds == 0) {
        return None
    }
    Some(Duration.second * Int64(seconds))
}

/**
 * 工具工作目录：会话没有指定目录时，取**进程当前目录的绝对路径**。
 *
 * 为什么不能留成 `"."`：信任闸门拿 workDir 当信任表的键，且只在文本上沿父目录回退 ——
 * 相对路径匹配不上任何按绝对路径登记的信任（`/trust <abs>`、`ATELIER_TRUST_DIR`），
 * 被拒绝时提示里也看不出是哪个目录；而工具实际是相对进程 cwd 解析路径的，两者语义应一致。
 */
func resolveWorkDir(se: SessionEnvironment): String {
    if (se.directory != "") {
        return se.directory
    }
    try {
        canonicalize(Path(".")).toString()
    } catch (e: Exception) {
        "."
    }
}

/**
 * 手动压缩的结果：新历史 + 覆盖量 + 未压成时的原因（宿主据此提示，无需自己比对）。
 *
 * [compacted] 为 false 时 [messages] 就是入参那份（历史未被改动）——调用方不必判空。
 */
public struct CompactionReport {
    public let messages: ArrayList<Message>
    public let trigger: String
    public let compacted: Bool
    public let tokensBefore: Int64
    public let tokensAfter: Int64
    public let messagesBefore: Int64
    public let messagesAfter: Int64
    public let reason: String

    public init(messages: ArrayList<Message>, trigger: String, compacted: Bool,
        tokensBefore: Int64, tokensAfter: Int64, messagesBefore: Int64, messagesAfter: Int64,
        reason: String) {
        this.messages = messages; this.trigger = trigger; this.compacted = compacted
        this.tokensBefore = tokensBefore; this.tokensAfter = tokensAfter
        this.messagesBefore = messagesBefore; this.messagesAfter = messagesAfter
        this.reason = reason
    }
}

public open class AgentRuntime {
    // 装配束：组件与派生能力都从这里来（子 agent 复用同一份，不再逐个穿参数）
    private let spec: HarnessSpec
    private let config: AgentConfig
    private let provider: Provider
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    // 生效的信任闸门（装配期解析一次：注入的优先，否则绑定 trustManager 的默认闸门）。
    // 语义与改动前等价，差别只在"判定从哪来"由装配束决定。
    private let trustGate: TrustGate
    // 生效的压缩策略（装配期解析一次：注入的优先，否则 BasicCompactor = 改动前行为）
    private let compactor: Compactor
    private let skillRegistry: SkillRegistry
    private let agentRegistry: AgentRegistry
    private let toolExecutor: ToolExecutor
    private let hooks: ArrayList<Hook>
    // 结构化提问（None = 该宿主没有交互通道，提问即取消）；用它可以返回 Pending 让 run 挂起
    private let askFn: Option<AskFn>
    // 本次 run 的恢复答复（chatWithEnv 开跑时设置）。运行时不跨 run 复用：
    // 现有宿主（CLI 每回合、ACP 每会话、server 每请求）都是新建实例，子 agent 亦各自持有一份。
    // PTC 子调用授权在深层调用栈里，拿不到开跑时的局部变量，故用瞬态字段传递。
    private var resumedAnswersForSub: HashMap<String, UserAnswer> = HashMap()
    private let modelRegistry: ModelContextRegistry
    // 未命中模型表只提醒一次（每回合一条会把日志淹掉）
    private let warnedModels = HashSet<String>()
    // 压缩配置算不出预算时也只提醒一次
    private var warnedCompactionSpec = false
    private let warnLock = Mutex()
    private let sessionEnv: SessionEnvironment
    private let mcpManager: McpManager
    // 自定义系统提示段贡献者（宿主扩展点，见 PromptSegmentContributor）
    private let promptContributors: ArrayList<PromptSegmentContributor>
    // 全局事件总线（可选挂载：宿主跨会话审计/监控；None = 不发布）
    private let eventBus: ?EventBus

    // 会话级取消：sessionId → 取消标志（chat 开始注册，收尾统一清理）
    private let cancels = HashMap<String, AtomicBool>()
    private let cancelLock = Mutex()

    /**
     * 唯一构造：装配束 + agent 配置。
     *
     * provider 由 `config.provider`（缺省 `"default"`）在装配束里解析，解析不到直接报错 ——
     * 不做「静默退化成某个默认端点」这种事。
     *
     * [sessionEnv] 是 `chat()` 的默认会话环境；需要按会话给环境的宿主走
     * `chatWithSessionId(sid, msgs, env)`。
     */
    public init(spec: HarnessSpec, config: AgentConfig,
        sessionEnv!: SessionEnvironment = SessionEnvironment()) {
        this.spec = spec
        this.config = config
        this.toolRegistry = spec.tools
        this.sessionStore = spec.store
        this.trustManager = spec.trust
        this.trustGate = spec.resolvedTrustGate()
        this.compactor = spec.resolvedCompactor()
        this.skillRegistry = spec.skills
        this.agentRegistry = spec.agents
        this.toolExecutor = ToolExecutor(this.toolRegistry,
            budget: toolBudgetPolicyOf(config))
        this.hooks = spec.hooks
        this.askFn = spec.ask
        this.modelRegistry = spec.models
        this.sessionEnv = sessionEnv
        this.mcpManager = spec.mcp
        this.promptContributors = spec.contributors
        this.eventBus = spec.eventBus
        // 请求级中间件链 wrap（先注入者最外层；委托链末端为原始 provider）
        var p = spec.resolveProvider(config)
        for (m in spec.middlewares) { p = m.wrap(p) }
        this.provider = p
    }

    /** 本次运行所用的装配束（子 agent / 工具代理要照同一份组件再建 runtime 时用） */
    public func components(): HarnessSpec {
        this.spec
    }

    // 生效的压缩策略：嵌套 CompactionConfig 优先，缺省用其默认值
    private func compactionConfig(): CompactionConfig {
        match (this.config.compaction) {
            case Some(c) => c
            case None => CompactionConfig()
        }
    }

    // 是否启用压缩：平面开关或嵌套策略任一开启
    private func compactionEnabledFor(): Bool {
        if (this.config.compactionEnabled) { return true }
        match (this.config.compaction) {
            case Some(c) => c.enabled
            case None => false
        }
    }

    // 当前压力（token）：Provider 报告的实际用量优先，本地估算兜底
    private func pressureTokens(assistantMsg: AssistantMessage, messages: ArrayList<Message>): Int64 {
        if (assistantMsg.usage.inputTokens > 0) { return assistantMsg.usage.inputTokens }
        estimateTokens(messages)
    }

    /**
     * 工具声明的 native 渲染。回合内与手动压缩共用同一份：手动压缩要复用主对话前缀
     * （system + 工具 + 被压区域回放）才谈得上命中 provider 缓存。
     */
    private func renderNativeTools(visible: ArrayList<Tool>): ArrayList<OpenAITool> {
        let result = ArrayList<OpenAITool>()
        for (t in visible) {
            result.add(OpenAITool(t.name(), t.description(), t.schema()))
        }
        result
    }

    /**
     * 手动压缩（宿主入口，如 `/compact`）：**绕过阈值**，仍守保留策略与三个不变量。
     *
     * 与自动触发共用同一条管线（修剪 → 摘要 → 切点替换）与同一个事务括弧：
     * 于是手动压缩同样进食谱的台账、同样走会话级互斥、同样发 `compaction_start/end` 事件。
     * 压不动（配置算不出预算、已在飞、压无可压）时如实返回原因，不改动历史。
     */
    public func compactNow(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): CompactionReport {
        let log = getGlobalLogger([("name", "AgentRuntime")])
        let total = this.pressureForNextRequest(messages)
        let before = Int64(messages.size)
        let unchanged = { reason: String => CompactionReport(messages, "manual", false, total, total,
            before, before, reason) }
        if (!this.compactionEnabledFor()) { return unchanged("compaction disabled") }
        if (globalCompactionLedger.isOpen(sessionId)) {
            return unchanged("another compaction is in flight for this session")
        }
        let cc = this.compactionConfig()
        let resolution = resolveCompactSpec(cc, this.modelInfoInUse().info.contextWindow,
            this.maxOutputTokensInUse())
        match (resolution.spec) {
            case None => return unchanged(resolution.reason)
            case Some(cSpec) =>
                // 上下文构建器复用回合内同一套（同一 system 提示词）；手动路径不跑 beforeTurn
                // 钩子（没有回合），因此工具声明取未过滤的可见集合
                let ctxBuilder = ContextBuilder(this.skillRegistry, sessionEnv,
                    contributors: this.promptContributors)
                let systemText = ctxBuilder.buildSystemText(this.config.systemPrompt, this.config.skills)
                let tools = this.renderNativeTools(this.resolveVisibleTools())
                let actualModel = this.pickModel(this.config.model)
                let next = this.compactBracketed("manual", sessionId, messages, total, log,
                    { msgs, totalBefore => this.summarizeAndCompact(msgs, cc, cSpec, totalBefore,
                        actualModel, systemText, tools, log) })
                let after = estimateTokens(next)
                if (next.size >= messages.size) {
                    return unchanged("nothing to compact (history fits the retain budget)")
                }
                CompactionReport(next, "manual", true, total, after, before, Int64(next.size), "")
        }
    }

    /**
     * 带事务括弧的压缩：同一会话同时只允许一次（跨 runtime 的台账），
     * 全程 `compaction_start` / `compaction_end` 成对（消费端据此显示进度与审计）。
     *
     * 台账被占时**跳过**并留痕：并发压缩各自基于同一份旧历史，后写的会覆盖先写的，
     * 摘要与保留区来自不同快照 —— 与其压出分叉的历史，不如这次不压。
     */
    private func compactBracketed(trigger: String, sessionId: String, messages: ArrayList<Message>,
        tokensBefore: Int64, log: Logger,
        body: (ArrayList<Message>, Int64) -> ArrayList<Message>): ArrayList<Message> {
        let compactionId = "cmp_" + nextId()
        if (!globalCompactionLedger.begin(sessionId, compactionId)) {
            log.warn("compaction skipped: another compaction is in flight for this session (${sessionId})", Array<Attr>())
            return messages
        }
        let startedAt = DateTime.now().toUnixTimeStamp().toMilliseconds()
        this.journalCompaction(CompactionRecord(compactionId, sessionId, trigger, startedAt, 0,
            tokensBefore, 0, Int64(messages.size), 0, "open"), log)
        this.publishCompactionStart(compactionId, trigger, tokensBefore)
        var result = messages
        try {
            result = body(messages, tokensBefore)
        } finally {
            this.publishCompactionEnd(compactionId, trigger, Int64(messages.size), result)
            // 台账闭合：outcome=replaced 才算真改写了历史，noop = 尝试过但没替换
            this.journalCompaction(CompactionRecord(compactionId, sessionId, trigger, startedAt,
                DateTime.now().toUnixTimeStamp().toMilliseconds(), tokensBefore, estimateTokens(result),
                Int64(messages.size), Int64(result.size),
                if (result.size < messages.size) { "replaced" } else { "noop" }), log)
            globalCompactionLedger.end(sessionId)
        }
        result
    }

    // 台账落库失败不该影响压缩本身（会话可用性优先）：留痕继续
    private func journalCompaction(record: CompactionRecord, log: Logger): Unit {
        try {
            this.sessionStore.appendCompaction(record)
        } catch (e: Exception) {
            log.warn("compaction journal write failed: ${e.toString()}", Array<Attr>())
        }
    }

    // 压缩事件与其它事件同源（走事件总线）；没有总线时退化为无事件，不影响压缩本身
    private func publishCompactionStart(compactionId: String, trigger: String, tokensBefore: Int64): Unit {
        match (this.eventBus) {
            case Some(bus) => bus.publish(CompactionStartEvent(compactionId, trigger, tokensBefore))
            case None => ()
        }
    }

    private func publishCompactionEnd(compactionId: String, trigger: String,
        messagesBefore: Int64, result: ArrayList<Message>): Unit {
        match (this.eventBus) {
            case Some(bus) => bus.publish(CompactionEndEvent(compactionId, trigger, messagesBefore,
                Int64(result.size), estimateTokens(result)))
            case None => ()
        }
    }

    /**
     * 真正发给模型的那一份请求：按需把超大工具结果换成"头 + 标记 + 尾"。
     *
     * **只作用于这一份**（历史保持原样，回放/导出仍拿得到完整输出）；这一步必须在
     * `currentMessages = chatReq.messages` 收编之后做，否则修剪会顺着收编流进落库历史。
     */
    private func wireRequest(req: ChatRequest): ChatRequest {
        if (!this.compactionEnabledFor()) { return req }
        let cc = this.compactionConfig()
        let cfg = match (cc.prune) {
            case Some(p) => p
            case None => ToolResultPruneConfig()
        }
        if (!cfg.enabled) { return req }
        let (pruned, prunedCount) = pruneToolResults(req.messages, cfg)
        if (prunedCount == 0) { return req }
        let log = getGlobalLogger([("name", "AgentRuntime")])
        log.info("pruned ${prunedCount} oversized tool result(s) for this request", Array<Attr>())
        ChatRequest(req.model, pruned, req.temperature, req.maxTokens, req.reasoningEffort,
            req.tools, req.extra, systemPrompt: req.systemPrompt)
    }

    /**
     * 下一次请求的压力估算：以**最近一次带用量的 assistant 消息**为锚（它反映那次请求的
     * 提示词规模），加上其后新增消息的估算 —— 与 dsh「provider 用量锚 + 表面增量」同源。
     * 没有锚（首轮 / provider 不报用量）时退回整体估算。
     */
    private func pressureForNextRequest(messages: ArrayList<Message>): Int64 {
        var i = Int64(messages.size) - 1
        while (i >= 0) {
            match (messages[i]) {
                case am: AssistantMessage =>
                    if (am.usage.inputTokens > 0) {
                        let tail = ArrayList<Message>()
                        var j = i + 1
                        while (j < Int64(messages.size)) {
                            tail.add(messages[Int64(j)])
                            j++
                        }
                        return am.usage.inputTokens + estimateTokens(tail)
                    }
                case _ => ()
            }
            i--
        }
        estimateTokens(messages)
    }

    /**
     * 摘要 + 切点替换：摘要失败时退化为占位摘要（保住会话可继续，而不是把 run 打断）。
     *
     * 摘要子调用**复用主对话的前缀**：system 提示词 + 工具声明 + 被压区域消息原样回放，
     * 指令作为最后一条 user 消息追加。provider 的前缀缓存按"缓存前缀单元完整匹配"计费
     * （DeepSeek 的硬盘缓存即如此），这样那段长输入走缓存价；若把对话内联进一个 user 消息，
     * 前缀从第一个 token 就不同，整段按未命中计价。
     */
    private func summarizeAndCompact(messages: ArrayList<Message>, cc: CompactionConfig,
        spec: CompactSpec, total: Int64, actualModel: String, systemText: String,
        tools: ArrayList<OpenAITool>, log: Logger): ArrayList<Message> {
        let cut = retainedCutIndex(messages, spec.retainTokens)
        let summary = try {
            let region = ArrayList<Message>()
            var i: Int64 = 0
            while (i < cut) {
                region.add(messages[i])
                i++
            }
            let conversation = summarizeText(region, 0)
            let prev = findPreviousSummary(region)
            let prompt = renderCompactionPrompt(cc, conversation, prev, spec.summaryMaxTokens)
            let summaryModel = match (cc.summaryModel) {
                case Some(m) => m
                case None => actualModel
            }
            // 被压区域原样回放 + 末尾追加指令：前缀与主请求一致，才能吃到缓存
            let reqMessages = ArrayList<Message>(region)
            reqMessages.add(UserMessage(ContentList.ofText(prompt), 0))
            let req = ChatRequest(summaryModel, reqMessages, Float64(0.2), spec.summaryMaxTokens,
                None, tools, systemPrompt: systemText)
            let resp = this.provider.chat(req)
            let raw = plainTextOf(resp.message)
            match (cc.outputSchema) {
                case Some(JsonValue.Map(schema)) =>
                    if (!validateSummary(cc, schema, raw)) {
                        throw Exception("summary failed schema validation")
                    }
                case _ => ()
            }
            raw
        } catch (e: Exception) {
            log.warn("compaction summary failed: ${e.message}, fallback to placeholder", Array<Attr>())
            "... ${total} previous tokens summarized ..."
        }
        let next = compactWithSummary(messages, spec.retainTokens, summary, total)
        // 摘要没让历史变短 = 白花一次调用，而且下回合还会再触发：留痕
        if (next.size >= messages.size) {
            log.warn("compaction did not shrink history (${messages.size} messages); check retain budget vs threshold", Array<Attr>())
        }
        next
    }

    /**
     * 溢出恢复：provider 明确报"超上下文窗口"时，压掉**最大的一段头部**（只保最后一条用户
     * 消息起的内容，且不拆散工具调用对），让调用方带着新历史重试同一请求。
     *
     * 返回 None = 这次救不了（不是溢出 / 重试次数用完 / 压无可压 / 摘要失败），
     * 调用方按普通失败收敛 —— 不留半截状态。
     */
    private func recoverFromOverflow(errText: String, messages: ArrayList<Message>,
        retries: Int64, cc: CompactionConfig, chatReq: ChatRequest, actualModel: String,
        systemText: String, tools: ArrayList<OpenAITool>, sessionId: String,
        log: Logger): Option<ArrayList<Message>> {
        if (!isContextOverflowError(errText)) { return None }
        if (retries >= cc.maxOverflowRetries) {
            log.warn("context overflow: recovery exhausted after ${retries} attempt(s)", Array<Attr>())
            return None
        }
        let keepFrom = lastUserIndex(messages)
        if (keepFrom <= 0) {
            // 只有一条用户消息（或没有）——没有可压的头部，摘要也救不了
            log.warn("context overflow: nothing to compact (single-turn history)", Array<Attr>())
            return None
        }
        let total = estimateTokens(messages)
        // 溢出恢复同样是一次改写历史的事务：括弧照开照合（放弃时 after == before）
        let outcome = this.compactBracketed("overflow", sessionId, messages, total, log,
            { msgs, totalBefore => this.summarizeHeadForOverflow(msgs, keepFrom, cc, actualModel,
                systemText, tools, totalBefore, log) })
        if (outcome.size >= messages.size) { return None }
        return Some(outcome)
    }

    // 溢出恢复的摘要 + 替换（括弧内的主体）：只保最后一条用户消息起的内容
    private func summarizeHeadForOverflow(messages: ArrayList<Message>, keepFrom: Int64,
        cc: CompactionConfig, actualModel: String, systemText: String,
        tools: ArrayList<OpenAITool>, total: Int64, log: Logger): ArrayList<Message> {
        let summary = try {
            let region = ArrayList<Message>()
            var k: Int64 = 0
            while (k < keepFrom) {
                region.add(messages[k])
                k++
            }
            let conversation = summarizeText(region, 0)
            let prev = findPreviousSummary(region)
            let prompt = renderCompactionPrompt(cc, conversation, prev, cc.headroomTokens)
            let summaryModel = match (cc.summaryModel) {
                case Some(m) => m
                case None => actualModel
            }
            // 同样复用主对话前缀（system + tools + 被压区域），让恢复用的摘要也走缓存价
            let reqMessages = ArrayList<Message>(region)
            reqMessages.add(UserMessage(ContentList.ofText(prompt), 0))
            let req = ChatRequest(summaryModel, reqMessages, Float64(0.2), cc.headroomTokens,
                None, tools, systemPrompt: systemText)
            plainTextOf(this.provider.chat(req).message)
        } catch (e: Exception) {
            log.warn("context overflow: summary failed (${e.message}); giving up recovery", Array<Attr>())
            return messages
        }
        let next = compactFrom(messages, keepFrom, summary, total)
        if (next.size >= messages.size) {
            log.warn("context overflow: compaction did not shrink history", Array<Attr>())
            return messages
        }
        log.info("context overflow recovered: ${messages.size} -> ${next.size} messages", Array<Attr>())
        next
    }

    // 配置算不出压力预算：每个原因只提醒一次（否则每回合一条，把日志淹掉）
    private func warnCompactionSpecOnce(reason: String, log: Logger): Unit {
        var first = false
        synchronized(this.warnLock) {
            if (!this.warnedCompactionSpec) {
                this.warnedCompactionSpec = true
                first = true
            }
        }
        if (first) {
            log.warn("compaction skipped: ${reason}", Array<Attr>())
        }
    }

    /** 本 agent 实际使用的上下文窗口（token）：声明 > provider 自报 > 兜底 */
    public func contextWindowInUse(): Int64 {
        this.modelInfoInUse().info.contextWindow
    }

    /**
     * 本 agent 实际使用的完成预算（token）：agent 显式给了就用它（0 = 交给模型事实），
     * 否则用模型事实（声明 > provider 自报 > 兜底）。
     */
    public func maxOutputTokensInUse(): Int64 {
        if (this.config.maxOutputTokens > 0) {
            return Int64(this.config.maxOutputTokens)
        }
        this.modelInfoInUse().info.maxTokens
    }

    // 模型事实（窗口 + 完成预算）：声明 > provider 自报 > 兜底，全链路没人知道时提醒一次
    // （静默按兜底值走 = "模型聊着聊着忘了前面"/"输出被莫名截断"，而下游看不到线索）
    private func modelInfoInUse(): ResolvedModelInfo {
        let model = this.pickModel(this.config.model)
        let providerName = providerNameOf(this.config)
        let resolved = this.spec.resolveModelInfo(providerName, model)
        if (!resolved.declared) {
            let key = providerName + "/" + model
            var first = false
            synchronized(this.warnLock) {
                if (!this.warnedModels.contains(key)) {
                    this.warnedModels.add(key)
                    first = true
                }
            }
            if (first) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("no model facts for provider '${providerName}' model '${model}': assuming ${resolved.info.contextWindow} context / ${resolved.info.maxTokens} max tokens; declare them with [[provider.model]]", Array<Attr>())
            }
        }
        resolved
    }

    // 取消进行中的会话回合（幂等：未知/已结束会话为 no-op）。
    // 取消后 runtime 在当前检查点尽快收敛并按正常路径收尾（AgentEndEvent + result），
    // 不再发起新的 provider 请求与工具批次；正在执行的工具不强制中断。
    public open func cancelSession(sessionId: String): Unit {
        synchronized(this.cancelLock) {
            match (this.cancels.get(sessionId)) {
                case Some(flag) => flag.store(true)
                case None => ()
            }
        }
    }

    public open func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        this.chatWithSessionId("sess_" + nextId(), messages, this.sessionEnv)
    }

    // 统一事件出口：可选事件总线（进程级发布）先行，随后进会话流（消费序不变）
    private func emit(stream: EventStream<AgentEvent, ArrayList<Message>>, ev: AgentEvent): Unit {
        match (this.eventBus) {
            case Some(bus) => bus.publish(ev)
            case None => ()
        }
        stream.emit(ev)
    }

    // 库用户兼容签名：内部生成 ulid 会话 id
    public open func chatWithEnv(messages: ArrayList<Message>, sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        this.chatWithSessionId("sess_" + nextId(), messages, sessionEnv)
    }

    // 显式会话 id（如 REPL 的持久化 sessionId），runtime 不落库，由调用方统一持久化
    public open func chatWithSessionId(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        this.chatWithEnv(sessionId, messages, sessionEnv)
    }

    // 由会话级上下文派生出「本次调用」的上下文：多一个 toolCallId，其余（含提问通道）原样带过去
    private func callContext(ctx: ToolContext, toolCallId: String): ToolContext {
        ToolContext(ctx.workDir, ctx.env, ctx.sessionId, toolCallId: toolCallId, ask: ctx.askFn)
    }

    // 问宿主要答复：恢复带回的答复优先（重放同一回合时命中就不再问），否则交给宿主的提问通道。
    // 无通道时按"取消"处理 —— 工具据此如实回报"没问到"，而不是拿一个空答复继续跑。
    private func askHost(req: UserRequest, resumed: HashMap<String, UserAnswer>): UserAnswer {
        match (resumed.get(req.id)) {
            case Some(a) => return a
            case None => ()
        }
        match (this.askFn) {
            case Some(f) => f(req)
            case None => UserAnswer(req.id, UserAnswerStatus.Cancelled)
        }
    }

    private func chatWithEnv(sessionId: String, messages: ArrayList<Message>, sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let se = sessionEnv
        let workDir = resolveWorkDir(se)
        let ctx = ToolContext(workDir, se.context, sessionId, ask: this.askFn)
        // 恢复：宿主随消息带回的答复（重放同一回合时要先查它，命中就不再问宿主）
        let resumedAnswers = collectResumedAnswers(messages)
        this.resumedAnswersForSub = resumedAnswers
        // 每次工具调用单独一份上下文（带该次调用的 id）：工具要把自己与协议/UI 上的同一次调用对上时用
        let ctxBuilder = ContextBuilder(this.skillRegistry, se, contributors: this.promptContributors)

        spawn {
            let log = getGlobalLogger([("name", "AgentRuntime")])
            // 会话级取消标志：chat 期间注册，收尾统一清理
            let cancelFlag = AtomicBool(false)
            synchronized(this.cancelLock) { this.cancels[sessionId] = cancelFlag }
            try {
                this.emit(stream, AgentStartEvent(sessionId))
                log.info("agent start: ${this.config.name}", Array<Attr>())
                let hookState = HookState()
                callHooks("beforeRun", 0, hookState)

                // 系统提示词独立通道（不再注入为消息）；初始消息 = 历史。
                // PTC 的 SDK 段随「本轮可见工具」变化，因此在循环内拼接（见下）。
                let baseSystemText = ctxBuilder.buildSystemText(
                    this.config.systemPrompt, this.config.skills)
                var currentMessages = ArrayList<Message>()
                for (m in messages) { currentMessages.add(m) }
                var turnCount: Int64 = 0
                var toolCallCount: Int64 = 0
                // 本回合内因输出被 token 上限截断而自动续跑的次数（每次续跑仍算同一个循环轮次）
                var lengthContinuations: Int64 = 0
                // 收尾前自验已用次数（每次自验按一个新回合计，受 maxTurns 约束）
                var verifyPasses: Int64 = 0
                // 本次迭代是「上一回合因截断而续跑」：不计新回合、不重置续跑预算、
                // 不推进 MCP 冷却回合（continue 会重新走一遍循环体顶部，副作用必须在这里挡住）
                var resumingSameTurn = false
                var lastToolTime: MonoTime = MonoTime.now()
                var finished = false

                while (!finished && !cancelFlag.load() && turnCount < Int64(this.config.maxTurns)) {
                    if (!resumingSameTurn) {
                        this.emit(stream, TurnStartEvent())
                        turnCount++
                        // 续跑预算按回合重置：每回合最多因截断续跑 maxLengthContinuations 次
                        lengthContinuations = 0
                        this.mcpManager.advanceTurn()
                        log.info("turn ${turnCount} start", Array<Attr>())
                    }
                    resumingSameTurn = false
                    // 顺序：历史归档标记在前（处理 store 加载的历史 ArchiveMessage），
                    // 本轮调用对在后（产生的 ArchiveMessage 位于 index==startIndex，不能被标记跳过）
                    currentMessages = ctxBuilder.applyArchiveMarks(currentMessages)
                    currentMessages = ctxBuilder.applyArchives(currentMessages)

                    this.emit(stream, MessageStartEvent(currentMessages[0]))
                    let actualModel = this.pickModel(this.config.model)
                    // 先解析可见工具，再据此生成 SDK 段：两处必须来自同一次解析，
                    // 否则模型看到的绑定会与程序实际能调用的能力分叉
                    let visible = this.resolveVisibleTools()
                    let tools = this.resolveTools(visible, ctx, stream, cancelFlag,
                        hookState, turnCount)
                    let systemText = if (this.config.toolPresentation == ToolPresentationMode.Native) {
                        baseSystemText
                    } else {
                        baseSystemText + "\n\n" + PtcSdkRenderer.render(visible)
                    }
                    // —— 请求派发前的上下文压力处理（dsh 的 pre-step 位置）——
                    // 先修剪（只影响本次请求，不落库），修剪后仍在阈值之上才摘要 + 替换历史。
                    // 放在请求前而不是回合结束后：回合结束后再压，本轮该发的请求早就发出去了。
                    // 注意：这里算出的修剪版**只用于测量与决策**。真正发出去的请求在
                    // wireRequest() 里再修剪一次 —— 因为下面 `currentMessages = chatReq.messages`
                    // 会把请求的消息表收编为历史，若在这里就把修剪版写回去，修剪会落进落库历史。
                    var measureMessages = currentMessages
                    if (this.compactionEnabledFor()) {
                        let cc = this.compactionConfig()
                        let route = CompactRoute(actualModel,
                            this.modelInfoInUse().info.contextWindow, this.maxOutputTokensInUse())
                        // 修剪版只用于测量：真正发出去的请求由 wireRequest 再修剪一次
                        // （下面 `currentMessages = chatReq.messages` 会把请求表收编为历史，
                        //  在这里写回修剪版会让修剪流进落库历史）
                        match (cc.prune) {
                            case Some(pruneCfg) =>
                                measureMessages = this.compactor.pruneForRequest(currentMessages, pruneCfg)
                            case None => ()
                        }
                        // 决策交给 compactor：它回答"压不压、切哪、预算多少"，
                        // 而时序（括弧/台账/互斥）留在运行时保证跨实现一致
                        let decision = match (this.compactor) {
                            case bc: BasicCompactor => bc.shouldCompactWith(measureMessages, route, cc)
                            case other => other.shouldCompact(measureMessages, route)
                        }
                        match (decision) {
                            case CompactDecision.Skip(reason) =>
                                // 只在"算不出预算"这类配置问题上留痕一次；
                                // 未达阈值是常态，不刷日志
                                if (!reason.startsWith("under threshold")) {
                                    this.warnCompactionSpecOnce(reason, log)
                                }
                            case CompactDecision.Proceed(plan) =>
                                // 报告给事件与台账的 token 数沿用运行时口径（provider 用量锚），
                                // 与 compactor 内部的判定口径可以不同：前者是"这次压之前有多大"
                                let total = this.pressureForNextRequest(measureMessages)
                                let compactor = this.compactor
                                let compactionRuntime = CompactionRuntime(this.provider, actualModel,
                                    systemText, tools, cc)
                                currentMessages = this.compactBracketed(plan.trigger, sessionId,
                                    currentMessages, total, log, { msgs, _ =>
                                    compactor.compact(msgs, plan, compactionRuntime)
                                })
                        }
                    }
                    var chatReq = ctxBuilder.buildChatRequest(actualModel, systemText, currentMessages,
                        Float64(this.config.temperature), this.maxOutputTokensInUse(),
                        this.config.thinkingLevel, tools)
                    match (runBeforeTurnHooks(hookState, turnCount, chatReq)) {
                        case Some(r) =>
                            chatReq = r
                            if (chatReq.model != actualModel) {
                                log.info("model routed: ${actualModel} -> ${chatReq.model}", Array<Attr>())
                            }
                            // 若 hook 改写了请求的 messages，同步回运行时上下文，避免分叉
                            currentMessages = chatReq.messages
                        case None =>
                            log.info("beforeTurn hook short-circuited run", Array<Attr>())
                            let shortCircuitMsg = AssistantMessage(ContentList.ofText("[Run short-circuited by hook]"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                            // 必须同时进消息列表：消费端只从 result() 读消息，仅 emit 事件
                            // 等于什么都没发生（交互前端表现为「跑完界面上没有任何输出」）
                            currentMessages.add(shortCircuitMsg)
                            this.emit(stream, TurnEndEvent(shortCircuitMsg, ArrayList<ToolResultMessage>()))
                            finished = true
                            break
                    }

                    // 发请求前的唯一收口：assistant 带 tool_calls 的消息必须跟齐每个 call 的结果，
                    // 否则 provider 判 400（不可重试）→ 整轮作废。历史改写路径不止一条
                    // （压缩、钩子、批次异常兜底、截断回复里已带的 tool_call），故在此统一兜底。
                    let patched = ensureToolCallResults(chatReq.messages)
                    if (patched > 0) {
                        log.warn("history had ${patched} tool call(s) without results; inserted placeholders to keep the request valid", Array<Attr>())
                    }

                    // provider 调用 + **溢出恢复**：明确报"超上下文窗口"时，压掉最大的一段头部
                    // 再重试同一请求（次数受 CompactionConfig.maxOverflowRetries 限制）。这条
                    // 恢复路径不受压力阈值约束 —— 已经被拒了，阈值就没有意义了。
                    let ccForOverflow = this.compactionConfig()
                    var overflowRetries: Int64 = 0
                    var assistantMsg = AssistantMessage(ContentList.ofText(""), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                    var requestFailed = false
                    while (true) {
                        var contentBuilder = StringBuilder()
                        var attemptOk = false
                        try {
                            // provider 通常在**发起请求时**就抛（HTTP 4xx 拿不到流），
                            // 所以这一步也必须在 try 内，否则溢出恢复接不到
                            let chatStream = this.provider.chatStreaming(this.wireRequest(chatReq))
                            var aborted = false
                            while (!aborted) {
                                if (cancelFlag.load()) {
                                    // 取消：用已累积内容构造部分消息，跳过 result() 等待
                                    assistantMsg = AssistantMessage(ContentList.ofText(contentBuilder.toString()), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                                    aborted = true
                                    break
                                }
                                match (chatStream.receive(5 * Duration.second)) {
                                    case Some(delta) =>
                                        if (delta.delta != "") {
                                            contentBuilder.append(delta.delta)
                                            this.emit(stream, MessageUpdateEvent(
                                                AssistantMessage(ContentList.ofText(contentBuilder.toString()), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0),
                                                delta.delta))
                                        }
                                        match (delta.finishReason) {
                                            case Some(_) => break
                                            case None => ()
                                        }
                                    case None => break
                                }
                            }
                            if (!aborted) { assistantMsg = chatStream.result() }
                            attemptOk = true
                        } catch (e: Exception) {
                            // 用 toString() 而不是 message：Socket/FS 这类异常的 message 常为空，
                            // 只打 message 在日志里就是一行「provider error: 」，等于没有信息
                            let errText = e.toString()
                            match (this.recoverFromOverflow(errText, currentMessages, overflowRetries,
                                ccForOverflow, chatReq, actualModel, systemText, tools, sessionId, log)) {
                                case Some(nextMsgs) =>
                                    overflowRetries++
                                    currentMessages = nextMsgs
                                    // 用同一套参数重建请求（保留可能已被 hook 改过的 model）
                                    chatReq = ctxBuilder.buildChatRequest(chatReq.model, systemText, currentMessages,
                                        Float64(this.config.temperature), this.maxOutputTokensInUse(),
                                        this.config.thinkingLevel, tools)
                                    continue
                                case None =>
                                    log.error("provider error: ${errText}", Array<Attr>())
                                    let failureMsg = AssistantMessage(ContentList.ofText("[provider error] ${errText}"), "", "", StopReason.Error, TokenUsage(0, 0), 0)
                                    // 同短路分支：错误必须进消息列表，否则消费端与界面都看不到它
                                    currentMessages.add(failureMsg)
                                    this.emit(stream, TurnEndEvent(failureMsg, ArrayList<ToolResultMessage>()))
                                    requestFailed = true
                            }
                        }
                        if (requestFailed || attemptOk) { break }
                    }
                    if (requestFailed) {
                        finished = true
                        break
                    }
                    log.info("provider response received", Array<Attr>())
                    this.emit(stream, MessageEndEvent(assistantMsg))
                    currentMessages.add(assistantMsg)

                    match (assistantMsg.stopReason) {
                        case StopReason.ToolUse =>
                            if (cancelFlag.load()) {
                                // 取消：不再发起工具批次，直接收尾
                                log.info("run cancelled at tool boundary", Array<Attr>())
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
                            }
                            let toolCalls = assistantMsg.toolCalls()
                            if (toolCalls.size == 0) {
                                // provider 报了工具回合却没给任何调用：空批次会让循环原地空转
                                // （每轮请求都一样），按回合结束收尾
                                log.warn("stop reason is ToolUse but the message carries no tool call; finish the turn", Array<Attr>())
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
                            }
                            log.info("tool calls: ${toolCalls.size}", Array<Attr>())
                            let maxCalls = Int64(this.config.maxToolCalls)
                            if (toolCallCount >= maxCalls) {
                                log.warn("max tool calls (${maxCalls}) reached", Array<Attr>())
                                currentMessages.add(ToolResultMessage("", "", ContentList.ofText("Max tool calls (${maxCalls}) reached, skipping"), true, 0))
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
                            }
                            if (toolCallCount + toolCalls.size > maxCalls) {
                                let allowed = maxCalls - toolCallCount
                                log.warn("tool calls ${toolCalls.size} exceeds remaining ${allowed}", Array<Attr>())
                                // Only allow up to the limit
                                let trimmed = ArrayList<ToolCallBlock>()
                                for (j in 0..allowed) { trimmed.add(toolCalls[Int64(j)]) }
                                // Replace full list with trimmed
                                let original = ArrayList<ToolCallBlock>(toolCalls)
                                toolCalls.clear()
                                for (j in 0..allowed) { toolCalls.add(trimmed[Int64(j)]) }
                                // Store skipped tool names for rejection
                                var skipIdx = allowed
                                while (skipIdx < original.size) {
                                    currentMessages.add(ToolResultMessage(original[Int64(skipIdx)].id, original[Int64(skipIdx)].name, ContentList.ofText("Skipped: max tool calls limit"), true, 0))
                                    skipIdx++
                                }
                            }
                            // 本轮闸门里"宿主要求挂起"的请求（审批 = confirmation；
                            // 选择/表单由工具内的提问走 ToolResult.external，不在此列）
                            let pendingAsks = ArrayList<ExternalRequest>()
                            let batch = ArrayList<(String, ToolContext, JsonValue)>()
                            let skipResults = HashMap<Int64, String>()
                            // 实际进入执行批的工具（与 batch 同序），用于发工具执行事件
                            let runCallIds = ArrayList<String>()
                            let runNames = ArrayList<String>()
                            var idx: Int64 = 0
                            while (idx < toolCalls.size) {
                                let tc = toolCalls[idx]
                                match (this.toolRegistry.get(tc.name)) {
                                    case Some(t) =>
                                        match (this.trustGate(t, ctx.workDir, sessionId)) {
                                            case TrustDecision.Allowed =>
                                                let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                match (args) {
                                                    case Some(a) =>
                                                        batch.add((tc.name, this.callContext(ctx, tc.id), a))
                                                        runCallIds.add(tc.id)
                                                        runNames.add(tc.name)
                                                    case None =>
                                                        skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                        log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                }
                                            case TrustDecision.NeedsApproval =>
                                                // 审批走结构化提问：菜单由 approvalRequest 统一构造，
                                                // 结论只认选项 id（不再比对 "y"/"yes"/"a" 这类魔法字符串）
                                                // 参数原样带上：审批的全部意义是让人看清「要执行什么」，
                                                // 只给工具名等于让人盲签（钩子改写前的原始参数）
                                                let gateReq = approvalRequest(
                                                    "ask:${sessionId}:${turnCount}:${tc.id}:approval",
                                                    tc.name, tc.args,
                                                    "Tool '" + tc.name + "' needs your approval.",
                                                    toolCallId: tc.id)
                                                let gateAns = this.askHost(gateReq, resumedAnswers)
                                                // 宿主要求挂起：记下来，整批都不执行（结果在批量执行后才写历史，
                                                // 所以此刻挂起等于"什么都没发生"，重放不会重复副作用）
                                                match (gateAns.status) {
                                                    case UserAnswerStatus.Pending =>
                                                        // 带上原始提问：协议适配层据此生成答复契约
                                                        // （AG-UI 的 responseSchema），只有 message 的话
                                                        // 前端只能猜表单该收什么字段
                                                        pendingAsks.add(ExternalRequest(gateReq.id,
                                                            "confirmation", gateReq.message,
                                                            toolCallId: tc.id, request: Some(gateReq)))
                                                    case _ => ()
                                                }
                                                // 答复一律过校验：不合格按拒绝处理（不静默接受）
                                                match (validateAnswer(gateReq, gateAns)) {
                                                    case Some(err) =>
                                                        log.warn("invalid approval answer (${err}); treating as deny", Array<Attr>())
                                                    case None => ()
                                                }
                                                let gateInvalid = match (validateAnswer(gateReq, gateAns)) {
                                                    case Some(_) => true
                                                    case None => false
                                                }
                                                if (!gateInvalid && gateAns.isAllowAlways()) {
                                                    this.trustManager.setTrust(ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} always approved for ${ctx.workDir}", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) =>
                                                            batch.add((tc.name, this.callContext(ctx, tc.id), a))
                                                            runCallIds.add(tc.id)
                                                            runNames.add(tc.name)
                                                        case None =>
                                                            skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                            log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                    }
                                                } else if (!gateInvalid && gateAns.isAllowOnce()) {
                                                    this.trustManager.setSessionTrust(sessionId, ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} approved for session", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) =>
                                                            batch.add((tc.name, this.callContext(ctx, tc.id), a))
                                                            runCallIds.add(tc.id)
                                                            runNames.add(tc.name)
                                                        case None =>
                                                            skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                            log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                    }
                                                } else {
                                                    skipResults[idx] = "Tool not allowed: user denied approval"
                                                    log.warn("tool ${tc.name} denied by user", Array<Attr>())
                                                }
                                            case TrustDecision.Denied =>
                                                skipResults[idx] = "Tool not allowed: workDir is untrusted"
                                                log.warn("tool ${tc.name} blocked: workDir untrusted", Array<Attr>())
                                        }
                                    case None =>
                                        skipResults[idx] = "Tool not found: " + tc.name
                                }
                                idx++
                            }
                            let minIntervalMs = Int64(this.config.minToolInterval)
                            if (minIntervalMs > 0) {
                                let elapsed = (MonoTime.now() - lastToolTime).toMilliseconds()
                                if (elapsed < minIntervalMs) {
                                    sleep(Duration.millisecond * (minIntervalMs - elapsed))
                                }
                            }
                            if (pendingAsks.size > 0) {
                                // 整批一起挂起：一次把本批所有待确认项交给宿主，
                                // 恢复后同一批一次做完（而不是逐个挂起、逐个恢复）
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                this.emit(stream, SuspendEvent(pendingAsks))
                                finished = true
                                continue
                            }
                            // 工具执行开始事件（供流式消费方展示工具进度；被跳过/拦截的工具不发）
                            for (k in 0..runCallIds.size) {
                                this.emit(stream, ToolExecutionStartEvent(runCallIds[Int64(k)], runNames[Int64(k)]))
                            }
                            let results = try {
                                this.toolExecutor.executeBatch(batch)
                            } catch (e: Exception) {
                                // 同 provider 错误：异常 message 常为空（FS/Socket 类），只打 message 等于没打
                                log.error("tool execute error: ${e.toString()}", Array<Attr>())
                                // 整批失败也必须**每个 call 各回一条**结果：只回一条（且 id 为空）
                                // 会让历史里 assistant(tool_calls=N) 对不上结果，下一次请求被 provider 判 400
                                for (i in 0..toolCalls.size) {
                                    let tc = toolCalls[Int64(i)]
                                    let text = match (skipResults.get(Int64(i))) {
                                        case Some(msg) => msg
                                        case None => "[Tool error: ${e.message}]"
                                    }
                                    currentMessages.add(ToolResultMessage(tc.id, tc.name,
                                        ContentList.ofText(text), true, 0))
                                }
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                continue
                            }
                            var resIdx: Int64 = 0
                            // 需要外部给结果的调用：本次 run 挂起（不写结果消息，历史停在
                            // assistant(tool_calls)），由调用方在下一次 run 带回结果
                            let pendingExternal = ArrayList<ExternalRequest>()
                            for (i in 0..toolCalls.size) {
                                let tc = toolCalls[Int64(i)]
                                match (skipResults.get(Int64(i))) {
                                    case Some(msg) =>
                                        let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(msg), false, 0)
                                        currentMessages.add(tr)
                                    case None =>
                                        if (resIdx < results.size) {
                                            let r = results[Int64(resIdx)]
                                            match (r.external) {
                                                case Some(req) =>
                                                    // 挂起：不产生结果消息（写了就等于伪造结果）
                                                    log.info("tool ${tc.name} awaits external result: ${req.id}", Array<Attr>())
                                                    pendingExternal.add(req)
                                                    resIdx++
                                                    continue
                                                case None => ()
                                            }
                                            log.info("tool ${tc.name} done: err=${r.isError}", Array<Attr>())
                                            this.mcpManager.markUsedTool(tc.name)
                                            // 工具执行结束事件（与开始事件一一对应）
                                            this.emit(stream, ToolExecutionEndEvent(tc.id, r.text, r.isError))
                                            let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(r.text), r.isError, 0)
                                            currentMessages.add(tr)
                                            callAfterToolHooks(hookState, turnCount, tc, tr)
                                            resIdx++
                                        } else {
                                            // 执行器少给了结果：静默跳过会让这条 call 永远没有配对结果，
                                            // 下一次请求直接被判 400 —— 宁可回一条显式失败
                                            log.error("tool executor returned ${results.size} result(s) for ${batch.size} call(s); '${tc.name}' has no result", Array<Attr>())
                                            currentMessages.add(ToolResultMessage(tc.id, tc.name,
                                                ContentList.ofText("[Tool error: no result returned by executor]"), true, 0))
                                        }
                                }
                            }
                            toolCallCount += toolCalls.size
                            lastToolTime = MonoTime.now()
                            this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                            if (pendingExternal.size > 0) {
                                // 中止本次 run：历史已落在 assistant(tool_calls)，
                                // 下一次 run 带结果即可继续（见 SuspendEvent 注释）
                                this.emit(stream, SuspendEvent(pendingExternal))
                                finished = true
                                continue
                            }

                        case _ =>
                            if (cancelFlag.load()) {
                                // 取消：跳过 afterTurn 改写与压缩等后续处理，直接收尾
                                log.info("run cancelled at turn end", Array<Attr>())
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
                            }
                            // 带 tool_call 却又不是工具回合（输出被截断、终止原因缺失/未识别、
                            // provider 异常）：这些调用没有执行、也不该执行（回复是半截的），
                            // 但历史里必须给它们配对结果 —— 否则后面追加 user 消息就等于
                            // 发出 assistant(tool_calls) 后不跟结果，provider 直接判 400。
                            let prematureCalls = assistantMsg.toolCalls()
                            if (prematureCalls.size > 0) {
                                log.warn("non-tool stop reason carries ${prematureCalls.size} tool call(s); recording them as not executed", Array<Attr>())
                                for (tc in prematureCalls) {
                                    currentMessages.add(ToolResultMessage(tc.id, tc.name,
                                        ContentList.ofText(unansweredToolCallNote(tc.name)), true, 0))
                                }
                            }
                            // 输出撞到 provider 的 token 上限（StopReason.Length）只说明「这一条没写完」，
                            // 不代表任务结束：同一回合内追加一条续跑消息再请求一次，而不是把半截结果交给宿主。
                            // 预算按回合计（maxLengthContinuations = 0 时保持旧的「截断即结束」行为）。
                            // 仓颉的枚举没有内置 == ：用模式匹配取出「是否被截断」
                            let truncated = match (assistantMsg.stopReason) {
                                case StopReason.Length => true
                                case _ => false
                            }
                            if (truncated && lengthContinuations < Int64(this.config.maxLengthContinuations)) {
                                lengthContinuations++
                                log.warn("response truncated by token limit, continue in same turn (${lengthContinuations}/${this.config.maxLengthContinuations})", Array<Attr>())
                                currentMessages.add(UserMessage(ContentList.ofText(lengthContinuationPrompt()), 0))
                                resumingSameTurn = true
                                continue
                            }
                            if (truncated) {
                                log.warn("response truncated and continuation budget exhausted (${this.config.maxLengthContinuations}), end turn", Array<Attr>())
                            }
                            // 收尾前自验：模型在「没有工具调用」的回合里宣布完成时，先要求它对着任务
                            // 要求实操核对（读产物 / 跑验证 / 复核约束），确认后再允许收尾。
                            // 只在真正做过事（toolCallCount > 0）且是正常回合结束时触发；
                            // 预算是整个 run 的总次数，0 = 关闭。
                            let announcedDone = match (assistantMsg.stopReason) {
                                case StopReason.EndTurn => true
                                case _ => false
                            }
                            if (announcedDone && toolCallCount > 0
                                && verifyPasses < Int64(this.config.maxVerifyPasses)) {
                                verifyPasses++
                                log.warn("agent announced completion, run verify pass (${verifyPasses}/${this.config.maxVerifyPasses})", Array<Attr>())
                                currentMessages.add(UserMessage(ContentList.ofText(verifyBeforeFinishPrompt()), 0))
                                continue
                            }
                            log.info("turn finished", Array<Attr>())
                            let turnUpdate = runAfterTurnHooks(hookState, turnCount)
                            match (turnUpdate.messages) {
                                case Some(msgs) =>
                                    currentMessages = msgs
                                    log.info("afterTurn hook rewrote messages to ${msgs.size}", Array<Attr>())
                                case None => ()
                            }
                            if (turnUpdate.shortCircuit) {
                                log.info("afterTurn hook short-circuited run", Array<Attr>())
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
                            }
                            this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                            finished = true
                    }
                }

                log.info("agent end, total turns=${turnCount}", Array<Attr>())
                callHooks("afterRun", turnCount, hookState)
                stream.setResult(currentMessages)
                this.emit(stream, AgentEndEvent(currentMessages))
            } catch (e: Exception) {
                log.error("unhandled error: ${e.message}", Array<Attr>())
                // 先发结束事件（携带错误说明），再置错误信号：流消费者按 AgentEndEvent 收敛，
                // 随后 result() 抛错由调用方决定策略
                this.emit(stream, AgentEndEvent(ArrayList<Message>([UserMessage(ContentList.ofText("[Runtime error: ${e.message}]"), 0)])))
                stream.setError(e)
            } catch (e: Error) {
                // Error（OOM 等）此前会带着 produce 线程一起走掉：既不 emit AgentEndEvent，
                // 也不 setError —— 消费端（SessionLoop）便永远每 200ms 空转一轮，result()
                // 也永久阻塞。这里兜住，维持「生产端一定会收尾」这一不变量。
                eprintln("[atelier] runtime system error: " + e.toString())
                this.emit(stream, AgentEndEvent(ArrayList<Message>([UserMessage(ContentList.ofText("[Runtime system error: ${e.toString()}]"), 0)])))
                stream.setError(Exception("runtime system error: " + e.toString()))
            }
            // 收尾哨兵：无论如何都标记「生产端已结束」。消费端据此判断循环是否该收敛，
            // 而不是无限等一个可能永远不会到来的 AgentEndEvent（close 不影响已排队事件）。
            stream.close()
            // 会话结束（正常/取消/异常统一路径）后清理取消标志
            synchronized(this.cancelLock) { this.cancels.remove(sessionId) }
        }

        stream
    }

    public func toolNames(): ArrayList<String> {
        this.config.tools
    }

    private func pickModel(m: String): String {
        if (m != "") { return m }
        let envModel = match (getVariable("OPENAI_MODEL")) { case Some(v) => v; case None => "" }
        if (envModel != "") { return envModel }
        "gpt-4o"
    }

    /**
     * 解析本轮**可见的工具对象**。
     *
     * 与投影（怎么通告给模型）分开：PTC 模式需要工具对象本身来构造绑定，
     * 而 native 模式只需要它们的 schema。两者必须来自同一次解析，
     * 否则模型看到的可用能力会与程序能调用的能力分叉。
     */
    private func resolveVisibleTools(): ArrayList<Tool> {
        let result = ArrayList<Tool>()
        for (name in this.config.tools) {
            if (name.startsWith("agent_")) {
                let agentName = name[6..]
                match (this.agentRegistry.get(agentName)) {
                    case Some(cfg) =>
                        // 子 agent 复用同一份装配束（provider 由它自己的配置解析）
                        let tool = AgentTool(agentName, cfg, this.spec)
                        this.toolRegistry.register(tool)
                        result.add(tool)
                    case None => ()
                }
            } else if (name.endsWith("_*")) {
                let prefix = name[0..name.size - 2]
                for (t in this.toolRegistry.list()) {
                    if (t.name().startsWith(prefix)) {
                        if (!this.mcpManager.isActiveTool(t.name(), this.config.mcpCooldownTurns)) {
                            continue
                        }
                        result.add(t)
                    }
                }
            } else {
                match (this.toolRegistry.get(name)) {
                    case Some(t) =>
                        result.add(t)
                    case None => ()
                }
            }
        }
        result
    }

    /**
     * 按呈现模式把可见工具投影成协议工具列表。
     *
     * `Native`：逐个通告原生 schema（现网行为）。
     * `Ptc`：只通告 `run_xisp`，其余能力经 SDK 绑定暴露。
     * `Both`：两者并存（提示词成本翻倍）。
     */
    private func resolveTools(
        visible: ArrayList<Tool>,
        ctx: ToolContext,
        stream: EventStream<AgentEvent, ArrayList<Message>>,
        cancelFlag: AtomicBool,
        hookState: HookState,
        turnCount: Int64
    ): ArrayList<OpenAITool> {
        let result = ArrayList<OpenAITool>()
        let native = this.config.toolPresentation == ToolPresentationMode.Native
        let programmatic = this.config.toolPresentation != ToolPresentationMode.Native

        if (native || this.config.toolPresentation == ToolPresentationMode.Both) {
            for (t in this.renderNativeTools(visible)) {
                result.add(t)
            }
        }
        if (programmatic) {
            let authorizer: PtcAuthorizer = { tool, args =>
                this.authorizeSubCall(tool, args, ctx, hookState, turnCount)
            }
            let emit: (PtcEvent) -> Unit = { event => this.emitPtcEvent(stream, event) }
            let env = PtcRunEnv(ctx.workDir, ctx.sessionId,
                { => cancelFlag.load() }, emit, authorizer,
                maxSubCalls: Int64(this.config.ptcMaxSubCalls),
                timeout: Some(Duration.second * Int64(this.config.ptcTimeoutSeconds)),
                toolBudget: toolBudgetPolicyOf(this.config))
            let tool = RunXispTool(visible, env)
            // 注册进注册表：分发链路按名字查找，因此必须与其它工具同样可见
            this.toolRegistry.register(tool)
            result.add(OpenAITool(tool.name(), tool.description(), tool.schema()))
        }
        result
    }

    /**
     * 子调用的授权：信任闸门 → 交互审批 → `beforeTool` 钩子。
     *
     * 与模型直调走同一套判定（见工具批次组装处的同名逻辑），因此 PTC
     * 不会成为绕过闸门的通道；钩子改写参数在这里同样生效。
     */
    private func authorizeSubCall(
        tool: Tool,
        args: JsonValue,
        ctx: ToolContext,
        hookState: HookState,
        turnCount: Int64
    ): PtcAuthDecision {
        match (this.trustGate(tool, ctx.workDir, ctx.sessionId)) {
            case TrustDecision.Denied =>
                return PtcAuthDecision.Deny("Tool not allowed: workDir is untrusted")
            case TrustDecision.NeedsApproval =>
                if (!this.approveSubCall(tool, args, ctx)) {
                    return PtcAuthDecision.Deny("Tool not allowed: user denied approval")
                }
            case TrustDecision.Allowed => ()
        }
        // callId 在此尚未生成，审批与钩子都不依赖它
        let (replaced, skipMessage) = this.decideToolCall(hookState, turnCount,
            ToolCallBlock("", tool.name(), args))
        match (replaced) {
            case Some(newArgs) => PtcAuthDecision.AllowWith(newArgs)
            case None => PtcAuthDecision.Deny(skipMessage ?? "Tool blocked by hook")
        }
    }

    /** 交互审批；与模型直调的审批分支保持同样的回答语义。 */
    private func approveSubCall(tool: Tool, args: JsonValue, ctx: ToolContext): Bool {
        let log = getGlobalLogger([("name", "AgentRuntime")])
        // 与模型直调的审批同一条路径（同一套选项、同一套判定）
        let subReq = approvalRequest(
            "ask:${ctx.sessionId}:sub:${tool.name()}:approval",
            tool.name(), args, "Tool '" + tool.name() + "' needs your approval.")
        let subAns = this.askHost(subReq, this.resumedAnswersForSub)
        let subInvalid = match (validateAnswer(subReq, subAns)) {
            case Some(err) =>
                log.warn("invalid approval answer (${err}); treating as deny", Array<Attr>())
                true
            case None => false
        }
        if (!subInvalid && subAns.isAllowAlways()) {
            this.trustManager.setTrust(ctx.workDir, TrustState.Trusted)
            log.info("sub-call ${tool.name()} always approved for ${ctx.workDir}", Array<Attr>())
            return true
        }
        if (!subInvalid && subAns.isAllowOnce()) {
            this.trustManager.setSessionTrust(ctx.sessionId, ctx.workDir, TrustState.Trusted)
            log.info("sub-call ${tool.name()} approved for session", Array<Attr>())
            return true
        }
        log.warn("sub-call ${tool.name()} denied by user", Array<Attr>())
        false
    }

    /** 把 PTC 事件翻译成宿主可见的 AgentEvent。 */
    private func emitPtcEvent(
        stream: EventStream<AgentEvent, ArrayList<Message>>,
        event: PtcEvent
    ): Unit {
        match (event) {
            case PtcEvent.DispatchStart(callId, name) =>
                this.emit(stream, ToolExecutionStartEvent(callId, name))
            case PtcEvent.DispatchEnd(callId, _, text, isError) =>
                this.emit(stream, ToolExecutionEndEvent(callId, text, isError))
            // 脚本输出必须实时发出去：它是长脚本唯一的进度信号。只随最终结果返回的话，
            // 前端在整个脚本跑完前只能显示读秒——用户看到的就是「卡住了」
            // （写操作类工具还可能在超时后于后台继续跑，更需要这条线索）。
            case PtcEvent.Log(callId, text) =>
                this.emit(stream, ToolExecutionUpdateEvent(callId, text))
        }
    }

    private func callHooks(phase: String, turnCount: Int64,
        state: HookState): Unit {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
        for (h in this.hooks) {
            try {
                match (phase) {
                    case "beforeRun" => h.beforeRun(ctx)
                    case "afterRun" => h.afterRun(ctx)
                    case _ => ()
                }
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("hook ${phase} error: ${e.message}", Array<Attr>())
            }
        }
    }

    private func runBeforeTurnHooks(state: HookState, turnCount: Int64,
        request: ChatRequest): Option<ChatRequest> {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
        var current = request
        for (h in this.hooks) {
            try {
                match (h.beforeTurn(ctx, current)) {
                    case TurnDecision.Continue(r) => current = r
                    case TurnDecision.ShortCircuit(msg) =>
                        let log = getGlobalLogger([("name", "AgentRuntime")])
                        log.warn("beforeTurn hook short-circuited run: ${msg}", Array<Attr>())
                        return None
                }
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("beforeTurn hook error: ${e.message}", Array<Attr>())
            }
        }
        Some(current)
    }

    private func runBeforeToolHooks(state: HookState, turnCount: Int64,
        call: ToolCallBlock): BeforeToolDecision {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
        var decision = BeforeToolDecision.Allow
        for (h in this.hooks) {
            try {
                match (h.beforeTool(ctx, call)) {
                    case BeforeToolDecision.Allow => ()
                    case BeforeToolDecision.Deny(reason) =>
                        return BeforeToolDecision.Deny(reason)
                    case BeforeToolDecision.Modify(args) =>
                        decision = BeforeToolDecision.Modify(args)
                }
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("beforeTool hook error: ${e.message}", Array<Attr>())
            }
        }
        decision
    }

    // 返回 Some(args) 表示应执行（可带 hook 改写后的参数）；None + Option(reason) 表示应跳过
    private func decideToolCall(state: HookState, turnCount: Int64,
        tc: ToolCallBlock): (Option<JsonValue>, Option<String>) {
        match (runBeforeToolHooks(state, turnCount, tc)) {
            case BeforeToolDecision.Allow =>
                (Some(tc.args), None)
            case BeforeToolDecision.Deny(reason) =>
                (None, Some("Tool blocked by hook: " + reason))
            case BeforeToolDecision.Modify(args) =>
                (Some(args), None)
        }
    }

    private func callAfterToolHooks(state: HookState, turnCount: Int64,
        call: ToolCallBlock, result: ToolResultMessage): Unit {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
        for (h in this.hooks) {
            try {
                h.afterTool(ctx, call, result)
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("afterTool hook error: ${e.message}", Array<Attr>())
            }
        }
    }

    private func runAfterTurnHooks(state: HookState, turnCount: Int64): AfterTurnUpdate {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount, state)
        var update = AfterTurnUpdate.none()
        for (h in this.hooks) {
            try {
                let u = h.afterTurn(ctx)
                let msgs = match (u.messages) {
                    case Some(m) => Some(m)
                    case None => update.messages
                }
                update = AfterTurnUpdate(msgs, update.shortCircuit || u.shortCircuit)
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("afterTurn hook error: ${e.message}", Array<Attr>())
            }
        }
        update
    }
}

// 输出被 token 上限截断时的续跑提示：要求「接着写」而不是重头再来（重复内容会白烧上下文）。
func lengthContinuationPrompt(): String {
    "（系统提示）你上一条回复因为输出长度上限被截断了，这不是回合结束。" +
    "请从被截断处继续，不要重复已经写过的内容；若要写长文件或长脚本，请拆成更小的片段分多次写入。"
}

// 收尾前自验提示：要求「实际核对」而不是凭记忆断言完成（评测里最常见的失败模式是
// 模型自认为做完、但产物不满足任务约束）。
func verifyBeforeFinishPrompt(): String {
    "（系统提示）在宣布任务完成之前，请对着任务要求逐条自验：" +
    "重新读取或运行你产出的文件与命令，核对是否真的满足每条约束（格式、路径、输出内容、" +
    "边界情况），而不是凭记忆断言。发现不符就先修正，全部确认无误后再给出结论。"
}
