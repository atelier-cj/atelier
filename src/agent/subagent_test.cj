package atelier.agent

import std.collection.*
import std.core.Duration
import std.core.sleep
import std.time.MonoTime
import jsonvalue.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream

// ========== P0：可持续子 Agent 基础设施（句柄/邮箱/worker 循环） ==========

// 录制式 Stub Provider：记录流式调用次数与每回合收到的最新 user 文本，回显 "答: <text>"
class SubRecordProvider <: Provider {
    public var streamCalls: Int64 = 0
    public var seenTexts = ArrayList<String>()
    private let chunkDelayMs: Int64
    private let chunkCount: Int64
    // chunkCount=0：不发中间 delta，直接 finish（快路径）；>0 供 cancel 慢流用例
    public init(chunkDelayMs!: Int64 = 0, chunkCount!: Int64 = 0) {
        this.chunkDelayMs = chunkDelayMs
        this.chunkCount = chunkCount
    }

    public func name(): String { "stub-subrecord" }

    private func lastUserText(req: ChatRequest): String {
        var last = ""
        for (m in req.messages) {
            match (m) {
                case um: UserMessage =>
                    var t = ""
                    for (b in um.content.blocks()) {
                        match (b) { case ContentBlock.TextBlock(x) => t = t + x; case _ => () }
                    }
                    if (t != "") { last = t }
                case _ => ()
            }
        }
        last
    }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("答: " + this.lastUserText(req)), "", "",
            StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.streamCalls++
        this.seenTexts.add(this.lastUserText(req))
        let stream = EventStream<ChatDelta, AssistantMessage>()
        let text = "答: " + this.lastUserText(req)
        spawn {
            var i: Int64 = 0
            while (i < this.chunkCount) {
                sleep(Duration.millisecond * this.chunkDelayMs)
                if (!stream.emit(ChatDelta("x", "", None))) { break }
                i++
            }
            let msg = AssistantMessage(ContentList.ofText(text), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
            ()
        }
        stream
    }
}

func makeSubManager(provider: Provider): (SubAgentManager, ProviderRegistry) {
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mgr = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, McpManager())
    (mgr, providerReg)
}

func subConfig(): AgentConfig {
    AgentConfig("t", None, "", None, "m", None, ArrayList(), ArrayList(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

func waitState(h: SubAgentHandle, want: SubagentState, attempts!: Int64 = 50): Bool {
    var i: Int64 = 0
    while (i < attempts) {
        if (h.state().index() == want.index()) { return true }
        sleep(Duration.millisecond * 100)
        i++
    }
    false
}

// start：立即返回句柄；首回合完成 → outbox 收到 done（含子最终文本）；子会话已落库
@Test
public func subagent_start_returnsHandleAndDone() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_1", "初始任务")
    @Expect(h.subSessionId.startsWith("sub_"), true)
    @Expect(h.parentSessionId, "parent_1")
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.kind, AgentMailKindDone)
            @Expect(mail.text, "答: 初始任务")
            @Expect(mail.from, h.subSessionId)
            @Expect(mail.to, "parent_1")
        case None => @Fail("timeout waiting done")
    }
    @Expect(provider.streamCalls, Int64(1))
    @Expect(provider.seenTexts[0], "初始任务")
    @Expect(waitState(h, SubagentState.Idle), true)
    // 注册表可查
    match (mgr.get(h.subSessionId)) {
        case Some(found) => @Expect(found.subSessionId, h.subSessionId)
        case None => @Fail("manager.get failed")
    }
    @Expect(mgr.has(h.subSessionId), true)
    @Expect(mgr.size(), Int64(1))
}

// 消息唤醒：首回合 done 后子空闲；send 新消息 → 子开新回合并 reply
@Test
public func subagent_send_wakesIdleChild() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_2", "第一单任务")
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) => @Expect(mail.kind, AgentMailKindDone)
        case None => @Fail("timeout waiting done")
    }
    // 空闲后发第二封
    h.send(AgentMail("parent_2", h.subSessionId, AgentMailKindUserText, "第二单任务"))
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.kind, AgentMailKindReply)
            @Expect(mail.text, "答: 第二单任务")
        case None => @Fail("timeout waiting reply")
    }
    @Expect(provider.streamCalls, Int64(2))
    @Expect(provider.seenTexts[1], "第二单任务")
}

// recv 超时：子无新消息 → None（不阻塞死）
@Test
public func subagent_recv_timeoutReturnsNone() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_3", "任务")
    h.recv(timeout: 10 * Duration.second)
    @Expect(h.recv(timeout: 300 * Duration.millisecond).isNone(), true)
}

// close：worker 终止（不再响应 send），状态 Closed，幂等
@Test
public func subagent_close_terminatesWorker() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_4", "任务")
    h.recv(timeout: 10 * Duration.second)
    h.close()
    @Expect(waitState(h, SubagentState.Closed), true)
    // 关闭后 send 不再触发回合
    let callsBefore = provider.streamCalls
    h.send(AgentMail("parent_4", h.subSessionId, AgentMailKindUserText, "不会执行的"))
    sleep(Duration.millisecond * 400)
    @Expect(provider.streamCalls, callsBefore)
    h.close()   // 幂等
    @Expect(h.state().index(), SubagentState.Closed.index())
}

// closeForParent：父会话级联关闭全部子
@Test
public func subagent_closeForParent_cascades() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let a = mgr.start(subConfig(), provider, "parent_5", "任务A")
    let b = mgr.start(subConfig(), provider, "parent_5", "任务B")
    let other = mgr.start(subConfig(), provider, "parent_6", "任务C")
    a.recv(timeout: 10 * Duration.second)
    b.recv(timeout: 10 * Duration.second)
    other.recv(timeout: 10 * Duration.second)
    mgr.closeForParent("parent_5")
    @Expect(waitState(a, SubagentState.Closed), true)
    @Expect(waitState(b, SubagentState.Closed), true)
    @Expect(mgr.size(), Int64(1))   // other 仍在
    @Expect(other.state().index() != SubagentState.Closed.index(), true)
    mgr.closeForParent("parent_6")
    @Expect(waitState(other, SubagentState.Closed), true)
    @Expect(mgr.size(), Int64(0))
}

// cancel：慢回合进行中取消 → 快速收敛并回信（不等 provider 自然结束）
@Test
public func subagent_cancel_interruptsRunningTurn() {
    let provider = SubRecordProvider(chunkDelayMs: 300, chunkCount: 10)  // 全程约 3s
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_7", "慢任务")
    // cancel 立即请求：回合尚未开始则启动即取消；已开始则中断流式，两种路径都快速收敛
    let t0 = MonoTime.now()
    h.cancel()
    // 取消后回合应快速收敛并回信（远小于 3s）；中断时文本为部分累积内容，仅断言非空
    match (h.recv(timeout: 5 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.text != "", true)
        case None => @Fail("timeout: cancel did not converge turn")
    }
    let elapsed = MonoTime.now() - t0
    @Expect(elapsed < Duration.millisecond * 1800, true)
    @Expect(waitState(h, SubagentState.Idle), true)
    h.close()
    @Expect(waitState(h, SubagentState.Closed), true)
}
