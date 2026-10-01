package atelier.session

import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*
import std.fs.*

func makeMsg(text: String): Message {
    UserMessage(ContentList.ofText(text), Int64(0))
}

func makeHeader(id: String): SessionHeader {
    SessionHeader(1, id, 100, 100, "gpt-4o", "openai", "helpful", None)
}

func addSession(store: MemorySessionStore, id: String, texts: ArrayList<String>): Unit {
    let msgs = ArrayList<Message>()
    for (t in texts) { msgs.add(makeMsg(t)) }
    store.save(id, makeHeader(id), msgs)
}

func count(store: MemorySessionStore): Int64 {
    store.list().size
}

// 每个用例一个独立临时目录；closeAndClean 只删自己那一个。
//
// 旧写法是 `remove(Path("/tmp"), recursive: true)` —— 它删的是**整个 /tmp**：并发跑的
// 其它用例的数据目录、并发编译的 /tmp/cangjie-tmp-* 都会被连带清掉，表现为「测试随机
// 失败」（list/load 少数据）与「链接期莫名 undefined reference」（本工作区实测踩到过）。
func stormStore(): (StormSessionStore, Path) {
    let dir = Directory.createTemp(Path("/tmp"))
    (StormSessionStore(dir.toString()), dir)
}

func closeAndClean(store: StormSessionStore, dir: Path): Unit {
    try { store.close() } catch (_) { () }
    try { remove(dir, recursive: true) } catch (_) { () }
}

@Test
func memory_saveAndLoad() {
    let store = MemorySessionStore()
    addSession(store, "s1", ArrayList<String>(["hi", "hello"]))
    @Expect(store.load("s1").size, 2)
}

@Test
func memory_list() {
    let store = MemorySessionStore()
    addSession(store, "a", ArrayList())
    addSession(store, "b", ArrayList())
    @Expect(count(store), 2)
}

@Test
func memory_delete() {
    let store = MemorySessionStore()
    addSession(store, "s1", ArrayList())
    store.delete("s1")
    @Expect(count(store), 0)
}

@Test
func memory_pathToLeaf() {
    let e1 = Entry("e1", None, 0, makeMsg("a"))
    let e2 = Entry("e2", Some("e1"), 0, makeMsg("b"))
    let e3 = Entry("e3", Some("e2"), 0, makeMsg("c"))
    let entries = ArrayList<Entry>([e1, e2, e3])
    let path = pathToLeaf(entries, "e3")
    @Expect(path.size, 3)
    @Expect(path[0].id, "e1")
    @Expect(path[2].id, "e3")
}

@Test
func storm_saveAndLoad() {
    let (store, dir) = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("hello"))
    msgs.add(makeMsg("world"))
    store.save("test_s1", makeHeader("test_s1"), msgs)
    let loaded = store.load("test_s1")
    @Expect(loaded.size, 2)
    closeAndClean(store, dir)
}

@Test
func storm_list() {
    let (store, dir) = stormStore()
    store.save("l1", makeHeader("l1"), ArrayList<Message>())
    store.save("l2", makeHeader("l2"), ArrayList<Message>())
    @Expect(store.list().size, 2)
    closeAndClean(store, dir)
}

@Test
func storm_delete() {
    let (store, dir) = stormStore()
    store.save("d1", makeHeader("d1"), ArrayList<Message>())
    store.delete("d1")
    @Expect(store.list().size, 0)
    closeAndClean(store, dir)
}

@Test
func storm_appendBranch() {
    let (store, dir) = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("first"))
    store.save("ab1", makeHeader("ab1"), msgs)
    let data = store.loadEntries("ab1")
    let leafId = data.entries[0].id
    let more = ArrayList<Message>()
    more.add(makeMsg("second"))
    store.appendBranch("ab1", leafId, more)
    @Expect(store.load("ab1").size, 2)
    closeAndClean(store, dir)
}

@Test
func appendBranch_archiveEntryKeepsOriginal() {
    let (store, dir) = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("m0"))
    msgs.add(makeMsg("m1"))
    store.save("aa1", makeHeader("aa1"), msgs)
    let data = store.loadEntries("aa1")
    let leafId = data.entries[1].id
    let arch = ArrayList<Message>()
    arch.add(ArchiveMessage(0, 1, "摘要", 0))
    store.appendBranch("aa1", leafId, arch)
    let entries = store.loadEntries("aa1")
    @Expect(entries.entries.size, 3)
    @Expect(store.load("aa1").size, 3)
    match (entries.entries[2].message) {
        case am: ArchiveMessage =>
            @Expect(am.startIndex, 0)
            @Expect(am.endIndex, 1)
            @Expect(am.summary, "摘要")
        case _ => @Fail("expected ArchiveMessage as appended entry")
    }
    closeAndClean(store, dir)
}

@Test
func storm_fork() {
    let (store, dir) = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("root"))
    msgs.add(makeMsg("child"))
    store.save("fk1", makeHeader("fk1"), msgs)
    let data = store.loadEntries("fk1")
    let leafId = data.entries[1].id
    let fork = store.fork("fk1", leafId)
    @Expect(fork.entries.size, 2)
    closeAndClean(store, dir)
}

// ========== 消息 metadata 通道（宿主业务数据随消息持久化；不参与语义比较） ==========

@Test
func entry_metadataRoundTrip_viaEntriesJson() {
    let md = HashMap<String, String>()
    md["taskId"] = "t-9"
    let u = UserMessage(ContentList.ofText("干活"), 0, metadata: md)
    let entries = ArrayList<Entry>()
    entries.add(Entry("e1", None, 0, u))
    let back = entriesFromJson(entriesToJson(entries))
    @Expect(back.size, 1)
    match (back[0].message) {
        case um: UserMessage =>
            @Expect(um.metadata["taskId"], "t-9")
        case _ => @Fail("expected UserMessage")
    }
}

@Test
func sameMessage_ignoresMetadata() {
    let md1 = HashMap<String, String>()
    md1["tag"] = "a"
    let md2 = HashMap<String, String>()
    md2["tag"] = "b"
    let a = UserMessage(ContentList.ofText("hello"), 0, metadata: md1)
    let b = UserMessage(ContentList.ofText("hello"), 0, metadata: md2)
    @Expect(sameMessage(a, b), true)
}

// ========== 压缩事务台账（审计 + 中断残留） ==========

func openRecord(id: String, sessionId: String, trigger: String, startedAt: Int64): CompactionRecord {
    CompactionRecord(id, sessionId, trigger, startedAt, 0, 100, 0, 5, 0, "open")
}

func finishRecord(id: String, sessionId: String, trigger: String, startedAt: Int64): CompactionRecord {
    CompactionRecord(id, sessionId, trigger, startedAt, startedAt + 7, 100, 40, 5, 2, "replaced")
}

@Test
func compactionJournal_memoryStoreRoundTrip() {
    let store = MemorySessionStore()
    store.appendCompaction(openRecord("c1", "s1", "manual", 100))
    store.appendCompaction(finishRecord("c1", "s1", "manual", 100))
    store.appendCompaction(openRecord("c2", "s1", "pressure", 200))
    store.appendCompaction(finishRecord("c2", "s1", "pressure", 200))
    // 别的会话互不干扰
    store.appendCompaction(openRecord("c3", "s2", "overflow", 300))

    let s1 = store.loadCompactions("s1")
    @Expect(s1.size, 4)
    @Expect(s1[0].compactionId, "c1")
    @Expect(s1[0].outcome, "open")
    @Expect(s1[0].finishedAt, 0)
    @Expect(s1[1].outcome, "replaced")
    @Expect(s1[1].tokensAfter, 40)
    @Expect(s1[1].messagesAfter, 2)
    @Expect(store.loadCompactions("s2").size, 1)
    @Expect(store.loadCompactions("nope").size, 0)
}

@Test
func compactionJournal_stormStoreRoundTrip() {
    let (store, dir) = stormStore()
    store.appendCompaction(openRecord("c1", "sess_j", "manual", 100))
    store.appendCompaction(finishRecord("c1", "sess_j", "manual", 100))
    // 重新打开连接读：确认真落盘（不是内存里记得）
    store.close()
    let reopened = StormSessionStore(dir.toString())
    let records = reopened.loadCompactions("sess_j")
    @Expect(records.size, 2)
    @Expect(records[0].compactionId, "c1")
    @Expect(records[0].trigger, "manual")
    @Expect(records[0].tokensBefore, 100)
    @Expect(records[1].finishedAt, 107)
    @Expect(records[1].outcome, "replaced")
    // 没有台账的会话读到空列表，不抛
    @Expect(reopened.loadCompactions("other").size, 0)
    closeAndClean(reopened, dir)
}

@Test
func compactionJournal_interruptedDetection() {
    let records = ArrayList<CompactionRecord>()
    records.add(openRecord("c1", "s1", "manual", 100))
    records.add(finishRecord("c1", "s1", "manual", 100))
    records.add(openRecord("c2", "s1", "pressure", 200))
    records.add(finishRecord("c3", "s1", "overflow", 300))

    let interrupted = interruptedCompactions(records)
    @Expect(interrupted.size, 1)
    @Expect(interrupted[0].compactionId, "c2")
    // 全部闭合：没有残留
    let clean = ArrayList<CompactionRecord>()
    clean.add(openRecord("c9", "s1", "manual", 1))
    clean.add(finishRecord("c9", "s1", "manual", 1))
    @Expect(interruptedCompactions(clean).size, 0)
    // 记录 JSON 往返不丢字段（落盘走这条）
    let back = fromJsonString<ArrayList<CompactionRecord>>(toJsonString(records))
    @Expect(back.size, 4)
    @Expect(back[3].tokensAfter, 40)
    @Expect(back[2].outcome, "open")
}

// 默认实现：不落台账的存储按契约返回空、写入不抛
@Test
func compactionJournal_defaultImplementationIsNoop() {
    let store = NoJournalStore()
    store.appendCompaction(openRecord("c1", "s1", "manual", 1))
    @Expect(store.loadCompactions("s1").size, 0)
}

class NoJournalStore <: SessionStore {
    private let inner = MemorySessionStore()
    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        this.inner.save(id, header, messages)
    }
    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        this.inner.appendBranch(id, parentLeafId, messages)
    }
    public func load(id: String): ArrayList<Message> { this.inner.load(id) }
    public func loadEntries(id: String): SessionData { this.inner.loadEntries(id) }
    public func list(): ArrayList<SessionHeader> { this.inner.list() }
    public func delete(id: String): Unit { this.inner.delete(id) }
    public func fork(sourceId: String, leafId: String): SessionData { this.inner.fork(sourceId, leafId) }
}
