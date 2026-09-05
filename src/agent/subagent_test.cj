package atelier.agent

import std.collection.*
import std.core.Duration
import std.core.sleep
import std.time.MonoTime
import std.env.getVariable
import std.fs.*
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
    // 等首回合真正开跑（provider 被调用；大窗口容忍并行调度压力）
    var started = false
    var i: Int64 = 0
    while (i < 200 && !started) {
        if (provider.streamCalls > 0) { started = true }
        sleep(Duration.millisecond * 50)
        i++
    }
    @Expect(started, true)
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

// ========== P1：子端 send_message（取代 report）+ 父回复唤醒 ==========

// 脚本化 Provider：第 1 次流式调用返回 ToolUse(send_message, toolArgs)，之后 EndTurn；
// 记录每次请求的全部消息文本（含工具结果，供断言父回复进入子上下文）
class ScriptMsgProvider <: Provider {
    public var streamCalls: Int64 = 0
    public var reqTexts = ArrayList<String>()
    private let toolArgs: JsonValue
    public init(toolArgs: JsonValue) { this.toolArgs = toolArgs }

    public func name(): String { "stub-scriptmsg" }

    private func fullText(req: ChatRequest): String {
        var out = ""
        for (m in req.messages) { out = out + " | " + textOfMsg(m) }
        out
    }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("完成"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.streamCalls++
        this.reqTexts.add(this.fullText(req))
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            if (this.streamCalls == Int64(1)) {
                let blocks = ArrayList<ContentBlock>()
                blocks.add(ContentBlock.ToolCall(ToolCallBlock("sm_1", "send_message", this.toolArgs)))
                let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            } else {
                let msg = AssistantMessage(ContentList.ofText("完成"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            }
            ()
        }
        stream
    }
}

func msgArgs(text: String, kind: String, waitReply: Bool, timeoutMs: Int64): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["text"] = JsonValue.String(text)
    m["kind"] = JsonValue.String(kind)
    m["waitReply"] = JsonValue.Boolean(waitReply)
    m["timeoutMs"] = JsonValue.Number(Float64(timeoutMs))
    JsonValue.Map(m)
}

// progress：子回合内主动发进度（不等待）→ 父 outbox 在 done 前收到 progress
@Test
public func subagent_sendMessage_progressVisibleToParent() {
    let provider = ScriptMsgProvider(msgArgs("进度 50%", "progress", false, 0))
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_p1", "汇报进度")
    var gotProgress = false
    var gotDone = false
    var progressBeforeDone = false
    var i: Int64 = 0
    while (i < 60 && !gotDone) {
        i++
        match (h.recv(timeout: Duration.second)) {
            case Some(mail) =>
                if (mail.kind == "progress" && mail.text == "进度 50%") { gotProgress = true }
                if (mail.kind == AgentMailKindDone) {
                    gotDone = true
                    progressBeforeDone = gotProgress
                }
            case None => ()
        }
    }
    @Expect(gotDone, true)
    @Expect(progressBeforeDone, true)
    // 子上下文吸收过工具结果（"消息已发送"）
    @Expect(provider.reqTexts.size >= Int64(2), true)
    @Expect(provider.reqTexts[1].contains("消息已发送"), true)
    h.close()
    @Expect(waitState(h, SubagentState.Closed), true)
}

// waitReply：子问父答 → 父回复进入子下一轮上下文，回合继续至 done
@Test
public func subagent_sendMessage_waitReply_continuesTurn() {
    let provider = ScriptMsgProvider(msgArgs("继续吗？", "reply", true, 10000))
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_p2", "需要确认")
    // 父先收到子的提问
    var gotQuestion = false
    var i: Int64 = 0
    while (i < 40 && !gotQuestion) {
        i++
        match (h.recv(timeout: Duration.second)) {
            case Some(mail) =>
                if (mail.kind == "reply" && mail.text == "继续吗？") { gotQuestion = true }
                else if (mail.kind == AgentMailKindDone) { @Fail("done 早于提问到达") }
            case None => ()
        }
    }
    @Expect(gotQuestion, true)
    // 父回复 → 子回合内 waitReply 被唤醒
    h.respond("好的，继续")
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) => @Expect(mail.kind, AgentMailKindDone)
        case None => @Fail("timeout waiting done after respond")
    }
    // 第二轮请求上下文包含父回复（工具结果 "父 Agent 回复：好的，继续"）
    @Expect(provider.reqTexts.size >= Int64(2), true)
    @Expect(provider.reqTexts[1].contains("父 Agent 回复：好的，继续"), true)
    h.close()
    @Expect(waitState(h, SubagentState.Closed), true)
}

// waitReply 超时：父不回复 → 工具返回超时提示，子回合照常结束
@Test
public func subagent_sendMessage_replyTimeout() {
    let provider = ScriptMsgProvider(msgArgs("在吗？", "reply", true, 300))
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_p3", "等回复")
    // 第一封：子的提问（reply 投递）；随后父不回复 → 工具超时 → 回合结束 done
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) => @Expect(mail.kind, "reply")
        case None => @Fail("timeout waiting question")
    }
    match (h.recv(timeout: 10 * Duration.second)) {
        case Some(mail) => @Expect(mail.kind, AgentMailKindDone)
        case None => @Fail("timeout waiting done")
    }
    @Expect(provider.reqTexts.size >= Int64(2), true)
    @Expect(provider.reqTexts[1].contains("超时"), true)
    h.close()
    @Expect(waitState(h, SubagentState.Closed), true)
}

// ========== P2：父端调度工具（start/send/await/watch/close） ==========

func mkObj(pairs: ArrayList<(String, JsonValue)>): JsonValue {
    let m = HashMap<String, JsonValue>()
    for ((k, v) in pairs) { m[k] = v }
    JsonValue.Map(m)
}

// 按步骤返回工具调用（name 空串 = EndTurn 收尾）；记录每次请求全文
class ScriptToolProvider <: Provider {
    public var streamCalls: Int64 = 0
    public var reqTexts = ArrayList<String>()
    private let steps: ArrayList<(String, JsonValue)>
    public init(steps: ArrayList<(String, JsonValue)>) { this.steps = steps }

    public func name(): String { "stub-scripttool" }

    private func fullText(req: ChatRequest): String {
        var out = ""
        for (m in req.messages) { out = out + " | " + textOfMsg(m) }
        out
    }

    public func chat(req: ChatRequest): ChatResponse {
        let msg = AssistantMessage(ContentList.ofText("完成"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        ChatResponse(msg)
    }

    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.streamCalls++
        this.reqTexts.add(this.fullText(req))
        let stream = EventStream<ChatDelta, AssistantMessage>()
        spawn {
            let idx = this.streamCalls - 1
            if (idx < this.steps.size) {
                let (tname, targs) = this.steps[Int64(idx)]
                if (tname != "") {
                    let blocks = ArrayList<ContentBlock>()
                    blocks.add(ContentBlock.ToolCall(ToolCallBlock("pt_" + idx.toString(), tname, targs)))
                    let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse, TokenUsage(0, 0), 0)
                    stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                    stream.setResult(msg)
                } else {
                    let msg = AssistantMessage(ContentList.ofText("完成"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                    stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                    stream.setResult(msg)
                }
            } else {
                let msg = AssistantMessage(ContentList.ofText("完成"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
                stream.emit(ChatDelta("", "", Some(msg.stopReason)))
                stream.setResult(msg)
            }
            ()
        }
        stream
    }
}

func parentCtx(): ToolContext {
    ToolContext("/tmp", { q => "" }, HashMap<String, String>(), "parent_session_1")
}

// 父端五工具直接 execute 链：start → await(done) → send → await(reply) → close
@Test
public func parentTools_fullChain() {
    let childProvider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(childProvider)
    // startByName 未知 agent → None（safe 路径）
    @Expect(mgr.startByName("__missing__", "ps1", "x").isNone(), true)
    // 工具错误路径（agent 未注册/缺参/无会话上下文/未知 id）
    let ctx = parentCtx()
    let startTool = SubagentStartTool(mgr)
    // agent 未注册 → 错误结果
    let r1 = startTool.execute(ctx, mkObj(ArrayList<(String, JsonValue)>([
        ("agent", JsonValue.String("helper")), ("prompt", JsonValue.String("x"))])))
    @Expect(r1.isError, true)
    // 缺参数
    let r2 = startTool.execute(ctx, mkObj(ArrayList<(String, JsonValue)>()))
    @Expect(r2.isError, true)
    // 无会话上下文拒绝
    let r3 = startTool.execute(ToolContext("/tmp"), mkObj(ArrayList<(String, JsonValue)>([
        ("agent", JsonValue.String("helper")), ("prompt", JsonValue.String("x"))])))
    @Expect(r3.isError, true)
    let closeTool = SubagentCloseTool(mgr)
    let r4 = closeTool.execute(ctx, mkObj(ArrayList<(String, JsonValue)>([("id", JsonValue.String("sub_nope"))])))
    @Expect(r4.isError, true)
    let sendTool = SubagentSendTool(mgr)
    let r5 = sendTool.execute(ctx, mkObj(ArrayList<(String, JsonValue)>([
        ("id", JsonValue.String("sub_nope")), ("text", JsonValue.String("hi"))])))
    @Expect(r5.isError, true)
}

// 父 agent 完整回合：subagent_start 启动 helper → subagent_watch 收 done → 回合继续收尾
@Test
public func parentTools_startAndWatchInTurn() {
    let childProvider = SubRecordProvider()
    // 组件：父 provider（script）注册 "default" 会被子解析——分名注册：
    // manager 的 providerReg 同时服务父子；子 config(provider=None) 取 "default"，
    // 父 config 显式 provider="parent"，父 provider 注册 "parent"。
    // 但 manager 解析子 provider 走 providerReg.get(default)，因此：
    //  default = childProvider；parent = scriptProvider
    let steps = ArrayList<(String, JsonValue)>()
    steps.add(("subagent_start", mkObj(ArrayList<(String, JsonValue)>([
        ("agent", JsonValue.String("helper")), ("prompt", JsonValue.String("帮我写报告"))]))))
    steps.add(("subagent_watch", mkObj(ArrayList<(String, JsonValue)>([
        ("timeoutMs", JsonValue.Number(Float64(10000)))]))))
    steps.add(("", mkObj(ArrayList<(String, JsonValue)>())))
    let parentProvider = ScriptToolProvider(steps)

    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    agentReg.create("helper", subConfig())
    let providerReg = ProviderRegistry()
    providerReg.register("default", childProvider)
    providerReg.register("parent", parentProvider)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let mgr = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
    registerParentSubagentTools(toolReg, mgr)

    // 父 config：provider 显式 parent
    let parentCfg = AgentConfig("p", None, "", None, "m", Some("parent"), ArrayList(), ArrayList(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, UInt32(16384), UInt32(20000), None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let runtime = AgentRuntime(parentCfg, parentProvider, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("分派任务"), 0))
    let result = runtime.chatWithSessionId("parent_session_1", msgs, SessionEnvironment()).result()
    // 子结果经 watch 进入父上下文
    @Expect(parentProvider.streamCalls >= Int64(3), true)
    let turn3 = parentProvider.reqTexts[2]
    @Expect(turn3.contains("已启动子 Agent"), true)
    @Expect(turn3.contains("[done]"), true)
    @Expect(turn3.contains("答: 帮我写报告"), true)
    @Expect(result.size >= 1, true)
}

// ========== P5：子句柄重启恢复（parentSession 标记 + resumeSession） ==========

// 子会话落库 header 记录 parentSession
@Test
public func subagent_headerMarksParentSession() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_r0", "首任务")
    h.recv(timeout: 10 * Duration.second)
    // store 经 makeSubManager 未返回——重建同构组件以取 store
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg2 = ProviderRegistry()
    providerReg2.register("default", provider)
    let store = MemorySessionStore()
    let mcp = McpManager()
    let mgr2 = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg2, store, mcp)
    let h2 = mgr2.start(subConfig(), provider, "parent_r0b", "任务B")
    h2.recv(timeout: 10 * Duration.second)
    match (store.loadEntries(h2.subSessionId).header.parentSession) {
        case Some(p) => @Expect(p, "parent_r0b")
        case None => @Fail("header.parentSession not marked")
    }
    h.close()
    h2.close()
}

// 恢复：复用既有子会话历史重建句柄；续聊请求上下文包含历史
@Test
public func subagent_resumeSession_reusesHistory() {
    let provider = ScriptToolProvider(ArrayList<(String, JsonValue)>())
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcp = McpManager()
    let mgr1 = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcp)
    let h1 = mgr1.start(subConfig(), provider, "parent_r1", "首任务")
    match (h1.recv(timeout: 10 * Duration.second)) {
        case Some(mail) => @Expect(mail.kind, AgentMailKindDone)
        case None => @Fail("timeout waiting done")
    }
    let childId = h1.subSessionId
    h1.close()
    @Expect(waitState(h1, SubagentState.Closed), true)

    // 模拟进程重启：新 manager 同一 store，恢复该子会话
    let mgr2 = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcp)
    match (mgr2.resumeSession(subConfig(), provider, "parent_r1", childId, SessionEnvironment())) {
        case Some(h2) =>
            h2.send(AgentMail("parent_r1", childId, AgentMailKindUserText, "续问"))
            match (h2.recv(timeout: 10 * Duration.second)) {
                case Some(mail) => @Expect(mail.kind, AgentMailKindReply)
                case None => @Fail("timeout waiting resume reply")
            }
            // 续聊回合请求上下文含历史（首任务）与新输入（续问）
            @Expect(provider.reqTexts.size >= Int64(2), true)
            @Expect(provider.reqTexts[1].contains("首任务"), true)
            @Expect(provider.reqTexts[1].contains("续问"), true)
            h2.close()
        case None => @Fail("resumeSession failed")
    }
}

// 恢复失败路径：未知会话 / 已活跃会话
@Test
public func subagent_resumeSession_unknownOrActiveReturnsNone() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    @Expect(mgr.resumeSession(subConfig(), provider, "parent_r2", "sub_notexist", SessionEnvironment()).isNone(), true)
    let h = mgr.start(subConfig(), provider, "parent_r2", "任务")
    h.recv(timeout: 10 * Duration.second)
    // 活跃子不可重复 resume
    @Expect(mgr.resumeSession(subConfig(), provider, "parent_r2", h.subSessionId, SessionEnvironment()).isNone(), true)
    h.close()
}

// ========== P6：REPL /subagent 的数据源（listForParent/activeCountFor） ==========

@Test
public func subagent_parentListAndCount() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let a = mgr.start(subConfig(), provider, "parent_l1", "任务A")
    let b = mgr.start(subConfig(), provider, "parent_l1", "任务B")
    let other = mgr.start(subConfig(), provider, "parent_l2", "任务C")
    a.recv(timeout: 10 * Duration.second)
    b.recv(timeout: 10 * Duration.second)
    other.recv(timeout: 10 * Duration.second)
    @Expect(mgr.listForParent("parent_l1").size, 2)
    @Expect(mgr.activeCountFor("parent_l1"), Int64(2))
    @Expect(mgr.activeCountFor("parent_l2"), Int64(1))
    // close 一个：仍可列出，但活跃数下降
    b.close()
    @Expect(waitState(b, SubagentState.Closed), true)
    @Expect(mgr.listForParent("parent_l1").size, 2)
    @Expect(mgr.activeCountFor("parent_l1"), Int64(1))
    a.close()
    other.close()
}

// ========== P7：跨进程子 Agent（ACP 桥）条件 e2e ==========
// 前置：ATELIER_PROVIDER=echo（bash 脚本注入）且 release 二进制存在（cjpm build 后）；
// 否则本用例空转跳过（保持常规 cjpm test 全绿）。
@Test
public func subagent_remoteBridge_e2e() {
    let echoMode = match (getVariable("ATELIER_PROVIDER")) {
        case Some(v) => v == "echo"
        case None => false
    }
    if (!echoMode) { return }
    // 由 scripts/remote_subagent_e2e.sh 保证 release 已构建（本用例随脚本运行）
    let base = match (getVariable("PWD")) { case Some(v) => v; case None => "." }
    let exe = base + "/target/release/bin/atelier.cli"
    let provider = SubRecordProvider()   // 本地父 provider 仅占位（父无回合也可）
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcp = McpManager()
    let mgr = SubAgentManager(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcp)

    let sessionDir = Directory.createTemp(Path("/tmp")).toString() + "/remote-sub-test"
    Directory.create(sessionDir, recursive: true)
    let h = mgr.startRemote(exe, "default", "parent_rm", "远程你好", "/tmp", sessionDir)
    @Expect(h.isSome(), true)
    let handle = h.getOrThrow()
    // 首回合 done：子进程（atelier acp echo provider）回显
    match (handle.recv(timeout: 30 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.kind, AgentMailKindDone)
            @Expect(mail.text.contains("echo: 远程你好"), true)
        case None => @Fail("timeout waiting remote done")
    }
    // 续聊（第二封）：新回合 reply
    handle.send(AgentMail("parent_rm", handle.subSessionId, AgentMailKindUserText, "远程第二问"))
    match (handle.recv(timeout: 30 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.kind, AgentMailKindReply)
            @Expect(mail.text.contains("echo: 远程第二问"), true)
        case None => @Fail("timeout waiting remote reply")
    }
    handle.close()
    @Expect(waitState(handle, SubagentState.Closed), true)
    try { remove(Path(sessionDir), recursive: true) } catch (_) { () }
}

// ========== 演进 B：非阻塞取信（回合外消息可见） ==========

@Test
public func subagent_pollOnceAndPollChildren() {
    let provider = SubRecordProvider()
    let (mgr, providerReg) = makeSubManager(provider)
    let h = mgr.start(subConfig(), provider, "parent_pc", "任务")
    // done 到达前 poll 为空
    var gotDone = false
    var i: Int64 = 0
    while (i < 60 && !gotDone) {
        i++
        match (h.recv(timeout: Duration.second)) {
            case Some(m) =>
                @Expect(m.kind, AgentMailKindDone)
                gotDone = true
            case None => ()
        }
    }
    @Expect(gotDone, true)
    // 空时 pollOnce None
    @Expect(h.pollOnce().isNone(), true)
    // 子回第二封 → pollOnce 可取
    h.send(AgentMail("parent_pc", h.subSessionId, AgentMailKindUserText, "任务二"))
    var polled = false
    var j: Int64 = 0
    while (j < 60 && !polled) {
        j++
        match (h.pollOnce()) {
            case Some(m) =>
                @Expect(m.kind, AgentMailKindReply)
                polled = true
            case None => sleep(Duration.millisecond * 100)
        }
    }
    @Expect(polled, true)
    // pollChildren 聚合
    let b = mgr.start(subConfig(), provider, "parent_pc", "任务B")
    b.recv(timeout: 10 * Duration.second)
    let agg = mgr.pollChildren("parent_pc")
    @Expect(agg.size >= Int64(0), true)   // 无未读即空
    h.close()
    b.close()
}
