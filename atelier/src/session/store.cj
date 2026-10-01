package atelier.session

import atelier.message.*
import std.collection.*
import stdx.serialization.serialization.*
import stdx.encoding.json.stream.*

public class SessionData {
    public let header: SessionHeader
    public let entries: ArrayList<Entry>
    public init(header: SessionHeader, entries: ArrayList<Entry>) {
        this.header = header; this.entries = entries
    }
}

/**
 * 一次压缩事务的台账记录：**开**（`finishedAt == 0`）与**合**各一条，按 [compactionId] 配对。
 *
 * 为什么落库：压缩是改写历史的操作，出问题时要能事后说清"哪次、为什么、覆盖了多少"；
 * 有开无合则是**中断残留**（进程在压缩中途没了）——只作提示，不当锁用：锁会因残留而永久卡死，
 * 而压缩结果与消息表是同一次原子写入，进程崩在中间留下的仍是压缩前的历史。
 */
public struct CompactionRecord <: JsonSerializable & JsonDeserializable<CompactionRecord> {
    public let compactionId: String
    public let sessionId: String
    /** pressure（请求前压力）/ overflow（超窗恢复）/ manual（手动 /compact） */
    public let trigger: String
    public let startedAt: Int64
    /** 0 = 尚未闭合 */
    public let finishedAt: Int64
    public let tokensBefore: Int64
    public let tokensAfter: Int64
    public let messagesBefore: Int64
    public let messagesAfter: Int64
    /** open（开）/ replaced（历史被替换）/ noop（尝试过但没替换） */
    public let outcome: String

    public init(compactionId: String, sessionId: String, trigger: String, startedAt: Int64,
        finishedAt: Int64, tokensBefore: Int64, tokensAfter: Int64,
        messagesBefore: Int64, messagesAfter: Int64, outcome: String) {
        this.compactionId = compactionId; this.sessionId = sessionId
        this.trigger = trigger; this.startedAt = startedAt; this.finishedAt = finishedAt
        this.tokensBefore = tokensBefore; this.tokensAfter = tokensAfter
        this.messagesBefore = messagesBefore; this.messagesAfter = messagesAfter
        this.outcome = outcome
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("compactionId").writeValue(this.compactionId)
        w.writeName("sessionId").writeValue(this.sessionId)
        w.writeName("trigger").writeValue(this.trigger)
        w.writeName("startedAt").writeValue(this.startedAt)
        w.writeName("finishedAt").writeValue(this.finishedAt)
        w.writeName("tokensBefore").writeValue(this.tokensBefore)
        w.writeName("tokensAfter").writeValue(this.tokensAfter)
        w.writeName("messagesBefore").writeValue(this.messagesBefore)
        w.writeName("messagesAfter").writeValue(this.messagesAfter)
        w.writeName("outcome").writeValue(this.outcome)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): CompactionRecord {
        var compactionId = ""
        var sessionId = ""
        var trigger = ""
        var startedAt = Int64(0)
        var finishedAt = Int64(0)
        var tokensBefore = Int64(0)
        var tokensAfter = Int64(0)
        var messagesBefore = Int64(0)
        var messagesAfter = Int64(0)
        var outcome = ""
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "compactionId" => compactionId = r.readValue<String>()
                case "sessionId" => sessionId = r.readValue<String>()
                case "trigger" => trigger = r.readValue<String>()
                case "startedAt" => startedAt = r.readValue<Int64>()
                case "finishedAt" => finishedAt = r.readValue<Int64>()
                case "tokensBefore" => tokensBefore = r.readValue<Int64>()
                case "tokensAfter" => tokensAfter = r.readValue<Int64>()
                case "messagesBefore" => messagesBefore = r.readValue<Int64>()
                case "messagesAfter" => messagesAfter = r.readValue<Int64>()
                case "outcome" => outcome = r.readValue<String>()
                case _ => r.skip()
            }
        }
        r.endObject()
        CompactionRecord(compactionId, sessionId, trigger, startedAt, finishedAt,
            tokensBefore, tokensAfter, messagesBefore, messagesAfter, outcome)
    }
}

/**
 * 有开无合的压缩事务（按 compactionId 找没有 finish 的 open）。
 *
 * 这是**中断残留**的证据，不是锁：宿主读到它只该提示/记录，不该据此拒绝新的压缩
 * （残留永久存在，当锁用会让会话永远压不动）。
 */
public func interruptedCompactions(records: ArrayList<CompactionRecord>): ArrayList<CompactionRecord> {
    let closed = HashSet<String>()
    for (r in records) {
        if (r.finishedAt > 0) { closed.add(r.compactionId) }
    }
    let out = ArrayList<CompactionRecord>()
    for (r in records) {
        if (r.finishedAt == 0 && !closed.contains(r.compactionId)) { out.add(r) }
    }
    out
}

public interface SessionStore {
    func save(id: String, header: SessionHeader, messages: ArrayList<Message>): Unit
    func appendBranch(id: String, parentLeafId: String, messages: ArrayList<Message>): String
    func load(id: String): ArrayList<Message>
    func loadEntries(id: String): SessionData
    func list(): ArrayList<SessionHeader>
    func delete(id: String): Unit
    func fork(sourceId: String, leafId: String): SessionData
    // 压缩事务台账（审计 + 中断残留检测）。不落台账的存储不必实现：
    // 默认空实现，读取方拿到空列表即可（台账不是压缩正确性的前提）
    func appendCompaction(record: CompactionRecord): Unit {}
    func loadCompactions(sessionId: String): ArrayList<CompactionRecord> { ArrayList<CompactionRecord>() }
    func close(): Unit {}
}
