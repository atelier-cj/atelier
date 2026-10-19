package atelier.session

/*
 * 截断与归档标记的配合（[truncateMessages]）。
 *
 * `ArchiveMessage.startIndex/endIndex` 记的是消息在**历史**里的绝对位置，
 * 而 `ContextBuilder.applyArchiveMarks` 用「当前列表下标」去比这个范围。
 * 截断丢掉头部若干条普通消息后，剩下的消息在列表里整体前移，Archive 记的范围却不变 ——
 * 那个范围于是指到「现在这个位置上的另一批消息」上，窗口内本该保留的普通消息被当成
 * 「已归档」静默吃掉。
 *
 * 不变量（本文件所有用例都在守它）：
 * **截断后 `applyArchiveMarks` 吃掉的普通消息数 = 归档原范围里仍然幸存的那几条**；
 * 已经不存在的消息不能被重复计一次。
 *
 * 常驻触发点：ACP 每回合 `maxLoad = 15`、SessionLoop 的加载窗口。
 */

import std.collection.*
import atelier.message.*

func a5Plain(text: String): Message {
    UserMessage(ContentList.ofText(text), Int64(0))
}

func a5PlainCount(messages: ArrayList<Message>): Int64 {
    var n: Int64 = 0
    for (m in messages) {
        match (m) {
            case _: ArchiveMessage => ()
            case _ => n++
        }
    }
    n
}

// 按**定义**算期望：归档声明范围 [s,e] ⊆ 原历史下标；
// 保留窗口是原下标 [windowStart, size)。
// 期望吃掉数 = 范围与窗口的交集大小（这些消息既在归档范围里、又还留在列表中）。
// 前提：窗口内没有 Archive（本文件的用例都满足，Archive 只出现在头部或范围之后）。
func a5ExpectedAte(messages: ArrayList<Message>, max: Int64): Int64 {
    let windowStart = messages.size - max
    if (windowStart < 0) { return Int64(0) }
    var ate: Int64 = 0
    for (m in messages) {
        match (m) {
            case am: ArchiveMessage =>
                var p = am.startIndex
                while (p <= am.endIndex) {
                    if (p >= windowStart && p < messages.size) { ate++ }
                    p++
                }
            case _ => ()
        }
    }
    ate
}

// 核心场景：头部一个 Archive(0,1) + 11 条普通消息，截断到最近 5 条。
// 归档声明的 m0/m1 早被截掉；修复前 applyArchiveMarks 会把当前窗口内第 1 条
// 正常消息当成"已归档"吃掉（实测 5 → 4）。
@Test
func truncate_archiveRangeShiftsWithDroppedMessages() {
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 1, "摘要", 0))
    var i: Int64 = 0
    while (i < 11) {
        msgs.add(a5Plain("m" + (i + 2).toString()))
        i++
    }
    let truncated = truncateMessages(msgs, 5)
    // 6 条 = 置顶的 Archive + 最近 5 条
    @Expect(truncated.size, Int64(6))
    @Expect(a5PlainCount(truncated), Int64(5))
    // 归档范围整体落在窗口之前 → 平移后为空范围，不跳过任何普通消息
    var shifted: Option<ArchiveMessage> = None
    for (m in truncated) {
        match (m) {
            case am: ArchiveMessage => shifted = Some(am)
            case _ => ()
        }
    }
    match (shifted) {
        case Some(am) =>
            @Expect(am.startIndex, Int64(0))
            // end < start 表示"范围内已无幸存消息"
            @Expect(am.endIndex < am.startIndex, true)
            // 摘要与 metadata 必须原样保留（宿主可见内容不因平移丢失）
            @Expect(am.summary, "摘要")
        case None => @Fail("ArchiveMessage 必须被保留在最前（它是被归档历史唯一的可见描述）")
    }
    @Expect(a5PlainCount(truncated) - a5PlainCount(afterMarks(truncated)), Int64(0))
}

// 组合断言（与上一条同场景，分开写成"损失数 = 期望数"的形式，便于回归时看清差异）
@Test
func truncate_thenMarks_onlyEatsStillPresentMessages() {
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 1, "摘要", 0))
    var i: Int64 = 0
    while (i < 11) {
        msgs.add(a5Plain("m" + (i + 2).toString()))
        i++
    }
    let expected = a5ExpectedAte(msgs, 5)
    let truncated = truncateMessages(msgs, 5)
    let before = a5PlainCount(truncated)
    let after = a5PlainCount(afterMarks(truncated))
    @Expect(before - after, expected)
    // 本场景归档里的消息全被截掉 → 一条都不该吃
    @Expect(expected, Int64(0))
}

// 归档范围**部分**落在保留窗口内：只吃仍然幸存的那几条，不许多吃
@Test
func truncate_thenMarks_eatsOnlySurvivingPartOfRange() {
    let msgs = ArrayList<Message>()
    var i: Int64 = 0
    while (i < 9) { msgs.add(a5Plain("m" + i.toString())); i++ }
    // 归档覆盖原下标 [5,8]
    msgs.add(ArchiveMessage(5, 8, "摘要", 0))
    while (i < 12) { msgs.add(a5Plain("m" + i.toString())); i++ }
    // 原表 13 条，窗口取最后 5 条 → 幸存原下标 8..12
    let expected = a5ExpectedAte(msgs, 5)
    let truncated = truncateMessages(msgs, 5)
    let before = a5PlainCount(truncated)
    let after = a5PlainCount(afterMarks(truncated))
    @Expect(before - after, expected)
    // 归档 [5,8] 中只有原下标 8 幸存 → 恰好 1 条
    @Expect(expected, Int64(1))
}

// 多个 Archive 同时被截断：每个都各自平移，互不叠加误伤
@Test
func truncate_multipleArchivesShiftIndependently() {
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 1, "摘要A", 0))
    msgs.add(ArchiveMessage(2, 3, "摘要B", 0))
    var i: Int64 = 0
    while (i < 10) { msgs.add(a5Plain("m" + i.toString())); i++ }
    let expected = a5ExpectedAte(msgs, 3)
    let truncated = truncateMessages(msgs, 3)
    let before = a5PlainCount(truncated)
    let after = a5PlainCount(afterMarks(truncated))
    @Expect(before - after, expected)
    // 两个归档的范围都落在窗口之前 → 0 条
    @Expect(expected, Int64(0))
    // 两条摘要都保留（不合并、不丢失）
    var archives: Int64 = 0
    for (m in truncated) {
        match (m) {
            case _: ArchiveMessage => archives++
            case _ => ()
        }
    }
    @Expect(archives, Int64(2))
}

// 没超过窗口时原样返回：不构造新列表，也不动下标
@Test
func truncate_withinWindowKeepsMessagesAndIndices() {
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 1, "摘要", 0))
    msgs.add(a5Plain("m0"))
    let out = truncateMessages(msgs, 5)
    @Expect(out.size, Int64(2))
    match (out[0]) {
        case am: ArchiveMessage =>
            @Expect(am.startIndex, Int64(0))
            @Expect(am.endIndex, Int64(1))
        case _ => @Fail("expected ArchiveMessage")
    }
}

// 平移时必须带上 metadata（宿主业务元数据随消息 roundtrip）
@Test
func truncate_shiftPreservesArchiveMetadata() {
    let meta = HashMap<String, String>()
    meta.add("source", "acp")
    let msgs = ArrayList<Message>()
    msgs.add(ArchiveMessage(0, 1, "摘要", 12345, metadata: meta))
    var i: Int64 = 0
    while (i < 11) { msgs.add(a5Plain("m" + (i + 2).toString())); i++ }
    let truncated = truncateMessages(msgs, 5)
    var found = false
    for (m in truncated) {
        match (m) {
            case am: ArchiveMessage =>
                found = true
                @Expect(am.summary, "摘要")
                @Expect(am.timestamp, Int64(12345))
                match (am.metadata.get("source")) {
                    case Some(v) => @Expect(v, "acp")
                    case None => @Fail("metadata 必须随平移一并保留")
                }
            case _ => ()
        }
    }
    @Expect(found, true)
}

// 调用 applyArchiveMarks 的便利封装（本包只依赖 atelier.message，不反向依赖 context 包，
// 因此这里用一个最小的等价实现：按范围跳过普通消息、保留 Archive）
//
// 等价性由 context 包自己的 applyArchiveMarks 用例保证；这里只关心"哪些下标会被跳过"，
// 而那正是两个实现共同的那一条规则（`i >= s && i <= e`）。
func afterMarks(messages: ArrayList<Message>): ArrayList<Message> {
    let ranges = ArrayList<(Int64, Int64)>()
    for (m in messages) {
        match (m) {
            case am: ArchiveMessage => ranges.add((am.startIndex, am.endIndex))
            case _ => ()
        }
    }
    let result = ArrayList<Message>()
    var i: Int64 = 0
    while (i < messages.size) {
        var skipped = false
        for ((s, e) in ranges) {
            if (i >= s && i <= e) { skipped = true; break }
        }
        if (!skipped) { result.add(messages[i]) }
        i++
    }
    // 与生产实现同一兜底：全部跳过时回退原列表（防空上下文）
    if (result.size == 0) { return messages }
    result
}
