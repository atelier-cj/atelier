package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.provider.*
import atelier.tool.*

// ========== EventBus：进程级事件发布/订阅（过滤/退订/容错/可选挂载） ==========

@Test
public func eventBus_publishDeliversAndFilter() {
    let bus = EventBus()
    let got = ArrayList<String>()
    let id = bus.subscribe({ ev => got.add("all") })
    bus.subscribe({ ev => got.add("tool") }, filter: { ev => ev is ToolExecutionEndEvent })
    bus.publish(AgentStartEvent("s1"))
    @Expect(got.size, Int64(1))
    @Expect(got[0], "all")
    bus.publish(ToolExecutionEndEvent("c1", "ok", false))
    @Expect(got.size, Int64(3))
    bus.unsubscribe(id)
    bus.publish(AgentStartEvent("s2"))
    @Expect(got.size, Int64(3))   // 全收订阅已退订；tool 过滤订阅不中 StartEvent
    @Expect(bus.subscriberCount(), Int64(1))
}

@Test
public func eventBus_subscriberErrorIsolation() {
    let bus = EventBus()
    let got = ArrayList<String>()
    bus.subscribe({ ev => throw Exception("boom") })
    bus.subscribe({ ev => got.add("ok") })
    bus.publish(AgentStartEvent("s1"))
    @Expect(got.size, Int64(1))
    @Expect(bus.subscriberCount(), Int64(2))
}

@Test
public func eventBus_runtimePublishesLifecycle() {
    let bus = EventBus()
    let seen = ArrayList<String>()
    bus.subscribe({ ev =>
        match (ev) {
            case _: AgentStartEvent => seen.add("start")
            case _: AgentEndEvent => seen.add("end")
            case _ => ()
        }
    })
    let inner = StubProvider()
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", inner)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let runtime = AgentRuntime(subConfig(), inner, toolReg, store, trustMgr,
        skillReg, agentReg, providerReg, ArrayList<Hook>(),
        SessionEnvironment(), mcpMgr, eventBus: Some(bus))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()
    @Expect(seen.contains("start"), true)
    @Expect(seen.contains("end"), true)
}

// SessionLoop 下传 eventBus（子 agent/ACP 桥回合同样发布）
@Test
public func eventBus_sessionLoopForwards() {
    let bus = EventBus()
    let seen = ArrayList<String>()
    bus.subscribe({ ev =>
        match (ev) {
            case _: AgentStartEvent => seen.add("start")
            case _: AgentEndEvent => seen.add("end")
            case _ => ()
        }
    })
    let inner = StubProvider()
    let toolReg = ToolRegistry()
    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()
    providerReg.register("default", inner)
    let store = MemorySessionStore()
    let mcpMgr = McpManager()
    let loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr,
        eventBus: Some(bus))
    let cfg = subConfig()
    loop.run("sess_eb", "你好", cfg, inner, None, SessionEnvironment(),
        { => false }, { => false })
    @Expect(seen.contains("start"), true)
    @Expect(seen.contains("end"), true)
}
