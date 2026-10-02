package atelier.a2a

import std.collection.*
import std.fs.*
import std.sync.*
import std.core.{sleep, Duration}
import jsonvalue.*
import a2a.*
import atelier.agent.*
import atelier.provider.{EchoProvider, ProviderRegistry}
import atelier.session.MemorySessionStore
import atelier.skill.{Skill, SkillRegistry}
import atelier.tool.{McpManager, ToolRegistry}
import atelier.trust.TrustManager
import atelier.interaction.*
import atelier.message.{AssistantMessage, ContentList, StopReason, TokenUsage, ToolResultMessage}

private func a2aBridgeTempDir(): String {
    Directory.createTemp(Path("/tmp")).toString()
}

private func a2aBridgeCleanup(dir: String): Unit {
    try { remove(Path(dir), recursive: true) } catch (_) { () }
}

private func a2aTestSkill(name: String): Skill {
    Skill(name, "技能 " + name, None, None, HashMap<String, String>(),
        ArrayList<String>(), "", "")
}

private func a2aTestSpec(skillNames: ArrayList<String>): HarnessSpec {
    let skills = SkillRegistry()
    for (n in skillNames) {
        skills.register(a2aTestSkill(n))
    }
    HarnessSpec(tools: ToolRegistry(), store: MemorySessionStore(), trust: TrustManager(),
        skills: skills, agents: AgentRegistry(), providers: ProviderRegistry(), mcp: McpManager())
}

private func a2aTestConfig(skillNames: ArrayList<String>): AgentConfig {
    AgentConfig("echo-agent", Some("回显测试 agent"), "你是测试 agent", None,
        "echo", None, ArrayList<String>(), skillNames, 0,
        4, 0.0, 1024, None, false, None, 8, 30, 0,
        ArrayList<String>(), None, 0, 0)
}

private func a2aEmptyArgs(): JsonValue {
    JsonValue.Map(HashMap<String, JsonValue>())
}

private func a2aUserMessage(text: String): Message {
    Message("m1", Role.User, ArrayList<Part>([Part.ofText(text)]))
}

private func a2aTaskOf(store: TaskStore, id: String): Task {
    match (store.get(id)) {
        case Some(t) => t
        case None => @Fail("task not found: " + id)
    }
}

private func a2aArtifactsText(task: Task): String {
    let sb = StringBuilder()
    for (a in task.artifacts) {
        for (p in a.parts) {
            match (p.text) {
                case Some(t) => sb.append(t)
                case None => ()
            }
        }
    }
    sb.toString()
}

// ---------- Agent Card ----------

// 卡片取 agent 配置的 name/description，技能只列「配置声明 + 注册表里真的存在」的
@Test
func a2aBridge_agentCardFromConfigListsRegisteredSkills() {
    let declared = ArrayList<String>()
    declared.add("alpha")
    declared.add("missing")
    let spec = a2aTestSpec(ArrayList<String>(["alpha"]))
    let cfg = a2aTestConfig(declared)
    let card = agentCardFromConfig(cfg, spec, "http://127.0.0.1:9999", "0.1.12")
    @Expect(card.name, "echo-agent")
    @Expect(card.version, "0.1.12")
    @Expect(card.description, "回显测试 agent")
    @Expect(card.capabilities.streaming, true)
    @Expect(card.supportedInterfaces.size, 1)
    @Expect(card.supportedInterfaces[0].protocolBinding, BindingJsonRpc)
    @Expect(card.supportedInterfaces[0].url, "http://127.0.0.1:9999")
    @Expect(card.skills.size, 1)
    @Expect(card.skills[0].id, "alpha")
    @Expect(card.skills[0].description, "技能 alpha")
}

// 描述缺省时给一句兜底文案（卡片 description 是必填字段）
@Test
func a2aBridge_agentCardFallsBackDescription() {
    let cfg = AgentConfig("solo", None, "sp", None,
        "echo", None, ArrayList<String>(), ArrayList<String>(), 0,
        4, 0.0, 1024, None, false, None, 8, 30, 0,
        ArrayList<String>(), None, 0, 0)
    let card = agentCardFromConfig(cfg, a2aTestSpec(ArrayList<String>()), "http://x", "1.0.0")
    @Expect(card.description, "atelier agent 'solo'")
    @Expect(card.skills.size, 0)
}

// ---------- 挂起提问的答复折算 ----------

// 选项 id / label 精确匹配优先（审批三态、选择项都走这条）
@Test
func a2aBridge_answerMatchesOptionIdAndLabel() {
    let req = approvalRequest("ask:1", "bash", a2aEmptyArgs(), "执行 bash？")
    let byId = a2aAnswerFor(req, "deny")
    @Expect(byId.statusName(), "answered")
    @Expect(byId.selected.size, 1)
    @Expect(byId.selected[0], "deny")
    // label 也认（"总是允许" → allow_always）
    let byLabel = a2aAnswerFor(req, "总是允许")
    @Expect(byLabel.selected.size, 1)
    @Expect(byLabel.selected[0], "allow_always")
}

// 审批类再认常见肯定 / 否定说法
@Test
func a2aBridge_answerNormalizesApprovalWords() {
    let req = approvalRequest("ask:2", "bash", a2aEmptyArgs(), "执行 bash？")
    let yes = a2aAnswerFor(req, "yes")
    @Expect(yes.selected.size, 1)
    @Expect(yes.selected[0], "allow_once")
    let no = a2aAnswerFor(req, "拒绝")
    @Expect(no.selected.size, 1)
    @Expect(no.selected[0], "deny")
    // 认不出的文本仍作为自由文本答复（合法性由 runtime 侧校验兜底）
    let free = a2aAnswerFor(req, "先跑 ls 看看")
    @Expect(free.selected.size, 0)
    @Expect(free.text, "先跑 ls 看看")
    @Expect(free.statusName(), "answered")
}

// 续聊消息到达时，把文本折算给全部挂起提问；没有挂起时不动既有答复
@Test
func a2aBridge_absorbPendingAnswersFillsHostAnswers() {
    let session = A2aSession("ctx_1", "/w", "sess_1", "")
    let host = A2aTaskHost(session, "task_1", "ctx_1")
    let req = approvalRequest("ask:3", "bash", a2aEmptyArgs(), "执行 bash？")
    host.pending[req.id] = req
    absorbPendingAnswers(host, "allow_once")
    @Expect(host.pending.size, 0)
    @Expect(host.answers.size, 1)
    match (host.answers.get("ask:3")) {
        case Some(a) =>
            @Expect(a.selected.size, 1)
            @Expect(a.selected[0], "allow_once")
        case None => @Fail("answer not recorded")
    }
    absorbPendingAnswers(host, "另一条消息")
    @Expect(host.answers.size, 1)
}

// ---------- 事件 → 队列转投 ----------

// 翻译器的 status / artifact 输出必须走 EventQueue 原语，任务快照与事件流才一致
@Test
func a2aBridge_forwardsTranslatorOutputIntoTaskStore() {
    let ctx = RequestContext("task_1", "ctx_1", a2aUserMessage("hi"))
    let store = InMemoryTaskStore()
    let channel = TaskChannel()
    let queue = EventQueue(ctx, store, channel)
    let t = A2aTranslator("task_1", "ctx_1")

    forwardToQueue(queue, t.translate(TurnStartEvent()))
    let working = a2aTaskOf(store, "task_1")
    @Expect(working.status.state, TaskState.Working)

    let msg = AssistantMessage(ContentList.ofText("答案"), "", "",
        StopReason.EndTurn, TokenUsage(0, 0), 0)
    forwardToQueue(queue, t.translate(TurnEndEvent(msg, ArrayList<ToolResultMessage>())))

    let task = a2aTaskOf(store, "task_1")
    @Expect(task.status.state, TaskState.Completed)
    @Expect(task.artifacts.size, 1)
    @Expect(a2aArtifactsText(task), "答案")
    @Expect(queue.isClosed(), true)
    // 事件顺序：WORKING → 产物 → COMPLETED
    @Expect(channel.eventCount(), Int64(3))
}

// ---------- 端到端：execute 跑完一个回合 ----------

// execute 走 SessionLoop 跑完一回合：会话映射/任务索引落地，任务进终态且产物是模型回复
@Test
func a2aBridge_executeRunsTurnAndCompletesTask() {
    let dir = a2aBridgeTempDir()
    let spec = a2aTestSpec(ArrayList<String>())
    let cfg = a2aTestConfig(ArrayList<String>())
    let bridge = A2aBridge(spec, cfg, EchoProvider(), dir + "/a2a-sessions.json", dir)

    let ctx = RequestContext("task_e2e", "ctx_e2e", a2aUserMessage("你好"))
    let store = InMemoryTaskStore()
    let channel = TaskChannel()
    let queue = EventQueue(ctx, store, channel)
    bridge.execute(ctx, queue)
    // 服务端在 execute 返回后统一收尾（这里模拟 runExecutor）
    queue.finish()

    let task = a2aTaskOf(store, "task_e2e")
    @Expect(task.status.state, TaskState.Completed)
    @Expect(task.contextId.isSome(), true)
    @Expect(a2aArtifactsText(task).contains("echo: 你好"), true)
    @Expect(queue.isClosed(), true)

    // 会话映射 + 任务级索引（tasks/get / resubscribe 的寻址信息）
    @Expect(bridge.sessions().size(), Int64(1))
    match (bridge.sessions().lookup("ctx_e2e")) {
        case Some(s) => @Expect(s.cwd, dir)
        case None => @Fail("session mapping missing")
    }
    match (bridge.sessions().lookupTask("task_e2e")) {
        case Some(b) =>
            @Expect(b.contextId, "ctx_e2e")
            @Expect(b.turn, 1)
        case None => @Fail("task binding missing")
    }
    a2aBridgeCleanup(dir)
}

// tasks/cancel：回合跑动中被取消 → 任务终态是 CANCELED（不是 COMPLETED，也不是停在 WORKING）
@Test
func a2aBridge_cancelDuringExecuteEndsCanceled() {
    let dir = a2aBridgeTempDir()
    let spec = a2aTestSpec(ArrayList<String>())
    let cfg = a2aTestConfig(ArrayList<String>())
    // EchoProvider 的延时就是为取消路径准备的：回合还在跑时才能取消到
    let bridge = A2aBridge(spec, cfg, EchoProvider(600), dir + "/a2a-sessions.json", dir)
    let ctx = RequestContext("task_cancel", "ctx_cancel", a2aUserMessage("慢一点"))
    let store = InMemoryTaskStore()
    let queue = EventQueue(ctx, store, TaskChannel())

    let done = AtomicBool(false)
    spawn {
        bridge.execute(ctx, queue)
        done.store(true)
    }
    sleep(Duration.millisecond * 150)
    ctx.requestCancel()
    var waited = 0
    while (!done.load() && waited < 8000) {
        sleep(Duration.millisecond * 20)
        waited += 20
    }
    @Expect(done.load(), true)
    let task = a2aTaskOf(store, "task_cancel")
    @Expect(task.status.state, TaskState.Canceled)
    a2aBridgeCleanup(dir)
}

// 同一 context 的第二次 execute（新任务）复用同一 atelier 会话，历史延续
@Test
func a2aBridge_executeReusesSessionAcrossTasks() {
    let dir = a2aBridgeTempDir()
    let spec = a2aTestSpec(ArrayList<String>())
    let cfg = a2aTestConfig(ArrayList<String>())
    let bridge = A2aBridge(spec, cfg, EchoProvider(), dir + "/a2a-sessions.json", dir)

    let store1 = InMemoryTaskStore()
    let ctx1 = RequestContext("task_1", "ctx_shared", a2aUserMessage("第一句"))
    bridge.execute(ctx1, EventQueue(ctx1, store1, TaskChannel()))
    let store2 = InMemoryTaskStore()
    let ctx2 = RequestContext("task_2", "ctx_shared", a2aUserMessage("第二句"))
    bridge.execute(ctx2, EventQueue(ctx2, store2, TaskChannel()))

    // 一个 context = 一个 atelier 会话；两个任务都在
    @Expect(bridge.sessions().size(), Int64(1))
    @Expect(bridge.sessions().taskSize(), Int64(2))
    @Expect(a2aTaskOf(store1, "task_1").status.state, TaskState.Completed)
    @Expect(a2aTaskOf(store2, "task_2").status.state, TaskState.Completed)
    match (bridge.sessions().lookup("ctx_shared")) {
        case Some(s) =>
            // 会话里累积了两轮的 user + assistant（复用而不是每次新建会话）
            @Expect(spec.store.load(s.atelierId).size >= 4, true)
        case None => @Fail("session missing")
    }
    match (bridge.sessions().lookupTask("task_2")) {
        case Some(b) => @Expect(b.contextId, "ctx_shared")
        case None => @Fail("task_2 binding missing")
    }
    a2aBridgeCleanup(dir)
}

// 配置没写名字时用启动时选定的 agent 名兜底：A2A 卡片的 name 是必填非空字段
@Test
func a2aBridge_agentCardFallsBackToAgentName() {
    let cfg = AgentConfig("", None, "sp", None, "echo", None,
        ArrayList<String>(), ArrayList<String>(), 0,
        4, 0.0, 1024, None, false, None, 8, 30, 0,
        ArrayList<String>(), None, 0, 0)
    let spec = a2aTestSpec(ArrayList<String>())
    let card = agentCardFromConfig(cfg, spec, "http://x", "1.0.0", name: "default")
    @Expect(card.name, "default")
    @Expect(card.description, "atelier agent 'default'")
    let bare = agentCardFromConfig(cfg, spec, "http://x", "1.0.0")
    @Expect(bare.name, "atelier")
}


// 能力声明必须与 ServerOptions 一致：默认不开推送，显式开启才声明 ——
// 卡片是对外承诺，「声明了做不到」比不声明更糟。
@Test
func a2aBridge_agentCardPushNotificationIsOptIn() {
    let spec = a2aTestSpec(ArrayList<String>())
    let cfg = a2aTestConfig(ArrayList<String>())

    let off = agentCardFromConfig(cfg, spec, "http://127.0.0.1:9999", "0.1.12")
    @Expect(off.capabilities.pushNotifications, false)

    let on = agentCardFromConfig(cfg, spec, "http://127.0.0.1:9999", "0.1.12",
        pushNotifications: true)
    @Expect(on.capabilities.pushNotifications, true)
}

// 多绑定：supportedInterfaces 的声明顺序 = 客户端的选择偏好顺序。
// 两种绑定共用一个地址（同端口按绑定分流），客户端换绑定不必换 url。
@Test
func a2aBridge_agentCardDeclaresBothBindingsInOrder() {
    let spec = a2aTestSpec(ArrayList<String>())
    let cfg = a2aTestConfig(ArrayList<String>())
    let bindings = ArrayList<String>([BindingJsonRpc, BindingHttpJson])

    let card = agentCardFromConfig(cfg, spec, "http://127.0.0.1:9999", "0.1.12",
        bindings: bindings, pushNotifications: true)

    @Expect(card.supportedInterfaces.size, 2)
    @Expect(card.supportedInterfaces[0].protocolBinding, BindingJsonRpc)
    @Expect(card.supportedInterfaces[1].protocolBinding, BindingHttpJson)
    @Expect(card.supportedInterfaces[1].url, "http://127.0.0.1:9999")
}
