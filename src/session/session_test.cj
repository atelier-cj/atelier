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
