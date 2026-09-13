package atelier.agent

import std.collection.*
import std.collection.concurrent.*
import std.core.Duration
import std.env.getVariable
import std.sync.*
import stdx.log.*
import opencj::ulid.nextId
import acp.transport.SubprocessTransport
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
// open：跨进程远程句柄（RemoteSubAgentHandle）继承复用队列与状态
public open class SubAgentHandle {
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
    // 子回合内 send_message(waitReply=true) 阻塞等待父回复中（respond 据此分派直通/唤醒）
    let waitingForReply = AtomicBool(false)

    public init(subSessionId: String, parentSessionId: String) {
        this.subSessionId = subSessionId
        this.parentSessionId = parentSessionId
    }

    // 父 → 子：异步投递（worker 空闲时被唤醒；已终止的 no-op）
    public open func send(mail: AgentMail): Unit {
        if (this.exited.load()) { return }
        this.inbox.add(mail)
    }

    // 子 → 父：阻塞取信，可超时（timeout 到期返回 None）
    public func recv(timeout!: Duration = 30 * Duration.second): ?AgentMail {
        this.outbox.remove(timeout)
    }

    // 子 → 父：非阻塞尝试取一封（无信返回 None；宿主输入循环轮询用）
    public func pollOnce(): ?AgentMail {
        this.outbox.remove(Duration.millisecond)
    }

    // 父 → 子：回复子（状态感知分派，对齐 dsh「父可随时向可持续子发 follow-up」语义）：
    // - 子正阻塞在 send_message(waitReply=true)（waitingForReply 置位）→ 专用通道解锁其当前回合；
    // - 子空闲 / 回合中未等待（含远程子，无 waitReply 通道）→ 投 inbox 作 follow-up：
    //   子在回合边界（worker 空闲循环）消费并开新回合——不滞留、不错配、不打断当前回合。
    public func respond(text: String): Unit {
        if (this.exited.load()) { return }
        let waiting = this.waitingForReply.load()
        if (waiting) {
            this.replyQueue.add(AgentMail(this.parentSessionId, this.subSessionId, AgentMailKindReply, text))
        } else {
            this.inbox.add(AgentMail(this.parentSessionId, this.subSessionId, AgentMailKindUserText, text))
        }
    }

    public func state(): SubagentState {
        synchronized(this.stateLock) { this.st }
    }

    func setState(s: SubagentState): Unit {
        synchronized(this.stateLock) { this.st = s }
    }

    // 请求取消当前回合（worker 轮询后执行 cancelSession，幂等）
    public open func cancel(): Unit {
        this.cancelRequested.store(true)
    }

    // 请求终止 worker（空闲/回合中均尽快生效；幂等；会话历史保留）
    public open func close(): Unit {
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
// idleTimeoutSec > 0：本地子 worker 连续空闲 N 秒自动回收（close + 从注册表摘除，
// 会话历史保留，resumeSession 可重建）；0（默认）= 永不自动回收（显式 close 语义）。
public class SubAgentManager {
    private let toolReg: ToolRegistry
    private let trustMgr: TrustManager
    private let skillReg: SkillRegistry
    private let agentReg: AgentRegistry
    private let providerReg: ProviderRegistry
    private let sessionStore: SessionStore
    private let mcpMgr: McpManager
    // 本地子空闲自动回收阈值（秒；0 = 不回收）。远程子无 idle 探测通道，仅显式 close。
    private let idleTimeoutSec: Int64
    private let handles = HashMap<String, SubAgentHandle>()
    private let lock = Mutex()
    // 父级聚合收件箱（该父全部子的来信副本；子隔离走 handle.outbox，聚合等待走这里）
    private let parentBoxes = HashMap<String, LinkedBlockingQueue<AgentMail>>()
    // 统一回合执行（历史装载/事件消费/落库）
    private let loop: SessionLoop

    public init(toolReg: ToolRegistry, trustMgr: TrustManager,
        skillReg: SkillRegistry, agentReg: AgentRegistry,
        providerReg: ProviderRegistry, sessionStore: SessionStore,
        mcpMgr: McpManager, idleTimeoutSec!: Int64 = 0) {
        this.toolReg = toolReg
        this.trustMgr = trustMgr
        this.skillReg = skillReg
        this.agentReg = agentReg
        this.providerReg = providerReg
        this.sessionStore = sessionStore
        this.mcpMgr = mcpMgr
        this.idleTimeoutSec = idleTimeoutSec
        this.loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, sessionStore, mcpMgr)
    }

    // 启动子 Agent：立即返回句柄（首回合在 worker 线程异步执行，完成后 outbox 投 done）
    public func start(config: AgentConfig, provider: Provider,
        parentSessionId: String, initialPrompt: String, env: SessionEnvironment): SubAgentHandle {
        let childId = "sub_" + nextId()
        let h = SubAgentHandle(childId, parentSessionId)
        synchronized(this.lock) { this.handles[childId] = h }
        this.runWorker(h, config, provider, Some(initialPrompt), env)
        h
    }

    // 无工作目录版本（env 留空，工具 workDir 回落 "."）
    public func start(config: AgentConfig, provider: Provider,
        parentSessionId: String, initialPrompt: String): SubAgentHandle {
        this.start(config, provider, parentSessionId, initialPrompt, SessionEnvironment())
    }

    // 恢复：复用既有子会话（store 中的历史）重建可持续句柄（模拟进程重启后恢复）。
    // 会话不存在或已注册 → None。恢复的 worker 不再投 initial，首封信即续聊输入。
    public func resumeSession(config: AgentConfig, provider: Provider,
        parentSessionId: String, childSessionId: String,
        env: SessionEnvironment): ?SubAgentHandle {
        // 会话必须存在于 store
        let exists = try { this.sessionStore.load(childSessionId).size >= Int64(0) } catch (_) { false }
        if (!exists) { return None }
        synchronized(this.lock) {
            if (this.handles.contains(childSessionId)) { return None }
        }
        let h = SubAgentHandle(childSessionId, parentSessionId)
        synchronized(this.lock) { this.handles[childSessionId] = h }
        this.runWorker(h, config, provider, None, env)
        Some(h)
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

    // 跨进程启动：子 agent 跑独立 `atelier acp <agent> [sessionDir]` 进程（ACP 桥）。
    // executable：子进程可执行文件（父二进制同款，如 /path/to/atelier.cli）；
    // sessionDir：子进程隔离会话目录（勿与父共享）；cwd：子会话工作目录。
    // 返回句柄；握手/建会话失败以 done 错误回信（异步可见于 recv）。
    public func startRemote(executable: String, agentName: String, parentSessionId: String,
        initialPrompt: String, cwd: String, sessionDir: String): ?SubAgentHandle {
        let childId = "rsub_" + nextId()
        let args: Array<String> = ["acp", agentName, sessionDir]
        let transport = SubprocessTransport(executable, args: args)
        let h = RemoteSubAgentHandle(childId, parentSessionId, transport, cwd,
            { m => this.parentBoxFor(parentSessionId).add(m) })
        synchronized(this.lock) { this.handles[childId] = h }
        h.send(AgentMail(parentSessionId, childId, AgentMailKindUserText, initialPrompt))
        h.serveRemote()
        Some(h)
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

    // 该父的全部子句柄（宿主 /subagent list 等用）
    public func listForParent(parentSessionId: String): ArrayList<SubAgentHandle> {
        let out = ArrayList<SubAgentHandle>()
        synchronized(this.lock) {
            for ((_, h) in this.handles) {
                if (h.parentSessionId == parentSessionId) { out.add(h) }
            }
        }
        out
    }

    // 该父全部子的未读来信（非阻塞；各子至多取一封，供宿主回合外展示/唤醒提示）
    public func pollChildren(parentSessionId: String): ArrayList<AgentMail> {
        let out = ArrayList<AgentMail>()
        for (h in this.listForParent(parentSessionId)) {
            match (h.pollOnce()) {
                case Some(m) => out.add(m)
                case None => ()
            }
        }
        out
    }

    // 该父的活跃（未关闭）子数量
    public func activeCountFor(parentSessionId: String): Int64 {
        let out = ArrayList<SubAgentHandle>()
        for (h in this.listForParent(parentSessionId)) {
            match (h.state()) {
                case SubagentState.Closed => ()
                case _ => out.add(h)
            }
        }
        out.size
    }

    // 测试/统计
    public func size(): Int64 {
        synchronized(this.lock) { this.handles.size }
    }

    // ===================== Worker：消息驱动回合循环 =====================

    private func runWorker(h: SubAgentHandle, config: AgentConfig, provider: Provider,
        initialMail: ?String, env: SessionEnvironment): Unit {
        spawn {
            let log = getGlobalLogger([("name", "SubAgent")])
            var pendingInitial: ?String = initialMail
            // start：首回合(turnNo=1) 标 done；resume（无 initial）：续聊首回合即 reply
            var turnNo: Int64 = if (initialMail.isSome()) { 0 } else { 1 }
            // 空闲计时（秒）：来信/回合重置；达 idleTimeoutSec 触发自动回收
            var idleSec: Int64 = 0
            var reclaimed = false
            while (!h.closeRequested.load() && !h.exited.load()) {
                // 首回合可用启动消息；否则阻塞等待来信（1s 轮询以响应 close/回收计时）
                let mail: ?AgentMail = match (pendingInitial) {
                    case Some(text) =>
                        pendingInitial = None
                        Some(AgentMail(h.parentSessionId, h.subSessionId, AgentMailKindUserText, text))
                    case None => h.inbox.remove(Duration.second)
                }
                match (mail) {
                    case Some(m) =>
                        idleSec = 0
                        if (m.kind == AgentMailKindUserText) {
                            turnNo++
                            let kind = if (turnNo == Int64(1)) { AgentMailKindDone } else { AgentMailKindReply }
                            this.runTurn(h, config, provider, m.text, env, log, kind)
                        }
                    case None =>
                        // 1s 轮询空转：累计空闲（回合外无来信不打断正在执行的回合）
                        idleSec++
                        if (this.idleTimeoutSec > 0 && idleSec >= this.idleTimeoutSec) {
                            reclaimed = true
                            break
                        }
                }
            }
            h.markExited()
            if (reclaimed) {
                // 自动回收：从注册表摘除（显式 close / closeForParent 不摘除，语义保持）
                synchronized(this.lock) { this.handles.remove(h.subSessionId) }
            }
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
            { timeoutMs =>
                // 置位等待标志：respond 据此走 replyQueue 直通；超时/收到回复即复位
                h.waitingForReply.store(true)
                var res: ?String = None
                try {
                    match (h.replyQueue.remove(Duration.millisecond * timeoutMs)) {
                        case Some(m) => res = Some(m.text)
                        case None => ()
                    }
                } catch (e: Exception) {
                    // 与「等超时」区分开：不留痕的话，队列读失败会被父 Agent
                    // 当成「子 Agent 没回复」（std 文档未声明该调用会抛，属防御性兜底）
                    eprintln("[atelier] subagent reply queue read failed: ${e.toString()}")
                }
                h.waitingForReply.store(false)
                res
            })
        childToolReg.register(sendTool)

        let outcome = this.loop.run(h.subSessionId, text, config, provider, Some(childToolReg), env,
            { => h.closeRequested.load() },
            { => h.cancelRequested.load() },
            parentSession: Some(h.parentSessionId))
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
