package atelier.session

import atelier.message.*
import std.collection.*

/**
 * 计数用的替身存储：只关心「打开了几次、关了几次、转发了几次调用」。
 * 断言的是懒加载的**时序**，不是存储语义——那由 MemorySessionStore / file_store 各自的用例覆盖。
 */
class CountingStore <: SessionStore {
    public var saves: Int64 = 0
    public var loads: Int64 = 0
    public var closes: Int64 = 0

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        this.saves++
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        this.saves++
        id
    }

    public func load(id: String): ArrayList<Message> {
        this.loads++
        ArrayList<Message>()
    }

    public func loadEntries(id: String): SessionData {
        this.loads++
        SessionData(SessionHeader(1, id, 0, 0, "", "", "", None), ArrayList<Entry>())
    }

    public func list(): ArrayList<SessionHeader> { ArrayList<SessionHeader>() }

    public func delete(id: String): Unit {}

    public func fork(sourceId: String, leafId: String): SessionData {
        SessionData(SessionHeader(1, sourceId, 0, 0, "", "", "", None), ArrayList<Entry>())
    }

    public func close(): Unit { this.closes++ }
}

// 计数 + 替身：把「打开了几次」与「转发到哪个存储」放在一处，避免用例里散落元组
class FakeOpener {
    public var opens: Int64 = 0
    public let store = CountingStore()

    public func open(): SessionStore {
        this.opens = this.opens + 1
        this.store
    }

    public func lazyStore(): LazySessionStore {
        LazySessionStore({ => this.open() })
    }
}

@Test
public func lazyStore_constructionDoesNotOpen() {
    // 构造不能碰磁盘：--version / 未知命令只走到构造这一步
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    @Expect(lazyStore.isOpen(), false)
    @Expect(o.opens, 0)
}

@Test
public func lazyStore_firstReadOpensOnce() {
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    lazyStore.load("s1")
    @Expect(o.opens, 1)
    @Expect(lazyStore.isOpen(), true)
    @Expect(o.store.loads, 1)
    // 第二次不再打开：badgercj 只有进程内锁，重复打开同一目录会直接失败
    lazyStore.list()
    lazyStore.load("s2")
    @Expect(o.opens, 1)
    @Expect(o.store.loads, 2)
}

@Test
public func lazyStore_firstWriteOpens() {
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    lazyStore.save("s1", SessionHeader(1, "s1", 0, 0, "", "", "", None), ArrayList<Message>())
    @Expect(o.opens, 1)
    @Expect(o.store.saves, 1)
}

@Test
public func lazyStore_closeWithoutOpenDoesNothing() {
    // 这条是「不留下 .mem」的保证：没打开就没有要 flush 的 WAL
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    lazyStore.close()
    @Expect(o.opens, 0)
    @Expect(o.store.closes, 0)
}

@Test
public func lazyStore_closeAfterOpenClosesInner() {
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    lazyStore.load("s1")
    lazyStore.close()
    @Expect(o.store.closes, 1)
    @Expect(lazyStore.isOpen(), false)
}

@Test
public func lazyStore_reopenAfterCloseOpensAgain() {
    // 关掉之后再用：重新打开，不复用已关闭的实例（关闭后其内部资源已释放）
    let o = FakeOpener()
    let lazyStore = o.lazyStore()
    lazyStore.load("s1")
    lazyStore.close()
    lazyStore.load("s1")
    @Expect(o.opens, 2)
}
