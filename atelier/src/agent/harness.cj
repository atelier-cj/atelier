package atelier.agent

import std.collection.*
import std.env.getVariable
import stdx.log.*
import atelier.message.*
import atelier.tool.*
import atelier.tool.builtin.{ReadFileTool, WriteFileTool, EditFileTool, BashTool, GrepTool, GlobTool,
    TodoTool, AskUserTool, UseSkillsTool}
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import atelier.trust.*
import atelier.context.ModelContextRegistry
import atelier.context.PromptSegmentContributor
import atelier.event.EventStream

/**
 * 装配束：一次说清「这个 Harness 由哪些组件构成」。
 *
 * 定位是**值**，不是容器 —— 宿主在组合根显式装一次，之后用 `with*` 派生（浅拷贝，
 * 组件本身是引用），而不是让运行期去发现/注入：
 *
 * - 开箱即用：`HarnessSpec.default()` 内置工具 + 内存会话 + 环境变量里的 provider
 * - 可定制：每个组件都是接口，`with*` 换掉任意一个
 * - 无隐藏状态：派生不改共享组件（provider 走叠加表、工具表走派生视图、模型表走副本）
 *
 * 每个 `with*` 参数与 [AgentRuntime] 能接受的组件一一对应，没有第二套抽象。
 */
public class HarnessSpec {
    /** 工具表（根表；run 作用域叠加用 [ToolRegistry.derived]） */
    public let tools: ToolRegistry
    /** Provider 注册表（宿主共享，只读使用；本 spec 自己的注册走叠加表） */
    public let providers: ProviderRegistry
    /** 会话存储 */
    public let store: SessionStore
    /** 信任闸门 */
    public let trust: TrustManager
    /** Skill 注册表 */
    public let skills: SkillRegistry
    /** Agent 配置注册表 */
    public let agents: AgentRegistry
    /** MCP 连接管理 */
    public let mcp: McpManager
    /** 横切钩子（注册序 = 执行序） */
    public let hooks: ArrayList<Hook>
    /** 提问通道：审批 / 选择 / 表单。None = 无交互通道（提问按取消处理） */
    public let ask: Option<AskFn>
    /** 模型 → 上下文窗口查表 */
    public let models: ModelContextRegistry
    /** 请求级 Provider 中间件（先注入者最外层） */
    public let middlewares: ArrayList<ProviderMiddleware>
    /** 系统提示段贡献者 */
    public let contributors: ArrayList<PromptSegmentContributor>
    /** 进程级事件总线（None = 不发布） */
    public let eventBus: ?EventBus
    // provider 叠加表：注册表是宿主共享的（且是外部类型、没有派生语义），
    // 衍生 spec 不该往里写 —— 叠加只属于这份 spec，查找时优先于注册表
    let providerOverlay: HashMap<String, Provider>

    public init(
        tools!: ToolRegistry = ToolRegistry(),
        providers!: ProviderRegistry = ProviderRegistry(),
        store!: SessionStore = MemorySessionStore(),
        trust!: TrustManager = TrustManager(),
        skills!: SkillRegistry = SkillRegistry(),
        agents!: AgentRegistry = AgentRegistry(),
        mcp!: McpManager = McpManager(),
        hooks!: ArrayList<Hook> = ArrayList<Hook>(),
        ask!: Option<AskFn> = None,
        models!: ModelContextRegistry = ModelContextRegistry(),
        middlewares!: ArrayList<ProviderMiddleware> = ArrayList<ProviderMiddleware>(),
        contributors!: ArrayList<PromptSegmentContributor> = ArrayList<PromptSegmentContributor>(),
        eventBus!: ?EventBus = None
    ) {
        this.tools = tools
        this.providers = providers
        this.store = store
        this.trust = trust
        this.skills = skills
        this.agents = agents
        this.mcp = mcp
        this.hooks = hooks
        this.ask = ask
        this.models = models
        this.middlewares = middlewares
        this.contributors = contributors
        this.eventBus = eventBus
        this.providerOverlay = HashMap<String, Provider>()
    }

    // 派生专用：以 from 为底，只覆盖显式给出的那些（None = 保持原样）
    private init(from: HarnessSpec,
        tools!: ?ToolRegistry = None,
        providers!: ?ProviderRegistry = None,
        store!: ?SessionStore = None,
        trust!: ?TrustManager = None,
        skills!: ?SkillRegistry = None,
        agents!: ?AgentRegistry = None,
        mcp!: ?McpManager = None,
        hooks!: ?ArrayList<Hook> = None,
        ask!: ?Option<AskFn> = None,
        models!: ?ModelContextRegistry = None,
        middlewares!: ?ArrayList<ProviderMiddleware> = None,
        contributors!: ?ArrayList<PromptSegmentContributor> = None,
        overlay!: ?HashMap<String, Provider> = None
    ) {
        this.tools = match (tools) { case Some(v) => v; case None => from.tools }
        this.providers = match (providers) { case Some(v) => v; case None => from.providers }
        this.store = match (store) { case Some(v) => v; case None => from.store }
        this.trust = match (trust) { case Some(v) => v; case None => from.trust }
        this.skills = match (skills) { case Some(v) => v; case None => from.skills }
        this.agents = match (agents) { case Some(v) => v; case None => from.agents }
        this.mcp = match (mcp) { case Some(v) => v; case None => from.mcp }
        this.hooks = match (hooks) { case Some(v) => v; case None => from.hooks }
        this.ask = match (ask) { case Some(v) => v; case None => from.ask }
        this.models = match (models) { case Some(v) => v; case None => from.models }
        this.middlewares = match (middlewares) { case Some(v) => v; case None => from.middlewares }
        this.contributors = match (contributors) { case Some(v) => v; case None => from.contributors }
        this.eventBus = from.eventBus
        this.providerOverlay = match (overlay) { case Some(v) => v; case None => from.providerOverlay }
    }

    /**
     * 开箱即用装配：内置工具 + 内存会话 + 默认模型表，
     * 环境里配了 `OPENAI_API_KEY` 就顺手接一个名为 `default` 的 provider。
     */
    public static func default(): HarnessSpec {
        withEnvProvider(withBuiltinTools(HarnessSpec()))
    }

    /**
     * 给装配束配上内置工具集。
     *
     * 技能入口与「按需加载 MCP」绑定的是**本装配束**的技能表 / MCP 管理器，
     * 所以要在组件定下来之后再调（宿主自带存储、配置化 provider 时走这条，
     * 而不是用 [default] 临时造一套组件再换掉）。
     */
    public static func withBuiltinTools(spec: HarnessSpec): HarnessSpec {
        registerBuiltinTools(spec.tools, spec.skills, spec.mcp)
        spec
    }

    /** 环境里配了 `OPENAI_API_KEY` 就挂一个名为 `default` 的 provider；没配则原样返回 */
    public static func withEnvProvider(spec: HarnessSpec): HarnessSpec {
        let key = match (getVariable("OPENAI_API_KEY")) { case Some(v) => v; case None => "" }
        if (key == "") {
            return spec
        }
        let baseURL = match (getVariable("OPENAI_BASE_URL")) {
            case Some(v) => v
            case None => "https://api.openai.com/v1"
        }
        spec.withProvider("default", OpenAIProvider("default", baseURL, key))
    }

    /** 测试/嵌入用的最小装配：内存会话 + 指定 provider，工具表为空 */
    public static func forTests(provider: Provider, name!: String = "default"): HarnessSpec {
        HarnessSpec(store: MemorySessionStore()).withProvider(name, provider)
    }

    // ---------- 派生 ----------

    /** 追加一个 provider（同名覆盖；写在叠加表里，不动宿主共享的注册表） */
    public func withProvider(name: String, p: Provider): HarnessSpec {
        let overlay = HashMap<String, Provider>()
        for (k in this.providerOverlay.keys()) {
            overlay[k] = this.providerOverlay[k]
        }
        overlay[name] = p
        HarnessSpec(this, overlay: overlay)
    }

    public func withStore(s: SessionStore): HarnessSpec {
        HarnessSpec(this, store: s)
    }

    public func withTrust(t: TrustManager): HarnessSpec {
        HarnessSpec(this, trust: t)
    }

    public func withSkills(s: SkillRegistry): HarnessSpec {
        HarnessSpec(this, skills: s)
    }

    public func withAgents(a: AgentRegistry): HarnessSpec {
        HarnessSpec(this, agents: a)
    }

    public func withMcp(m: McpManager): HarnessSpec {
        HarnessSpec(this, mcp: m)
    }

    public func withProviders(reg: ProviderRegistry): HarnessSpec {
        HarnessSpec(this, providers: reg)
    }

    /** 换一张（或换一个兜底窗口的）模型表 */
    public func withModels(m: ModelContextRegistry): HarnessSpec {
        HarnessSpec(this, models: m)
    }

    /** 声明某个模型的上下文窗口（覆盖内置表；副本语义，不动共享表） */
    public func withModelContext(model: String, contextWindow: Int64): HarnessSpec {
        HarnessSpec(this, models: this.models.merged(model, contextWindow))
    }

    /** 未知模型兜底窗口 */
    public func withDefaultContextWindow(contextWindow: Int64): HarnessSpec {
        HarnessSpec(this, models: this.models.withDefaultWindow(contextWindow))
    }

    public func withHook(h: Hook): HarnessSpec {
        let hooks = ArrayList<Hook>(this.hooks)
        hooks.add(h)
        HarnessSpec(this, hooks: hooks)
    }

    public func withHooks(hs: ArrayList<Hook>): HarnessSpec {
        HarnessSpec(this, hooks: hs)
    }

    /** 设置提问通道（审批/选择/表单） */
    public func withAsk(f: AskFn): HarnessSpec {
        HarnessSpec(this, ask: Some(f))
    }

    public func withMiddlewares(ms: ArrayList<ProviderMiddleware>): HarnessSpec {
        HarnessSpec(this, middlewares: ms)
    }

    public func withContributors(cs: ArrayList<PromptSegmentContributor>): HarnessSpec {
        HarnessSpec(this, contributors: cs)
    }

    /** 挂上进程级事件总线（审计/监控；不传 = 不发布） */
    public func withEventBus(bus: EventBus): HarnessSpec {
        HarnessSpec(tools: this.tools, providers: this.providers, store: this.store,
            trust: this.trust, skills: this.skills, agents: this.agents, mcp: this.mcp,
            hooks: this.hooks, ask: this.ask, models: this.models,
            middlewares: this.middlewares, contributors: this.contributors,
            eventBus: Some(bus))
            .withProviderOverlay(this.providerOverlay)
    }

    // 叠加表是内部状态，派生时原样带走（withEventBus 走公开构造，需要补一次）
    private func withProviderOverlay(overlay: HashMap<String, Provider>): HarnessSpec {
        HarnessSpec(this, overlay: overlay)
    }

    /**
     * 追加一个工具到根表（同名覆盖）。
     *
     * 需要**只影响本次 run** 的追加（按请求传入的客户端工具）时，用
     * [withToolsView]，别改共享的根表。
     */
    public func withTool(t: Tool): HarnessSpec {
        this.tools.register(t)
        this
    }

    /**
     * 派生一份「工具表叠加了 overlay」的装配束：run 作用域，根表不动，
     * 派生之后注册进根表的工具（运行中按需加载的 MCP 工具）在视图里照样可见。
     */
    public func withToolsView(overlay: ArrayList<Tool>): HarnessSpec {
        HarnessSpec(this, tools: this.tools.derived(overlay))
    }

    /** 换一整张工具表（子 agent / 隔离回合用各自的工具集） */
    public func withToolRegistry(reg: ToolRegistry): HarnessSpec {
        HarnessSpec(this, tools: reg)
    }

    // ---------- 解析 ----------

    /**
     * 按 agent 配置解析 provider：`config.provider`（缺省 `"default"`）→ 本 spec 的
     * 叠加表 → 宿主注册表。都没有时**明确报错**，不静默退化成某个默认端点。
     */
    public func resolveProvider(cfg: AgentConfig): Provider {
        let name = providerNameOf(cfg)
        match (this.providerOverlay.get(name)) {
            case Some(p) => p
            case None => match (this.providers.get(name)) {
                case Some(p) => p
                case None => throw Exception("no provider named '${name}': register one with HarnessSpec.withProvider(...)")
            }
        }
    }

    private static func registerBuiltinTools(tools: ToolRegistry, skills: SkillRegistry, mcp: McpManager): Unit {
        tools.register(ReadFileTool())
        tools.register(WriteFileTool())
        tools.register(EditFileTool())
        tools.register(BashTool())
        tools.register(GrepTool())
        tools.register(GlobTool())
        tools.register(TodoTool())
        tools.register(AskUserTool())
        tools.register(UseSkillsTool(skills))
        tools.register(LoadMcpToolsetTool(mcp, tools))
    }
}

/**
 * 便利层：拿一个装配束就能跑。
 *
 * ```cangjie
 * let h = Harness.open(HarnessSpec.default())     // 或 fromToml(...) 的装配束
 * println(h.run("你好"))
 * h.close()
 * ```
 *
 * 需要细粒度控制（会话 id、事件流、取消、子 Agent）时下钻到 [AgentRuntime]，
 * 两者用的是同一份装配束 —— 这里没有任何"另一套配置"。
 */
public class Harness {
    private let spec: HarnessSpec
    private let log = getGlobalLogger([("name", "atelier.harness")])

    public init(spec: HarnessSpec) {
        this.spec = spec
    }

    public static func open(spec: HarnessSpec): Harness {
        Harness(spec)
    }

    /** 零配置入口：内置工具 + 内存会话 + 环境变量 provider */
    public static func open(): Harness {
        Harness(HarnessSpec.default())
    }

    public func components(): HarnessSpec {
        this.spec
    }

    /** 取 agent 配置：注册表里没有该名字时用默认配置（零配置也能跑） */
    public func configOf(agent: String): AgentConfig {
        match (this.spec.agents.get(agent)) {
            case Some(c) => c
            case None => AgentConfig.default()
        }
    }

    public func runtimeOf(cfg: AgentConfig): AgentRuntime {
        AgentRuntime(this.spec, cfg)
    }

    public func runtime(agent: String): AgentRuntime {
        this.runtimeOf(this.configOf(agent))
    }

    /** 会话 id 显式给出的一次运行（会话由调用方负责持久化，与 AgentRuntime 口径一致） */
    public func stream(agent: String, sessionId: String, msgs: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>> {
        this.runtime(agent).chatWithSessionId(sessionId, msgs, SessionEnvironment())
    }

    public func run(agent: String, prompt: String): String {
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText(prompt), 0))
        lastAssistantTextOf(this.runtime(agent).chat(msgs).result())
    }

    public func run(prompt: String): String {
        this.run("default", prompt)
    }

    /** 收尾：会话存储落盘 + MCP 连接关闭（两个都失败不互相影响） */
    public func close(): Unit {
        try {
            this.spec.store.close()
        } catch (e: Exception) {
            this.log.warn("session store close failed: ${e.toString()}", Array<Attr>())
        }
        try {
            this.spec.mcp.closeAll()
        } catch (e: Exception) {
            this.log.warn("mcp close failed: ${e.toString()}", Array<Attr>())
        }
    }
}

// agent 配置声明的 provider 名（缺省 default）
func providerNameOf(cfg: AgentConfig): String {
    match (cfg.provider) {
        case Some(v) => v
        case None => "default"
    }
}

// 最后一条助手消息的纯文本（一次性运行的返回值）
func lastAssistantTextOf(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[Int64(i)]) {
            case am: AssistantMessage =>
                var text = ""
                for (b in am.content.blocks()) {
                    match (b) {
                        case ContentBlock.TextBlock(t) => text = text + t
                        case _ => ()
                    }
                }
                return text
            case _ => ()
        }
        i--
    }
    ""
}
