package atelier.session

import std.collection.*
import atelier.message.*

// 提取 newMsgs 中 oldMsgs 最后一条消息之后的消息（内容比较定位，兼容压缩/归档轮）。
// 定位失败（旧尾部被归档替换）时降级：差集法（newMsgs 中与 oldMsgs 全部不同的消息 = 新消息）。
// REPL 与 ACP 回合落库共用（runtime 不落库，由宿主统一追加）。
public func extractNewMessages(oldMsgs: ArrayList<Message>, newMsgs: ArrayList<Message>): ArrayList<Message> {
    if (oldMsgs.size == 0) { return newMsgs }
    let lastOld = oldMsgs[oldMsgs.size - 1]
    var startIdx: Int64 = -1
    var i: Int64 = 0
    while (i < newMsgs.size) {
        if (sameMessage(newMsgs[Int64(i)], lastOld)) { startIdx = i + 1 }
        i++
    }
    let result = ArrayList<Message>()
    if (startIdx >= 0) {
        for (j in startIdx..newMsgs.size) { result.add(newMsgs[Int64(j)]) }
    } else {
        // 降级：差集（newMsgs 中与 oldMsgs 全部不同 = 新消息）
        for (m in newMsgs) {
            var inOld = false
            for (o in oldMsgs) {
                if (sameMessage(m, o)) { inOld = true; break }
            }
            if (!inOld) { result.add(m) }
        }
    }
    result
}

// 消息内容等价（role + 文本比较；ArchiveMessage 按范围与摘要）
public func sameMessage(a: Message, b: Message): Bool {
    match (a) {
        case ua: UserMessage =>
            match (b) {
                case ub: UserMessage => textOfMsg(ua) == textOfMsg(ub)
                case _ => false
            }
        case aa: AssistantMessage =>
            match (b) {
                case ab: AssistantMessage =>
                    aa.content.blocks().size == ab.content.blocks().size && textOfMsg(aa) == textOfMsg(ab)
                case _ => false
            }
        case ta: ToolResultMessage =>
            match (b) {
                case tb: ToolResultMessage => ta.toolCallId == tb.toolCallId && ta.toolName == tb.toolName
                case _ => false
            }
        case ca: CompactionMessage =>
            match (b) {
                case cb: CompactionMessage => ca.summary == cb.summary
                case _ => false
            }
        case aa2: ArchiveMessage =>
            match (b) {
                case ab2: ArchiveMessage =>
                    aa2.startIndex == ab2.startIndex && aa2.endIndex == ab2.endIndex && aa2.summary == ab2.summary
                case _ => false
            }
        case _ => false
    }
}
