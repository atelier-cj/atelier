package atelier.a2a

import std.collection.*
import std.sync.*
import a2a.*
import atelier.agent.*
import atelier.provider.Provider
import atelier.session.SessionEnvironment
import atelier.interaction.*

// 每个 A2A 任务一份运行时上下文。
// 翻译器按 taskId 存活（而不是按 execute）：同一任务续聊（INPUT_REQUIRED 之后）必须沿用
// 回合计数与产物 id —— 否则新一轮会重新用 "art_t1"，把上一轮的产物顶掉。
class A2aTaskHost {
    let session: A2aSession
    let translator: A2aTranslator
    // 未答复的提问：requestId → 请求
    let pending = HashMap<String, UserRequest>()
    // 客户端已经给出的答复：requestId → 答复（下次 run 里的 askFn 命中即回填）
    let answers = HashMap<String, UserAnswer>()

    init(session: A2aSession, taskId: String, contextId: String) {
        this.session = session
        this.translator = A2aTranslator(taskId, contextId)
    }
}

// A2aBridge：把 atelier 的 AgentRuntime 暴露为 A2A Agent（服务端执行器）。
//
// 一次 execute = 客户端一条消息 = atelier 的一次 SessionLoop 回合（唯一回合执行器，
// 桥里不自己编排模型/工具循环）。运行时事件经 A2aTranslator 转 StreamResponse 后，
// 按 a2a-cj 的 EventQueue 原语（status / artifact）转投：任务状态机、产物合并、落库
// 都由队列负责，桥只描述「发生了什么」。
//
// 会话：contextId 是 A2A 的对话标识，映射到 atelier 会话 id（A2aSessionManager，
// JSON 持久化，跨进程可续聊）；taskId 是任务级寻址（tasks/get、resubscribe）。
// 同一 context 的多个任务共享同一份会话历史，因此按 context 串行执行。
public class A2aBridge <: A2aExecutor {
    private let baseConfig: AgentConfig
    private let provider: Provider
    private let spec: HarnessSpec
    private let manager: A2aSessionManager
    private let loop: SessionLoop
    // 会话工作目录（工具工作目录 + AGENTS.md 注入点）：A2A 请求本身不带 cwd
    private let workspace: String
    private let maxLoad: Int64
    private let hosts = HashMap<String, A2aTaskHost>()
    private let hostsLock = Mutex()
    // 同一 context（= 同一 atelier 会话）内的执行锁
    private let contextLocks = HashMap<String, Mutex>()
    private let contextLocksLock = Mutex()
    private let running = HashMap<String, Bool>()
    private let runningLock = Mutex()

    public init(spec: HarnessSpec, baseConfig: AgentConfig, provider: Provider,
        mappingFile: String, workspace: String, maxLoad!: Int64 = 15) {
        this.spec = spec
        this.baseConfig = baseConfig
        this.provider = provider
        this.manager = A2aSessionManager(mappingFile)
        this.loop = SessionLoop(spec)
        this.workspace = workspace
        this.maxLoad = maxLoad
    }

    // 由 atelier 配置生成 Agent Card（宿主起服务时用）
    public func agentCard(baseUrl: String, version: String,
        bindings!: ArrayList<String> = ArrayList<String>([BindingJsonRpc]),
        streaming!: Bool = true): AgentCard {
        agentCardFromConfig(this.baseConfig, this.spec, baseUrl, version,
            bindings: bindings, streaming: streaming)
    }

    // 会话映射管理器（宿主做 tasks/list、会话清理时用）
    public func sessions(): A2aSessionManager {
        this.manager
    }

    // ===================== A2aExecutor =====================

    public func execute(ctx: RequestContext, queue: EventQueue): Unit {
        // 1. contextId → atelier 会话（首次出现时建映射；cwd 用宿主配置的工作目录）
        let session = match (this.manager.lookup(ctx.contextId)) {
            case Some(s) => s
            case None => this.manager.newSessionWithId(ctx.contextId, this.workspace)
        }
        // 2. 任务 host：续聊（existingTask 非空）复用既有翻译状态，回合号继续推进
        let host = this.hostFor(ctx, session)
        // 3. 这条消息若在答复上一轮挂起的提问，先把答复折算好（askFn 命中即不再挂起）
        absorbPendingAnswers(host, ctx.clientText())
        this.markRunning(ctx.taskId, true)
        try {
            // 4. 同一 context 串行：会话历史是单一序列，并发 run 会交错写入
            let ctxLock = this.lockFor(ctx.contextId)
            synchronized(ctxLock) {
                this.loop.run(session.atelierId, ctx.clientText(),
                    this.baseConfig, this.provider, None,
                    SessionEnvironment(session.cwd, HashMap<String, String>()),
                    { => false },
                    { => ctx.isCancelled() },
                    onEvent: { ev => this.pushEvent(ctx, queue, host, ev) },
                    askFn: Some({ req: UserRequest => this.answerRequest(host, req) }),
                    maxLoad: this.maxLoad)
            }
        } catch (e: Exception) {
            // 回合异常若不留痕，A2A 端只看到任务停在 WORKING —— 必须可见
            eprintln("[atelier-a2a] turn failed (task=${ctx.taskId}, session=${session.atelierId}): ${e.toString()}")
            if (!queue.isClosed()) {
                queue.status(TaskState.Failed, message: errorMessage(ctx, e.message))
            }
        }
        this.finishExecute(ctx, queue, host)
    }

    // 服务端收到 tasks/cancel 时调用：requestCancel 已由服务端置位，正在跑的 execute 会读到
    // 并收敛（SessionLoop 的 requestCancel 探针）。这里只兜底「已经没有在跑的 execute」。
    public func cancel(ctx: RequestContext, queue: EventQueue): Unit {
        if (!this.isRunning(ctx.taskId) && !queue.isClosed()) {
            queue.status(TaskState.Canceled)
        }
    }

    // ===================== 内部 =====================

    private func finishExecute(ctx: RequestContext, queue: EventQueue, host: A2aTaskHost): Unit {
        this.markRunning(ctx.taskId, false)
        // 任务索引：记录本任务推进到的回合（tasks/get / resubscribe 的寻址信息）
        try {
            this.manager.bindTask(ctx.taskId, ctx.contextId, host.translator.turnCount())
        } catch (e: Exception) {
            eprintln("[atelier-a2a] bindTask failed (task=${ctx.taskId}): ${e.toString()}")
        }
        // 取消是外部事实（provider 中断时的 stopReason 不可靠）：事件流若已给出终态，
        // 以先到者为准（终态不可回退）；否则补一个 CANCELED
        if (ctx.isCancelled() && !queue.isClosed()) {
            queue.status(TaskState.Canceled)
        }
        // 终态任务不会再被 execute：摘掉 host，别让任务表随服务时长无限增长
        if (host.translator.isFinished()) {
            synchronized(this.hostsLock) {
                this.hosts.remove(ctx.taskId)
            }
        }
    }

    private func hostFor(ctx: RequestContext, session: A2aSession): A2aTaskHost {
        synchronized(this.hostsLock) {
            match (this.hosts.get(ctx.taskId)) {
                case Some(h) =>
                    // 续聊：清回合内状态（回合号与任务级状态保留）
                    if (ctx.existingTask.isSome()) {
                        h.translator.reset()
                    }
                    h
                case None =>
                    let h = A2aTaskHost(session, ctx.taskId, ctx.contextId)
                    this.hosts[ctx.taskId] = h
                    h
            }
        }
    }

    // SessionLoop 的事件钩子：翻译 + 转投队列
    private func pushEvent(ctx: RequestContext, queue: EventQueue, host: A2aTaskHost,
        ev: AgentEvent): Unit {
        if (ctx.isCancelled()) {
            host.translator.markCancelled()
        }
        forwardToQueue(queue, host.translator.translate(ev))
    }

    // askFn：结构化提问（审批 / 选择 / 表单 / 外部执行）。
    // A2A 没有反向同步调用：没有现成答复时一律挂起（Pending），runtime 随即发 SuspendEvent，
    // 翻译器映射为 INPUT_REQUIRED；客户端用同一 taskId 续发消息时再回填。
    private func answerRequest(host: A2aTaskHost, req: UserRequest): UserAnswer {
        match (host.answers.remove(req.id)) {
            case Some(a) => return a
            case None => ()
        }
        host.pending[req.id] = req
        UserAnswer(req.id, UserAnswerStatus.Pending)
    }

    private func lockFor(contextId: String): Mutex {
        synchronized(this.contextLocksLock) {
            match (this.contextLocks.get(contextId)) {
                case Some(m) => m
                case None =>
                    let m = Mutex()
                    this.contextLocks[contextId] = m
                    m
            }
        }
    }

    private func markRunning(taskId: String, value: Bool): Unit {
        synchronized(this.runningLock) {
            if (value) {
                this.running[taskId] = true
            } else {
                this.running.remove(taskId)
            }
        }
    }

    private func isRunning(taskId: String): Bool {
        synchronized(this.runningLock) {
            this.running.contains(taskId)
        }
    }
}

// 翻译器输出 → a2a-cj 的 EventQueue 原语。
// 刻意不用 queue.publish：status / artifact 原语才会同步任务状态机、按 append 合并产物并落库，
// 直接 publish 只广播事件、任务快照会与事件流不一致。
func forwardToQueue(queue: EventQueue, outs: ArrayList<StreamResponse>): Unit {
    for (r in outs) {
        match (r.statusUpdate) {
            case Some(s) => queue.status(s.status.state, message: s.status.message)
            case None => ()
        }
        match (r.artifactUpdate) {
            case Some(a) => queue.artifact(a.artifact, append: a.append, lastChunk: a.lastChunk)
            case None => ()
        }
    }
}

// 客户端在挂起后用同 taskId 回了消息：把这条文本折算成对各挂起提问的答复。
// 只做「文本 → 结构化答复」的折算，答复合法性仍由 runtime 侧校验（与本仓其它宿主一致）。
func absorbPendingAnswers(host: A2aTaskHost, text: String): Unit {
    if (host.pending.size == 0) {
        return
    }
    let reqs = ArrayList<UserRequest>(host.pending.values())
    host.pending.clear()
    for (req in reqs) {
        host.answers[req.id] = a2aAnswerFor(req, text)
    }
}

// 文本 → 结构化答复：先按候选选项的 id / label 精确匹配（大小写不敏感），
// 审批类再认一组常见的肯定 / 否定说法，都不中则作为自由文本答复。
func a2aAnswerFor(req: UserRequest, text: String): UserAnswer {
    let lower = text.toAsciiLower()
    let selected = ArrayList<String>()
    for (o in req.options) {
        if (lower == o.id.toAsciiLower() || lower == o.label.toAsciiLower()) {
            selected.add(o.id)
        }
    }
    if (selected.size > 0) {
        return UserAnswer(req.id, UserAnswerStatus.Answered, selected: selected, text: text)
    }
    let approval = match (req.kind) {
        case UserRequestKind.Approval => true
        case _ => false
    }
    if (approval) {
        match (normalizeDecision(lower)) {
            case Some(id) => selected.add(id)
            case None => ()
        }
        if (selected.size > 0) {
            return UserAnswer(req.id, UserAnswerStatus.Answered, selected: selected, text: text)
        }
    }
    UserAnswer(req.id, UserAnswerStatus.Answered, text: text)
}

// 审批的常见说法 → 选项 id（认不出返回 None：调用方按自由文本处理，由 runtime 校验兜底）
func normalizeDecision(lower: String): ?String {
    match (lower) {
        case "y" | "yes" | "ok" | "once" | "allow" | "allow_once" => Some("allow_once")
        case "a" | "always" | "allow_always" => Some("allow_always")
        case "n" | "no" | "reject" | "deny" => Some("deny")
        case _ => None
    }
}

// 失败状态消息：带 taskId / contextId，客户端才能把错误对上任务
func errorMessage(ctx: RequestContext, detail: String): Message {
    let parts = ArrayList<Part>()
    parts.add(Part.ofText(detail))
    let m = Message("err-${ctx.taskId}", Role.Agent, parts)
    m.contextId = Some(ctx.contextId)
    m.taskId = Some(ctx.taskId)
    m
}

// 由 atelier 配置生成 A2A Agent Card：name / description 取 agent 配置；
// skills 取配置声明**且**在 SkillRegistry 里注册到的技能 —— 声明了却查不到的技能不列进卡片
// （卡片是对外承诺，「声明了做不到」比不声明更糟）。
public func agentCardFromConfig(cfg: AgentConfig, spec: HarnessSpec, baseUrl: String,
    version: String, bindings!: ArrayList<String> = ArrayList<String>([BindingJsonRpc]),
    streaming!: Bool = true): AgentCard {
    let skills = ArrayList<AgentSkill>()
    for (name in cfg.skills) {
        match (spec.skills.get(name)) {
            case Some(sk) =>
                let item = AgentSkill()
                item.id = sk.name
                item.name = sk.name
                item.description = sk.description
                item.inputModes.add(ModeText)
                item.outputModes.add(ModeText)
                skills.add(item)
            case None => ()
        }
    }
    let description = match (cfg.description) {
        case Some(d) => d
        case None => "atelier agent '${cfg.name}'"
    }
    buildAgentCard(cfg.name, description, version, baseUrl,
        bindings: bindings, streaming: streaming, skills: skills)
}
