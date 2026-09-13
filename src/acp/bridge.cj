package atelier.acp

import std.collection.*
import std.sync.*
import std.core.Duration
import std.env.getStdErr
import jsonvalue.*
import ystyle::jsonrpc.{Result, JsonRpcError}
import acp.{AcpAgent, PromptContext, SessionInitialState}
import acp.types.*
import acp.transport.StdioTransport
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.message.{Message, UserMessage, AssistantMessage, ToolResultMessage, ArchiveMessage, ContentList, ToolCallBlock, StopReason, textOfMsg}
import atelier.context.ModelContextRegistry

// ACP 会话的运行时状态（每个 ACP session 一个，生命周期 = session 生命周期）
class HostState {
    public var session: AcpSession
    public var options: AcpConfigOptions
    public var translator = AcpTranslator()
    public var activeRuntime: ?AgentRuntime = None
    public init(session: AcpSession, options: AcpConfigOptions) {
        this.session = session
        this.options = options
    }
}

// 一次 prompt 会话消息加载上限（与 REPL 保持一致，防止历史无限膨胀）
let MaxAcpLoadMessages: Int64 = 15

// AcpBridge：把 atelier 运行时接入 ACP v1 Agent 侧（stdio）。
// 组装 AcpAgent + 注册全部生命周期回调 + serve()；一个进程服务一个 agent（启动时选定）。
public class AcpBridge {
    private let agent: AcpAgent
    private let agentName: String
    private let baseConfig: AgentConfig
    private let provider: Provider
    private let toolReg: ToolRegistry
    private let trustMgr: TrustManager
    private let skillReg: SkillRegistry
    private let agentReg: AgentRegistry
    private let providerReg: ProviderRegistry
    private let sessionStore: SessionStore
    private let mcpMgr: McpManager
    private let modelReg: ModelContextRegistry
    private let manager: AcpSessionManager
    private let hosts = HashMap<String, HostState>()
    private let hostsLock = Mutex()
    // 统一回合执行（与子 worker 同源）
    private let loop: SessionLoop
    // session/new 钩子链：onNewSession 先于 setInitialSessionState，用于关联刚建的 host
    private var lastNewAcpId: String = ""

    // 默认压缩开关（nested CompactionConfig 优先）
    private func defaultCompaction(): Bool {
        match (this.baseConfig.compaction) {
            case Some(c) => c.enabled
            case None => this.baseConfig.compactionEnabled
        }
    }

    public init(agentName: String, baseConfig: AgentConfig, provider: Provider,
        toolReg: ToolRegistry, trustMgr: TrustManager, skillReg: SkillRegistry,
        agentReg: AgentRegistry, providerReg: ProviderRegistry,
        sessionStore: SessionStore, mcpMgr: McpManager,
        modelReg: ModelContextRegistry, mappingFile: String,
        acpName: String, acpVersion: String) {
        this.agentName = agentName
        this.baseConfig = baseConfig
        this.provider = provider
        this.toolReg = toolReg
        this.trustMgr = trustMgr
        this.skillReg = skillReg
        this.agentReg = agentReg
        this.providerReg = providerReg
        this.sessionStore = sessionStore
        this.mcpMgr = mcpMgr
        this.modelReg = modelReg
        this.manager = AcpSessionManager(mappingFile)
        this.loop = SessionLoop(toolReg, trustMgr, skillReg, agentReg, providerReg, sessionStore, mcpMgr)
        this.agent = AcpAgent(StdioTransport(), acpName, acpVersion)
        this.agent.capabilities.loadSession = true
        this.agent.capabilities.sessionCapabilities.list = Some(EmptyCapability())
        this.agent.capabilities.sessionCapabilities.delete = Some(EmptyCapability())
        this.agent.capabilities.sessionCapabilities.resume = Some(EmptyCapability())
        this.agent.capabilities.sessionCapabilities.close = Some(EmptyCapability())
        this.agent.capabilities.sessionCapabilities.additionalDirectories = Some(EmptyCapability())
        this.registerCallbacks()
    }

    // ===================== 生命周期 =====================

    public func serve(): Unit { this.agent.serve() }

    // ===================== 回调注册 =====================

    private func registerCallbacks(): Unit {
        this.agent.setInitialSessionState({ req => this.initialState(req) })
        this.agent.setOnNewSession({ sid, cwd => this.onNewSession(sid, cwd) })
        this.agent.setPromptHandler({ ctx => this.runPrompt(ctx) })
        this.agent.setOnLoadSession({ req, complete, fail => this.onLoadSession(req, complete, fail) })
        this.agent.setOnResumeSession({ req => this.onResumeSession(req) })
        this.agent.setOnListSessions({ req => this.onListSessions(req) })
        this.agent.setOnDeleteSession({ sid => this.onDeleteSession(sid) })
        this.agent.setOnClose({ sid => this.onCloseSession(sid) })
        this.agent.setOnCancel({ sid => this.onCancel(sid) })
        this.agent.setOnSetConfigOption({ sid, req => this.onSetConfigOption(sid, req) })
        this.agent.setOnSetMode({ sid, modeId => false })
    }

    // ===================== 会话生命周期实现 =====================

    // session/new 后续：登记映射并建 host；随后 setInitialSessionState 下发 config options
    private func onNewSession(sid: String, cwd: String): Unit {
        let s = this.manager.newSessionWithId(sid, cwd)
        synchronized(this.hostsLock) {
            this.hosts[sid] = HostState(s, this.buildOptions())
            this.lastNewAcpId = sid
        }
        // 附加工作区根 = 会话级预信任目录（副作用工具直接放行，无需逐次审批；cwd 维持现状走审批）
        match (this.agent.sessionAdditionalDirectories(sid)) {
            case Some(dirs) =>
                for (d in dirs) {
                    this.trustMgr.setSessionTrust(s.atelierId, d, TrustState.Trusted)
                }
            case None => ()
        }
        // 宿主代管 MCP（session/new.mcpServers）：映射并注册进会话共用的 McpManager，
        // 与本地 [[mcpServer]] 同生命周期与工具门控（on-demand 激活）；同名幂等跳过（本地优先）。
        // 连接为异步：MCP 握手不阻塞 session/new 响应（对不可用 server 超时隔离）。
        match (this.agent.sessionMcpServers(sid)) {
            case Some(servers) =>
                spawn {
                    for (ms in servers) {
                        if (this.mcpMgr.hasServer(ms.name)) {
                            logErr("[atelier-acp] client mcp '${ms.name}' 已存在（本地配置优先），跳过")
                            continue
                        }
                        match (acpMcpServerToConfig(ms)) {
                            case Some(cfg) =>
                                this.mcpMgr.addServer(this.toolReg, cfg)
                                logErr("[atelier-acp] client mcp '${ms.name}' 注册完成（${cfg.transport}）")
                            case None =>
                                logErr("[atelier-acp] client mcp '${ms.name}' 形态不支持或配置无效，跳过（stdio env 暂不支持）")
                        }
                    }
                }
            case None => ()
        }
    }

    // session/new 响应：下发会话初始配置（client 未声明 session.configOptions 时不带）
    private func initialState(req: NewSessionRequest): ?SessionInitialState {
        if (this.agent.clientCapabilities.session.isNone()) { return None }
        // onNewSession 钩子先于本钩子执行并登记 host（空 id 时 get 亦返回 None）
        let host: ?HostState = synchronized(this.hostsLock) {
            match (this.hosts.get(this.lastNewAcpId)) {
                case Some(h) => Some(h)
                case None => None
            }
        }
        match (host) {
            case Some(h) =>
                let st = SessionInitialState()
                st.configOptions = Some(h.options.optionList())
                Some(st)
            case None => None
        }
    }

    // session/load：恢复 host 并重放会话历史（通知全部发出后才 complete）
    private func onLoadSession(req: SessionLifecycleRequest, complete: (JsonValue) -> Unit, fail: (JsonRpcError) -> Unit): Unit {
        let acpId = req.sessionId
        let host = synchronized(this.hostsLock) { this.hosts.get(acpId) }
        match (host) {
            case Some(h) =>
                this.replayHistory(acpId, h.session.atelierId)
                complete(JsonValue.fromObject(LoadSessionResponse()))
            case None =>
                match (this.manager.lookup(acpId)) {
                    case Some(rec) =>
                        let h = HostState(rec, this.buildOptions())
                        synchronized(this.hostsLock) { this.hosts[acpId] = h }
                        this.replayHistory(acpId, rec.atelierId)
                        complete(JsonValue.fromObject(LoadSessionResponse()))
                    case None =>
                        fail(JsonRpcError(INVALID_PARAMS, "Unknown sessionId: ${acpId}"))
                }
        }
    }

    // session/resume：恢复运行状态但不重放历史
    private func onResumeSession(req: SessionLifecycleRequest): ?ResumeSessionResponse {
        let acpId = req.sessionId
        match (this.manager.lookup(acpId)) {
            case Some(rec) =>
                let host = synchronized(this.hostsLock) { this.hosts.get(acpId) }
                if (host.isNone()) {
                    let h = HostState(rec, this.buildOptions())
                    synchronized(this.hostsLock) { this.hosts[acpId] = h }
                }
                Some(ResumeSessionResponse())
            case None => None
        }
    }

    // session/list：全部已记录会话
    private func onListSessions(req: ListSessionsRequest): ListSessionsResponse {
        let resp = ListSessionsResponse()
        for (r in this.manager.list()) {
            let info = SessionInfo()
            info.sessionId = r.sessionId
            info.cwd = r.cwd
            resp.sessions.add(info)
        }
        resp
    }

    // session/delete：删映射 + 删 atelier 会话
    private func onDeleteSession(acpId: String): Bool {
        match (this.manager.lookup(acpId)) {
            case Some(rec) =>
                try { this.sessionStore.delete(rec.atelierId) } catch (_) { () }
                this.manager.deleteMapping(acpId)
                synchronized(this.hostsLock) { this.hosts.remove(acpId) }
                true
            case None => false
        }
    }

    // session/close：取消进行中回合、清运行态（映射保留供 load/resume）
    private func onCloseSession(acpId: String): Unit {
        this.onCancel(acpId)
        synchronized(this.hostsLock) {
            match (this.hosts.get(acpId)) {
                case Some(h) => h.options.reset()
                case None => ()
            }
            this.hosts.remove(acpId)
        }
        this.manager.dropActive(acpId)
    }

    // session/cancel：AcpAgent 置 cancelFlag；回合消费循环经 ctx.isCancelled 触发作废（幂等空实现）
    private func onCancel(acpId: String): Unit { () }

    // session/set_config_option：会话级覆盖（model select / compaction boolean），
    // 非法值返回 None（AcpAgent 回 -32602）；成功响应完整最新列表
    private func onSetConfigOption(acpId: String, req: SetSessionConfigOptionRequest): ?ArrayList<SessionConfigOption> {
        let host = synchronized(this.hostsLock) { this.hosts.get(acpId) }
        match (host) {
            case Some(h) =>
                // 组装协议 value（select 的字符串值 / boolean 开关）
                let jv: ?JsonValue = match (req.boolValue) {
                    case Some(b) => Some(JsonValue.Boolean(b))
                    case None =>
                        match (req.value) {
                            case Some(v) => Some(JsonValue.String(v))
                            case None => None
                        }
                }
                match (jv) {
                    case Some(v) =>
                        if (h.options.setOption(req.configId, v)) {
                            return Some(h.options.optionList())
                        }
                        None
                    case None => None
                }
            case None => None
        }
    }

    // ===================== config options =====================

    private func buildOptions(): AcpConfigOptions {
        AcpConfigOptions(this.modelCandidates(), this.baseConfig.model, this.defaultCompaction())
    }

    // 模型候选：AgentRegistry 出现过的 model ∪ ModelContextRegistry 已知模型（去重由 AcpConfigOptions 完成）
    private func modelCandidates(): ArrayList<String> {
        let out = ArrayList<String>()
        for ((_, cfg) in this.agentReg.list()) { out.add(cfg.model) }
        for (m in this.modelReg.list()) { out.add(m) }
        out
    }

    // ===================== prompt 回合 =====================

    private func runPrompt(ctx: PromptContext): PromptResponse {
        // host 兜底：进程重启后 client 先 load 再 prompt（协议路径），此处再兜底一次
        let host = synchronized(this.hostsLock) { this.hosts.get(ctx.sessionId) }
        match (host) {
            case Some(h) => this.runPromptWithHost(ctx, h)
            case None =>
                match (this.manager.lookup(ctx.sessionId)) {
                    case Some(rec) =>
                        let h = HostState(rec, this.buildOptions())
                        synchronized(this.hostsLock) { this.hosts[ctx.sessionId] = h }
                        this.runPromptWithHost(ctx, h)
                    case None =>
                        PromptResponse(StopReasonRefusal)
                }
        }
    }

    private func runPromptWithHost(ctx: PromptContext, host: HostState): PromptResponse {
        let acpId = ctx.sessionId
        let atelierId = host.session.atelierId
        // 1. 会话级覆盖生效的 config（model / compaction）
        let cfg = this.buildConfig(host.options.effectiveModel(), host.options.effectiveCompaction())
        let env = SessionEnvironment(host.session.cwd, HashMap<String, String>())
        let text = ctx.getText()
        let model = host.options.effectiveModel()
        // 2. SessionLoop 统一回合（历史截断窗口 15 与迁移前一致；落库由 loop 完成）
        try {
            let outcome = this.loop.run(atelierId, text, cfg, this.provider, None, env,
                { => false },
                { => ctx.isCancelled() },
                onEvent: { ev => this.pushEvent(acpId, host, ev, model) },
                parentSession: None,
                approvalFn: { tc, wd => this.requestToolApproval(acpId, tc) },
                askUserFn: { q => this.elicitationAsk(acpId, q) },
                maxLoad: MaxAcpLoadMessages)
            this.lastStopReason(outcome.messages)
        } catch (e: Exception) {
            // 回合异常若不留痕，ACP 端只看到一次无理由的 refusal，无从定位
            eprintln("[atelier-acp] prompt turn failed (session=${atelierId}): ${e.toString()}")
            if (ctx.isCancelled()) { PromptResponse(StopReasonCancelled) }
            else { PromptResponse(StopReasonRefusal) }
        }
    }

    // 回合事件 → session/update 推送 + usage_update（SessionLoop onEvent 钩子）
    private func pushEvent(acpId: String, host: HostState, ev: AgentEvent, model: String): Unit {
        let ups = host.translator.translate(ev)
        for (u in ups) { this.agent.sessionUpdate(acpId, u) }
        match (ev) {
            case e: TurnEndEvent => this.emitUsage(acpId, e.message, model)
            case _ => ()
        }
    }

    // 加载会话历史并重放为 session/update 通知（session/load 语义）
    private func replayHistory(acpId: String, atelierId: String): Unit {
        var msgs = ArrayList<Message>()
        // session/load 的历史重放：加载失败会导致「会话打开后一片空白」——必须留痕
        try { msgs = this.sessionStore.load(atelierId) } catch (e: Exception) {
            eprintln("[atelier-acp] session history load failed (session=${atelierId}): ${e.toString()}")
        }
        var msgNo: Int64 = 0
        for (m in msgs) {
            msgNo++
            let mid = "msg_hist_" + msgNo.toString()
            match (m) {
                case um: UserMessage =>
                    let t = textOfMsg(um)
                    if (t != "") {
                        this.agent.sessionUpdate(acpId, SessionUpdate.userMessageChunk(ContentBlock.ofText(t), messageId: Some(mid)))
                    }
                case am: AssistantMessage =>
                    let t = textOfMsg(am)
                    if (t != "") {
                        this.agent.sessionUpdate(acpId, SessionUpdate.agentMessage(t, messageId: Some(mid)))
                    }
                    let calls = am.toolCalls()
                    for (tc in calls) {
                        this.agent.sessionUpdate(acpId, SessionUpdate.toolCall(tc.id, tc.name,
                            kind: Some(toolKindFor(tc.name)),
                            status: Some(ToolStatusCompleted),
                            rawInput: Some(tc.args)))
                    }
                case tr: ToolResultMessage =>
                    this.agent.sessionUpdate(acpId, SessionUpdate.toolCallUpdate(tr.toolCallId,
                        status: Some(if (tr.isError) { ToolStatusFailed } else { ToolStatusCompleted })))
                case _ => ()
            }
        }
    }

    // 回合内 usage_update（provider 报告 inputTokens > 0 时发送）
    private func emitUsage(acpId: String, msg: Message, model: String): Unit {
        match (msg) {
            case am: AssistantMessage =>
                if (am.usage.inputTokens > 0) {
                    let size = UInt64(this.modelReg.get(model))
                    this.agent.sessionUpdate(acpId,
                        SessionUpdate.usageUpdate(UInt64(am.usage.inputTokens), size))
                }
            case _ => ()
        }
    }

    // 结果消息 → ACP stopReason（取最后一条 assistant 的停止原因）
    private func lastStopReason(messages: ArrayList<Message>): PromptResponse {
        var i = messages.size - 1
        while (i >= 0) {
            match (messages[i]) {
                case am: AssistantMessage =>
                    match (am.stopReason) {
                        case StopReason.Length => return PromptResponse(StopReasonMaxTokens)
                        case StopReason.Error => return PromptResponse(StopReasonRefusal)
                        case _ => return PromptResponse(StopReasonEndTurn)
                    }
                case _ => ()
            }
            i--
        }
        PromptResponse(StopReasonEndTurn)
    }

    // ===================== 落库（单落库职责，与 REPL 同构） =====================
    // ===================== 用户提问（Elicitation 表单桥，ask_user 工具用） =====================

    // 以单字段表单向 Client 询问用户；能力未声明/decline/cancel/失败返回 ""（兼容文本 askUser 拒绝语义）
    private func elicitationAsk(acpId: String, question: String): String {
        let propsArr: Array<(String, ElicitationPropertySchema)> = [("answer", ElicitationPropertySchema.string())]
        let requiredArr = ArrayList<String>()
        requiredArr.add("answer")
        let schema = ElicitationSchema.of(propsArr, required: Some(requiredArr))
        let req = CreateElicitationRequest.form(acpId, question, schema)
        match (this.agent.createElicitation(req, timeout: 5 * Duration.minute)) {
            case Result.Ok(resp) => elicitationAnswerOf(resp.action, resp.content)
            case Result.Err(e) =>
                // 通道失败/超时一律降级为「未作答」：不留痕则与「用户拒绝」不可区分
                eprintln("[atelier-acp] elicitation failed, treated as no answer: ${e.toString()}")
                ""
        }
    }

    // ===================== 工具授权（request_permission 反向调用） =====================

    private func requestToolApproval(acpId: String, tc: ToolCallBlock): String {
        // 反向调用 client：同步等待授权（超时/失败按拒绝处理）
        let call = ToolCallUpdate()
        call.toolCallId = tc.id
        call.title = Some(tc.name)
        call.kind = Some(toolKindFor(tc.name))
        call.status = Some(ToolStatusPending)
        call.rawInput = Some(tc.args)
        let options = ArrayList<PermissionOption>()
        options.add(PermissionOption("allow_once", "允许一次", "allow_once"))
        options.add(PermissionOption("allow_always", "始终允许（此目录）", "allow_always"))
        options.add(PermissionOption("reject", "拒绝", "reject_once"))
        match (this.agent.requestPermission(acpId, call, options, timeout: 10 * Duration.minute)) {
            case Result.Ok(resp) =>
                match (resp.outcome.optionId) {
                    case Some(optId) =>
                        if (optId == "allow_once") { "y" }
                        else if (optId == "allow_always") { "a" }
                        else { "" }
                    case None => ""
                }
            case Result.Err(e) =>
                // 授权通道失败按拒绝处理（fail-safe 语义不变），但必须留痕：否则「工具为何被拒」无从排查
                eprintln("[atelier-acp] permission request failed, treated as denied: ${e.toString()}")
                ""
        }
    }

    // ===================== 配置合成 =====================

    private func buildConfig(model: String, compactionOn: Bool): AgentConfig {
        AgentConfig(
            this.baseConfig.name, this.baseConfig.description,
            this.baseConfig.systemPrompt, this.baseConfig.userPromptTemplate,
            model, this.baseConfig.provider,
            this.baseConfig.tools, this.baseConfig.skills,
            this.baseConfig.mcpCooldownTurns,
            this.baseConfig.maxTurns, this.baseConfig.temperature,
            this.baseConfig.maxOutputTokens, this.baseConfig.thinkingLevel,
            compactionOn,
            this.baseConfig.compactionReserveTokens,
            this.baseConfig.keepRecentTokens,
            None,
            this.baseConfig.maxToolCalls,
            this.baseConfig.toolTimeout,
            this.baseConfig.minToolInterval,
            this.baseConfig.tags, this.baseConfig.createdBy,
            this.baseConfig.createdAt, this.baseConfig.updatedAt)
    }
}

// Elicitation 表单响应 → 答案文本（纯函数，单测重点）。
// 表单模式：accept 时 content 为符合 schema 的对象（{ answer: "..." }）；
// decline/cancel/缺失返回空串（与 askUserFn 拒绝语义一致，兼容旧行为）。
public func elicitationAnswerOf(action: String, content: ?JsonValue): String {
    if (action != ElicitationActionAccept) { return "" }
    if (content.isNone()) { return "" }
    match (content.getOrThrow()) {
        case JsonValue.Map(m) =>
            let ans = m.get("answer")
            if (ans.isNone()) { return "" }
            match (ans.getOrThrow()) {
                case JsonValue.String(v) => v
                case _ => ""
            }
        case _ => ""
    }
}

// ACP 进程诊断日志：stdout 只允许 ACP 帧，一切日志走 stderr
func logErr(msg: String): Unit {
    try {
        let err = getStdErr()
        err.write((msg + "\n").toArray())
        err.flush()
    } catch (_) { () }
}
