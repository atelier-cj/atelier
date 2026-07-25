package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.*
import atelier.skill.*
import atelier.session.*
import atelier.trust.*
import atelier.context.compactMessages
import atelier.event.EventStream
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

    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        hooks: ArrayList<Hook>) {
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
    }

    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry) {
        this.config = config
        this.provider = provider
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.skillRegistry = skillRegistry
        this.agentRegistry = agentRegistry
        this.providerRegistry = providerRegistry
        this.toolExecutor = ToolExecutor(this.toolRegistry)
        this.hooks = ArrayList<Hook>()
    }

    public func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let ctx = ToolContext(".")
        let sessionId = "sess_0"

        spawn {
            let log = getGlobalLogger([("name", "AgentRuntime")])
            try {
                stream.emit(AgentStartEvent(sessionId))
                log.info("agent start: ${this.config.name}", Array<Attr>())
                callHooks("beforeRun", 0, ArrayList<ToolCallBlock>(), ArrayList<ToolResultMessage>())

                // Build system prompt with skill instructions
                let systemText = buildSystemPrompt(this.config, this.skillRegistry)
                var currentMessages = ArrayList<Message>()
                if (systemText != "") {
                    currentMessages.add(UserMessage(ContentList.ofText(systemText), 0))
                }
                for (m in messages) { currentMessages.add(m) }
                var turnCount: Int64 = 0
                var toolCallCount: Int64 = 0
                var lastToolTime: MonoTime = MonoTime.now()
                var finished = false

                while (!finished && turnCount < Int64(this.config.maxTurns)) {
                    stream.emit(TurnStartEvent())
                    turnCount++
                    log.info("turn ${turnCount} start", Array<Attr>())
                    callHooks("beforeTurn", turnCount, ArrayList<ToolCallBlock>(), ArrayList<ToolResultMessage>())

                    stream.emit(MessageStartEvent(currentMessages[0]))
                    let actualModel = this.pickModel(this.config.model)
                    let tools = this.resolveTools()
                    let chatReq = ChatRequest(actualModel, currentMessages,
                        Float64(this.config.temperature), Int64(this.config.maxOutputTokens),
                        this.config.thinkingLevel, tools)

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
                                        if (shouldAllow(t, ctx.workDir, this.trustManager)) {
                                            batch.add((tc.name, ctx, tc.args))
                                        } else {
                                            skipResults[idx] = "Tool not allowed: workDir not trusted"
                                            log.warn("tool ${tc.name} blocked by trust gate", Array<Attr>())
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
                            callHooks("beforeTool", turnCount, toolCalls, ArrayList<ToolResultMessage>())
                            let results = try {
                                this.toolExecutor.executeBatch(batch)
                            } catch (e: Exception) {
                                log.error("tool execute error: ${e.message}", Array<Attr>())
                                currentMessages.add(ToolResultMessage("", "", ContentList.ofText("[Tool error: ${e.message}]"), true, 0))
                                stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                                continue
                            }
                            var resIdx: Int64 = 0
                            let toolResults = ArrayList<ToolResultMessage>()
                            for (i in 0..toolCalls.size) {
                                let tc = toolCalls[Int64(i)]
                                match (skipResults.get(Int64(i))) {
                                    case Some(msg) =>
                                        let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(msg), false, 0)
                                        currentMessages.add(tr)
                                        toolResults.add(tr)
                                    case None =>
                                        if (resIdx < results.size) {
                                            let r = results[Int64(resIdx)]
                                            log.info("tool ${tc.name} done: err=${r.isError}", Array<Attr>())
                                            let tr = ToolResultMessage(tc.id, tc.name, ContentList.ofText(r.text), r.isError, 0)
                                            currentMessages.add(tr)
                                            toolResults.add(tr)
                                            resIdx++
                                        }
                                }
                            }
                            callHooks("afterTool", turnCount, toolCalls, toolResults)
                            toolCallCount += toolCalls.size
                            lastToolTime = MonoTime.now()
                            stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                        case _ =>
                            log.info("turn finished", Array<Attr>())
                            callHooks("afterTurn", turnCount, ArrayList<ToolCallBlock>(), ArrayList<ToolResultMessage>())
                            if (this.config.compactionEnabled) {
                                currentMessages = compactMessages(currentMessages,
                                    Int64(this.config.maxOutputTokens) * 8,
                                    Int64(this.config.compactionReserveTokens),
                                    Int64(this.config.keepRecentTokens))
                            }
                            stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                            finished = true
                    }
                }

                log.info("agent end, total turns=${turnCount}", Array<Attr>())
                callHooks("afterRun", turnCount, ArrayList<ToolCallBlock>(), ArrayList<ToolResultMessage>())
                stream.setResult(currentMessages)
                stream.emit(AgentEndEvent(currentMessages))
            } catch (e: Exception) {
                log.error("unhandled error: ${e.message}", Array<Attr>())
                stream.setError(e)
            }
        }

        stream
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
                            this.agentRegistry, this.providerRegistry)
                        this.toolRegistry.register(tool)
                        result.add(OpenAITool(tool.name(), tool.description(), tool.schema()))
                    case None => ()
                }
            } else if (name.endsWith("_*")) {
                let prefix = name[0..name.size - 2]
                for (t in this.toolRegistry.list()) {
                    if (t.name().startsWith(prefix)) {
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
        toolCalls: ArrayList<ToolCallBlock>,
        toolResults: ArrayList<ToolResultMessage>): Unit {
        let ctx = HookContext(this.config, this.toolRegistry, turnCount,
            toolCalls, toolResults)
        for (h in this.hooks) {
            try {
                match (phase) {
                    case "beforeRun" => h.beforeRun(ctx)
                    case "afterRun" => h.afterRun(ctx)
                    case "beforeTurn" => h.beforeTurn(ctx)
                    case "afterTurn" => h.afterTurn(ctx)
                    case "beforeTool" => h.beforeTool(ctx)
                    case "afterTool" => h.afterTool(ctx)
                    case _ => ()
                }
            } catch (e: Exception) {
                let log = getGlobalLogger([("name", "AgentRuntime")])
                log.warn("hook ${phase} error: ${e.message}", Array<Attr>())
            }
        }
    }
}

func buildSystemPrompt(config: AgentConfig, skills: SkillRegistry): String {
    let sp = config.systemPrompt
    if (config.skills.size == 0) { return sp }
    let sb = StringBuilder()
    if (sp != "") {
        sb.append(sp)
        sb.append("\n\n")
    }
    for (name in config.skills) {
        match (skills.get(name)) {
            case Some(skill) =>
                sb.append(skill.instructions)
                sb.append("\n\n")
            case None => ()
        }
    }
    sb.toString()
}
