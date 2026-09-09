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
                        match (b) {
                            case ContentBlock.ImageBlock(_, _) => this.seenImages++
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

@Test
public func sessionLoop_noAttachment_textOnly() {
    let provider = RecordingImageProvider()
    let (loop, _) = makeImageLoop(provider)
    loop.run("sess_img_3", "hello", subConfig(), provider, None, SessionEnvironment(),
        { => false }, { => false })
    @Expect(provider.seenImages, 0)
    @Expect(provider.seenTexts.contains("hello"), true)
}
