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

/**
 * 一次回合结束的**真实原因**。
 *
 * 与 [StopReason] 的分工（两者都必要，不能互相替代）：
 * - `StopReason` 描述**模型这一条回复**怎么停的（自然结束 / 要调工具 / 被截断 …）；
 * - `TurnEndReason` 描述**这个回合**为什么收尾 —— 回合可能因为与模型无关的原因结束
 *   （工具预算耗尽、钩子短路、宿主要求挂起、调用方取消、内部失败）。
 *
 * 混用两者的后果：消费端会把「任务被预算掐断」当成「模型正常收尾」，
 * 于是该提示用户"预算用完了"的场景显示成"已完成"。
 *
 * **不带载荷**：错误细节留在 [TurnEndEvent.message] 里（provider 失败消息本就在
 * 那条 AssistantMessage 上）。一个事实不存两处 —— 否则两处会不一致，消费端还得猜
 * 该信哪个。
 */
public enum TurnEndReason {
    /** 模型自然收尾，无后续动作 */
    | Completed
    /** 工具调用预算耗尽：剩余调用未执行，历史里已补"未执行"结果 */
    | ToolBudgetExhausted
    /** `beforeTurn` 钩子短路了整个 run（本条回复是占位说明，不是模型产出） */
    | BlockedByHook
    /** 宿主要求先确认/补充：历史停在 `assistant(tool_calls)`，等下一次 run 带回结果 */
    | Suspended
    /** 调用方取消（协作式收敛，不是错误） */
    | Cancelled
    /** 失败：provider 不可恢复错误、工具批次异常、或运行时内部异常 */
    | Failed
    /**
     * 达到 `maxTurns` 上限：循环条件把回合数卡住，任务**没跑完**。
     *
     * 这条路径原本连 `TurnEndEvent` 都不发（循环条件直接为假退出），
     * 消费端因此看到一个"跑完了"的 run，实际是被上限掐断的 ——
     * 正是本枚举要消除的那类事实缺口。现在由收尾处补发一条事件。
     */
    | MaxTurnsReached
}

public class TurnEndEvent <: AgentEvent {
    public let message: AssistantMessage
    public let toolResults: ArrayList<ToolResultMessage>
    /**
     * 本回合为什么结束。
     *
     * **不设默认值**：默认值会把"旧的错误收尾"静默当成 `Completed`，
     * 而那正是这个字段要消除的那类事实缺口。构造点必须逐个给出正确原因，
     * 漏改会编译报错。
     */
    public let reason: TurnEndReason
    public init(message: AssistantMessage, toolResults: ArrayList<ToolResultMessage>,
        reason: TurnEndReason) {
        this.message = message; this.toolResults = toolResults; this.reason = reason
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
