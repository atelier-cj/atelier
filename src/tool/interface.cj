package atelier.tool

import jsonvalue.*

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

    public init(workDir: String) {
        this.workDir = workDir
        this.askUser = { q => "" }
    }

    public init(workDir: String, askUser: AskUserFn) {
        this.workDir = workDir
        this.askUser = askUser
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
