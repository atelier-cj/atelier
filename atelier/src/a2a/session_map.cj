package atelier.a2a

import jsonvalue.*
import stdx.encoding.json.stream.*
import std.collection.*
import std.sync.*
import std.fs.{File, Path, exists}
import a2a.types.{fromJsonObject, reparse}
import opencj::ulid.nextId

// A2A 会话映射记录：contextId（A2A 侧可见，客户端可携带也可由服务端生成）
// ↔ atelier 会话 id（存储侧 ULID）。与 ACP 侧的 AcpSession 同构。
public class A2aSession <: JsonSerializable & JsonDeserializable<A2aSession> {
    public var contextId: String = ""
    public var cwd: String = ""
    public var atelierId: String = ""
    public var createdAt: String = ""

    public init() {}

    public init(contextId: String, cwd: String, atelierId: String, createdAt: String) {
        this.contextId = contextId
        this.cwd = cwd
        this.atelierId = atelierId
        this.createdAt = createdAt
    }

    public init(contextId: String, cwd: String, atelierId: String) {
        this(contextId, cwd, atelierId, "")
    }

    public func withAtelierId(atelierId: String): A2aSession {
        A2aSession(this.contextId, this.cwd, atelierId, this.createdAt)
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("contextId").writeValue(this.contextId)
        w.writeName("cwd").writeValue(this.cwd)
        w.writeName("atelierId").writeValue(this.atelierId)
        w.writeName("createdAt").writeValue(this.createdAt)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): A2aSession {
        let res = A2aSession()
        fromJsonObject(r,
            ("contextId", {=> res.contextId = r.readValue<String>()}),
            ("cwd", {=> res.cwd = r.readValue<String>()}),
            ("atelierId", {=> res.atelierId = r.readValue<String>()}),
            ("createdAt", {=> res.createdAt = r.readValue<String>()})
        )
        res
    }
}

// 任务级索引：taskId → (contextId, turn)。
// A2A 的 tasks/get、tasks/cancel、SubscribeToTask 都以 taskId 寻址，而 atelier 侧
// 一个会话（contextId）可以承载多个任务回合，因此比 ACP 的「1 会话 = 1 映射」多这一级。
public class A2aTaskBinding <: JsonSerializable & JsonDeserializable<A2aTaskBinding> {
    public var taskId: String = ""
    public var contextId: String = ""
    // 绑定时刻该会话已推进到的回合号（tasks/get 与 resubscribe 据此定位回合）
    public var turn: Int64 = 0
    public var createdAt: String = ""

    public init() {}

    public init(taskId: String, contextId: String, turn: Int64, createdAt: String) {
        this.taskId = taskId
        this.contextId = contextId
        this.turn = turn
        this.createdAt = createdAt
    }

    public init(taskId: String, contextId: String, turn: Int64) {
        this(taskId, contextId, turn, "")
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("taskId").writeValue(this.taskId)
        w.writeName("contextId").writeValue(this.contextId)
        w.writeName("turn").writeValue(this.turn)
        w.writeName("createdAt").writeValue(this.createdAt)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): A2aTaskBinding {
        let res = A2aTaskBinding()
        fromJsonObject(r,
            ("taskId", {=> res.taskId = r.readValue<String>()}),
            ("contextId", {=> res.contextId = r.readValue<String>()}),
            ("turn", {=> res.turn = r.readValue<Int64>()}),
            ("createdAt", {=> res.createdAt = r.readValue<String>()})
        )
        res
    }
}

// 映射文件的持久化存储（JSON）。
// 文件形如 {"sessions": {<contextId>: A2aSession}, "tasks": {<taskId>: A2aTaskBinding}}：
// 键是运行期才知道的 id，容器层用 JsonValue.Map 承载；记录本身走 json.stream 序列化接口，
// 不做字段级手工解析。映射文件所在目录需由调用方保证存在。
class A2aSessionStore {
    private let filePath: String
    private let sessions = HashMap<String, A2aSession>()
    private let tasks = HashMap<String, A2aTaskBinding>()
    private let lock = Mutex()

    init(filePath: String) {
        this.filePath = filePath
        this.reload()
    }

    func upsertSession(s: A2aSession): Unit {
        synchronized(this.lock) {
            this.sessions[s.contextId] = s
            this.persistLocked()
        }
    }

    func getSession(contextId: String): ?A2aSession {
        synchronized(this.lock) { this.sessions.get(contextId) }
    }

    func containsSession(contextId: String): Bool {
        synchronized(this.lock) { this.sessions.contains(contextId) }
    }

    // 删会话映射，并连带删除该 context 下的全部任务索引：
    // 留下悬挂索引会让 tasks/get 指回一个已不存在的上下文
    func deleteSession(contextId: String): Unit {
        synchronized(this.lock) {
            var changed = this.sessions.remove(contextId).isSome()
            let doomed = ArrayList<String>()
            for ((k, v) in this.tasks) {
                if (v.contextId == contextId) {
                    doomed.add(k)
                }
            }
            for (k in doomed) {
                this.tasks.remove(k)
                changed = true
            }
            if (changed) {
                this.persistLocked()
            }
        }
    }

    func listSessions(): ArrayList<A2aSession> {
        synchronized(this.lock) { ArrayList<A2aSession>(this.sessions.values()) }
    }

    func sessionCount(): Int64 {
        synchronized(this.lock) { this.sessions.size }
    }

    func upsertTask(b: A2aTaskBinding): Unit {
        synchronized(this.lock) {
            this.tasks[b.taskId] = b
            this.persistLocked()
        }
    }

    func getTask(taskId: String): ?A2aTaskBinding {
        synchronized(this.lock) { this.tasks.get(taskId) }
    }

    func tasksOf(contextId: String): ArrayList<A2aTaskBinding> {
        synchronized(this.lock) {
            let res = ArrayList<A2aTaskBinding>()
            for ((_, v) in this.tasks) {
                if (v.contextId == contextId) {
                    res.add(v)
                }
            }
            res
        }
    }

    func listTasks(): ArrayList<A2aTaskBinding> {
        synchronized(this.lock) { ArrayList<A2aTaskBinding>(this.tasks.values()) }
    }

    func taskCount(): Int64 {
        synchronized(this.lock) { this.tasks.size }
    }

    // 加载映射文件。文件不存在（首次启动）属正常；单条记录损坏只丢该条，
    // 整个文件解析失败则视为空库 —— 两种情况都必须留下痕迹（诊断走 stderr）。
    private func reload(): Unit {
        synchronized(this.lock) {
            if (!exists(Path(this.filePath))) {
                return
            }
            try {
                let text = String.fromUtf8(File.readFrom(Path(this.filePath)))
                let jv = JsonValue.parse(text)
                match (jv) {
                    case JsonValue.Map(m) =>
                        match (m.get("sessions")) {
                            case Some(JsonValue.Map(sm)) =>
                                for ((k, v) in sm) {
                                    try {
                                        this.sessions[k] = reparse<A2aSession>(v)
                                    } catch (e: Exception) {
                                        eprintln("[atelier-a2a] session_map: 跳过损坏的会话映射 '${k}': " + e.toString())
                                    }
                                }
                            case _ => ()
                        }
                        match (m.get("tasks")) {
                            case Some(JsonValue.Map(tm)) =>
                                for ((k, v) in tm) {
                                    try {
                                        this.tasks[k] = reparse<A2aTaskBinding>(v)
                                    } catch (e: Exception) {
                                        eprintln("[atelier-a2a] session_map: 跳过损坏的任务索引 '${k}': " + e.toString())
                                    }
                                }
                            case _ => ()
                        }
                    case _ => ()
                }
            } catch (e: Exception) {
                eprintln("[atelier-a2a] session_map: 加载 '${this.filePath}' 失败（视为空库）: " + e.toString())
            }
        }
    }

    private func persistLocked(): Unit {
        let sessions = HashMap<String, JsonValue>()
        for ((k, v) in this.sessions) {
            sessions.add(k, JsonValue.fromObject(v))
        }
        let tasks = HashMap<String, JsonValue>()
        for ((k, v) in this.tasks) {
            tasks.add(k, JsonValue.fromObject(v))
        }
        let root = HashMap<String, JsonValue>()
        root.add("sessions", JsonValue.Map(sessions))
        root.add("tasks", JsonValue.Map(tasks))
        try {
            File.writeTo(Path(this.filePath), JsonValue.Map(root).toBytes())
        } catch (e: Exception) {
            // 持久化失败不致命（只影响跨进程恢复），但映射会静默消失 → 必须可见
            eprintln("[atelier-a2a] session_map: 持久化 '${this.filePath}' 失败: " + e.toString())
        }
    }
}

// A2A ↔ atelier 会话映射管理：
// - 运行期：contextId → A2aSession（active 表，代表「该上下文正被使用」）
// - 持久化：A2aSessionStore（JSON 文件），供进程重启后 tasks/get、续聊、tasks/list 恢复；
//   任务索引同时持久化（taskId 级寻址跨进程可用）
// 语义与 AcpSessionManager 对齐：close（dropActive）只清运行态、保留映射；
// delete（deleteMapping）两者都清，并连带清掉该 context 的任务索引。
public class A2aSessionManager {
    private let store: A2aSessionStore
    private let active = HashMap<String, A2aSession>()
    private let lock = Mutex()

    public init(mappingFile: String) {
        this.store = A2aSessionStore(mappingFile)
    }

    // 服务端生成 contextId（客户端未携带 contextId 的首次消息）
    public func newSession(cwd: String): A2aSession {
        this.newSessionWithId("ctx_" + nextId(), cwd)
    }

    // 以给定 contextId 建映射。幂等：同一 contextId 重复登记返回既有映射，
    // 不会另发一个 atelier 会话把上一个变成孤儿（客户端可能重复携带同一 contextId）。
    public func newSessionWithId(contextId: String, cwd: String): A2aSession {
        synchronized(this.lock) {
            match (this.lookupLocked(contextId)) {
                case Some(s) => s
                case None =>
                    let s = A2aSession(contextId, cwd, nextId(), nowIso8601())
                    this.active[contextId] = s
                    this.store.upsertSession(s)
                    s
            }
        }
    }

    // 按 contextId 取会话：active 优先，其次从持久化映射恢复（跨进程场景）
    public func lookup(contextId: String): ?A2aSession {
        synchronized(this.lock) { this.lookupLocked(contextId) }
    }

    // 仅查 active（close 后 active 已清除；本方法用于区分「运行中」与「已归档」）
    public func getActive(contextId: String): ?A2aSession {
        synchronized(this.lock) { this.active.get(contextId) }
    }

    // A2A 侧会话关闭：清除运行期状态（持久化映射与任务索引保留，供 tasks/get 与续聊）
    public func dropActive(contextId: String): Unit {
        synchronized(this.lock) { this.active.remove(contextId) }
    }

    // 删除会话：持久化映射、运行期状态、该 context 下的任务索引一并清除
    public func deleteMapping(contextId: String): Unit {
        synchronized(this.lock) {
            this.active.remove(contextId)
            this.store.deleteSession(contextId)
        }
    }

    // 全部已记录会话（含历史，供 tasks/list 组装）
    public func list(): ArrayList<A2aSession> {
        synchronized(this.lock) { this.store.listSessions() }
    }

    // 已记录会话数（测试/统计）
    public func size(): Int64 {
        synchronized(this.lock) { this.store.sessionCount() }
    }

    // 生成任务 id（与 nextId 的 ULID 一致，便于按时间排序）
    public func newTaskId(): String {
        "task_" + nextId()
    }

    // 记录任务级索引：taskId → (contextId, turn)。
    // 同一 taskId 重复绑定视为推进（覆盖为新回合）；未登记的 contextId 直接拒绝 ——
    // 悬挂索引会让 tasks/get 指回不存在的上下文，属于调用方顺序错误。
    public func bindTask(taskId: String, contextId: String, turn: Int64): Unit {
        synchronized(this.lock) {
            if (!this.store.containsSession(contextId)) {
                throw Exception("A2aSessionManager.bindTask: contextId '${contextId}' 未登记，先建会话映射再绑定任务")
            }
            this.store.upsertTask(A2aTaskBinding(taskId, contextId, turn, nowIso8601()))
        }
    }

    // 按 taskId 取索引（tasks/get、SubscribeToTask 的寻址入口；close 后仍可取到）
    public func lookupTask(taskId: String): ?A2aTaskBinding {
        synchronized(this.lock) { this.store.getTask(taskId) }
    }

    // 某 context 下的全部任务索引
    public func tasksOf(contextId: String): ArrayList<A2aTaskBinding> {
        synchronized(this.lock) { this.store.tasksOf(contextId) }
    }

    // 全部任务索引（跨 context；供 tasks/list 过滤/分页）
    public func listTasks(): ArrayList<A2aTaskBinding> {
        synchronized(this.lock) { this.store.listTasks() }
    }

    // 已记录任务索引数（测试/统计）
    public func taskSize(): Int64 {
        synchronized(this.lock) { this.store.taskCount() }
    }

    private func lookupLocked(contextId: String): ?A2aSession {
        match (this.active.get(contextId)) {
            case Some(s) => Some(s)
            case None =>
                match (this.store.getSession(contextId)) {
                    case Some(r) =>
                        this.active[contextId] = r
                        Some(r)
                    case None => None
                }
        }
    }
}
