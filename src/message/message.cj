package atelier.message

import std.collection.*

public struct TokenUsage {
    let inputTokens: Int64
    let outputTokens: Int64

    public init(inputTokens: Int64, outputTokens: Int64) {
        this.inputTokens = inputTokens
        this.outputTokens = outputTokens
    }
}

sealed interface Message {
    func role(): MessageRole
}

public class UserMessage <: Message {
    public let content: ContentList
    public let timestamp: Int64

    public init(content: ContentList, timestamp: Int64) {
        this.content = content
        this.timestamp = timestamp
    }

    public func role(): MessageRole {
        MessageRole.User
    }
}

public class AssistantMessage <: Message {
    public let content: ContentList
    public let model: String
    public let provider: String
    public let stopReason: StopReason
    public let usage: TokenUsage
    public let timestamp: Int64
    public let reasoningContent: String

    public init(
        content: ContentList,
        model: String,
        provider: String,
        stopReason: StopReason,
        usage: TokenUsage,
        timestamp: Int64,
        reasoningContent: String
    ) {
        this.content = content
        this.model = model
        this.provider = provider
        this.stopReason = stopReason
        this.usage = usage
        this.timestamp = timestamp
        this.reasoningContent = reasoningContent
    }

    public init(
        content: ContentList,
        model: String,
        provider: String,
        stopReason: StopReason,
        usage: TokenUsage,
        timestamp: Int64
    ) {
        this.content = content
        this.model = model
        this.provider = provider
        this.stopReason = stopReason
        this.usage = usage
        this.timestamp = timestamp
        this.reasoningContent = ""
    }

    public func role(): MessageRole {
        MessageRole.Assistant
    }

    public func toolCalls(): ArrayList<ToolCallBlock> {
        return this.content.toolCalls()
    }
}

public class ToolResultMessage <: Message {
    public let toolCallId: String
    public let toolName: String
    public let content: ContentList
    public let isError: Bool
    public let timestamp: Int64

    public init(
        toolCallId: String,
        toolName: String,
        content: ContentList,
        isError: Bool,
        timestamp: Int64
    ) {
        this.toolCallId = toolCallId
        this.toolName = toolName
        this.content = content
        this.isError = isError
        this.timestamp = timestamp
    }

    public func role(): MessageRole {
        MessageRole.ToolResult
    }
}

public class CompactionMessage <: Message {
    public let summary: String
    public let tokensBefore: Int64
    public let timestamp: Int64

    public init(summary: String, tokensBefore: Int64, timestamp: Int64) {
        this.summary = summary
        this.tokensBefore = tokensBefore
        this.timestamp = timestamp
    }

    public func role(): MessageRole {
        MessageRole.Compaction
    }
}

public class ArchiveMessage <: Message {
    public let startIndex: Int64
    public let endIndex: Int64
    public let summary: String
    public let timestamp: Int64

    public init(startIndex: Int64, endIndex: Int64, summary: String, timestamp: Int64) {
        this.startIndex = startIndex
        this.endIndex = endIndex
        this.summary = summary
        this.timestamp = timestamp
    }

    public func role(): MessageRole {
        MessageRole.Archive
    }
}
