package atelier.context

import atelier.message.*
import std.collection.*

public func compactMessages(messages: ArrayList<Message>, contextWindow: Int64, reserveTokens: Int64, keepRecentTokens: Int64): ArrayList<Message> {
    let total = estimateTokens(messages)
    if (total <= reserveTokens || contextWindow == 0) {
        return messages  // no compaction needed
    }

    let threshold = contextWindow - reserveTokens
    if (total <= threshold) {
        return messages
    }

    // Simple strategy: keep the last keepRecentTokens worth of messages,
    // summarize everything before that
    var running: Int64 = 0
    var cutIndex: Int64 = 0
    var i = messages.size - 1
    while (i >= 0 && running < keepRecentTokens) {
        running += estimateMessageTokens(messages[i])
        i--
    }
    cutIndex = i + 1

    if (cutIndex <= 0) {
        return messages  // all messages fit
    }

    // Replace cut messages with a summary
    let compacted = ArrayList<Message>()
        let subList = ArrayList<Message>()
        for (k in 0..cutIndex) { subList.add(messages[Int64(k)]) }
        compacted.add(CompactionMessage("... ${cutIndex} previous messages summarized ...", estimateTokens(subList), 0))
        for (j in cutIndex..Int64(messages.size)) {
        compacted.add(messages[Int64(j)])
    }
    compacted
}
