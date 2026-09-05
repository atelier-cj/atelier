package atelier.agent

import std.collection.*
import std.collection.concurrent.*
import std.core.Duration
import std.sync.*
import stdx.log.*
import opencj::ulid.nextId
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

// ===================== 消息信封（父子双向） =====================

public const AgentMailKindUserText: String = "user_text"   // 委派/续聊（父 → 子）
public const AgentMailKindProgress: String = "progress"    // 进度（子 → 父，P1 起）
public const AgentMailKindReply: String = "reply"          // 回合回复（子 → 父）
public const AgentMailKindDone: String = "done"            // 最终报告（子 → 父，start 的首回合）
public const AgentMailKindClose: String = "close"          // 终止（保留给 close() 语义说明）

public class AgentMail {
    public let from: String
    public let to: String
    public let kind: String
    public let text: String

    public init(from: String, to: String, kind: String, text: String) {
        this.from = from
        this.to = to
        this.kind = kind
        this.text = text
    }
}

public enum SubagentState {
    | Idle     // 空闲等待来信
    | Running  // 回合进行中
    | Closed   // 已终止

    // 数值化（比较用：仓颉 enum 无内建 ==；0/1/2 稳定契约）
    public func index(): Int64 {
        match (this) {
            case SubagentState.Idle => 0
            case SubagentState.Running => 1
            case SubagentState.Closed => 2
        }
    }
}

// ===================== 子 Agent 句柄 =====================

// 可持续子 Agent 句柄：父侧持有。send() 投递消息（唤醒空闲子）；recv() 取子来信（阻塞可超时）。
public class SubAgentHandle {
    public let subSessionId: String
    public let parentSessionId: String

    // 父 → 子（内容消息）；worker 空闲时阻塞取、回合中不消费（回合后处理）
    let inbox = LinkedBlockingQueue<AgentMail>()
    // 子 → 父（回合结束回信）；父经 recv() 取
    let outbox = LinkedBlockingQueue<AgentMail>()

    private let stateLock = Mutex()
    private var st = SubagentState.Idle
    // 控制标志：不占队列（回合中也能及时响应）
    let closeRequested = AtomicBool(false)
    let cancelRequested = AtomicBool(false)
    let exited = AtomicBool(false)

    public init(subSessionId: String, parentSessionId: String) {
        this.subSessionId = subSessionId
        this.parentSessionId = parentSessionId
    }

    // 父 → 子：异步投递（worker 空闲时被唤醒；已终止的 no-op）
    public func send(mail: AgentMail): Unit {
        if (this.exited.load()) { return }
        this.inbox.add(mail)
    }

    // 子 → 父：阻塞取信，可超时（timeout 到期返回 None）
    public func recv(timeout!: Duration = 30 * Duration.second): ?AgentMail {
        this.outbox.remove(timeout)
    }

    public func state(): SubagentState {
        synchronized(this.stateLock) { this.st }
    }

    func setState(s: SubagentState): Unit {
        synchronized(this.stateLock) { this.st = s }
    }

    // 请求取消当前回合（worker 轮询后执行 cancelSession，幂等）
    public func cancel(): Unit {
        this.cancelRequested.store(true)
    }

    // 请求终止 worker（空闲/回合中均尽快生效；幂等；会话历史保留）
    public func close(): Unit {
        this.closeRequested.store(true)
    }

    func markExited(): Unit {
        this.exited.store(true)
        this.closeRequested.store(true)
        this.cancelRequested.store(false)
        this.setState(SubagentState.Closed)
    }
}

// ===================== 子 Agent 管理器 =====================

// 组件与 AgentTool 同源（同进程共享 toolReg/trustMgr/mcpMgr 等），
// start() 为每个子 Agent 启动常驻 worker（消息驱动回合循环）。
public class SubAgentManager {
    private let toolReg: ToolRegistry
    private let trustMgr: TrustManager
    private let skillReg: SkillRegistry
    private let agentReg: AgentRegistry
    private let providerReg: ProviderRegistry
    private let sessionStore: SessionStore
    private let mcpMgr: McpManager
    private let handles = HashMap<String, SubAgentHandle>()
    private let lock = Mutex()

    public init(toolReg: ToolRegistry, trustMgr: TrustManager,
        skillReg: SkillRegistry, agentReg: AgentRegistry,
        providerReg: ProviderRegistry, sessionStore: SessionStore,
        mcpMgr: McpManager) {
        this.toolReg = toolReg
        this.trustMgr = trustMgr
        this.skillReg = skillReg
        this.agentReg = agentReg
        this.providerReg = providerReg
        this.sessionStore = sessionStore
        this.mcpMgr = mcpMgr
    }

    // 启动子 Agent：立即返回句柄（首回合在 worker 线程异步执行，完成后 outbox 投 done）
    public func start(config: AgentConfig, provider: Provider,
        parentSessionId: String, initialPrompt: String, env: SessionEnvironment): SubAgentHandle {
        let childId = "sub_" + nextId()
        let h = SubAgentHandle(childId, parentSessionId)
        synchronized(this.lock) { this.handles[childId] = h }
        this.runWorker(h, config, provider, initialPrompt, env)
        h
    }

    // 无工作目录版本（env 留空，工具 workDir 回落 "."）
    public func start(config: AgentConfig, provider: Provider,
        parentSessionId: String, initialPrompt: String): SubAgentHandle {
        this.start(config, provider, parentSessionId, initialPrompt, SessionEnvironment())
    }

    public func get(subSessionId: String): ?SubAgentHandle {
        synchronized(this.lock) { this.handles.get(subSessionId) }
    }

    public func has(subSessionId: String): Bool {
        synchronized(this.lock) { this.handles.contains(subSessionId) }
    }

    // 父会话级联：关闭该父的全部子 Agent（句柄从注册表移除）
    public func closeForParent(parentSessionId: String): Unit {
        let toClose = ArrayList<SubAgentHandle>()
        synchronized(this.lock) {
            for ((_, h) in this.handles) {
                if (h.parentSessionId == parentSessionId) { toClose.add(h) }
            }
        }
        for (h in toClose) {
            h.close()
            h.markExited()
            synchronized(this.lock) { this.handles.remove(h.subSessionId) }
        }
    }

    // 测试/统计
    public func size(): Int64 {
        synchronized(this.lock) { this.handles.size }
    }

    // ===================== Worker：消息驱动回合循环 =====================

    private func runWorker(h: SubAgentHandle, config: AgentConfig, provider: Provider,
        initialPrompt: String, env: SessionEnvironment): Unit {
        spawn {
            let log = getGlobalLogger([("name", "SubAgent")])
            var firstTurn = true
            var turnNo: Int64 = 0
            while (!h.closeRequested.load() && !h.exited.load()) {
                // 首回合用启动消息；之后阻塞等待来信（1s 轮询以响应 close）
                let mail: ?AgentMail = if (firstTurn) {
                    firstTurn = false
                    Some(AgentMail(h.parentSessionId, h.subSessionId, AgentMailKindUserText, initialPrompt))
                } else {
                    h.inbox.remove(Duration.second)
                }
                match (mail) {
                    case Some(m) =>
                        if (m.kind == AgentMailKindUserText) {
                            turnNo++
                            let kind = if (turnNo == Int64(1)) { AgentMailKindDone } else { AgentMailKindReply }
                            this.runTurn(h, config, provider, m.text, env, log, kind)
                        }
                    case None => ()
                }
            }
            h.markExited()
        }
    }

    // 单回合：历史 + 来信 → runtime 回合 → 落库 → outbox 回信（kind=首回合 done / 后续 reply）
    private func runTurn(h: SubAgentHandle, config: AgentConfig, provider: Provider,
        text: String, env: SessionEnvironment, log: Logger, replyKind: String): Unit {
        h.setState(SubagentState.Running)
        var oldLoaded = ArrayList<Message>()
        try { oldLoaded = this.sessionStore.load(h.subSessionId) } catch (_) { () }
        let msgs = ArrayList<Message>(oldLoaded)
        msgs.add(UserMessage(ContentList.ofText(text), 0))

        let runtime = AgentRuntime(config, provider, this.toolReg, this.sessionStore,
            this.trustMgr, this.skillReg, this.agentReg, this.providerReg,
            ArrayList<Hook>(), { q => "" }, env, this.mcpMgr)
        let stream = runtime.chatWithSessionId(h.subSessionId, msgs, env)
        // 回合内轮询控制标志（cancel/close 及时生效），事件流消费至回合结束。
        // AgentStartEvent 到达 ⇔ runtime 已注册 cancelFlag：此前的取消/关闭请求此时补发（幂等）。
        var cancelArmed = false
        var abortedByClose = false
        var ended = false
        while (!ended && !abortedByClose) {
            if (h.closeRequested.load()) {
                runtime.cancelSession(h.subSessionId)
                abortedByClose = true
                break
            }
            if (cancelArmed && h.cancelRequested.load()) {
                runtime.cancelSession(h.subSessionId)
                h.cancelRequested.store(false)
            }
            match (stream.receive(Duration.millisecond * 200)) {
                case Some(_: AgentStartEvent) =>
                    cancelArmed = true
                    if (h.cancelRequested.load()) {
                        runtime.cancelSession(h.subSessionId)
                        h.cancelRequested.store(false)
                    }
                case Some(_: AgentEndEvent) => ended = true
                case Some(_) =>
                    if (h.cancelRequested.load()) {
                        runtime.cancelSession(h.subSessionId)
                        h.cancelRequested.store(false)
                    }
                case None => ()
            }
        }
        let all = try { stream.result() } catch (e: Exception) {
            log.error("subagent ${h.subSessionId} turn error: ${e.message}", Array<Attr>())
            ArrayList<Message>(oldLoaded)
        }
        // 落库（runtime 不落库，由 worker 统一追加；错误仅记日志）
        match (persistAppend(this.sessionStore, h.subSessionId, oldLoaded, all)) {
            case Some(err) => log.error("subagent persist: ${err}", Array<Attr>())
            case None => ()
        }
        // 回信：close 打断不回；否则首回合 done、后续 reply（kind 由调用方决定）
        if (!abortedByClose) {
            let body = lastAgentText(all)
            h.outbox.add(AgentMail(h.subSessionId, h.parentSessionId, replyKind, body))
        }
        h.setState(SubagentState.Idle)
    }
}
