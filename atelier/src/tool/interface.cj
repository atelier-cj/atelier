package atelier.tool

import std.collection.*
import jsonvalue.*
import atelier.interaction.{UserRequest, UserAnswer, UserAnswerStatus, UserRequestKind}
import std.collection.HashMap

/**
 * Execution mode for a tool.
 * - Parallel: the tool can be executed concurrently with other tools.
 * - Sequential: the tool must be executed sequentially (e.g., stateful tools).
 */
public enum ToolExecutionMode {
    | Parallel
    | Sequential
}

/**
 * Context passed to tool execution.
 * Provides runtime information such as working directory and user interaction.
 */
public type AskUserFn = (String) -> String

// 结构化提问（可选升级）：宿主实现它就能回答"审批/选择/表单"，并可用 Pending 表示挂起。
// 未提供时退回下面的字符串问答，行为与改造前一致 —— 升级是逐宿主进行的。
public type AskFn = (UserRequest) -> UserAnswer

/**
 * 结构化提问入口（审批 / 选择 / 表单）。
 *
 * 适配器语义：老宿主只提供 `askUser(String) -> String`，这里把它的答复映射成结构化结果 ——
 * 审批按历史约定认 "y"/"once"/"a"/"always"/"yes"，其余一律按拒绝处理，与改造前的行为一致。
 * 想支持挂起（AG-UI 那类"结束本次 run、下一次输入再答"）的宿主，直接构造 ToolContext 时
 * 传入自己的 askUser 实现返回 pending 语义的答复即可（见 docs/plans/2026-10-01-user-interaction-refactor.md）。
 */
extend ToolContext {
    public func ask(req: UserRequest): UserAnswer {
        // 宿主提供了结构化实现就用它（它能返回 Pending → 运行时据此挂起）
        match (this.askFn) {
            case Some(f) => return f(req)
            case None => ()
        }
        let raw = this.askUser(req.message)
        match (req.kind) {
            case UserRequestKind.Approval =>
                let selected = ArrayList<String>()
                if (raw == "a" || raw == "always" || raw == "yes") {
                    selected.add("allow_always")
                } else if (raw == "y" || raw == "once") {
                    selected.add("allow_once")
                } else {
                    selected.add("deny")
                }
                UserAnswer(req.id, UserAnswerStatus.Answered, selected: selected)
            case UserRequestKind.Choice =>
                if (raw == "") { return UserAnswer(req.id, UserAnswerStatus.Cancelled) }
                let selected = ArrayList<String>()
                selected.add(raw)
                UserAnswer(req.id, UserAnswerStatus.Answered, selected: selected, text: raw)
            case UserRequestKind.Form =>
                if (raw == "") { return UserAnswer(req.id, UserAnswerStatus.Cancelled) }
                UserAnswer(req.id, UserAnswerStatus.Answered, text: raw)
            case UserRequestKind.ToolExecution =>
                UserAnswer(req.id, UserAnswerStatus.Answered, text: raw)
        }
    }
}

public struct ToolContext {
    public let workDir: String
    public let askUser: AskUserFn
    public let env: HashMap<String, String>
    // 当前运行会话 id（无会话上下文时为空 ""）；子 agent 父向调度等场景使用
    public let sessionId: String
    // 本次工具调用的 id（LLM 侧 tool_call id；无调用上下文时为空 ""）。
    // 工具要把自己的执行与协议/UI 上的同一次调用对上（进度上报、等外部执行结果）时用得到它：
    // 一次调用一份上下文，而不是一个会话共用一份。
    public let toolCallId: String
    // 结构化提问实现（None = 走字符串问答适配器）
    public let askFn: Option<AskFn>

    public init(workDir: String) {
        this.workDir = workDir
        this.askUser = { q => "" }
        this.env = HashMap()
        this.sessionId = ""
        this.toolCallId = ""
        this.askFn = None
    }

    public init(workDir: String, askUser: AskUserFn) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = HashMap()
        this.sessionId = ""
        this.toolCallId = ""
        this.askFn = None
    }

    public init(workDir: String, askUser: AskUserFn, env: HashMap<String, String>) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = env
        this.sessionId = ""
        this.toolCallId = ""
        this.askFn = None
    }

    public init(workDir: String, askUser: AskUserFn, env: HashMap<String, String>, sessionId: String,
        toolCallId!: String = "", ask!: Option<AskFn> = None) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = env
        this.sessionId = sessionId
        this.toolCallId = toolCallId
        this.askFn = ask
    }
}

/**
 * Tool interface.
 * All tools must implement this interface to be registered in the ToolRegistry.
 */
public interface Tool {
    func name(): String
    func description(): String
    func schema(): JsonValue
    func execute(ctx: ToolContext, args: JsonValue): ToolResult
    func executionMode(): ToolExecutionMode
    /**
     * 该工具对自己时间预算的声明。
     *
     * 默认 `ToolBudget.Default`：交由框架策略决定。工具比框架更清楚自己需要多久，
     * 所以有两种更具体的声明方式——见 {@link ToolBudget}（声明额度 / 声明不该有预算）。
     */
    func timeoutBudget(): ToolBudget {
        ToolBudget.Default
    }
}

/**
 * Result of a tool execution.
 *
 * At this level, tools output plain text. The runtime wraps this into
 * a ToolResultMessage if needed for conversation history.
 */
public struct ToolResult {
    /** Primary text output of the tool execution. */
    public let text: String
    /** Structured details for UI/logging (optional). */
    public let details: Option<JsonValue>
    /** Whether the execution resulted in an error. */
    public let isError: Bool
    /** Whether this result should terminate the entire Run. */
    public let terminate: Bool
    /**
     * 本次调用要由**外部**给结果（前端执行、用户确认……）。
     *
     * 非 None 表示：本进程不产出结果，运行时挂起这次 run（不写结果消息，历史停在
     * assistant(tool_calls)），把中断交给调用方；调用方在**下一次** run 里带回结果。
     */
    public let external: Option<ExternalRequest>

    public init(
        text: String,
        details: Option<JsonValue>,
        isError: Bool,
        terminate: Bool,
        external!: Option<ExternalRequest> = None
    ) {
        this.text = text
        this.details = details
        this.isError = isError
        this.terminate = terminate
        this.external = external
    }
}

/**
 * 挂起请求：这次运行需要外部在之后提供结果。
 *
 * id 是跨 run 的关联键（调用方在恢复时原样回填）：同一个挂起被重复提交要幂等。
 */
public class ExternalRequest {
    public let id: String
    /** 分类：tool_call（绑定某次工具调用）/ input_required（要一段结构化输入） */
    public let reason: String
    /** 给人看的一句话（前端没有专用 UI 时的兜底展示） */
    public let message: String
    /** reason=tool_call 时绑定到的工具调用 id，否则为空 */
    public let toolCallId: String

    public init(id: String, reason: String, message: String, toolCallId!: String = "") {
        this.id = id
        this.reason = reason
        this.message = message
        this.toolCallId = toolCallId
    }
}
