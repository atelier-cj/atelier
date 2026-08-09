package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.*
import atelier.skill.*
import atelier.session.*
import atelier.trust.*
import atelier.context.compactMessages
import atelier.context.ContextBuilder
import atelier.context.ModelContextRegistry
import atelier.context.renderCompactionPrompt
import atelier.context.validateSummary
import atelier.context.compactWithSummary
import atelier.context.CompactionConfig
import atelier.context.estimateTokens
import atelier.event.EventStream
import std.io.InputStream
import jsonvalue.*
import std.collection.*
import std.core.Duration
import std.core.sleep
import std.env.getVariable
import std.time.MonoTime
import stdx.log.*

public class AgentRuntime {
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

    // 13 参：最全签名（hooks + askUser + sessionEnv + mcpManager），其余构造统一委托至此
    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        hooks: ArrayList<Hook>, askUser: AskUserFn,
        sessionEnv: SessionEnvironment, mcpManager: McpManager) {
        this.config = config
        this.provider = provider
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

    public func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        this.chatWithEnv(messages, this.sessionEnv)
    }

    public func chatWithEnv(messages: ArrayList<Message>, sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let se = sessionEnv
        let workDir = if (se.directory != "") { se.directory } else { "." }
        let ctx = ToolContext(workDir, this.askUser, se.context)
        let sessionId = "sess_0"
        let ctxBuilder = ContextBuilder(this.skillRegistry, se)

        spawn {
            let log = getGlobalLogger([("name", "AgentRuntime")])
            try {
                stream.emit(AgentStartEvent(sessionId))
                log.info("agent start: ${this.config.name}", Array<Attr>())
                let hookState = HookState()
                callHooks("beforeRun", 0, hookState)

                // Build system prompt + assemble initial messages (L2)
                var currentMessages = ctxBuilder.initMessages(
                    this.config.systemPrompt, this.config.skills, messages)
                var turnCount: Int64 = 0
                var toolCallCount: Int64 = 0
                var lastToolTime: MonoTime = MonoTime.now()
                var finished = false

                while (!finished && turnCount < Int64(this.config.maxTurns)) {
                    stream.emit(TurnStartEvent())
                    turnCount++
                    this.mcpManager.advanceTurn()
                    log.info("turn ${turnCount} start", Array<Attr>())
                    currentMessages = ctxBuilder.applyArchives(currentMessages)

                    stream.emit(MessageStartEvent(currentMessages[0]))
                    let actualModel = this.pickModel(this.config.model)
                    let tools = this.resolveTools()
                    var chatReq = ctxBuilder.buildChatRequest(actualModel, currentMessages,
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
                            stream.emit(TurnEndEvent(AssistantMessage(ContentList.ofText("[Run short-circuited by hook]"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>()))
                            finished = true
                            break
                    }

                    let chatStream = this.provider.chatStreaming(chatReq)
                    var contentBuilder = StringBuilder()
                    var assistantMsg: AssistantMessage
                    try {
                        while (true) {
                            match (chatStream.receive(5 * Duration.second)) {
                                case Some(delta) =>
                                    if (delta.delta != "") {
                                        contentBuilder.append(delta.delta)
                                        stream.emit(MessageUpdateEvent(
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
                        assistantMsg = chatStream.result()
                    } catch (e: Exception) {
                        log.error("provider error: ${e.message}", Array<Attr>())
                        stream.emit(TurnEndEvent(AssistantMessage(ContentList.ofText(e.message), "", "", StopReason.Error, TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>()))
                        finished = true
                        break
                    }
                    log.info("provider response received", Array<Attr>())
                    stream.emit(MessageEndEvent(assistantMsg))
                    currentMessages.add(assistantMsg)

                    match (assistantMsg.stopReason) {
                        case StopReason.ToolUse =>
                            let toolCalls = assistantMsg.toolCalls()
                            log.info("tool calls: ${toolCalls.size}", Array<Attr>())
                            let maxCalls = Int64(this.config.maxToolCalls)
                            if (toolCallCount >= maxCalls) {
                                log.warn("max tool calls (${maxCalls}) reached", Array<Attr>())
                                currentMessages.add(ToolResultMessage("", "", ContentList.ofText("Max tool calls (${maxCalls}) reached, skipping"), true, 0))
                                stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
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
                            var idx: Int64 = 0
                            while (idx < toolCalls.size) {
                                let tc = toolCalls[idx]
                                match (this.toolRegistry.get(tc.name)) {
                                    case Some(t) =>
                                        match (shouldAllow(t, ctx.workDir, this.trustManager)) {
                                            case TrustDecision.Allowed =>
                                                let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                match (args) {
                                                    case Some(a) => batch.add((tc.name, ctx, a))
                                                    case None =>
                                                        skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                        log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                }
                                            case TrustDecision.NeedsApproval =>
                                                let answer = this.askUser(
                                                    "Tool '" + tc.name + "' needs your approval.\n" +
                                                    "  y  — allow this once (session only)\n" +
                                                    "  a  — always allow this directory\n" +
                                                    "  n  — deny")
                                                if (answer == "a" || answer == "always" || answer == "yes") {
                                                    this.trustManager.setTrust(ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} always approved for ${ctx.workDir}", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) => batch.add((tc.name, ctx, a))
                                                        case None =>
                                                            skipResults[idx] = skipMsg ?? "Tool blocked by hook"
                                                            log.warn("tool ${tc.name} blocked by hook", Array<Attr>())
                                                    }
                                                } else if (answer == "y" || answer == "once") {
                                                    this.trustManager.setSessionTrust(ctx.workDir, TrustState.Trusted)
                                                    log.info("tool ${tc.name} approved for session", Array<Attr>())
                                                    let (args, skipMsg) = decideToolCall(hookState, turnCount, tc)
                                                    match (args) {
                                                        case Some(a) => batch.add((tc.name, ctx, a))
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
                            let results = try {
                                this.toolExecutor.executeBatch(batch)
                            } catch (e: Exception) {
                                log.error("tool execute error: ${e.message}", Array<Attr>())
                                currentMessages.add(ToolResultMessage("", "", ContentList.ofText("[Tool error: ${e.message}]"), true, 0))
                                stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
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
                                            let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(r.text), r.isError, 0)
                                            currentMessages.add(tr)
                                            callAfterToolHooks(hookState, turnCount, tc, tr)
                                            resIdx++
                                        }
                                }
                            }
                            toolCallCount += toolCalls.size
                            lastToolTime = MonoTime.now()
                            stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                        case _ =>
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
                                stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
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
                                        let prompt = renderCompactionPrompt(cc, conversation, None, reserve)
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
                            stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                            finished = true
                    }
                }

                log.info("agent end, total turns=${turnCount}", Array<Attr>())
                callHooks("afterRun", turnCount, hookState)
                stream.setResult(currentMessages)
                stream.emit(AgentEndEvent(currentMessages))
            } catch (e: Exception) {
                log.error("unhandled error: ${e.message}", Array<Attr>())
                stream.setError(e)
            }
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

    private func resolveTools(): ArrayList<OpenAITool> {
        let result = ArrayList<OpenAITool>()
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
                        result.add(OpenAITool(tool.name(), tool.description(), tool.schema()))
                    case None => ()
                }
            } else if (name.endsWith("_*")) {
                let prefix = name[0..name.size - 2]
                for (t in this.toolRegistry.list()) {
                    if (t.name().startsWith(prefix)) {
                        if (!this.mcpManager.isActiveTool(t.name(), this.config.mcpCooldownTurns)) {
                            continue
                        }
                        result.add(OpenAITool(t.name(), t.description(), t.schema()))
                    }
                }
            } else {
                match (this.toolRegistry.get(name)) {
                    case Some(t) =>
                        result.add(OpenAITool(t.name(), t.description(), t.schema()))
                    case None => ()
                }
            }
        }
        result
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
