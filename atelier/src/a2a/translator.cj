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
import atelier.message.textOfMsg
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
                // 本回合怎么结束的 —— 判据是 `reason`，不再用 `stopReason` 推断。
                // `StopReason` 只描述模型那条回复怎么停的，表达不了
                // 「预算耗尽 / 钩子短路 / 达到回合上限」这类"模型回了话但 run 没成功"的收尾。
                let succeeded = isSuccess(te.reason)
                this.closeText(if (succeeded) { assistantTextOf(te.message) } else { "" }, out)
                this.closeOpenTools(out)
                // `Suspended` 要单独拎出来：它既不是成功也不是失败，而是"等你输入"。
                // 终态转换留给随后的 `SuspendEvent`（那才是协议要求的 INPUT_REQUIRED，
                // 且要带上待确认项的文案）。在这里提前转 Terminal 会把那条状态吞掉。
                let suspended = match (te.reason) {
                    case TurnEndReason.Suspended => true
                    case _ => false
                }
                if (suspended) {
                    // 什么状态都不发：SuspendEvent 负责
                } else if (!succeeded) {
                    // 失败/取消：都是终态。失败要带说明（协议对端才定位得了），
                    // 取消则不带消息（对端只关心"停了"）。
                    this.phase = A2aTaskPhase.Terminal
                    let cancelled = match (te.reason) {
                        case TurnEndReason.Cancelled => true
                        case _ => false
                    }
                    if (cancelled) {
                        this.emitStatus(TaskState.Canceled, None, out)
                    } else {
                        this.emitStatus(TaskState.Failed,
                            this.agentMessage(assistantTextOf(te.message)), out)
                    }
                } else {
                    // 成功的回合也不一定是任务终态：**工具回合之后还有新回合**，
                    // 提前收终态会让后续更新违反协议。
                    //
                    // 这个判断需要 `StopReason`：`reason == Completed` 只说"本回合正常收尾"，
                    // 表达不了"模型还要求继续调工具"（stopReason = ToolUse）。
                    // **这不是在用 stopReason 猜 run 的结局**——结局已由 reason 判完，
                    // 这里判的是"任务整体是否结束"，两者是不同的问题。
                    // 两条"本回合还没完"的信号：
                    // · ToolUse —— 模型要求继续调工具
                    // · Length  —— 输出被截断，运行时会接着写完（同一回合内续跑）
                    // 两者都不能当作任务终态。
                    let continues = match (te.message.stopReason) {
                        case StopReason.ToolUse => true
                        case StopReason.Length => true
                        case _ => false
                    }
                    if (!continues && te.toolResults.size == 0) {
                        this.phase = A2aTaskPhase.Terminal
                        this.emitStatus(this.terminalState(), None, out)
                    }
                }
            case ae: AgentEndEvent =>
                // 运行收尾。已在中断态（等外部输入）时不改状态。
                //
                // **崩溃收尾**（运行时 catch 住异常直接收尾，没有 TurnEndEvent）此前只能靠
                // 匹配 messages 里 `"[Runtime error: ...]"` 文本前缀识别 —— 现在
                // `ae.reason` 直接给出 `Failed`，文本匹配已删除。
                if (this.phase == A2aTaskPhase.Working || this.phase == A2aTaskPhase.Idle) {
                    this.closeText("", out)
                    this.closeOpenTools(out)
                    this.phase = A2aTaskPhase.Terminal
                    if (isSuccess(ae.reason)) {
                        this.emitStatus(this.terminalState(), None, out)
                    } else {
                        // 失败/取消：与 turn_end 分支同口径
                        let cancelled = match (ae.reason) {
                            case TurnEndReason.Cancelled => true
                            case _ => false
                        }
                        if (cancelled) {
                            this.emitStatus(TaskState.Canceled, None, out)
                        } else {
                            // 崩溃说明取自 messages 末条（错误文本本就在里面）
                            this.emitStatus(TaskState.Failed,
                                this.agentMessage(textOfLastMessage(ae.messages)), out)
                        }
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

// AgentEndEvent.messages 末条的文本。
//
// 崩溃收尾时那条是运行时写的说明性 UserMessage（错误文本），**不匹配任何前缀**：
// 「这次是不是崩溃」已由调用方用 `ae.reason` 判断，这里只负责取文本。
private func textOfLastMessage(messages: ArrayList<AtelierMessage>): String {
    if (messages.size == 0) { return "" }
    // 只认 UserMessage：崩溃收尾时运行时写的是一条说明性用户消息；
    // 正常路径末条是 assistant —— 那种情况调用方不会走到这里（reason 已判为成功），
    // 万一走到也不该把模型产出当成错误说明。
    match (messages[messages.size - 1]) {
        case um: UserMessage => textOfMsg(um)
        case _ => ""
    }
}

