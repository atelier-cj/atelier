package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.interaction.*
import atelier.provider.*
import atelier.skill.*
import atelier.session.*
import atelier.trust.*
import atelier.context.compactMessages
import atelier.context.ContextBuilder
import atelier.context.PromptSegmentContributor
import atelier.context.ModelContextRegistry
import atelier.context.renderCompactionPrompt
import atelier.context.findPreviousSummary
import atelier.context.validateSummary
import atelier.context.compactWithSummary
import atelier.context.CompactionConfig
import atelier.context.estimateTokens
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

public open class AgentRuntime {
    private let config: AgentConfig
    private let provider: Provider
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private let skillRegistry: SkillRegistry
    private let agentRegistry: AgentRegistry
    private let providerRegistry: ProviderRegistry
    private let toolExecutor: ToolExecutor
    private let hooks: ArrayList<Hook>
    private let askUser: AskUserFn
    private let modelRegistry: ModelContextRegistry
    private let sessionEnv: SessionEnvironment
    private let mcpManager: McpManager
    // 自定义系统提示段贡献者（宿主扩展点，见 PromptSegmentContributor）
    private let promptContributors: ArrayList<PromptSegmentContributor>
    // 全局事件总线（可选挂载：宿主跨会话审计/监控；None = 不发布）
    private let eventBus: ?EventBus

    // 会话级取消：sessionId → 取消标志（chat 开始注册，收尾统一清理）
    private let cancels = HashMap<String, AtomicBool>()
    private let cancelLock = Mutex()

    // 可选工具级授权回调（ACP 等无终端宿主注入）：返回 y/a/""（once/always/deny）。
    // None 时维持文本 askUser 问答（默认行为）。NeedsApproval 判定优先走本回调。
    public var toolApprovalFn: ?(ToolCallBlock, String) -> String = None

    // 13 参：最全签名（hooks + askUser + sessionEnv + mcpManager），其余构造统一委托至此
    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        hooks: ArrayList<Hook>, askUser: AskUserFn,
        sessionEnv: SessionEnvironment, mcpManager: McpManager,
        promptContributors!: ArrayList<PromptSegmentContributor> = ArrayList(),
        middlewares!: ArrayList<ProviderMiddleware> = ArrayList(),
        eventBus!: ?EventBus = None) {
        this.config = config
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.skillRegistry = skillRegistry
        this.agentRegistry = agentRegistry
        this.providerRegistry = providerRegistry
        this.toolExecutor = ToolExecutor(this.toolRegistry,
            budget: toolBudgetPolicyOf(config))
        this.hooks = hooks
        this.askUser = askUser
        this.modelRegistry = ModelContextRegistry()
        this.sessionEnv = sessionEnv
        this.mcpManager = mcpManager
        this.promptContributors = promptContributors
        this.eventBus = eventBus
        // 请求级中间件链 wrap（先注入者最外层；委托链末端为原始 provider）
        var p = provider
        for (m in middlewares) { p = m.wrap(p) }
        this.provider = p
    }

    // 11 参：hooks + askUser + mcpManager
    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        hooks: ArrayList<Hook>, askUser: AskUserFn, mcpManager: McpManager) {
        this(config, provider, toolRegistry, sessionStore, trustManager,
            skillRegistry, agentRegistry, providerRegistry, hooks, askUser,
            SessionEnvironment(), mcpManager)
    }

    // 9 参：config..providerRegistry + mcpManager
    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        mcpManager: McpManager) {
        this(config, provider, toolRegistry, sessionStore, trustManager,
            skillRegistry, agentRegistry, providerRegistry,
            ArrayList<Hook>(), { q => "" }, mcpManager)
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

    // 由会话级上下文派生出「本次调用」的上下文：只多一个 toolCallId
    private func callContext(ctx: ToolContext, toolCallId: String): ToolContext {
        ToolContext(ctx.workDir, ctx.askUser, ctx.env, ctx.sessionId, toolCallId: toolCallId)
    }

    private func chatWithEnv(sessionId: String, messages: ArrayList<Message>, sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let se = sessionEnv
        let workDir = resolveWorkDir(se)
        let ctx = ToolContext(workDir, this.askUser, se.context, sessionId)
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
                    var chatReq = ctxBuilder.buildChatRequest(actualModel, systemText, currentMessages,
                        Float64(this.config.temperature), Int64(this.config.maxOutputTokens),
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

                    let chatStream = this.provider.chatStreaming(chatReq)
                    var contentBuilder = StringBuilder()
                    var assistantMsg = AssistantMessage(ContentList.ofText(""), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                    try {
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
                    } catch (e: Exception) {
                        // 用 toString() 而不是 message：Socket/FS 这类异常的 message 常为空，
                        // 只打 message 在日志里就是一行「provider error: 」，等于没有信息
                        log.error("provider error: ${e.toString()}", Array<Attr>())
                        let failureMsg = AssistantMessage(ContentList.ofText("[provider error] ${e.toString()}"), "", "", StopReason.Error, TokenUsage(0, 0), 0)
                        // 同短路分支：错误必须进消息列表，否则消费端与界面都看不到它
                        currentMessages.add(failureMsg)
                        this.emit(stream, TurnEndEvent(failureMsg, ArrayList<ToolResultMessage>()))
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
                                        match (shouldAllowFor(t, ctx.workDir, this.trustManager, sessionId)) {
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
                                                let gateReq = approvalRequest(
                                                    "ask:${sessionId}:${turnCount}:${tc.id}:approval",
                                                    tc.name, JsonValue.Map(HashMap<String, JsonValue>()),
                                                    "Tool '" + tc.name + "' needs your approval.",
                                                    toolCallId: tc.id)
                                                let gateAns = match (this.toolApprovalFn) {
                                                    case Some(f) =>
                                                        let raw = f(tc, ctx.workDir)
                                                        let sel = ArrayList<String>()
                                                        if (raw == "a" || raw == "always" || raw == "yes") {
                                                            sel.add("allow_always")
                                                        } else if (raw == "y" || raw == "once") {
                                                            sel.add("allow_once")
                                                        } else {
                                                            sel.add("deny")
                                                        }
                                                        UserAnswer(gateReq.id, UserAnswerStatus.Answered,
                                                            selected: sel)
                                                    case None => ctx.ask(gateReq)
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
                            if (this.config.compactionEnabled || match (this.config.compaction) {
                                case Some(c) => c.enabled
                                case None => false }) {
                                let contextWindow = this.modelRegistry.get(actualModel)
                                let cc = match (this.config.compaction) {
                                    case Some(c) => c
                                    case None => CompactionConfig()
                                }
                                let reserve = match (this.config.compaction) {
                                    case Some(c) => c.reserveTokens
                                    case None => Int64(this.config.compactionReserveTokens)
                                }
                                let keepRecent = match (this.config.compaction) {
                                    case Some(c) => c.keepRecentTokens
                                    case None => Int64(this.config.keepRecentTokens)
                                }
                                // 用量优先：Provider 报告的实际用量 > 0 时优先，本地估算兜底
                                let total = if (assistantMsg.usage.inputTokens > 0) { assistantMsg.usage.inputTokens }
                                    else { estimateTokens(currentMessages) }
                                if (total > reserve && contextWindow != 0 && total > contextWindow - reserve) {
                                    // 独立子调用（请求体无 system/tools，缓存 Key 独立，不污染主对话）
                                    let summary = try {
                                        let conversation = summarizeText(currentMessages, reserve)
                                        let prev = findPreviousSummary(currentMessages)
                                        let prompt = renderCompactionPrompt(cc, conversation, prev, reserve)
                                        let summaryModel = match (cc.summaryModel) {
                                            case Some(m) => m
                                            case None => actualModel
                                        }
                                        let req = ChatRequest(summaryModel,
                                            ArrayList<Message>([UserMessage(ContentList.ofText(prompt), 0)]),
                                            Float64(0.2), reserve, None, ArrayList<OpenAITool>())
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
                                    currentMessages = compactWithSummary(currentMessages, keepRecent, summary, total)
                                } else {
                                    currentMessages = compactMessages(currentMessages, contextWindow, reserve, keepRecent)
                                }
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
                        let prov = this.resolveSubProvider(cfg)
                        let tool = AgentTool(agentName, cfg, prov,
                            this.toolRegistry, this.sessionStore,
                            this.trustManager, this.skillRegistry,
                            this.agentRegistry, this.providerRegistry,
                            this.mcpManager)
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
            for (t in visible) {
                result.add(OpenAITool(t.name(), t.description(), t.schema()))
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
        match (shouldAllowFor(tool, ctx.workDir, this.trustManager, ctx.sessionId)) {
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
        let call = ToolCallBlock("", tool.name(), args)
        // 与模型直调的审批同一条路径（同一套选项、同一套判定）
        let subReq = approvalRequest(
            "ask:${ctx.sessionId}:sub:${tool.name()}:approval",
            tool.name(), args, "Tool '" + tool.name() + "' needs your approval.")
        let subAns = match (this.toolApprovalFn) {
            case Some(f) =>
                let raw = f(call, ctx.workDir)
                let sel = ArrayList<String>()
                if (raw == "a" || raw == "always" || raw == "yes") {
                    sel.add("allow_always")
                } else if (raw == "y" || raw == "once") {
                    sel.add("allow_once")
                } else {
                    sel.add("deny")
                }
                UserAnswer(subReq.id, UserAnswerStatus.Answered, selected: sel)
            case None => ctx.ask(subReq)
        }
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

    private func resolveSubProvider(cfg: AgentConfig): Provider {
        let provName = match (cfg.provider) { case Some(v) => v; case None => "default" }
        match (this.providerRegistry.get(provName)) {
            case Some(p) => p
            case None => this.provider
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

// 待压缩对话文本（截取到约 reserve*4 字节上限，避免子调用超长）
func summarizeText(msgs: ArrayList<Message>, limit: Int64): String {
    let sb = StringBuilder()
    var used: Int64 = 0
    for (m in msgs) {
        let t = match (m) {
            case um: UserMessage => plainTextOf(um)
            case am: AssistantMessage => plainTextOf(am)
            case tm: ToolResultMessage => "[tool " + tm.toolName + "]: " + plainTextOf(tm)
            case cm: CompactionMessage => "[summary] " + cm.summary
            case am2: ArchiveMessage => "[archived " + am2.startIndex.toString() + "-" + am2.endIndex.toString() + "]: " + am2.summary
            case _ => ""
        }
        if (t == "") { continue }
        if (used + Int64(t.size) > limit * 4) {
            // 超限：截取该消息前缀到剩余额度，避免摘要子调用拿到空对话
            let remaining = limit * 4 - used
            if (remaining > 0) {
                let cut = if (Int64(t.size) < remaining) { Int64(t.size) } else { remaining }
                sb.append(t[0..cut])
                sb.append("\n")
            }
            break
        }
        sb.append(t)
        sb.append("\n")
        used += Int64(t.size)
    }
    sb.toString()
}

// 提取消息文本（ContentList 的 TextBlock 拼接）
func plainTextOf(m: Message): String {
    let cl = match (m) {
        case um: UserMessage => um.content
        case am: AssistantMessage => am.content
        case tm: ToolResultMessage => tm.content
        case cm: CompactionMessage => ContentList.ofText(cm.summary)
        case _ => ContentList.ofText("")
    }
    let sb = StringBuilder()
    for (b in cl.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
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
