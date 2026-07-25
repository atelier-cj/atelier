package atelier.session

import atelier.message.*
import std.collection.*

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
