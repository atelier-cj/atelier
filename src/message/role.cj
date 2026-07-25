package atelier.message

public enum MessageRole {
    | User
    | Assistant
    | ToolResult
    | Compaction
}

public enum StopReason {
    | EndTurn
    | ToolUse
    | Length
    | Error
    | Aborted
}
