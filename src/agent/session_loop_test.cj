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
