package atelier.session

import std.collection.*
import atelier.message.*

// 通用回合落库：把本次 run 新增消息追加到会话树（首轮 save 创建）。
// oldLoaded 传「加载时的全量消息」（勿传截断后子集——保证本轮 user 与回复都被追加）。
// 返回错误消息字符串（成功为 None）；由调用方决定日志/告警策略。
public func persistAppend(store: SessionStore, sessionId: String,
    oldLoaded: ArrayList<Message>, all: ArrayList<Message>): ?String {
    persistAppendWithParent(store, sessionId, oldLoaded, all, None)
}

// 同上，但首轮 save 时在 SessionHeader 记录 parentSession（子 agent 会话标记父会话用）
public func persistAppendWithParent(store: SessionStore, sessionId: String,
    oldLoaded: ArrayList<Message>, all: ArrayList<Message>, parentSession: ?String): ?String {
    let newMsgs = extractNewMessages(oldLoaded, all)
    if (newMsgs.size == 0) { return None }
    let lastLeaf: Option<String> = try {
        let data = store.loadEntries(sessionId)
        if (data.entries.size > 0) { Some(data.entries[data.entries.size - 1].id) } else { None }
    } catch (_) {
        // 首轮（会话尚未落库）正常路径；其它异常一并走 save 分支兜底
        None
    }
    match (lastLeaf) {
        case Some(leaf) =>
            try {
                store.appendBranch(sessionId, leaf, newMsgs)
                None
            } catch (e: Exception) {
                Some("appendBranch: ${e.message}")
            }
        case None =>
            try {
                let header = SessionHeader(1, sessionId, 0, 0, "", "", "", parentSession)
                store.save(sessionId, header, all)
                None
            } catch (e: Exception) {
                Some("save: ${e.message}")
            }
    }
}

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
