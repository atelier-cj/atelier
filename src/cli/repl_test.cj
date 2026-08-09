package atelier.cli

import atelier.message.*
import std.collection.*

func plain(text: String): Message { UserMessage(ContentList.ofText(text), 0) }

func asst(text: String): Message {
    AssistantMessage(ContentList.ofText(text), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
}

@Test
func extractNewMessages_basic() {
    let oldMsgs = ArrayList<Message>()
    oldMsgs.add(plain("a"))
    oldMsgs.add(plain("b"))
    let newMsgs = ArrayList<Message>()
    newMsgs.add(plain("a"))
    newMsgs.add(plain("b"))
    newMsgs.add(plain("c"))
    let out = extractNewMessages(oldMsgs, newMsgs)
    @Expect(out.size, 1)
    match (out[0]) {
        case um: UserMessage => @Expect(textOfMsg(um), "c")
        case _ => @Fail("expected c")
    }
}

// 压缩轮：oldMsgs 尾部消息在 newMsgs 中仍存在（内容比较定位），其后新消息提取正确
@Test
func extractNewMessages_compactionShift() {
    let oldMsgs = ArrayList<Message>()
    oldMsgs.add(plain("a"))
    oldMsgs.add(plain("b"))
    let newMsgs = ArrayList<Message>()
    newMsgs.add(CompactionMessage("摘要", 10, 0))
    newMsgs.add(plain("b"))      // 旧尾部消息仍在
    newMsgs.add(plain("c"))      // 新消息
    let out = extractNewMessages(oldMsgs, newMsgs)
    @Expect(out.size, 1)
    match (out[0]) {
        case um: UserMessage => @Expect(textOfMsg(um), "c")
        case _ => @Fail("expected c")
    }
}

// 归档轮：本轮归档产生的 ArchiveMessage 位于旧尾部消息之后，一并提取
@Test
func extractNewMessages_archiveAfterOldTail() {
    let oldMsgs = ArrayList<Message>()
    oldMsgs.add(plain("a"))
    oldMsgs.add(plain("b"))
    oldMsgs.add(plain("新输入"))   // oldMsgs 尾 = 本轮新用户输入
    let newMsgs = ArrayList<Message>()
    newMsgs.add(plain("a"))
    newMsgs.add(plain("b"))
    newMsgs.add(plain("新输入"))
    newMsgs.add(ArchiveMessage(2, 2, "摘要", 0))   // 本轮归档产生
    newMsgs.add(asst("回复"))
    let out = extractNewMessages(oldMsgs, newMsgs)
    @Expect(out.size, 2)
    match (out[1]) {
        case am: AssistantMessage => @Expect(textOfMsg(am), "回复")
        case _ => @Fail("expected assistant reply")
    }
}

// 重复内容：定位取最后匹配，之后的消息才是新增
@Test
func extractNewMessages_duplicateTailTakesLastMatch() {
    let oldMsgs = ArrayList<Message>()
    oldMsgs.add(plain("x"))
    let newMsgs = ArrayList<Message>()
    newMsgs.add(plain("x"))
    newMsgs.add(plain("x"))
    newMsgs.add(plain("y"))
    let out = extractNewMessages(oldMsgs, newMsgs)
    @Expect(out.size, 1)
    match (out[0]) {
        case um: UserMessage => @Expect(textOfMsg(um), "y")
        case _ => @Fail("expected y")
    }
}

@Test
func extractNewMessages_emptyOld() {
    let oldMsgs = ArrayList<Message>()
    let newMsgs = ArrayList<Message>()
    newMsgs.add(plain("a"))
    @Expect(extractNewMessages(oldMsgs, newMsgs).size, 1)
}

@Test
func sameMessage_userText() {
    @Expect(sameMessage(plain("hello"), plain("hello")), true)
    @Expect(sameMessage(plain("hello"), plain("world")), false)
}

@Test
func sameMessage_diffRoles() {
    @Expect(sameMessage(plain("a"), asst("a")), false)
    @Expect(sameMessage(asst("a"), plain("a")), false)
}

@Test
func sameMessage_archiveByRangeSummary() {
    let a: Message = ArchiveMessage(1, 2, "摘要", 0)
    let b: Message = ArchiveMessage(1, 2, "摘要", 0)
    let c: Message = ArchiveMessage(1, 2, "其他", 0)
    let d: Message = ArchiveMessage(2, 2, "摘要", 0)
    @Expect(sameMessage(a, b), true)
    @Expect(sameMessage(a, c), false)
    @Expect(sameMessage(a, d), false)
}

@Test
func sameMessage_compactionBySummary() {
    let a: Message = CompactionMessage("摘要", 10, 0)
    let b: Message = CompactionMessage("摘要", 20, 0)
    @Expect(sameMessage(a, b), true)
}

@Test
func sameMessage_toolResultById() {
    let a: Message = ToolResultMessage("call_1", "read_file", ContentList.ofText("内容"), false, 0)
    let b: Message = ToolResultMessage("call_1", "read_file", ContentList.ofText("内容2"), false, 0)
    let c: Message = ToolResultMessage("call_2", "read_file", ContentList.ofText("内容"), false, 0)
    @Expect(sameMessage(a, b), true)
    @Expect(sameMessage(a, c), false)
}
