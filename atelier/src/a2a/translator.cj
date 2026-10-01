package atelier.a2a

import std.collection.*
import std.deriving.*
import jsonvalue.*
import a2a.types.*
import atelier.agent.*
import atelier.message.AssistantMessage
import atelier.message.ToolCallBlock
import atelier.message.UserMessage
import atelier.message.StopReason
import atelier.message.ContentBlock as MsgContentBlock
// 事件里的消息是 atelier（llm_api）消息类型，与 a2a.types.Message 同名，取别名区分
import atelier.message.Message as AtelierMessage
import atelier.tool.ExternalRequest

// 任务阶段。A2A 规范（3.1.2 任务生命周期流）规定：任务进入终态后流必须关闭、
// 且不再接受该任务的任何状态更新；中断态（INPUT_REQUIRED）不是终态，可用同一 taskId 续聊。
// 仓颉枚举没有内置 ==，要比较阶段就得派生 Equatable。
@Derive[Equatable]
enum A2aTaskPhase {
    | Idle          // 尚未开始（新建 / reset 之后）
    | Working       // 回合进行中
    | Interrupted   // 挂起等待外部输入（INPUT_REQUIRED）
    | Terminal      // Completed / Failed / Canceled 已下发
}

// 把 atelier 运行时事件翻译为 A2A 流式事件（StreamResponse）。
//
// per-task 单实例：构造时固定 taskId / contextId（A2A 的状态与产物事件必须带这两个字段）。
// 任务生命周期流只允许「首个 Task + 若干 statusUpdate / artifactUpdate」，
// 因此 assistant 文本以 artifact 分片下发（而不是 Message 载荷 —— 那是 message-only 流的形态）。
//
// 分片语义（对齐 A2A 的 append / lastChunk）：
// - 首片 append=false 建立产物，后续片 append=true 追加（append=true 但产物不存在时，
//   规范的参考实现会直接丢弃该片，所以首片必须 append=false）；
// - 每个增量先缓冲一片，下一个增量到达时才发出上一片，这样 lastChunk=true 能落在
//   **有内容**的那一片上（代价是流式展示滞后一个增量）。
public class A2aTranslator {
    private let taskId: String
    private let contextId: String
    private var turnNo: Int64 = 0
    private var phase = A2aTaskPhase.Idle
    // 当前回合「输出流」的消息 id：惰性分配、同回合的状态消息共用（ACP 侧 openMessageId 的镜像）
    private var openMessageId: ?String = None
    // 当前回合文本产物：id 惰性分配、同回合各分片共用
    private var textArtifactId: ?String = None
    // 本回合是否已发过首片（决定后续分片的 append；首片必须 append=false）
    private var textAppended: Bool = false
    // 本回合文本产物是否已收尾（收尾只能做一次，重复调用是空操作）
    private var textFinished: Bool = false
    // 宿主已知本次运行被取消（A2A 的 tasks/cancel）：终态一律判为 CANCELED
    private var cancelled: Bool = false
    private var pendingText: ?String = None
    // toolCallId → 工具产物是否已闭合（lastChunk 已发）
    private let toolArtifacts = HashMap<String, Bool>()

    public init(taskId: String, contextId: String) {
        this.taskId = taskId
        this.contextId = contextId
    }

    // 同一 taskId 上的新一轮运行（如 INPUT_REQUIRED 后用同一 taskId 续聊）前调用：
    // 清回合内状态、阶段拨回 Idle。turnNo 不重置 —— artifactId 在一个任务内必须唯一，
    // 新回合必须拿到新的产物 id。
    public func reset(): Unit {
        this.openMessageId = None
        this.textArtifactId = None
        this.textAppended = false
        this.textFinished = false
        this.pendingText = None
        this.toolArtifacts.clear()
        this.cancelled = false
        this.phase = A2aTaskPhase.Idle
    }

    // 已推进的回合数（宿主据此把 taskId 绑定到回合：A2aSessionManager.bindTask）
    public func turnCount(): Int64 {
        this.turnNo
    }

    // 终态是否已下发（宿主据此拒绝后续更新 / 决定是否新建 task）
    public func isFinished(): Bool {
        this.phase == A2aTaskPhase.Terminal
    }

    // 宿主已知本次运行被取消（服务端 tasks/cancel 置位）：provider 在中断时的 stopReason
    // 不可靠，取消是外部事实，因此由宿主显式告知 —— 后续终态判为 CANCELED 而不是 COMPLETED。
    public func markCancelled(): Unit {
        this.cancelled = true
    }

    // 外部驱动的终态（如服务端已回 CANCELED 的 tasks/cancel）：置终态并下发状态事件。
    // 只接受终态（Completed / Failed / Canceled / Rejected），否则视为调用方错误。
    public func finish(state: TaskState): ArrayList<StreamResponse> {
        let out = ArrayList<StreamResponse>()
        if (!isTerminal(state)) {
            throw Exception("A2aTranslator.finish: '${taskStateToJson(state)}' 不是终态")
        }
        if (this.phase == A2aTaskPhase.Terminal) {
            return out
        }
        this.phase = A2aTaskPhase.Terminal
        this.closeText("", out)
        this.closeOpenTools(out)
        this.emitStatus(state, None, out)
        out
    }

    // 处理单个事件，返回 0..N 条 StreamResponse（按协议顺序组织）
    public func translate(ev: AgentEvent): ArrayList<StreamResponse> {
        let out = ArrayList<StreamResponse>()
        if (this.phase == A2aTaskPhase.Terminal) {
            // 终态任务不再接受更新：桥接层若要在同一 taskId 上继续，须先 reset()
            return out
        }
        match (ev) {
            case _: AgentStartEvent => ()
            case _: MessageStartEvent => ()
            case _: CompactionStartEvent => ()
            case _: CompactionEndEvent => ()
            case _: CompactionEvent => ()
            case _: TurnStartEvent =>
                this.turnNo++
                this.openMessageId = None
                this.textArtifactId = None
                this.textAppended = false
                this.textFinished = false
                this.pendingText = None
                this.toolArtifacts.clear()
                this.phase = A2aTaskPhase.Working
                this.emitStatus(TaskState.Working, None, out)
            case u: MessageUpdateEvent =>
                if (u.delta != "") {
                    this.bufferText(u.delta, out)
                }
            case e: MessageEndEvent =>
                // 文本增量已逐条发送；此处处理消息携带的工具调用声明
                match (e.message) {
                    case am: AssistantMessage =>
                        for (tc in am.toolCalls()) {
                            this.declareTool(tc, out)
                        }
                    case _ => ()
                }
            case e: ToolExecutionStartEvent =>
                this.updateTool(e.toolCallId, ArrayList<Part>(), "running", false, out)
            case e: ToolExecutionUpdateEvent =>
                if (e.progress != "") {
                    let parts = ArrayList<Part>()
                    parts.add(Part.ofText(e.progress))
                    this.updateTool(e.toolCallId, parts, "running", false, out)
                }
            case e: ToolExecutionEndEvent =>
                let parts = ArrayList<Part>()
                parts.add(Part.ofText(e.result))
                this.updateTool(e.toolCallId, parts,
                    if (e.isError) { "failed" } else { "completed" }, true, out)
            case se: SuspendEvent =>
                // 本次运行挂起：产物收尾 + INPUT_REQUIRED（非终态，同 taskId 可续聊）
                this.closeText("", out)
                this.closeOpenTools(out)
                this.phase = A2aTaskPhase.Interrupted
                this.emitStatus(TaskState.InputRequired,
                    this.agentMessage(this.pendingRequestsText(se.requests)), out)
            case te: TurnEndEvent =>
                // 异常回合（如 provider 报错）：失败文本一条增量都没发过，
                // 把它挂到 FAILED 状态消息上，宿主（评测框架/日志）才有办法定位。
                let failed = match (te.message.stopReason) {
                    case StopReason.Error => true
                    case _ => false
                }
                this.closeText(if (failed) { "" } else { assistantTextOf(te.message) }, out)
                this.closeOpenTools(out)
                match (te.message.stopReason) {
                    case StopReason.Error =>
                        this.phase = A2aTaskPhase.Terminal
                        this.emitStatus(TaskState.Failed,
                            this.agentMessage(assistantTextOf(te.message)), out)
                    case StopReason.Aborted =>
                        this.phase = A2aTaskPhase.Terminal
                        this.emitStatus(TaskState.Canceled, None, out)
                    case StopReason.EndTurn =>
                        // 只有「正常结束且没有待执行工具」才是本任务的终态；
                        // 带工具结果的回合之后还有新回合，提前收终态会让后续更新违反协议
                        if (te.toolResults.size == 0) {
                            this.phase = A2aTaskPhase.Terminal
                            this.emitStatus(this.terminalState(), None, out)
                        }
                    case _ =>
                        // ToolUse：工具批次（或挂起）之后继续；Length：截断续跑或由 AgentEnd 收尾
                        ()
                }
            case ae: AgentEndEvent =>
                // 运行收尾。已在中断态（等外部输入）时不改状态；其余情况按完成收尾，
                // 除非运行以系统错误哨兵收尾 —— 那种情况任务并没有成功。
                if (this.phase == A2aTaskPhase.Working || this.phase == A2aTaskPhase.Idle) {
                    match (runtimeFailureText(ae.messages)) {
                        case Some(text) =>
                            // 崩溃收尾同样要把已产出的分片收干净，再下发失败
                            this.closeText("", out)
                            this.closeOpenTools(out)
                            this.phase = A2aTaskPhase.Terminal
                            this.emitStatus(TaskState.Failed, this.agentMessage(text), out)
                        case None =>
                            this.closeText("", out)
                            this.closeOpenTools(out)
                            this.phase = A2aTaskPhase.Terminal
                            this.emitStatus(this.terminalState(), None, out)
                    }
                }
            case _ => ()
        }
        out
    }

    // ---------- 文本产物 ----------

    // 缓冲一个文本增量：先把上一片冲出去，再缓冲本片
    private func bufferText(delta: String, out: ArrayList<StreamResponse>): Unit {
        match (this.pendingText) {
            case Some(prev) => this.emitTextChunk(prev, this.textAppended, false, out)
            case None => ()
        }
        this.pendingText = Some(delta)
    }

    // 收尾当前回合的文本产物：缓冲片带 lastChunk=true 发出；
    // 本回合一片都没发过（非流式 provider / 失败消息）时用 fallback 补一片完整文本。
    // 幂等：本回合已经收尾过就直接返回。
    private func closeText(fallback: String, out: ArrayList<StreamResponse>): Unit {
        if (this.textFinished) {
            return
        }
        let tail = match (this.pendingText) {
            case Some(t) => t
            case None => if (this.textAppended) { "" } else { fallback }
        }
        this.pendingText = None
        this.textFinished = true
        if (tail != "") {
            this.emitTextChunk(tail, this.textAppended, true, out)
        }
    }

    private func emitTextChunk(text: String, append: Bool, lastChunk: Bool,
        out: ArrayList<StreamResponse>): Unit {
        let parts = ArrayList<Part>()
        parts.add(Part.ofText(text))
        let art = Artifact(this.currentArtifactId(), parts)
        art.name = Some("assistant")
        let ev = TaskArtifactUpdateEvent(this.taskId, this.contextId, art)
        ev.append = append
        ev.lastChunk = lastChunk
        out.add(StreamResponse.ofArtifact(ev))
        this.textAppended = true
    }

    private func currentArtifactId(): String {
        match (this.textArtifactId) {
            case Some(id) => id
            case None =>
                let id = "art_t" + this.turnNo.toString()
                this.textArtifactId = Some(id)
                id
        }
    }

    // ---------- 工具产物 ----------

    // 声明一次工具调用：先落一份产物（含入参 data part），执行过程再往同一 artifactId 追加
    private func declareTool(tc: ToolCallBlock, out: ArrayList<StreamResponse>): Unit {
        let parts = ArrayList<Part>()
        parts.add(Part.ofData(tc.args))
        let art = Artifact(this.toolArtifactId(tc.id), parts)
        art.name = Some(tc.name)
        art.metadata = Some(toolMetadata(tc.id, "pending"))
        let ev = TaskArtifactUpdateEvent(this.taskId, this.contextId, art)
        ev.append = false
        ev.lastChunk = false
        out.add(StreamResponse.ofArtifact(ev))
        this.toolArtifacts[tc.id] = false
    }

    // 工具产物更新：已声明过则 append=true，否则按首片建立（append=false）
    private func updateTool(callId: String, parts: ArrayList<Part>, status: String,
        lastChunk: Bool, out: ArrayList<StreamResponse>): Unit {
        let known = this.toolArtifacts.contains(callId)
        let art = Artifact(this.toolArtifactId(callId), parts)
        art.metadata = Some(toolMetadata(callId, status))
        let ev = TaskArtifactUpdateEvent(this.taskId, this.contextId, art)
        ev.append = known
        ev.lastChunk = lastChunk
        out.add(StreamResponse.ofArtifact(ev))
        this.toolArtifacts[callId] = lastChunk
    }

    // 声明了却没跑到的工具调用（被信任闸门/钩子跳过、或等待外部执行而挂起）：
    // 产物不能半开，收尾时补一片 lastChunk=true（空 parts，只标记结束）。
    private func closeOpenTools(out: ArrayList<StreamResponse>): Unit {
        let open = ArrayList<String>()
        for ((callId, closed) in this.toolArtifacts) {
            if (!closed) {
                open.add(callId)
            }
        }
        for (callId in open) {
            this.updateTool(callId, ArrayList<Part>(), "skipped", true, out)
        }
    }

    private func toolArtifactId(callId: String): String {
        "tool_t" + this.turnNo.toString() + "_" + callId
    }

    // 运行正常收尾时的终态：宿主报过取消就是 CANCELED
    private func terminalState(): TaskState {
        if (this.cancelled) {
            return TaskState.Canceled
        }
        TaskState.Completed
    }

    // ---------- 状态消息 ----------

    private func emitStatus(state: TaskState, message: ?Message, out: ArrayList<StreamResponse>): Unit {
        let st = TaskStatus(state)
        st.timestamp = Some(nowIso8601())
        match (message) {
            case Some(m) => st.message = Some(m)
            case None => ()
        }
        out.add(StreamResponse.ofStatus(TaskStatusUpdateEvent(this.taskId, this.contextId, st)))
    }

    // 状态更新携带的 agent 消息：文本为空则不带消息
    private func agentMessage(text: String): ?Message {
        if (text == "") {
            return None
        }
        let parts = ArrayList<Part>()
        parts.add(Part.ofText(text))
        Some(Message.agent(this.currentMessageId(), parts,
            contextId: Some(this.contextId), taskId: Some(this.taskId)))
    }

    // 当前回合输出流的消息 id（惰性分配，同回合共用）
    private func currentMessageId(): String {
        match (this.openMessageId) {
            case Some(id) => id
            case None =>
                let id = "msg_t" + this.turnNo.toString()
                this.openMessageId = Some(id)
                id
        }
    }

    private func pendingRequestsText(requests: ArrayList<ExternalRequest>): String {
        let sb = StringBuilder()
        var first = true
        for (r in requests) {
            if (!first) {
                sb.append("\n")
            }
            first = false
            sb.append(r.message)
        }
        sb.toString()
    }
}

// 工具调用元数据：客户端据此渲染工具生命周期（参考实现的产物元数据在 append 时按 key 合并）
private func toolMetadata(callId: String, status: String): JsonValue {
    let m = HashMap<String, JsonValue>()
    m.add("toolCallId", JsonValue.String(callId))
    m.add("status", JsonValue.String(status))
    JsonValue.Map(m)
}

// assistant 消息的全部文本块拼接（工具调用/图片等块忽略）
private func assistantTextOf(am: AssistantMessage): String {
    let sb = StringBuilder()
    for (b in am.content.blocks()) {
        match (b) {
            case MsgContentBlock.TextBlock(txt) => sb.append(txt)
            case _ => ()
        }
    }
    sb.toString()
}

// 运行时 catch 路径的收尾哨兵：AgentEndEvent 只带一条说明性 UserMessage
// （"[Runtime error: ...]" / "[Runtime system error: ...]"）。这类收尾代表任务并没有成功，
// 不能按 COMPLETED 下发；正常收尾的历史末条是 assistant 消息，不会命中。
private func runtimeFailureText(messages: ArrayList<AtelierMessage>): ?String {
    if (messages.size == 0) {
        return None
    }
    match (messages[messages.size - 1]) {
        case um: UserMessage =>
            let text = textOfUserMessage(um)
            if (text.startsWith("[Runtime error") || text.startsWith("[Runtime system error")) {
                return Some(text)
            }
            None
        case _ => None
    }
}

private func textOfUserMessage(um: UserMessage): String {
    let sb = StringBuilder()
    for (b in um.content.blocks()) {
        match (b) {
            case MsgContentBlock.TextBlock(txt) => sb.append(txt)
            case _ => ()
        }
    }
    sb.toString()
}
