package atelier.agent

import std.core.Duration
import atelier.provider.ProviderRegistry
import atelier.tool.ToolRegistry
import atelier.session.MemorySessionStore

// `SubAgentManager.create`：宿主只需要给出"子真正需要的那几样"。
//
// 为什么值得单独钉住：`HarnessSpec` 有 17 个字段，而宿主实际必须提供的是
// 工具表 / 会话存储 /（可选）技能表。这条知识一旦散落在各宿主里，
// 每个宿主都要自己判断"哪些字段是必需的"，加错一个默认值就会让子静默变哑。

@Test
public func subagent_create_needsOnlyToolsAndStore() {
    let provider = SubRecordProvider()
    let toolReg = ToolRegistry()
    let store = MemorySessionStore()
    let mgr = SubAgentManager.create(tools: toolReg, store: store)
    let h = mgr.start(subConfig(), provider, "parent_f", "只给工具和存储")
    match (h.recv(timeout: 30 * Duration.second)) {
        case Some(mail) =>
            @Expect(mail.kind, AgentMailKindDone)
            @Expect(mail.text, "答: 只给工具和存储")
        case None => @Fail("timeout waiting done")
    }
    // 子历史必须落到**调用方给的那个** store，而不是 create 内部的某个默认实现
    @Expect(store.load(h.subSessionId).size > 0, true)
}

@Test
public func subagent_create_startByNameWithoutAgentsIsNone() {
    // 没注册 agent 时 startByName 返回 None 而不是抛——`subagent_start` 工具据此报"未知 agent"
    let mgr = SubAgentManager.create(tools: ToolRegistry(), store: MemorySessionStore())
    let h = mgr.startByName("ghost", "parent_g", "hi")
    @Expect(h.isNone(), true)
}

@Test
public func subagent_create_acceptsAgentsForStartByName() {
    // 走 startByName 就必须自己把 agents + providers 放进去（providers 空了会去读环境变量兜底）
    let provider = SubRecordProvider()
    let agentReg = AgentRegistry()
    agentReg.create("worker-a", subConfig())
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let mgr = SubAgentManager.create(tools: ToolRegistry(), store: MemorySessionStore(),
        agents: agentReg, providers: providerReg)
    match (mgr.startByName("worker-a", "parent_h", "按名字启动")) {
        case Some(h) =>
            match (h.recv(timeout: 30 * Duration.second)) {
                case Some(mail) => @Expect(mail.text, "答: 按名字启动")
                case None => @Fail("timeout waiting done")
            }
        case None => @Fail("startByName 应能找到已注册 agent")
    }
}
