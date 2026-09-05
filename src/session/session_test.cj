package atelier.session

import atelier.message.*
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

func stormStore(): StormSessionStore {
    let dir = Directory.createTemp(Path("/tmp"))
    StormSessionStore(dir.toString())
}

func closeAndClean(store: StormSessionStore): Unit {
    try { store.close() } catch (_) { () }
    try { remove(Path("/tmp"), recursive: true) } catch (_) { () }
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
    let store = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("hello"))
    msgs.add(makeMsg("world"))
    store.save("test_s1", makeHeader("test_s1"), msgs)
    let loaded = store.load("test_s1")
    @Expect(loaded.size, 2)
    closeAndClean(store)
}

@Test
func storm_list() {
    let store = stormStore()
    store.save("l1", makeHeader("l1"), ArrayList<Message>())
    store.save("l2", makeHeader("l2"), ArrayList<Message>())
    @Expect(store.list().size, 2)
    closeAndClean(store)
}

@Test
func storm_delete() {
    let store = stormStore()
    store.save("d1", makeHeader("d1"), ArrayList<Message>())
    store.delete("d1")
    @Expect(store.list().size, 0)
    closeAndClean(store)
}

@Test
func storm_appendBranch() {
    let store = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("first"))
    store.save("ab1", makeHeader("ab1"), msgs)
    let data = store.loadEntries("ab1")
    let leafId = data.entries[0].id
    let more = ArrayList<Message>()
    more.add(makeMsg("second"))
    store.appendBranch("ab1", leafId, more)
    @Expect(store.load("ab1").size, 2)
    closeAndClean(store)
}

@Test
func appendBranch_archiveEntryKeepsOriginal() {
    let store = stormStore()
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
    closeAndClean(store)
}

@Test
func storm_fork() {
    let store = stormStore()
    let msgs = ArrayList<Message>()
    msgs.add(makeMsg("root"))
    msgs.add(makeMsg("child"))
    store.save("fk1", makeHeader("fk1"), msgs)
    let data = store.loadEntries("fk1")
    let leafId = data.entries[1].id
    let fork = store.fork("fk1", leafId)
    @Expect(fork.entries.size, 2)
    closeAndClean(store)
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
