package atelier.agent

import std.collection.*
import std.collection.concurrent.*
import std.sync.*
import atelier.message.*

public interface AgentEvent {
    func eventType(): String
}

public class AgentStartEvent <: AgentEvent {
    public let sessionId: String

    public init(sessionId: String) {
        this.sessionId = sessionId
    }

    public func eventType(): String {
        "agent_start"
    }
}

public class AgentEndEvent <: AgentEvent {
    public let messages: ArrayList<Message>

    public init(messages: ArrayList<Message>) {
        this.messages = messages
    }

    public func eventType(): String {
        "agent_end"
    }
}

public class TurnStartEvent <: AgentEvent {
    public init() {}

    public func eventType(): String {
        "turn_start"
    }
}

public class TurnEndEvent <: AgentEvent {
    public let message: AssistantMessage
    public let toolResults: ArrayList<ToolResultMessage>

    public init(message: AssistantMessage, toolResults: ArrayList<ToolResultMessage>) {
        this.message = message
        this.toolResults = toolResults
    }

    public func eventType(): String {
        "turn_end"
    }
}

public class MessageStartEvent <: AgentEvent {
    public let message: Message

    public init(message: Message) {
        this.message = message
    }

    public func eventType(): String {
        "message_start"
    }
}

public class MessageUpdateEvent <: AgentEvent {
    public let message: Message
    public let delta: String

    public init(message: Message, delta: String) {
        this.message = message
        this.delta = delta
    }

    public func eventType(): String {
        "message_update"
    }
}

public class MessageEndEvent <: AgentEvent {
    public let message: Message

    public init(message: Message) {
        this.message = message
    }

    public func eventType(): String {
        "message_end"
    }
}

public class ToolExecutionStartEvent <: AgentEvent {
    public let toolCallId: String
    public let toolName: String

    public init(toolCallId: String, toolName: String) {
        this.toolCallId = toolCallId
        this.toolName = toolName
    }

    public func eventType(): String {
        "tool_execution_start"
    }
}

public class ToolExecutionUpdateEvent <: AgentEvent {
    public let toolCallId: String
    public let progress: String

    public init(toolCallId: String, progress: String) {
        this.toolCallId = toolCallId
        this.progress = progress
    }

    public func eventType(): String {
        "tool_execution_update"
    }
}

public class ToolExecutionEndEvent <: AgentEvent {
    public let toolCallId: String
    public let result: String
    public let isError: Bool

    public init(toolCallId: String, result: String, isError: Bool) {
        this.toolCallId = toolCallId
        this.result = result
        this.isError = isError
    }

    public func eventType(): String {
        "tool_execution_end"
    }
}

public class CompactionEvent <: AgentEvent {
    public let reason: String
    public let tokensBefore: Int64
    public let tokensAfter: Int64

    public init(reason: String, tokensBefore: Int64, tokensAfter: Int64) {
        this.reason = reason
        this.tokensBefore = tokensBefore
        this.tokensAfter = tokensAfter
    }

    public func eventType(): String {
        "compaction"
    }
}

enum StreamSignal<R> {
    | Value(R)
    | Error(Exception)
}

public class EventStream<T, R> {
    let eventQueue: LinkedBlockingQueue<T>
    let signalQueue: LinkedBlockingQueue<StreamSignal<R>>
    let closed: AtomicBool

    public init() {
        eventQueue = LinkedBlockingQueue<T>()
        signalQueue = LinkedBlockingQueue<StreamSignal<R>>(1)
        closed = AtomicBool(false)
    }

    public func emit(event: T): Bool {
        if (closed.load()) {
            return false
        }
        eventQueue.add(event)
        return true
    }

    public func receive(): T {
        return eventQueue.remove()
    }

    public func receive(timeout: Duration): Option<T> {
        return eventQueue.remove(timeout)
    }

    public func setResult(r: R): Bool {
        return signalQueue.tryAdd(StreamSignal.Value(r))
    }

    public func setError(e: Exception): Bool {
        return signalQueue.tryAdd(StreamSignal.Error(e))
    }

    public func result(): R {
        let signal = signalQueue.remove()
        match (signal) {
            case Value(r) => return r
            case Error(e) => throw e
        }
    }

    public func close() {
        closed.store(true)
    }
}

public type LoopEventStream = EventStream<AgentEvent, ArrayList<Message>>
