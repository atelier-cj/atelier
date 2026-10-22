package atelier.session

import bstorm.*
import bstorm.macros.Model
import bstorm.macros.Id
import stdx.encoding.json.stream.*
import stdx.serialization.serialization.*
import atelier.message.*
import atelier.util.{toJsonString, fromJsonString}
import std.collection.*

@Model
public class SessionRecord {
    @Id
    public var id: String = ""
    public var headerJson: String = ""
    public var entriesJson: String = ""
    public var updatedAt: Int64 = 0
    public init() {}
}

/**
 * 压缩台账行：一条会话一行，整份台账（ArrayList<CompactionRecord> 的 JSON）存在 [json] 里。
 *
 * 独立表而不是给 SessionRecord 加列：加列要面对既有行的缺列问题，而这张表按 id 键读写、
 * 用新表名，既有会话零影响。一条会话的台账只有寥寥几条，整份重写的代价可忽略。
 */
@Model
public class CompactionJournalRow {
    @Id
    public var id: String = ""
    public var json: String = ""
    public init() {}
}

public class StormSessionStore <: SessionStore {
    private let db: Storm
    // 数据库生命周期归谁：自己 open 的就自己关；外部注入的交给持有者。
    // 不能让 close() 无条件关 —— 注入场景下关掉会连带弄死持有者的其它表。
    private let ownsDb: Bool

    public init(path: String) {
        // syncWrites=true：每次写入同步落盘。
        //
        // 会话是**用户可见的持久数据**，不能像缓存那样等 memtable 满了才刷。
        // 默认的 syncWrites=false 意味着进程被 kill（容器重启、OOM、Ctrl-C 之外的
        // 强制终止）时，最近的全部对话直接消失——而现象是"重启后历史没了"，
        // 排查时会被误导到上层。
        //
        // 代价是每次写的延迟略高；会话写入频率（每轮一次）远达不到这个瓶颈。
        this.db = Storm.open(path, syncWrites: true)
        this.ownsDb = true
    }

    /**
     * 用**已有的** Storm 实例构造：调用方负责打开与关闭。
     *
     * 场景：同一进程里还要存别的东西（如宿主的可写配置），而 bstorm 的数据目录
     * 不能被打开两次（badgercj 只有进程内锁，没有跨进程文件锁）。此时由调用方
     * 持有唯一的 `Storm`，会话存储与其它用途的表共用一个实例 —— 不同 tableName，
     * 互不影响。
     */
    public init(db: Storm) {
        this.db = db
        this.ownsDb = false
    }

    public func close(): Unit {
        if (this.ownsDb) {
            this.db.close()
        }
    }

    private func journalId(sessionId: String): String { "compact:" + sessionId }

    public func appendCompaction(record: CompactionRecord): Unit {
        let records = this.loadCompactions(record.sessionId)
        records.add(record)
        let row = CompactionJournalRow()
        row.id = this.journalId(record.sessionId)
        row.json = recordsToJson(records)
        this.db.save(row)
    }

    public func loadCompactions(sessionId: String): ArrayList<CompactionRecord> {
        match (this.db.get<CompactionJournalRow>(this.journalId(sessionId))) {
            case Some(row) => recordsFromJson(row.json)
            case None => ArrayList<CompactionRecord>()
        }
    }

    public func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit {
        var entries = ArrayList<Entry>()
        var parentId: Option<String> = None
        for (i in 0..messages.size) {
            let msg = messages[Int64(i)]
            let eid = id + "_" + i.toString()
            entries.add(Entry(eid, parentId, 0, msg))
            parentId = Some(eid)
        }
        let record = SessionRecord()
        record.id = id
        record.headerJson = toJsonString(header)
        record.entriesJson = entriesToJson(entries)
        this.db.save(record)
    }

    public func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let existing = entriesFromJson(record.entriesJson)
        var parentId: Option<String> = Some(parentLeafId)
        var leaf = parentLeafId
        var idx = existing.size
        for (m in messages) {
            let eid = id + "_" + idx.toString()
            existing.add(Entry(eid, parentId, 0, m))
            parentId = Some(eid); leaf = eid; idx++
        }
        record.entriesJson = entriesToJson(existing)
        this.db.save(record)
        leaf
    }

    public func load(id: String): ArrayList<Message> {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let entries = entriesFromJson(record.entriesJson)
        let msgs = ArrayList<Message>()
        for (e in entries) { msgs.add(e.message) }
        msgs
    }

    public func loadEntries(id: String): SessionData {
        let record = match (this.db.get<SessionRecord>(id)) {
            case Some(r) => r
            case None => throw Exception("Session not found: ${id}")
        }
        let header = fromJsonString<SessionHeader>(record.headerJson)
        let entries = entriesFromJson(record.entriesJson)
        SessionData(header, entries)
    }

    public func list(): ArrayList<SessionHeader> {
        let records = this.db.all<SessionRecord>()
        let result = ArrayList<SessionHeader>()
        for (r in records) {
            result.add(fromJsonString<SessionHeader>(r.headerJson))
        }
        result
    }

    public func delete(id: String): Unit {
        let r = SessionRecord(); r.id = id; this.db.delete(r)
    }

    public func fork(sourceId: String, leafId: String): SessionData {
        let data = this.loadEntries(sourceId)
        SessionData(data.header, pathToLeaf(data.entries, leafId))
    }
}

// 台账列表的 JSON 编解码：复用 util 的助手（与 entries 同一套口径）
func recordsToJson(records: ArrayList<CompactionRecord>): String {
    toJsonString(records)
}

func recordsFromJson(json: String): ArrayList<CompactionRecord> {
    // 台账坏了不该影响会话可用性：留痕 + 当作空台账
    try { fromJsonString<ArrayList<CompactionRecord>>(json) } catch (e: Exception) {
        eprintln("[atelier] compaction journal deserialize failed: ${e.toString()}")
        ArrayList<CompactionRecord>()
    }
}
