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

// 截断保留最近 max 条；窗口外的 ArchiveMessage（历史归档标记）保留在最前。
//
// **契约：保留下来的一切仍声明同一批「历史绝对下标」**。
// `ArchiveMessage.startIndex/endIndex` 记的是消息在**历史**里的绝对位置（不是它在某个
// 列表里的循环下标），而 `ContextBuilder.applyArchiveMarks` 正是拿当前列表下标去比这个
// 范围。截断丢掉头部若干条普通消息后，剩下的消息在列表里整体前移，而 Archive 记的范围
// 不变 —— 于是那个范围会指到「现在这个位置上的另一批消息」上，`applyArchiveMarks` 把
// 窗口内本该保留的普通消息当成「已归档」静默吃掉。误吃通常只发生在范围与窗口的交叠处，
// 所以 `applyArchiveMarks` 那句「全部被跳过则回退原列表」的兜底救不到。
//
// 因此保留下来的 Archive 必须**按下标平移**：丢掉几条普通消息就整体往前挪几位。
// 平移之后，Archive 声明的范围与「它在原历史里指的那些消息」始终对齐：
// **被继续吃掉的普通消息数 = 原范围里仍然存在于窗口内的那几条**，已经不在窗口里的
// 消息不会被重复计一次。
//
// 平移量只数**普通消息**：Archive 自身被保留，不算"被丢掉"。
// 这一点必须在构造结果**之前**一次算完 —— 边扫边累加会让位于头部最前面的 Archive
// 拿到 0 平移量，等于没修。
//
// 范围整体落到窗口之前（原范围里的消息全被截掉了）时，要表达成**空范围**而不是把
// 下界钳成 [0,0]：钳成 [0,0] 会让它转而吃掉窗口里的第一条消息 —— 那正是本条要消除的
// 那类误伤。空范围用 `end = start - 1` 表达（`applyArchiveMarks` 的 `i >= s && i <= e`
// 对任何下标都不成立）。
//
// SessionLoop/ACP bridge/REPL 共用同一语义。
public func truncateMessages(messages: ArrayList<Message>, max: Int64): ArrayList<Message> {
    if (messages.size <= max) { return messages }
    let start = messages.size - max
    // 先数完：窗口外被丢掉的普通消息条数 = 保留下来的 Archive 需要前移的位数
    var dropped: Int64 = 0
    for (i in 0..start) {
        match (messages[Int64(i)]) {
            case _: ArchiveMessage => ()
            case _ => dropped++
        }
    }
    let result = ArrayList<Message>()
    // 窗口外的 Archive 提到最前（保留摘要，它是被归档历史唯一的可见描述）
    for (i in 0..start) {
        match (messages[Int64(i)]) {
            case am: ArchiveMessage => result.add(shiftArchive(am, dropped))
            case _ => ()
        }
    }
    // 窗口内的消息原样保留；其中若也有 Archive，范围同样要平移
    for (i in start..messages.size) {
        match (messages[Int64(i)]) {
            case am: ArchiveMessage => result.add(shiftArchive(am, dropped))
            case other => result.add(other)
        }
    }
    result
}

// 按「被丢掉的普通消息条数」平移归档范围。
//
// **为什么平移量就是 `dropped`**：被保留的普通消息原先在绝对位置 p（p >= start），
// 它在新列表里的下标是 `h + (p - start)`（h = 提到最前的 Archive 条数）；
// 而 `p - dropped = p - (start - h) = h + (p - start)`，两者相等 —— 平移量与
// 「把窗口外普通消息从计数里去掉」恰好是同一件事。
//
// 平移后若范围整体落到窗口之前（`end < 0`），表达成**空范围**（`end = start - 1`）：
// 此时范围内已经没有幸存消息，什么也不该跳过。若把它钳成 `[0,0]`，反而会吃掉窗口里
// 的第一条消息 —— 那正是本条要消除的那类误伤。
//
// ArchiveMessage 不可变，故重新构造并带上 metadata（宿主业务元数据要随消息继续 roundtrip）。
private func shiftArchive(am: ArchiveMessage, dropped: Int64): ArchiveMessage {
    var s = am.startIndex - dropped
    var e = am.endIndex - dropped
    if (e < 0) {
        // 范围内已无幸存消息：空范围（end < start，任何下标都不命中）
        s = 0
        e = -1
    } else {
        if (s < 0) { s = 0 }
        if (e < s) { e = s - 1 }
    }
    ArchiveMessage(s, e, am.summary, am.timestamp, metadata: am.metadata)
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
