package atelier.agent

import std.collection.*
import std.core.Duration
import std.env.getStdErr
import std.sync.*
import stdx.log.*
import std.fs.{Directory, Path}
import acp.{AcpClient, Implementation}
import acp.types.*
import acp.transport.SubprocessTransport
import atelier.message.{Message, ContentList}
import jsonvalue.*
import ystyle::jsonrpc.Result

// 跨进程子 Agent（ACP 桥）：RemoteSubAgentHandle 以独立 `atelier acp <agent> [sessionDir]`
// 子进程承载子 agent；send = 一次自主回合（ACP prompt）；子回合内 waitReply/主动唤醒父
// 受 ACP v1 限制不支持（设计见 docs/plans 2026-09-05-subagent-duplex-plan.md §P7）。
public open class RemoteSubAgentHandle <: SubAgentHandle {
    // 子进程协议句柄（worker 线程内 connect/回合）
    private let boxAdder: (AgentMail) -> Unit
    // 每回合的文本缓冲（session/update agent_message_chunk 收集）
    private let bufLock = Mutex()
    private var buffered: String = ""
    private var turnNo: Int64 = 0

    // worker 循环内使用的连接（connect 成功后赋值）
    private var client: ?AcpClient = None
    // 子进程 ACP 会话 id（newSession 返回；prompt/close 用，与父侧句柄 id 不同）
    private var acpSessionId: ?String = None
    private let transport: SubprocessTransport
    private let cwd: String

    public init(subSessionId: String, parentSessionId: String,
        transport: SubprocessTransport, cwd: String,
        boxAdder: (AgentMail) -> Unit) {
        super(subSessionId, parentSessionId)
        this.transport = transport
        this.cwd = cwd
        this.boxAdder = boxAdder
    }

    // 收集子回合流式文本（接收线程回调）
    private func onSessionUpdate(update: SessionUpdate): Unit {
        if (update.sessionUpdate == SessionUpdateAgentMessageChunk) {
            match (update.content) {
                case Some(c) =>
                    match (c.text) {
                        case Some(t) =>
                            synchronized(this.bufLock) { this.buffered = this.buffered + t }
                        case None => ()
                    }
                case None => ()
            }
        }
    }

    private func takeBuffer(): String {
        synchronized(this.bufLock) {
            let v = this.buffered
            this.buffered = ""
            v
        }
    }

    // 回合（worker 线程执行）：text 组装 ContentBlock → prompt → 回信
    private func runTurn(text: String): Unit {
        let c = match (this.client) {
            case Some(v) => v
            case None =>
                this.deliver("远程子 Agent 未连接", AgentMailKindReply)
                return
        }
        this.turnNo++
        let replyKind = if (this.turnNo == Int64(1)) { AgentMailKindDone } else { AgentMailKindReply }
        let sid = match (this.acpSessionId) {
            case Some(v) => v
            case None =>
                this.deliver("远程子 Agent 会话未就绪", replyKind)
                return
        }
        let blocks = ArrayList<ContentBlock>()
        blocks.add(ContentBlock.ofText(text))
        match (c.prompt(sid, blocks, timeout: 20 * Duration.minute)) {
            case Result.Ok(resp) =>
                var body = this.takeBuffer()
                if (resp.stopReason == StopReasonCancelled) {
                    body = if (body == "") { "[cancelled]" } else { body }
                }
                if (body == "") { body = "[stop: ${resp.stopReason}]" }
                this.deliver(body, replyKind)
            case Result.Err(e) =>
                this.deliver("远程子 Agent 错误: ${e}", replyKind)
        }
    }

    private func deliver(body: String, kind: String): Unit {
        let mail = AgentMail(this.subSessionId, this.parentSessionId, kind, body)
        this.outbox.add(mail)
        this.boxAdder(mail)
    }

    // 重写：投递 = 一次远程回合（worker 线程串行消费 inbox）
    public override func send(mail: AgentMail): Unit {
        if (this.exited.load()) { return }
        if (mail.kind != AgentMailKindUserText) { return }
        this.inbox.add(mail)
    }

    // 重写：中断进行中回合（ACP session/cancel）
    public override func cancel(): Unit {
        if (this.state().index() != SubagentState.Running.index()) { return }
        match (this.client) {
            case Some(c) =>
                match (this.acpSessionId) {
                    case Some(sid) => c.cancel(sid)
                    case None => ()
                }
            case None => ()
        }
    }

    // 重写：请求终止（cancel 进行中回合 + worker 退出后关闭进程）
    public override func close(): Unit {
        this.cancel()
        this.closeRequested.store(true)
    }

    // worker 循环（manager.startRemote 内 spawn 调用）；初始 prompt 已在 inbox
    public func serveRemote(): Unit {
        spawn {
            this.logRemote("remote worker start: ${this.subSessionId}")
            try {
                this.serveRemoteInner()
            } catch (e: Exception) {
                this.logRemote("remote worker error: ${e.message}")
                this.deliver("远程子 Agent 异常: ${e.message}", AgentMailKindDone)
            }
            this.markExited()
        }
    }

    private func logRemote(msg: String): Unit {
        try {
            let err = getStdErr()
            err.write(("[remote-sub] " + msg + "\n").toArray())
            err.flush()
        } catch (_) { () }
    }

    private func serveRemoteInner(): Unit {
        try {
            // 1. 握手 + 建会话（失败：回信错误并退出）
            let client = AcpClient(this.transport)
            this.client = Some(client)
            this.client = Some(client)
            client.setOnSessionUpdate({ sid, update => this.onSessionUpdate(update) })
            var ready = false
            this.logRemote("before connect")
            match (client.connect(Implementation("atelier-parent", "0.1.0"), ClientCapabilities())) {
                case Result.Ok(_) =>
                    this.logRemote("connect ok")
                    // 与 pi_bridge 同时序：握手成功后订阅流式通知
                    client.setOnSessionUpdate({ sid, update => this.onSessionUpdate(update) })
                    ready = true
                case Result.Err(e) =>
                    this.logRemote("connect error: ${e}")
                    this.deliver("远程子 Agent 握手失败: ${e}", AgentMailKindDone)
                    this.markExited()
                    return
            }
            if (!ready) {
                this.markExited()
                return
            }
            match (client.newSession(this.cwd, timeout: 60 * Duration.second)) {
                case Result.Ok(resp) =>
                    this.acpSessionId = Some(resp.sessionId)
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
                    match (this.acpSessionId) {
                        case Some(sid) => client.closeSession(sid)
                        case None => ()
                    }
                case Result.Err(e) =>
                    this.logRemote("newSession error: ${e}")
                    this.deliver("远程子 Agent 会话创建失败: ${e}", AgentMailKindDone)
            }
            client.close()
        } catch (e: Exception) {
            this.logRemote("serveRemoteInner error: ${e.message}")
            this.deliver("远程子 Agent 异常: ${e.message}", AgentMailKindDone)
        }
    }
}
