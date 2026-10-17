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
