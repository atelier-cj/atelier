package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.*
import atelier.session.*
import atelier.trust.*
import atelier.event.EventStream
import jsonvalue.*
import std.collection.*
import std.env.getVariable

public class AgentRuntime {
    private let config: AgentConfig
    private let provider: Provider
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private let toolExecutor: ToolExecutor

    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager) {
        this.config = config
        this.provider = provider
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.toolExecutor = ToolExecutor(this.toolRegistry)
    }

    public func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        let stream = EventStream<AgentEvent, ArrayList<Message>>()
        let ctx = ToolContext(".")
        let sessionId = "sess_0"

        spawn {
            stream.emit(AgentStartEvent(sessionId))

            let provName = match (this.config.provider) {
                case Some(v) => v; case None => ""
            }
            let header = SessionHeader(1, sessionId, 0, 0,
                this.config.model, provName, this.config.systemPrompt, None)
            this.sessionStore.save(sessionId, header, messages)

            var currentMessages = ArrayList<Message>(messages)
            var turnCount: Int64 = 0
            var finished = false

            while (!finished && turnCount < Int64(this.config.maxTurns)) {
                stream.emit(TurnStartEvent())
                turnCount++

                stream.emit(MessageStartEvent(currentMessages[0]))
                let actualModel = this.pickModel(this.config.model)
                let tools = resolveTools(this.config.tools, this.toolRegistry)
                let chatReq = ChatRequest(actualModel, currentMessages,
                    Float64(this.config.temperature), Int64(this.config.maxOutputTokens),
                    this.config.thinkingLevel, tools)

                let chatStream = this.provider.chatStreaming(chatReq)
                var assistantMsg: AssistantMessage
                try {
                    assistantMsg = chatStream.result()
                } catch (_) {
                    stream.emit(TurnEndEvent(AssistantMessage(ContentList.ofText(""), "", "", StopReason.Error, TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>()))
                    finished = true
                    break
                }
                stream.emit(MessageEndEvent(assistantMsg))
                currentMessages.add(assistantMsg)

                match (assistantMsg.stopReason) {
                    case StopReason.ToolUse =>
                        let toolCalls = assistantMsg.toolCalls()
                        let batch = ArrayList<(String, ToolContext, JsonValue)>()
                        var idx: Int64 = 0
                        while (idx < toolCalls.size) {
                            let tc = toolCalls[idx]
                            let t = (tc.name, ctx, tc.args)
                            batch.add(t)
                            idx++
                        }
                        let results = this.toolExecutor.executeBatch(batch)
                        idx = 0
                        for (r in results) {
                            let tcId = if (idx < toolCalls.size) { toolCalls[idx].id } else { "" }
                            currentMessages.add(ToolResultMessage(tcId, toolCalls[idx].name, ContentList.ofText(r.text), r.isError, 0))
                            idx++
                        }
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                    case _ =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                        finished = true
                }
            }

            stream.setResult(currentMessages)
            stream.emit(AgentEndEvent(currentMessages))
        }

        stream
    }

    private func pickModel(m: String): String {
        if (m != "") { return m }
        let envModel = match (getVariable("OPENAI_MODEL")) { case Some(v) => v; case None => "" }
        if (envModel != "") { return envModel }
        "gpt-4o"
    }
}

func resolveTools(names: ArrayList<String>, reg: ToolRegistry): ArrayList<OpenAITool> {
    let result = ArrayList<OpenAITool>()
    for (name in names) {
        match (reg.get(name)) {
            case Some(t) =>
                result.add(OpenAITool(t.name(), t.description(), t.schema()))
            case None => ()
        }
    }
    result
}
