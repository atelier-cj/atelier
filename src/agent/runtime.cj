package atelier.agent

import atelier.message.*
import atelier.tool.*
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
import std.sync.*
import std.time.MonoTime
import stdx.log.*
import opencj::ulid.nextId

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
        this.toolExecutor = ToolExecutor(this.toolRegistry)
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

    private func chatWithEnv(sessionId: String, messages: ArrayList<Message>, sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let se = sessionEnv
        let workDir = if (se.directory != "") { se.directory } else { "." }
        let ctx = ToolContext(workDir, this.askUser, se.context, sessionId)
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
                var lastToolTime: MonoTime = MonoTime.now()
                var finished = false

                while (!finished && !cancelFlag.load() && turnCount < Int64(this.config.maxTurns)) {
                    this.emit(stream, TurnStartEvent())
                    turnCount++
                    this.mcpManager.advanceTurn()
                    log.info("turn ${turnCount} start", Array<Attr>())
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
                            this.emit(stream, TurnEndEvent(AssistantMessage(ContentList.ofText("[Run short-circuited by hook]"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>()))
                            finished = true
                            break
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
                        log.error("provider error: ${e.message}", Array<Attr>())
                        this.emit(stream, TurnEndEvent(AssistantMessage(ContentList.ofText(e.message), "", "", StopReason.Error, TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>()))
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
                                                        batch.add((tc.name, ctx, a))
                                                        runCallIds.add(tc.id)
                                                        runNames.add(tc.name)
                                                    case None =>
                                                        skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                        log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                }
                                            case TrustDecision.NeedsApproval =>
                                                let answer = match (this.toolApprovalFn) {
                                                    case Some(f) => f(tc, ctx.workDir)
                                                    case None =>
                                                        this.askUser(
                                                            "Tool '" + tc.name + "' needs your approval.\n" +
                                                            "  y  — allow this once (session only)\n" +
                                                            "  a  — always allow this directory\n" +
                                                            "  n  — deny")
                                                }
                                                if (answer == "a" || answer == "always" || answer == "yes") {
                                                    this.trustManager.setTrust(ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} always approved for ${ctx.workDir}", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) =>
                                                            batch.add((tc.name, ctx, a))
                                                            runCallIds.add(tc.id)
                                                            runNames.add(tc.name)
                                                        case None =>
                                                            skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                            log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                    }
                                                } else if (answer == "y" || answer == "once") {
                                                    this.trustManager.setSessionTrust(sessionId, ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} approved for session", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) =>
                                                            batch.add((tc.name, ctx, a))
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
                                log.error("tool execute error: ${e.message}", Array<Attr>())
                                currentMessages.add(ToolResultMessage("", "", ContentList.ofText("[Tool error: ${e.message}]"), true, 0))
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                continue
                            }
                            var resIdx: Int64 = 0
                            for (i in 0..toolCalls.size) {
                                let tc = toolCalls[Int64(i)]
                                match (skipResults.get(Int64(i))) {
                                    case Some(msg) =>
                                        let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(msg), false, 0)
                                        currentMessages.add(tr)
                                    case None =>
                                        if (resIdx < results.size) {
                                            let r = results[Int64(resIdx)]
                                            log.info("tool ${tc.name} done: err=${r.isError}", Array<Attr>())
                                            this.mcpManager.markUsedTool(tc.name)
                                            // 工具执行结束事件（与开始事件一一对应）
                                            this.emit(stream, ToolExecutionEndEvent(tc.id, r.text, r.isError))
                                            let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(r.text), r.isError, 0)
                                            currentMessages.add(tr)
                                            callAfterToolHooks(hookState, turnCount, tc, tr)
                                            resIdx++
                                        }
                                }
                            }
                            toolCallCount += toolCalls.size
                            lastToolTime = MonoTime.now()
                            this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                        case _ =>
                            if (cancelFlag.load()) {
                                // 取消：跳过 afterTurn 改写与压缩等后续处理，直接收尾
                                log.info("run cancelled at turn end", Array<Attr>())
                                this.emit(stream, TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                finished = true
                                break
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
                timeout: Some(Duration.second * Int64(this.config.ptcTimeoutSeconds)))
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
        let answer = match (this.toolApprovalFn) {
            case Some(f) => f(call, ctx.workDir)
            case None =>
                this.askUser(
                    "Tool '" + tool.name() + "' needs your approval.\n" +
                    "  y  — allow this once (session only)\n" +
                    "  a  — always allow this directory\n" +
                    "  n  — deny")
        }
        if (answer == "a" || answer == "always" || answer == "yes") {
            this.trustManager.setTrust(ctx.workDir, TrustState.Trusted)
            log.info("sub-call ${tool.name()} always approved for ${ctx.workDir}", Array<Attr>())
            return true
        }
        if (answer == "y" || answer == "once") {
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
            // 脚本输出随最终结果一起返回，不额外占用事件流
            case PtcEvent.Log(_) => ()
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
