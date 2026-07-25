package atelier.agent

import atelier.message.*
import atelier.tool.*
import atelier.provider.*
import atelier.session.*
import atelier.trust.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

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
        let stream = EventStream<AgentEvent, ArrayList<Message>>(0)
        let ctx = ToolContext(".")
        let sessionId = "sess_${Int64(0)}"

        spawn {
            // Outer loop: Run
            stream.emit(AgentStartEvent(sessionId))

            // Save initial messages as session
            let header = SessionHeader(1, sessionId, 0, 0,
                this.config.model, this.config.provider.getOr(""), this.config.systemPrompt, None)
            this.sessionStore.save(sessionId, header, messages)

            var currentMessages = ArrayList<Message>(messages)
            var turnCount: Int64 = 0
            var finished = false

            while (!finished && turnCount < Int64(this.config.maxTurns)) {
                // Turn start
                stream.emit(TurnStartEvent())
                turnCount++

                // 1. Build request and call provider
                stream.emit(MessageStartEvent(currentMessages[0]))
                let chatReq = ChatRequest(this.config.model, currentMessages,
                    this.config.temperature, Int64(this.config.maxOutputTokens))

                // 2. Stream from provider
                let chatStream = this.provider.chatStreaming(chatReq)
                var collectedDelta = StringBuilder()
                var finishReason: Option<StopReason> = None

                loop {
                    match (chatStream.receive()) {
                        case Some(delta) =>
                            collectedDelta.append(delta.delta)
                            stream.emit(MessageUpdateEvent(currentMessages[0], delta.delta))
                            finishReason = delta.finishReason
                        case None => break
                    }
                }

                // Build assistant message
                let assistantMsg = AssistantMessage(
                    ContentList.ofText(collectedDelta.toString()),
                    this.config.model, this.config.provider.getOr(""),
                    finishReason.getOr(StopReason.EndTurn),
                    TokenUsage(0, 0), 0)
                stream.emit(MessageEndEvent(assistantMsg))
                currentMessages.add(assistantMsg)

                // 3. Check stop reason
                match (finishReason) {
                    case Some(StopReason.ToolUse) =>
                        // Execute tools
                        let toolCalls = assistantMsg.toolCalls()
                        let batch = ArrayList<(String, ToolContext, JsonValue)>()
                        for (tc in toolCalls) {
                            match (tc) {
                                case ToolCallBlock(id, name, args) =>
                                    batch.add((name, ctx, args))
                                case _ => ()
                            }
                        }
                        let results = this.toolExecutor.executeBatch(batch)
                        for (r in results) {
                            currentMessages.add(ToolResultMessage("", "", ContentList.ofText(r.text), r.isError, 0))
                        }
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                    case Some(StopReason.EndTurn) =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                        finished = true

                    case Some(StopReason.Length) =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))

                    case Some(StopReason.Error) =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                        finished = true

                    case Some(StopReason.Aborted) =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                        finished = true

                    case None =>
                        stream.emit(TurnEndEvent(assistantMsg, ArrayList<ToolResultMessage>()))
                        finished = true
                }

                // Check follow-up steering messages
                // TODO: implement steering
            }

            // End of run
            stream.setResult(currentMessages)
            stream.emit(AgentEndEvent(currentMessages))
        }

        stream
    }
}
