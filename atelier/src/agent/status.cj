package atelier.agent

import std.collection.*
import std.sync.Mutex
import std.time.DateTime

/**
 * Agent 的生命周期状态：**比一次 run 长寿**的那一层。
 *
 * 为什么需要它（而不是只看 `AgentEvent`）：事件流是**一次 run 内**的。
 * 而常驻 agent 大部分时间不在 run 里——它在空闲、等触发、等审批、排队。
 * 屏幕上要能显示「等待中的它」，就必须有这个状态位，否则只能显示"上一次干了什么"。
 *
 * **`Idle` 与 `Running` 的界线**：`Running` 从「开始处理一次输入」算起，
 * 到「本次执行收敛（含挂起）」为止。挂起**不是**回到 `Idle`——它把状态交回给
 * 等待方（`pending-*` 由上层表达），而 agent 本身已无执行中的回合。
 */
public enum AgentStatus {
    /** 没有执行中的回合：等触发 */
    | Idle
    /** 有回合在执行（可能正在等模型、跑工具、或等审批答复） */
    | Running
}

/**
 * 状态转变事件：**与 `AgentEvent` 并列的另一条流**，不实现 `AgentEvent`。
 *
 * 为什么不能塞进 `AgentEvent`：那条流的生命周期是 run，run 结束流就关了；
 * 而状态转变恰恰包含「run 结束后回到 idle」这一刻。硬塞进去会让 `Idle` 无处可发。
 *
 * 订阅面仍是同一个（都从 `EventBus` 出），面板只需订阅一次。
 */
public class AgentStatusEvent {
    public let sessionId: String
    public let status: AgentStatus
    /** 转变发生时刻（毫秒） */
    public let at: Int64

    public init(sessionId: String, status: AgentStatus, at: Int64) {
        this.sessionId = sessionId
        this.status = status
        this.at = at
    }
}

/**
 * 状态持有者：把「某个会话/agent 现在处于什么状态」记下来并广播。
 *
 * 一个 `AgentRuntime` 实例只服务若干次 run，**不足以承载 `Idle`**——
 * 因此持有者必须比 runtime 长寿（由宿主/runner 层持有并传入）。
 */
public class AgentStatusRegistry {
    private let lock = Mutex()
    private let statuses = HashMap<String, AgentStatus>()
    private let subs = HashMap<Int64, (AgentStatusEvent) -> Unit>()
    private var seq: Int64 = 0

    public init() {}

    /** 当前状态；从未登记过的会话视为 Idle */
    public func statusOf(sessionId: String): AgentStatus {
        synchronized(this.lock) {
            match (this.statuses.get(sessionId)) {
                case Some(s) => s
                case None => AgentStatus.Idle
            }
        }
    }

    /**
     * 状态转变：**同状态重复设置不广播**（避免每次 run 收尾都刷一条 Idle）。
     *
     * @return 真的发生了转变则为 true
     */
    public func transition(sessionId: String, status: AgentStatus): Bool {
        var changed = false
        synchronized(this.lock) {
            let prev = match (this.statuses.get(sessionId)) {
                case Some(s) => s
                case None => AgentStatus.Idle
            }
            if (!sameStatus(prev, status)) {
                this.statuses[sessionId] = status
                changed = true
            }
        }
        if (changed) {
            this.broadcast(AgentStatusEvent(sessionId, status,
                DateTime.now().toUnixTimeStamp().toMilliseconds()))
        }
        changed
    }

    /** 忘记某个会话（会话被删除/回收时调，避免表无限增长） */
    public func forget(sessionId: String): Unit {
        synchronized(this.lock) {
            this.statuses.remove(sessionId)
        }
    }

    /**
     * 订阅状态转变，返回退订函数。
     *
     * **为什么是独立订阅面而不是复用 [EventBus]**：那个总线只接受 `AgentEvent`
     * （run 内事件）。状态转变包含「run 结束后回到 idle」，在 `AgentEvent` 之外，
     * 硬塞进去就得让 `AgentEvent` 承担两种生命周期。
     * 面板侧要同时看两条流时，各订阅一次即可（订阅成本是常数）。
     */
    public func subscribe(fn: (AgentStatusEvent) -> Unit): () -> Unit {
        let id = synchronized(this.lock) {
            this.seq++
            this.subs[this.seq] = fn
            this.seq
        }
        { => synchronized(this.lock) { this.subs.remove(id) }; () }
    }

    // 快照后逐个投递（容忍投递期间订阅变更）；单订阅者异常不连坐
    private func broadcast(ev: AgentStatusEvent): Unit {
        let targets = synchronized(this.lock) {
            let arr = ArrayList<(AgentStatusEvent) -> Unit>()
            for ((_, h) in this.subs) { arr.add(h) }
            arr
        }
        for (h in targets) {
            try {
                h(ev)
            } catch (e: Exception) {
                eprintln("[atelier] status subscriber failed: ${e.toString()}")
            }
        }
    }
}

func sameStatus(a: AgentStatus, b: AgentStatus): Bool {
    match ((a, b)) {
        case (AgentStatus.Idle, AgentStatus.Idle) => true
        case (AgentStatus.Running, AgentStatus.Running) => true
        case _ => false
    }
}
