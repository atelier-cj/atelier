package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.tool.ExternalRequest
import atelier.event.EventStream

public interface AgentEvent {
    func eventType(): String
}

public class AgentStartEvent <: AgentEvent {
    public let sessionId: String
    public init(sessionId: String) { this.sessionId = sessionId }
    public func eventType(): String { "agent_start" }
}

public class AgentEndEvent <: AgentEvent {
    public let messages: ArrayList<Message>
    public init(messages: ArrayList<Message>) { this.messages = messages }
    public func eventType(): String { "agent_end" }
}

public class TurnStartEvent <: AgentEvent {
    public init() {}
    public func eventType(): String { "turn_start" }
}

public class TurnEndEvent <: AgentEvent {
    public let message: AssistantMessage
    public let toolResults: ArrayList<ToolResultMessage>
    public init(message: AssistantMessage, toolResults: ArrayList<ToolResultMessage>) {
        this.message = message; this.toolResults = toolResults
    }
    public func eventType(): String { "turn_end" }
}

/**
 * 压缩事务开始：与 [CompactionEndEvent] 成对，同一个 compactionId 一开一合。
 *
 * 括弧的意义是把"重写历史"这件事变成可观测量：消费端据此显示进度、审计一次压缩
 * 覆盖了多少、以及发现只开不合的残迹。[trigger] 标明是哪条路触发的
 * （"pressure" = 请求前压力越阈值；"overflow" = provider 报超窗后的恢复）。
 */
public class CompactionStartEvent <: AgentEvent {
    public let compactionId: String
    public let trigger: String
    public let tokensBefore: Int64
    public init(compactionId: String, trigger: String, tokensBefore: Int64) {
        this.compactionId = compactionId
        this.trigger = trigger
        this.tokensBefore = tokensBefore
    }
    public func eventType(): String { "compaction_start" }
}

/**
 * 压缩事务结束：一定与同一 compactionId 的 [CompactionStartEvent] 配对。
 *
 * [messagesAfter] 等于 [messagesBefore] 表示"尝试过但没替换"（摘要失败且无兜底、
 * 或压无可压）——括弧照样闭合，不留悬挂状态。
 */
public class CompactionEndEvent <: AgentEvent {
    public let compactionId: String
    public let trigger: String
    public let messagesBefore: Int64
    public let messagesAfter: Int64
    public let tokensAfter: Int64
    public init(compactionId: String, trigger: String, messagesBefore: Int64,
        messagesAfter: Int64, tokensAfter: Int64) {
        this.compactionId = compactionId
        this.trigger = trigger
        this.messagesBefore = messagesBefore
        this.messagesAfter = messagesAfter
        this.tokensAfter = tokensAfter
    }
    public func eventType(): String { "compaction_end" }
}

public class MessageStartEvent <: AgentEvent {
    public let message: Message
    public init(message: Message) { this.message = message }
    public func eventType(): String { "message_start" }
}

public class MessageUpdateEvent <: AgentEvent {
    public let message: Message
    public let delta: String
    public init(message: Message, delta: String) { this.message = message; this.delta = delta }
    public func eventType(): String { "message_update" }
}

public class MessageEndEvent <: AgentEvent {
    public let message: Message
    public init(message: Message) { this.message = message }
    public func eventType(): String { "message_end" }
}

public class ToolExecutionStartEvent <: AgentEvent {
    public let toolCallId: String; public let toolName: String
    public init(toolCallId: String, toolName: String) { this.toolCallId = toolCallId; this.toolName = toolName }
    public func eventType(): String { "tool_execution_start" }
}

public class ToolExecutionUpdateEvent <: AgentEvent {
    public let toolCallId: String; public let progress: String
    public init(toolCallId: String, progress: String) { this.toolCallId = toolCallId; this.progress = progress }
    public func eventType(): String { "tool_execution_update" }
}

public class ToolExecutionEndEvent <: AgentEvent {
    public let toolCallId: String; public let result: String; public let isError: Bool
    public init(toolCallId: String, result: String, isError: Bool) {
        this.toolCallId = toolCallId; this.result = result; this.isError = isError
    }
    public func eventType(): String { "tool_execution_end" }
}

/**
 * 本次运行挂起：等待外部结果（前端执行工具、用户确认……）。
 *
 * 挂起不是失败：历史停在 assistant(tool_calls)，调用方带结果发起下一次 run 即可继续。
 * 消费者见本事件后不应再期待后续回合。
 */
public class SuspendEvent <: AgentEvent {
    public let requests: ArrayList<ExternalRequest>
    public init(requests: ArrayList<ExternalRequest>) { this.requests = requests }
    public func eventType(): String { "suspend" }
}

public class CompactionEvent <: AgentEvent {
    public let reason: String; public let tokensBefore: Int64; public let tokensAfter: Int64
    public init(reason: String, tokensBefore: Int64, tokensAfter: Int64) {
        this.reason = reason; this.tokensBefore = tokensBefore; this.tokensAfter = tokensAfter
    }
    public func eventType(): String { "compaction" }
}

public type LoopEventStream = EventStream<AgentEvent, ArrayList<Message>>
