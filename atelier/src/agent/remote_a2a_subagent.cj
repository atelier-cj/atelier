package atelier.agent

import std.collection.*
import std.core.Duration
import std.env.getStdErr
import std.sync.*
import a2a.*
import a2a.client.A2aClient
import opencj::ulid.nextId

// 单轮流式的收敛状态：远端终态 / 是否在等输入（等输入 ≠ 终态，任务仍然活着、可续聊）
class A2aStreamOutcome {
    var terminal: ?TaskState = None
    var inputRequired: Bool = false
    var question: String = ""
}

// 远端 A2A 子 Agent：把「别的 A2A agent」（HTTP + Agent Card 发现）当作可持续子代理驱动。
// 父侧既有的 subagent_* 工具零改动即可使用本句柄（与本地子、ACP 远程子同构）。
//
// 与 ACP 版（子进程 + stdio）的差异：
// - 走 HTTP（JSON-RPC / HTTP+JSON 绑定），不拉子进程，不需要父二进制路径与隔离 sessionDir；
// - **支持 input-required 反向提问**：远端任务挂起后把问题作为一封来信投回父，任务保持打开；
//   父下发下一条消息即作为答复续聊同一 taskId（答复文本由服务端桥折算成结构化答复）。
public open class RemoteA2aSubAgentHandle <: SubAgentHandle {
    private let baseUrl: String
    private let boxAdder: (AgentMail) -> Unit
    // worker 线程内建立/使用；close 时回收
    private var client: ?A2aClient = None
    // 远端任务/上下文：首轮流式事件里的 Task 快照给出；续聊与取消都用它寻址
    private var taskId: ?String = None
    private var contextId: ?String = None
    private let bufLock = Mutex()
    private var buffered: String = ""
    private var turnNo: Int64 = 0

    public init(subSessionId: String, parentSessionId: String, baseUrl: String,
        boxAdder: (AgentMail) -> Unit) {
        super(subSessionId, parentSessionId)
        this.baseUrl = baseUrl
        this.boxAdder = boxAdder
    }

    // 重写：投递 = 一次远端回合（worker 线程串行消费 inbox）
    public override func send(mail: AgentMail): Unit {
        if (this.exited.load()) { return }
        if (mail.kind != AgentMailKindUserText) { return }
        this.inbox.add(mail)
    }

    // 重写：中断进行中的远端任务（A2A CancelTask，协作式；不强杀连接）
    public override func cancel(): Unit {
        if (this.state().index() != SubagentState.Running.index()) { return }
        match (this.taskId) {
            case Some(id) =>
                match (this.client) {
                    case Some(c) =>
                        try {
                            c.cancelTask(id)
                        } catch (e: Exception) {
                            this.logRemote("cancelTask error: ${e.message}")
                        }
                    case None => ()
                }
            case None => ()
        }
    }

    // 重写：请求终止（取消进行中回合 + worker 退出后关闭连接，会话历史留在远端）
    public override func close(): Unit {
        this.cancel()
        this.closeRequested.store(true)
    }

    // worker 循环（SubAgentManager.startRemoteA2a 内 spawn 调用）；初始 prompt 已在 inbox
    public func serveRemote(): Unit {
        spawn {
            this.logRemote("remote a2a worker start: ${this.subSessionId} -> ${this.baseUrl}")
            try {
                this.serveRemoteInner()
            } catch (e: Exception) {
                this.logRemote("remote a2a worker error: ${e.message}")
                this.deliver("远程 A2A 子 Agent 异常: ${e.message}", AgentMailKindDone)
            }
            this.markExited()
        }
    }

    private func serveRemoteInner(): Unit {
        // Agent Card 发现 + 建客户端：失败直接回信错误，不留悬挂句柄
        let card = A2aClient.discover(this.baseUrl)
        let c = A2aClient(card, readTimeout: Some(20 * Duration.minute))
        this.client = Some(c)
        this.logRemote("discovered '${card.name}' binding=${c.protocolBinding()}")
        // 消息驱动回合循环（与本地子同构：inbox 串行消费，回合外空闲）
        while (!this.closeRequested.load() && !this.exited.load()) {
            match (this.inbox.remove(Duration.second)) {
                case Some(m) =>
                    if (m.kind == AgentMailKindUserText) {
                        this.setState(SubagentState.Running)
                        this.runTurn(m.text)
                        this.setState(SubagentState.Idle)
                    }
                case None => ()
            }
        }
        c.close()
    }

    // 一次远端回合：流式发消息 → 累积产出 → 回信（首回合 done，其后 reply）
    private func runTurn(text: String): Unit {
        let c = match (this.client) {
            case Some(v) => v
            case None =>
                this.deliver("远程 A2A 子 Agent 未连接", AgentMailKindReply)
                return
        }
        this.turnNo++
        let replyKind = if (this.turnNo == Int64(1)) { AgentMailKindDone } else { AgentMailKindReply }
        synchronized(this.bufLock) { this.buffered = "" }
        // 续聊：带上下文/任务 id（远端据此把这条消息接进既有任务）
        let msg = Message.user("msg_" + nextId(), text,
            contextId: this.contextId, taskId: this.taskId)
        let outcome = A2aStreamOutcome()
        try {
            c.sendStreamingMessage(SendMessageRequest(msg),
                { ev => this.absorb(ev, outcome) })
        } catch (e: Exception) {
            this.deliver("远程 A2A 调用失败: ${e.message}", replyKind)
            return
        }
        // 远端等输入：本条回合到此为止，把问题交回父；任务保持打开，父的下一条消息即答复
        if (outcome.inputRequired) {
            let q = if (outcome.question != "") { outcome.question } else { this.takeBuffer() }
            this.deliver(if (q == "") { "[远端等待补充输入]" } else { q }, replyKind)
            return
        }
        let body = this.takeBuffer()
        match (outcome.terminal) {
            case Some(TaskState.Failed) =>
                this.deliver(if (body == "") { "远程 A2A 任务失败（无详情）" } else { body }, replyKind)
            case Some(TaskState.Canceled) =>
                this.deliver(if (body == "") { "[cancelled]" } else { body }, replyKind)
            case Some(TaskState.Rejected) =>
                this.deliver(if (body == "") { "远程 A2A 任务被拒绝" } else { body }, replyKind)
            case _ =>
                this.deliver(if (body == "") { "[远程 A2A 无输出]" } else { body }, replyKind)
        }
        if (outcome.terminal.isSome()) {
            // 任务已终态：下一条消息必须开新任务（协议不允许再往终态任务发消息），
            // contextId 保留，因此仍是同一段远端对话
            this.taskId = None
        }
    }

    // 流式事件累积；返回 false 让客户端停止读流（终态 / 中断态都已收齐）
    private func absorb(ev: StreamResponse, outcome: A2aStreamOutcome): Bool {
        match (ev.task) {
            case Some(t) =>
                this.taskId = Some(t.id)
                match (t.contextId) {
                    case Some(cid) => this.contextId = Some(cid)
                    case None => ()
                }
            case None => ()
        }
        // 纯消息流（不建任务）：agent 消息即产出
        match (ev.message) {
            case Some(m) =>
                if (m.role == Role.Agent) {
                    this.appendText(m.text())
                }
            case None => ()
        }
        // 任务流的文本产出在 artifact 分片里（append 语义由服务端合并，客户端只累积）
        match (ev.artifactUpdate) {
            case Some(a) =>
                for (p in a.artifact.parts) {
                    match (p.text) {
                        case Some(t) => this.appendText(t)
                        case None => ()
                    }
                }
            case None => ()
        }
        match (ev.statusUpdate) {
            case Some(s) =>
                if (isInterrupted(s.status.state)) {
                    outcome.inputRequired = true
                    outcome.question = messageText(s.status.message)
                    return false
                }
                if (isTerminal(s.status.state)) {
                    // 终态状态消息里可能带失败原因/最终答复，一并收进产出
                    this.appendText(messageText(s.status.message))
                    outcome.terminal = Some(s.status.state)
                    return false
                }
            case None => ()
        }
        true
    }

    private func appendText(t: String): Unit {
        if (t == "") { return }
        synchronized(this.bufLock) { this.buffered = this.buffered + t }
    }

    private func takeBuffer(): String {
        synchronized(this.bufLock) {
            let v = this.buffered
            this.buffered = ""
            v
        }
    }

    private func deliver(body: String, kind: String): Unit {
        let mail = AgentMail(this.subSessionId, this.parentSessionId, kind, body)
        this.outbox.add(mail)
        this.boxAdder(mail)
    }

    private func logRemote(msg: String): Unit {
        try {
            let err = getStdErr()
            err.write(("[remote-a2a] " + msg + "\n").toArray())
            err.flush()
        } catch (_) { () }
    }
}

// 状态消息文本（缺省空串）
func messageText(m: ?Message): String {
    match (m) {
        case Some(v) => v.text()
        case None => ""
    }
}
