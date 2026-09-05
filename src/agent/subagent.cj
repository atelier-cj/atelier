package atelier.agent

import std.collection.*
import std.collection.concurrent.*
import std.core.Duration
import std.env.getVariable
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
    // 子 → 父（回合结束回信/主动消息）；父经 recv() 取
    let outbox = LinkedBlockingQueue<AgentMail>()
    // 父 → 子（回合内 send_message waitReply 的专用回复通道，子回合内阻塞取）
    let replyQueue = LinkedBlockingQueue<AgentMail>()

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

    // 父 → 子：回复子回合内 send_message(waitReply=true) 的提问（专用通道）。
    // 子空闲时调用无即时效果（消息留存，供其后续回合内 waitReply 消费）。
    public func respond(text: String): Unit {
        if (this.exited.load()) { return }
        this.replyQueue.add(AgentMail(this.parentSessionId, this.subSessionId, AgentMailKindReply, text))
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
    // 父级聚合收件箱（该父全部子的来信副本；子隔离走 handle.outbox，聚合等待走这里）
    private let parentBoxes = HashMap<String, LinkedBlockingQueue<AgentMail>>()
    // 统一回合执行（历史装载/事件消费/落库）
    private let loop: SessionLoop

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
        this.loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, sessionStore, mcpMgr)
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

    // 按 agent 注册名启动（父端 subagent_start 工具入口）；config/provider 从注册表解析
    public func startByName(agentName: String, parentSessionId: String, initialPrompt: String): ?SubAgentHandle {
        match (this.agentReg.get(agentName)) {
            case Some(cfg) =>
                match (this.resolveSubProvider(cfg)) {
                    case Some(p) => Some(this.start(cfg, p, parentSessionId, initialPrompt))
                    case None => None
                }
            case None => None
        }
    }

    // 解析子 agent provider：配置指定名 → default → 环境变量 OpenAI 兜底（与 CLI resolveProviderFor 同策略）
    private func resolveSubProvider(cfg: AgentConfig): ?Provider {
        let providerName = match (cfg.provider) { case Some(v) => v; case None => "default" }
        match (this.providerReg.get(providerName)) {
            case Some(p) => Some(p)
            case None =>
                match (this.providerReg.get("default")) {
                    case Some(p) => Some(p)
                    case None =>
                        let baseURL = match (getVariable("OPENAI_BASE_URL")) {
                            case Some(v) => v; case None => "https://api.openai.com/v1"
                        }
                        let apiKey = match (getVariable("OPENAI_API_KEY")) {
                            case Some(v) => v; case None => ""
                        }
                        Some(OpenAIProvider(providerName, baseURL, apiKey))
                }
        }
    }

    // 阻塞等待该父的任一子来信（父端 subagent_watch 工具；parentId 无子/无消息按超时返回 None）
    public func awaitChildren(parentSessionId: String, timeout!: Duration = 30 * Duration.second): ?AgentMail {
        this.parentBoxFor(parentSessionId).remove(timeout)
    }

    private func parentBoxFor(parentSessionId: String): LinkedBlockingQueue<AgentMail> {
        synchronized(this.lock) {
            match (this.parentBoxes.get(parentSessionId)) {
                case Some(q) => q
                case None =>
                    let fresh = LinkedBlockingQueue<AgentMail>()
                    this.parentBoxes[parentSessionId] = fresh
                    fresh
            }
        }
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
            synchronized(this.lock) {
                this.handles.remove(h.subSessionId)
                this.parentBoxes.remove(parentSessionId)
            }
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

    // 单回合：来信 → SessionLoop（历史/消费/落库）→ outbox 回信（kind=首回合 done / 后续 reply）
    private func runTurn(h: SubAgentHandle, config: AgentConfig, provider: Provider,
        text: String, env: SessionEnvironment, log: Logger, replyKind: String): Unit {
        h.setState(SubagentState.Running)
        // 子工具注册表 = 共享全量 + send_message（避免 send_message 泄漏进父的工具列表）
        let childToolReg = ToolRegistry()
        for (t in this.toolReg.list()) { childToolReg.register(t) }
        let sendTool = SendMessageTool(
            { body, kind =>
                let mail = AgentMail(h.subSessionId, h.parentSessionId, kind, body)
                h.outbox.add(mail)
                this.parentBoxFor(h.parentSessionId).add(mail)
            },
            { timeoutMs => match (h.replyQueue.remove(Duration.millisecond * timeoutMs)) {
                case Some(m) => Some(m.text)
                case None => None
            } })
        childToolReg.register(sendTool)

        let outcome = this.loop.run(h.subSessionId, text, config, provider, Some(childToolReg), env,
            { => h.closeRequested.load() },
            { => h.cancelRequested.load() },
            None)
        // 消费掉本次取消请求（一个请求对应一次回合打断）
        h.cancelRequested.store(false)
        // 回信：close 打断不回；否则首回合 done、后续 reply（kind 由调用方决定）
        if (!outcome.stoppedByClose) {
            let body = lastAgentText(outcome.messages)
            let mail = AgentMail(h.subSessionId, h.parentSessionId, replyKind, body)
            h.outbox.add(mail)
            this.parentBoxFor(h.parentSessionId).add(mail)
        }
        h.setState(SubagentState.Idle)
    }
}
