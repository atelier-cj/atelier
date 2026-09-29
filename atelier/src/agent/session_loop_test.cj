package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.tool.builtin.AskUserTool
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream
import atelier.context.PromptSegmentContributor
import jsonvalue.*

// onEvent 钩子：逐事件回调（ACP 翻译等宿主集成的挂载点）
@Test
public func sessionLoop_onEventSeesLifecycle() {
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", StubProvider())
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
    let events = ArrayList<String>()
    let cfg = subConfig()
    let outcome = loop.run("sess_loop_1", "你好", cfg, StubProvider(), None, SessionEnvironment(),
        { => false }, { => false },
        onEvent: { ev =>
            match (ev) {
                case _: AgentStartEvent => events.add("start")
                case _: AgentEndEvent => events.add("end")
                case _ => ()
            }
        })
    @Expect(events.size >= Int64(2), true)
    @Expect(events[0], "start")
    @Expect(events[events.size - 1], "end")
    @Expect(outcome.messages.size >= Int64(2), true)   // user + assistant 已落库结果
    @Expect(outcome.stoppedByClose, false)
    // 落库可查
    @Expect(store.load("sess_loop_1").size >= Int64(2), true)
}

// askUserFn 注入：ask_user 工具回合走注入实现（ACP Elicitation 桥的挂载点）
@Test
public func sessionLoop_askUserFnInjectedToAskTool() {
    let asked = ArrayList<String>()
    // 回合脚本：第 1 轮调 ask_user，第 2 轮 EndTurn
    let steps = ArrayList<(String, JsonValue)>()
    let args = HashMap<String, JsonValue>()
    args["question"] = JsonValue.String("方案 A 还是 B？")
    steps.add(("ask_user", JsonValue.Map(args)))
    steps.add(("", JsonValue.Map(HashMap<String, JsonValue>())))
    let provider = ScriptToolProvider(steps)

    let toolReg = ToolRegistry()
    toolReg.register(AskUserTool())
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
    let cfg = subConfig()
    let askFn: (String) -> String = { q => asked.add(q); "选 A" }
    loop.run("sess_ask_1", "帮我决策", cfg, provider, None, SessionEnvironment(),
        { => false }, { => false }, askUserFn: askFn)
    @Expect(asked.size, 1)
    @Expect(asked[0], "方案 A 还是 B？")
    // 答案作为工具结果进入第二轮上下文
    @Expect(provider.reqTexts.size >= Int64(2), true)
    @Expect(provider.reqTexts[1].contains("选 A"), true)
}

// promptContributors 下传：SessionLoop 构造注入 → 回合内 runtime 系统提示含自定义段
class SegContributor <: PromptSegmentContributor {
    public func render(env: SessionEnvironment): String { "[Test Seg]\n来自宿主" }
}

@Test
public func sessionLoop_forwardsPromptContributors() {
    let provider = ScriptToolProvider(ArrayList<(String, JsonValue)>())
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let cs = ArrayList<PromptSegmentContributor>()
    cs.add(SegContributor())
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr,
        promptContributors: cs)
    let cfg = subConfig()
    let outcome = loop.run("sess_pc", "你好", cfg, provider, None, SessionEnvironment(),
        { => false }, { => false })
    @Expect(outcome.messages.size >= Int64(1), true)
    @Expect(provider.reqTexts.size >= Int64(1), true)
    @Expect(provider.reqTexts[0].contains("[Test Seg]"), true)
    @Expect(provider.reqTexts[0].contains("来自宿主"), true)
}

// ========== 图片输入（ImageBlock attachments） ==========

// 记录请求消息中图片/文本的 provider：验证图片块到达协议层
class RecordingImageProvider <: Provider {
    public var seenImages: Int64 = 0
    public var seenTexts = ArrayList<String>()
    public func name(): String { "rec" }
    private func record(req: ChatRequest): Unit {
        for (m in req.messages) {
            match (m) {
                case um: UserMessage =>
                    for (b in um.content.blocks()) {
                        // 用 isImageBlock 而非逐个 match：图片有多种形态（内联/URL、带 detail、
                        // Files API 引用），漏一种就会让"图片没到协议层"被误判成通过
                        if (isImageBlock(b)) { this.seenImages++ }
                        match (b) {
                            case ContentBlock.TextBlock(t) => this.seenTexts.add(t)
                            case _ => ()
                        }
                    }
                case _ => ()
            }
        }
    }
    public func chat(req: ChatRequest): ChatResponse {
        this.record(req)
        ChatResponse(AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.record(req)
        let s = EventStream<ChatDelta, AssistantMessage>()
        let msg = AssistantMessage(ContentList.ofText("ok"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0)
        s.emit(ChatDelta("", "", Some(StopReason.EndTurn)))
        s.setResult(msg)
        s
    }
}

func makeImageLoop(provider: Provider): (SessionLoop, MemorySessionStore) {
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
    (loop, store)
}

@Test
public func sessionLoop_imageAttachment_reachesProviderAndPersists() {
    let provider = RecordingImageProvider()
    let (loop, store) = makeImageLoop(provider)
    let att = ArrayList<ContentBlock>()
    att.add(ContentBlock.ImageBlock("aGVsbG8=", "image/png"))
    loop.run("sess_img_1", "图里有什么", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false }, attachments: att)
    // 协议层收到：user 消息含 1 张图 + 文本
    @Expect(provider.seenImages, 1)
    @Expect(provider.seenTexts.contains("图里有什么"), true)
    // 会话持久化 roundtrip：ImageBlock 还原
    let msgs = store.load("sess_img_1")
    var foundImage = false
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                for (b in um.content.blocks()) {
                    match (b) {
                        case ContentBlock.ImageBlock(d, mm) =>
                            if (d == "aGVsbG8=" && mm == "image/png") { foundImage = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(foundImage, true)
}

@Test
public func sessionLoop_imageOnlyAttachment_noText() {
    let provider = RecordingImageProvider()
    let (loop, _) = makeImageLoop(provider)
    let att = ArrayList<ContentBlock>()
    att.add(ContentBlock.ImageBlock("eA==", "image/jpeg"))
    loop.run("sess_img_2", "", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false }, attachments: att)
    @Expect(provider.seenImages, 1)
    @Expect(provider.seenTexts.size, 0)
}

// Files API 引用：本地只有 file_id，会话里必须把它存住 —— 丢了 file_id，
// 重放历史时这张图就彻底消失了（服务端数据没有本地线索可查）
@Test
public func sessionLoop_fileRefAttachment_reachesProviderAndPersists() {
    let provider = RecordingImageProvider()
    let (loop, store) = makeImageLoop(provider)
    let att = ArrayList<ContentBlock>()
    att.add(ContentBlock.ImageFileBlock("file-api-abc123"))
    loop.run("sess_img_file", "这是什么", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false }, attachments: att)
    @Expect(provider.seenImages, 1)
    let msgs = store.load("sess_img_file")
    var found = false
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                for (b in um.content.blocks()) {
                    match (b) {
                        case ContentBlock.ImageFileBlock(f) =>
                            if (f == "file-api-abc123") { found = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(found, true)
}

// detail 属于"图片怎么被处理"的一部分：不存住，重放历史时会悄悄退回服务端默认粒度
@Test
public func sessionLoop_imageDetailSurvivesRoundTrip() {
    let provider = RecordingImageProvider()
    let (loop, store) = makeImageLoop(provider)
    let att = ArrayList<ContentBlock>()
    att.add(ContentBlock.ImageBlock("aGVsbG8=", "image/png", "low"))
    loop.run("sess_img_detail", "看图", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false }, attachments: att)
    @Expect(provider.seenImages, 1)
    let msgs = store.load("sess_img_detail")
    var found = false
    for (m in msgs) {
        match (m) {
            case um: UserMessage =>
                for (b in um.content.blocks()) {
                    match (b) {
                        case ContentBlock.ImageBlock(d, _, detail) =>
                            if (d == "aGVsbG8=" && detail == "low") { found = true }
                        case _ => ()
                    }
                }
            case _ => ()
        }
    }
    @Expect(found, true)
}

@Test
public func sessionLoop_noAttachment_textOnly() {
    let provider = RecordingImageProvider()
    let (loop, _) = makeImageLoop(provider)
    loop.run("sess_img_3", "hello", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false })
    @Expect(provider.seenImages, 0)
    @Expect(provider.seenTexts.contains("hello"), true)
}

// ========== 回合消费循环的收尾哨兵（生产端线程没了也不能空转） ==========

func outcomeName(o: ConsumeOutcome): String {
    match (o) {
        case ConsumeOutcome.Ended => "ended"
        case ConsumeOutcome.Stopped => "stopped"
        case ConsumeOutcome.ClosedNoEnd => "closed-no-end"
    }
}

// 构造回合事件流：emitEnd 控制是否发 AgentEndEvent，closeIt 控制是否置收尾哨兵
func fakeTurnStream(emitEnd: Bool, closeIt: Bool): EventStream<AgentEvent, ArrayList<Message>> {
    let s = EventStream<AgentEvent, ArrayList<Message>>()
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    s.emit(AgentStartEvent("s1"))
    if (emitEnd) { s.emit(AgentEndEvent(msgs)) }
    s.setResult(msgs)
    if (closeIt) { s.close() }
    s
}

@Test
public func consumeTurnStream_endsOnAgentEndEvent() {
    let s = fakeTurnStream(true, true)
    let seen = ArrayList<String>()
    let outcome = consumeTurnStream(s, { => false }, { => false },
        Some({ ev => seen.add(ev.eventType()) }), { => () })
    @Expect(outcomeName(outcome), "ended")
    @Expect(seen.size, 2)
    @Expect(seen[0], "agent_start")
    @Expect(seen[1], "agent_end")
}

// 回归：生产端已收尾却没发终止事件（线程被 Error 带走、或收尾路径漏发）时，
// 消费循环必须收敛——以前这里是 `while (!ended)` 空转，等一个永远不会来的事件。
@Test
public func consumeTurnStream_closedWithoutEndStopsSpinning() {
    let s = fakeTurnStream(false, true)
    let outcome = consumeTurnStream(s, { => false }, { => false }, None, { => () })
    @Expect(outcomeName(outcome), "closed-no-end")
}

@Test
public func consumeTurnStream_requestStopCancelsTurnAndStops() {
    let s = fakeTurnStream(false, false)
    let cancels = ArrayList<String>()
    let outcome = consumeTurnStream(s, { => true }, { => false }, None, { => cancels.add("cancel") })
    @Expect(outcomeName(outcome), "stopped")
    @Expect(cancels.size, 1)
}

// 早到的取消请求：AgentStartEvent 到达（runtime 已注册 cancelFlag）后补发
@Test
public func consumeTurnStream_cancelRequestDeliveredAfterStart() {
    let s = fakeTurnStream(true, true)
    let cancels = ArrayList<String>()
    let outcome = consumeTurnStream(s, { => false }, { => true }, None, { => cancels.add("cancel") })
    @Expect(outcomeName(outcome), "ended")
    @Expect(cancels.size >= Int64(1), true)
}
