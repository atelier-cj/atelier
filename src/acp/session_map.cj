package atelier.acp

import std.collection.*
import std.sync.*
import acp.{SessionStore, SessionRecord}
import opencj::ulid.nextId

// ACP 会话运行时状态：ACP sessionId（外部可见） ↔ atelier 会话 id（存储侧）
public class AcpSession {
    public let acpId: String
    public let cwd: String
    public let atelierId: String
    public let createdAt: String

    public init(acpId: String, cwd: String, atelierId: String, createdAt: String) {
        this.acpId = acpId
        this.cwd = cwd
        this.atelierId = atelierId
        this.createdAt = createdAt
    }

    public init(acpId: String, cwd: String, atelierId: String) {
        this(acpId, cwd, atelierId, "")
    }

    public func withAtelierId(atelierId: String): AcpSession {
        AcpSession(this.acpId, this.cwd, atelierId, this.createdAt)
    }
}

// ACP ↔ atelier 会话映射管理：
// - 运行期：acpId → AcpSession（active 表）
// - 持久化：acp.SessionStore（JSON 文件，映射文件所在目录需由调用方保证存在），
//   供进程重启后 session/load、session/list、session/delete 恢复
public class AcpSessionManager {
    private let store: SessionStore
    private let active = HashMap<String, AcpSession>()
    private let lock = Mutex()

    public init(mappingFile: String) {
        this.store = SessionStore(mappingFile)
    }

    // 建新会话：生成 ACP id 与 atelier 会话 id，登记 active 并持久化映射
    public func newSession(cwd: String): AcpSession {
        let s = AcpSession("acp_" + nextId(), cwd, nextId())
        synchronized(this.lock) {
            this.active[s.acpId] = s
            this.store.upsert(SessionRecord(s.acpId, s.cwd, s.atelierId))
        }
        s
    }

    // 按 ACP id 取会话：active 优先，其次从持久化映射恢复（跨进程场景）
    public func lookup(acpId: String): ?AcpSession {
        synchronized(this.lock) {
            match (this.active.get(acpId)) {
                case Some(s) => Some(s)
                case None =>
                    match (this.store.get(acpId)) {
                        case Some(r) =>
                            let s = AcpSession(r.sessionId, r.cwd, r.backendSessionId, r.createdAt)
                            this.active[acpId] = s
                            Some(s)
                        case None => None
                    }
            }
        }
    }

    // 仅查 active（session/close 后 active 已清除；本方法用于区分「运行中」与「已归档」）
    public func getActive(acpId: String): ?AcpSession {
        synchronized(this.lock) { this.active.get(acpId) }
    }

    // session/close：清除运行期状态（持久化映射保留，供后续 load/resume）
    public func dropActive(acpId: String): Unit {
        synchronized(this.lock) { this.active.remove(acpId) }
    }

    // session/delete：删除持久化映射并清除运行期状态
    public func deleteMapping(acpId: String): Unit {
        synchronized(this.lock) {
            this.active.remove(acpId)
            this.store.delete(acpId)
        }
    }

    // 全部已记录映射（含历史，供 session/list 组装）
    public func list(): ArrayList<SessionRecord> {
        synchronized(this.lock) { this.store.list() }
    }

    // 持久化记录条数（测试/统计）
    public func size(): Int64 {
        synchronized(this.lock) { this.store.list().size }
    }
}
