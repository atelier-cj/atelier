package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream
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
        { ev =>
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
