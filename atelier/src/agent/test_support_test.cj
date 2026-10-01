package atelier.agent

import std.collection.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.provider.*
import atelier.context.PromptSegmentContributor

/**
 * 测试装配助手。
 *
 * 生产侧只有一个构造（`AgentRuntime(spec, cfg)`）；这里保留「组件逐个列出」的装配顺序，
 * 只是把它们收进装配束，避免每条用例都写一遍 `HarnessSpec(...)`。仅测试期编译
 * （`*_test.cj`），不进发布制品。
 */

func testSpec(toolReg: ToolRegistry, trustMgr: TrustManager, skillReg: SkillRegistry,
    agentReg: AgentRegistry, providerReg: ProviderRegistry, store: SessionStore,
    mcpMgr: McpManager): HarnessSpec {
    HarnessSpec(tools: toolReg, store: store, trust: trustMgr, skills: skillReg,
        agents: agentReg, providers: providerReg, mcp: mcpMgr)
}

// 9 参（mcpMgr [+ ask]）
func testRuntime(cfg: AgentConfig, provider: Provider, toolReg: ToolRegistry, store: SessionStore,
    trustMgr: TrustManager, skillReg: SkillRegistry, agentReg: AgentRegistry,
    providerReg: ProviderRegistry, mcpMgr: McpManager,
    ask!: Option<AskFn> = None): AgentRuntime {
    testRuntime(cfg, provider, toolReg, store, trustMgr, skillReg, agentReg, providerReg,
        ArrayList<Hook>(), SessionEnvironment(), mcpMgr, ask: ask)
}

// 11 参（hooks + mcpMgr [+ ask]）
func testRuntime(cfg: AgentConfig, provider: Provider, toolReg: ToolRegistry, store: SessionStore,
    trustMgr: TrustManager, skillReg: SkillRegistry, agentReg: AgentRegistry,
    providerReg: ProviderRegistry, hooks: ArrayList<Hook>, mcpMgr: McpManager,
    ask!: Option<AskFn> = None): AgentRuntime {
    testRuntime(cfg, provider, toolReg, store, trustMgr, skillReg, agentReg, providerReg,
        hooks, SessionEnvironment(), mcpMgr, ask: ask)
}

// 最全：hooks + 会话环境 + 命名可选（ask / 提示段 / 中间件 / 事件总线）
func testRuntime(cfg: AgentConfig, provider: Provider, toolReg: ToolRegistry, store: SessionStore,
    trustMgr: TrustManager, skillReg: SkillRegistry, agentReg: AgentRegistry,
    providerReg: ProviderRegistry, hooks: ArrayList<Hook>, sessionEnv: SessionEnvironment,
    mcpMgr: McpManager,
    ask!: Option<AskFn> = None,
    promptContributors!: ArrayList<PromptSegmentContributor> = ArrayList(),
    middlewares!: ArrayList<ProviderMiddleware> = ArrayList(),
    eventBus!: ?EventBus = None): AgentRuntime {
    var spec = testSpec(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
        .withProvider(providerNameOf(cfg), provider)
        .withHooks(hooks)
        .withContributors(promptContributors)
        .withMiddlewares(middlewares)
    match (ask) {
        case Some(f) => spec = spec.withAsk(f)
        case None => ()
    }
    match (eventBus) {
        case Some(bus) => spec = spec.withEventBus(bus)
        case None => ()
    }
    AgentRuntime(spec, cfg, sessionEnv: sessionEnv)
}

func testSessionLoop(toolReg: ToolRegistry, trustMgr: TrustManager, skillReg: SkillRegistry,
    agentReg: AgentRegistry, providerReg: ProviderRegistry, store: SessionStore,
    mcpMgr: McpManager,
    promptContributors!: ArrayList<PromptSegmentContributor> = ArrayList(),
    middlewares!: ArrayList<ProviderMiddleware> = ArrayList(),
    eventBus!: ?EventBus = None): SessionLoop {
    var spec = testSpec(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr)
        .withContributors(promptContributors)
        .withMiddlewares(middlewares)
    match (eventBus) {
        case Some(bus) => spec = spec.withEventBus(bus)
        case None => ()
    }
    SessionLoop(spec)
}

func testSubAgentManager(toolReg: ToolRegistry, trustMgr: TrustManager, skillReg: SkillRegistry,
    agentReg: AgentRegistry, providerReg: ProviderRegistry, store: SessionStore,
    mcpMgr: McpManager, idleTimeoutSec!: Int64 = 0): SubAgentManager {
    SubAgentManager(testSpec(toolReg, trustMgr, skillReg, agentReg, providerReg, store, mcpMgr),
        idleTimeoutSec: idleTimeoutSec)
}
