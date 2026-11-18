package atelier.session

import std.sync.*
import atelier.message.*
import std.collection.*

/**
 * 懒打开会话存储：第一次真正读写时才连库。
 *
 * 为什么不是「入口按命令判断要不要开库」：装配束（[HarnessSpec]）是唯一构造入口，
 * 所有子命令拿到同一形状的组件；把判定放在入口意味着每个命令各判一次，漏判就是
 * 「静默不落库」——那种故障当场看不出来，要等用户发现历史没了。
 * 懒加载把判定收在存储自己身上：不用就不开，用了自动开，语义与立即打开完全一致。
 *
 * 实测动机：入口是先装配后分发，于是 `--version` / 未知命令这类**不需要任何存储**的
 * 调用也要替用户把会话库打开一遍。而打开成本取决于库里遗留的 `.mem`（WAL）数量：
 * 288 个时单次 7–9 秒。这些遗留文件又恰恰是「入口提前 return、没走到 close()」留下的
 * ——两者互为因果，形成正反馈。懒打开把这条链在第一环切断。
 *
 * 线程安全：会话读写可能来自工作线程与子 Agent，首次打开用 [Mutex] 保护，只打开一次
 * （badgercj 只有进程内锁，重复打开同一目录会直接失败）。
 */
public class LazySessionStore <: SessionStore {
    private let lock = Mutex()
    private let opener: () -> SessionStore
    private var inner: ?SessionStore = None

    /** 按目录懒打开（生产用）。 */
    public init(path: String) {
        this.opener = { => StormSessionStore(path) }
    }

    /** 注入打开方式（测试用：不碰文件系统，可观测打开次数）。 */
    public init(opener: () -> SessionStore) {
        this.opener = opener
    }

    /** 当前是否已经真正打开过底层存储。 */
    public func isOpen(): Bool {
        synchronized(this.lock) { this.inner.isSome() }
    }

    private func target(): SessionStore {
        synchronized(this.lock) {
            match (this.inner) {
                case Some(s) => s
                case None =>
                    let s = this.opener()
                    this.inner = Some(s)
                    s
            }
        }
    }

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        this.target().save(id, header, messages)
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        this.target().appendBranch(id, parentLeafId, messages)
    }

    public func load(id: String): ArrayList<Message> { this.target().load(id) }

    public func loadEntries(id: String): SessionData { this.target().loadEntries(id) }

    public func list(): ArrayList<SessionHeader> { this.target().list() }

    public func delete(id: String): Unit { this.target().delete(id) }

    public func fork(sourceId: String, leafId: String): SessionData {
        this.target().fork(sourceId, leafId)
    }

    public func appendCompaction(record: CompactionRecord): Unit {
        this.target().appendCompaction(record)
    }

    public func loadCompactions(sessionId: String): ArrayList<CompactionRecord> {
        this.target().loadCompactions(sessionId)
    }

    /**
     * 关库：没打开过就什么都不做（`--version` 这类调用因此零 I/O，也不会留下 .mem）。
     * 先取出再置空，避免 close 期间有别的线程重新打开。
     */
    public func close(): Unit {
        let s = synchronized(this.lock) {
            let cur = this.inner
            this.inner = None
            cur
        }
        match (s) {
            case Some(v) => v.close()
            case None => ()
        }
    }
}
