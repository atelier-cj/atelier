package atelier.context

import atelier.message.*
import std.collection.*

public func estimateTokens(messages: ArrayList<Message>): Int64 {
    var total: Int64 = 0
    for (m in messages) { total += estimateMessageTokens(m) }
    total
}

public func estimateTextTokens(text: String): Int64 {
    Int64(text.size / 4)
}

func estimateMessageTokens(m: Message): Int64 {
    match (m) {
        case um: UserMessage =>
            var t: Int64 = 5
            for (b in um.content.blocks()) {
                match (b) {
                    case ContentBlock.TextBlock(s) => t += estimateTextTokens(s)
                    case _ => t += 10
                }
            }
            t
        case am: AssistantMessage =>
            var t: Int64 = 5
            for (b in am.content.blocks()) {
                match (b) {
                    case ContentBlock.TextBlock(s) => t += estimateTextTokens(s)
                    case ContentBlock.ToolCall(tc) => t += estimateTextTokens(tc.name) + 20
                    case _ => t += 10
                }
            }
            t
        case tm: ToolResultMessage =>
            var t: Int64 = 5
            for (b in tm.content.blocks()) {
                match (b) {
                    case ContentBlock.ToolResultBlock(_, r) => t += estimateTextTokens(r)
                    case _ => t += 10
                }
            }
            t
        case cm: CompactionMessage =>
            estimateTextTokens(cm.summary) + 20
        case _ => 50
    }
}
