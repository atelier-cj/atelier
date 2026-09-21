package atelier.tool

import jsonvalue.*
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

public struct ToolContext {
    public let workDir: String
    public let askUser: AskUserFn
    public let env: HashMap<String, String>
    // 当前运行会话 id（无会话上下文时为空 ""）；子 agent 父向调度等场景使用
    public let sessionId: String

    public init(workDir: String) {
        this.workDir = workDir
        this.askUser = { q => "" }
        this.env = HashMap()
        this.sessionId = ""
    }

    public init(workDir: String, askUser: AskUserFn) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = HashMap()
        this.sessionId = ""
    }

    public init(workDir: String, askUser: AskUserFn, env: HashMap<String, String>) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = env
        this.sessionId = ""
    }

    public init(workDir: String, askUser: AskUserFn, env: HashMap<String, String>, sessionId: String) {
        this.workDir = workDir
        this.askUser = askUser
        this.env = env
        this.sessionId = sessionId
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
     * 该工具自身的时间预算。
     *
     * 默认 `None`：交由框架配置（`AgentConfig.toolTimeout`）决定。
     * 返回非 `None` 时**优先**于框架配置——工具比框架更清楚自己需要多久，
     * 典型场景是内部还压着一层自己的预算：那层预算走完才会给出具体失败原因，
     * 被外层提前掐断只会得到一句笼统的「工具超时」。
     */
    func timeoutBudget(): Option<Duration> {
        None
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

    public init(
        text: String,
        details: Option<JsonValue>,
        isError: Bool,
        terminate: Bool
    ) {
        this.text = text
        this.details = details
        this.isError = isError
        this.terminate = terminate
    }
}
