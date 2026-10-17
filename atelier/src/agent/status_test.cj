package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.event.EventStream
import atelier.session.SessionEnvironment
import atelier.tool.*
import atelier.provider.*
import atelier.provider.EchoProvider
import atelier.skill.SkillRegistry
import atelier.trust.TrustManager
import atelier.session.MemorySessionStore
import atelier.context.plainTextOf

// ==================== AgentStatus / AgentStatusRegistry ====================

func dummyMsg(t: String): Message { UserMessage(ContentList.ofText(t), 0) }

// 从未登记 → Idle（不是"未知"：没有执行中的回合就是空闲）
@Test
func status_unknownSessionIsIdle() {
    let r = AgentStatusRegistry()
    match (r.statusOf("nope")) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("unknown session must be Idle")
    }
}

// 转变会被记录，且同状态重复设置不重复广播
@Test
func status_transitionIsIdempotent() {
    let r = AgentStatusRegistry()
    let events = ArrayList<AgentStatus>()
    r.subscribe({ e => events.add(e.status) })
    @Expect(r.transition("s1", AgentStatus.Running), true)
    @Expect(r.transition("s1", AgentStatus.Running), false)   // 重复不广播
    @Expect(r.transition("s1", AgentStatus.Idle), true)
    @Expect(events.size, Int64(2))                            // Running + Idle
}

// 状态按会话隔离
@Test
func status_isPerSession() {
    let r = AgentStatusRegistry()
    r.transition("a", AgentStatus.Running)
    match (r.statusOf("a")) {
        case AgentStatus.Running => @Expect(true, true)
        case AgentStatus.Idle => @Fail("a must be Running")
    }
    match (r.statusOf("b")) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("b must be Idle")
    }
}

// 退订生效
@Test
func status_unsubscribeStopsDelivery() {
    let r = AgentStatusRegistry()
    let got = ArrayList<AgentStatus>()
    let off = r.subscribe({ e => got.add(e.status) })
    r.transition("s", AgentStatus.Running)
    off()
    r.transition("s", AgentStatus.Idle)
    @Expect(got.size, Int64(1))
}

// forget 后回到 Idle
@Test
func status_forgetResetsToIdle() {
    let r = AgentStatusRegistry()
    r.transition("s", AgentStatus.Running)
    r.forget("s")
    match (r.statusOf("s")) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("forgotten session must read Idle")
    }
}

// 订阅者抛异常不连坐其它订阅者
@Test
func status_subscriberFailureIsIsolated() {
    let r = AgentStatusRegistry()
    let got = ArrayList<AgentStatus>()
    r.subscribe({ _ => throw Exception("boom") })
    r.subscribe({ e => got.add(e.status) })
    r.transition("s", AgentStatus.Running)
    @Expect(got.size, Int64(1))
}

// ==================== AgentLoop 接口：工厂与插话 ====================

// 默认工厂造出 AgentRuntime（= 改动前行为），且它满足 AgentLoop
@Test
func loop_defaultFactoryCreatesRuntime() {
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager()).withProvider("default", EchoProvider())
    let loop = spec.createLoop(cfgForLoop())
    // 能当 AgentLoop 用：status 可查
    match (loop.status()) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("fresh loop must be Idle")
    }
}

// 注入工厂后 createLoop 走的是注入的实现（可替换性）
@Test
func loop_customFactoryIsUsed() {
    let fake = FakeLoop()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager()).withProvider("default", EchoProvider())
        .withLoopFactory({ _, _ => fake })
    let loop = spec.createLoop(cfgForLoop())
    loop.drive(RunInput(ArrayList<Message>()))
    @Expect(fake.driven, Int64(1))
}

// steer 只收用户消息（其它类型静默忽略，不塞进上下文让模型困惑）
@Test
func loop_steerIgnoresNonUserMessages() {
    let rt = makeRuntimeForSteer()
    // 助手消息不该进队列
    rt.steer("s", AssistantMessage(ContentList.ofText("hi"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    @Expect(rt.pendingSteerCount("s"), Int64(0))
    rt.steer("s", UserMessage(ContentList.ofText("user"), 0))
    @Expect(rt.pendingSteerCount("s"), Int64(1))
}

// 插话标注：进入上下文的文本带「用户中途补充」前缀（与替代指令区分）
@Test
func loop_steerMarksInterjection() {
    let marked = withInterjectionMark(UserMessage(ContentList.ofText("补充一句"), 0))
    match (marked) {
        case um: UserMessage =>
            @Expect(plainTextOf(um).contains("[用户中途补充]"), true)
            @Expect(plainTextOf(um).contains("补充一句"), true)
        case _ => @Fail("mark must keep UserMessage")
    }
}

class FakeLoop <: AgentLoop {
    public var driven: Int64 = 0
    public func status(): AgentStatus { AgentStatus.Idle }
    public func drive(input: RunInput): EventStream<AgentEvent, ArrayList<Message>> {
        this.driven++
        EventStream<AgentEvent, ArrayList<Message>>()
    }
    public func cancel(sessionId: String): Unit {}
    public func steer(sessionId: String, message: Message): Unit {}
    public func inject(sessionId: String, message: Message): Unit {}
    public func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        EventStream<AgentEvent, ArrayList<Message>>()
    }
    public func chatWithSessionId(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>> {
        EventStream<AgentEvent, ArrayList<Message>>()
    }
    public func cancelSession(sessionId: String): Unit {}
    public func compactNow(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): CompactionReport {
        CompactionReport(messages, "manual", false, 0, 0, 0, 0, "fake")
    }
}

func makeRuntimeForSteer(): AgentRuntime {
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager()).withProvider("default", EchoProvider())
    AgentRuntime(spec, cfgForLoop())
}

func cfgForLoop(): AgentConfig {
    AgentConfig("loopcfg", None, "", None, "m", None,
        ArrayList(), ArrayList(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None,
        UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
}

// ==================== 生命周期状态：走真实执行入口 ====================
//
// 这一组用例的存在理由：`AgentStatusRegistry` 自身的用例全绿，但它们直接调
// `transition()` —— 从不经过宿主真实走的入口。曾经因此漏掉两个缺陷：
//   ① 状态只在 `drive()` 里推进，而所有宿主走的都是 `chat*` → status() 永为 Idle；
//   ② 收尾只在正常路径写 Idle，异常路径留在 Running。
// 故这里一律通过 chat / chatWithSessionId 驱动，断言「执行中为 Running、结束后为 Idle」。

// 同一个 agent 同时服务两个会话：键位必须是会话 id，否则互相覆盖
@Test
func lifecycle_concurrentSessionsDoNotOverwrite() {
    let registry = AgentStatusRegistry()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager())
        .withProvider("default", EchoProvider())
        .withStatusRegistry(registry)
    let rt = AgentRuntime(spec, cfgForLoop())

    // 直接经 registry 模拟「A 在跑、B 收尾」
    registry.transition("sessA", AgentStatus.Running)
    registry.transition("sessB", AgentStatus.Running)
    registry.transition("sessB", AgentStatus.Idle)

    match (rt.statusOf("sessA")) {
        case AgentStatus.Running => @Expect(true, true)
        case AgentStatus.Idle => @Fail("A 仍在执行，不应因 B 收尾而变成 Idle")
    }
    match (rt.statusOf("sessB")) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("B 已收尾，必须是 Idle")
    }
}

// 并发会话下无参 status() 必须跟随「本实例最近执行的会话」，不能串台
@Test
func lifecycle_statusFollowsLastExecutedSession() {
    let registry = AgentStatusRegistry()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager())
        .withProvider("default", EchoProvider())
        .withStatusRegistry(registry)
    let rt = AgentRuntime(spec, cfgForLoop())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    rt.chatWithSessionId("sess_latest", msgs, SessionEnvironment()).result()

    // 执行结束后 status() 回答 Idle（键位已指向 sess_latest）
    match (rt.status()) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail("run 结束后必须回到 Idle")
    }
    expectIdle(rt.statusOf("sess_latest"), "run 结束后会话必须为 Idle")
}

// 唯一主干：无论从哪个入口进，执行结束后都必须回到 Idle。
// 这条用例覆盖「status 只挂在 drive 上」那个缺陷：chat 与 drive 的行为必须一致。
@Test
func lifecycle_allEntriesLeaveIdle() {
    let registry = AgentStatusRegistry()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager())
        .withProvider("default", EchoProvider())
        .withStatusRegistry(registry)
    let rt = AgentRuntime(spec, cfgForLoop())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    rt.chat(msgs).result()
    expectIdle(registry.statusOf(rt.recentStatusKey()), "chat 入口收尾后必须 Idle")

    let msgs2 = ArrayList<Message>()
    msgs2.add(UserMessage(ContentList.ofText("hi"), 0))
    rt.drive(RunInput(msgs2, sessionId: "sess_drive")).result()
    expectIdle(registry.statusOf("sess_drive"), "drive 入口收尾后必须 Idle")

    let msgs3 = ArrayList<Message>()
    msgs3.add(UserMessage(ContentList.ofText("hi"), 0))
    rt.chatWithEnv(msgs3, SessionEnvironment()).result()
    expectIdle(registry.statusOf(rt.recentStatusKey()), "chatWithEnv 入口收尾后必须 Idle")
}

// 执行期间必须观测到 Running（而不是等结束后才补记）：
// 用带延时的 EchoProvider 卡住执行，在跑的过程中读状态。
@Test
func lifecycle_runningWhileExecuting() {
    let registry = AgentStatusRegistry()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager())
        .withProvider("default", EchoProvider(300))
        .withStatusRegistry(registry)
    let rt = AgentRuntime(spec, cfgForLoop())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let stream = rt.chatWithSessionId("sess_running", msgs, SessionEnvironment())

    // 短轮询等到 Running（spawn 出线程后才会置位）
    var saw = false
    var i = 0
    while (!saw && i < 40) {
        match (registry.statusOf("sess_running")) {
            case AgentStatus.Running => saw = true
            case AgentStatus.Idle => sleep(Duration.millisecond * 20)
        }
        i++
    }
    @Expect(saw, true)
    stream.result()
    expectIdle(registry.statusOf("sess_running"), "执行结束后必须 Idle")
}

// 异常路径也必须回到 Idle：否则宿主会以为 agent 永久不可用
@Test
func lifecycle_errorPathReturnsIdle() {
    let registry = AgentStatusRegistry()
    let spec = testSpec(ToolRegistry(), TrustManager(), SkillRegistry(), AgentRegistry(),
        ProviderRegistry(), MemorySessionStore(), McpManager())
        .withProvider("default", ThrowingProvider())
        .withStatusRegistry(registry)
    let rt = AgentRuntime(spec, cfgForLoop())

    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    try {
        rt.chatWithSessionId("sess_err", msgs, SessionEnvironment()).result()
    } catch (e: Exception) {
        ()   // 失败是预期：provider 抛错
    }
    // 收尾在 finally 里，但线程调度可能滞后：短轮询
    var idle = false
    var i = 0
    while (!idle && i < 40) {
        match (registry.statusOf("sess_err")) {
            case AgentStatus.Idle => idle = true
            case AgentStatus.Running => sleep(Duration.millisecond * 20)
        }
        i++
    }
    @Expect(idle, true)
}

// 枚举没有 Equatable，@Expect 直接比会推断不出泛型参数 → 用 match 断言
func expectIdle(actual: AgentStatus, msg: String): Unit {
    match (actual) {
        case AgentStatus.Idle => @Expect(true, true)
        case AgentStatus.Running => @Fail(msg)
    }
}

// 每次抛错的 Provider（用于验证异常路径的生命周期收尾）
class ThrowingProvider <: Provider {
    public func name(): String { "throwing" }
    public func chat(req: ChatRequest): ChatResponse {
        throw Exception("provider boom")
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        throw Exception("provider boom")
    }
}
