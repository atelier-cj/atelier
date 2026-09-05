package atelier.agent

import std.collection.*
import std.core.Duration
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import stdx.log.*
import atelier.event.EventStream

// 一次回合的结果：最终消息列表（含历史与新增）与是否被 close 打断
public class TurnOutcome {
    public let messages: ArrayList<Message>
    public let stoppedByClose: Bool
    public init(messages: ArrayList<Message>, stoppedByClose: Bool) {
        this.messages = messages
        this.stoppedByClose = stoppedByClose
    }
}

// SessionLoop：统一「消息驱动的单回合执行」——历史 + 输入文本 → chatWithSessionId →
// 事件消费（可选逐事件回调；支持协作式取消与关闭）→ persistAppend 落库。
// 子 Agent worker、ACP 会话桥、未来宿主循环共用同一回合语义（runtime 本身零改动）。
public class SessionLoop {
    private let toolReg: ToolRegistry
    private let trustMgr: TrustManager
    private let skillReg: SkillRegistry
    private let agentReg: AgentRegistry
    private let providerReg: ProviderRegistry
    private let sessionStore: SessionStore
    private let mcpMgr: McpManager

    public init(toolReg: ToolRegistry, trustMgr: TrustManager,
        skillReg: SkillRegistry, agentReg: AgentRegistry,
        providerReg: ProviderRegistry, sessionStore: SessionStore,
        mcpMgr: McpManager) {
        this.toolReg = toolReg
        this.trustMgr = trustMgr
        this.skillReg = skillReg
        this.agentReg = agentReg
        this.providerReg = providerReg
        this.sessionStore = sessionStore
        this.mcpMgr = mcpMgr
    }

    // 执行一次回合。requestStop：close 请求（打断且不回信语义由调用方判定）；
    // requestCancel：cancel 请求（中断进行中回合，回合正常收敛收尾）。
    // onEvent：可选的逐事件钩子（如 ACP 事件翻译），在事件被内部消费前调用。
    // parentSession：首轮落库写入 header.parentSession 的提示（子 agent 标记父会话用）。
    // approvalFn：工具级授权回调（ACP 权限桥注入；None 走默认文本 askUser）。
    // askUserFn：用户问答实现（ask_user 工具调用；ACP 场景注入 Elicitation 表单桥）。
    // maxLoad：历史加载截断窗口（0=不截断；>0 语义同 truncateMessages，保留 Archive 头部）。
    public func run(sessionId: String, inputText: String,
        config: AgentConfig, provider: Provider, toolRegOverride: ?ToolRegistry,
        env: SessionEnvironment,
        requestStop: () -> Bool, requestCancel: () -> Bool,
        onEvent!: ?(AgentEvent) -> Unit = None,
        parentSession!: ?String = None,
        approvalFn!: ?(ToolCallBlock, String) -> String = None,
        askUserFn!: (String) -> String = { q => "" },
        maxLoad!: Int64 = 0): TurnOutcome {
        let toolRegistry = match (toolRegOverride) {
            case Some(r) => r
            case None => this.toolReg
        }
        var oldLoaded = ArrayList<Message>()
        try { oldLoaded = this.sessionStore.load(sessionId) } catch (_) { () }
        let loaded = if (maxLoad > 0) { truncateMessages(oldLoaded, maxLoad) } else { oldLoaded }
        let msgs = ArrayList<Message>(loaded)
        if (inputText != "") {
            msgs.add(UserMessage(ContentList.ofText(inputText), 0))
        }
        let runtime = AgentRuntime(config, provider, toolRegistry, this.sessionStore,
            this.trustMgr, this.skillReg, this.agentReg, this.providerReg,
            ArrayList<Hook>(), askUserFn, env, this.mcpMgr)
        runtime.toolApprovalFn = approvalFn
        let stream = runtime.chatWithSessionId(sessionId, msgs, env)
        // 事件消费 + 控制轮询；AgentStartEvent 到达 ⇔ runtime 已注册 cancelFlag：
        // 早到的取消/关闭请求在事件到达后补发（幂等）。
        var cancelArmed = false
        var stoppedByClose = false
        var ended = false
        while (!ended && !stoppedByClose) {
            if (requestStop()) {
                runtime.cancelSession(sessionId)
                stoppedByClose = true
                break
            }
            if (cancelArmed && requestCancel()) {
                runtime.cancelSession(sessionId)
            }
            match (stream.receive(Duration.millisecond * 200)) {
                case Some(ev: AgentStartEvent) =>
                    cancelArmed = true
                    if (requestCancel()) {
                        runtime.cancelSession(sessionId)
                    }
                    if (let Some(cb) <- onEvent) { cb(ev) }
                case Some(ev: AgentEndEvent) =>
                    if (let Some(cb) <- onEvent) { cb(ev) }
                    ended = true
                case Some(ev) =>
                    if (requestCancel()) {
                        runtime.cancelSession(sessionId)
                    }
                    if (let Some(cb) <- onEvent) { cb(ev) }
                case None => ()
            }
        }
        let all = try { stream.result() } catch (e: Exception) {
            ArrayList<Message>(oldLoaded)
        }
        // 落库（错误由调用方按日志策略处理）
        match (persistAppendWithParent(this.sessionStore, sessionId, oldLoaded, all, parentSession)) {
            case Some(err) => getGlobalLogger([("name", "SessionLoop")]).error("persist: ${err}", Array<Attr>())
            case None => ()
        }
        TurnOutcome(all, stoppedByClose)
    }
}
