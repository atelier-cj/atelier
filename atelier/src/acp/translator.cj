package atelier.acp

import std.collection.*
import acp.types.*
import atelier.agent.*
import atelier.message.AssistantMessage
import atelier.message.StopReason
// ACP 侧也有 ContentBlock，取别名避免歧义
import atelier.message.ContentBlock as MsgContentBlock

// 把 atelier 运行时事件翻译为 ACP session/update 通知。
// per-ACP-session 单实例：内部维护回合计数与「当前 assistant 文本消息」的 messageId，
// 保证同一回合的增量 chunk 共用同一 messageId（ACP v1 message id 语义）。
public class AcpTranslator {
    private var turnNo: Int64 = 0
    private var openMessageId: ?String = None

    public init() {}

    // 会话生命周期（load/resume）后如需从新回合开始，调用本方法
    public func reset(): Unit {
        this.turnNo = 0
        this.openMessageId = None
    }

    // 处理单个事件，返回 0..N 条 session/update（按协议顺序组织）
    public func translate(ev: AgentEvent): ArrayList<SessionUpdate> {
        let out = ArrayList<SessionUpdate>()
        match (ev) {
            case _: AgentStartEvent => ()
            case _: MessageStartEvent => ()
            case _: TurnStartEvent =>
                // 新回合：先前回合的文本消息闭合
                this.turnNo++
                this.openMessageId = None
            case te: TurnEndEvent =>
                // 异常回合（如 provider 报错）：文本增量可能一条都没发过，而 ACP 侧只拿得到
                // 一个无理由的 stopReason。这里把失败消息作为可见的 agent 消息推出去，
                // 宿主（评测框架/日志）才有办法定位；正常回合不重复推送已发过的增量。
                match (te.message) {
                    case am: AssistantMessage =>
                        let failed = match (am.stopReason) {
                            case StopReason.Error => true
                            case _ => false
                        }
                        if (failed) {
                            let sb = StringBuilder()
                            for (b in am.content.blocks()) {
                                match (b) {
                                    case MsgContentBlock.TextBlock(txt) => sb.append(txt)
                                    case _ => ()
                                }
                            }
                            let text = sb.toString()
                            if (text != "") {
                                out.add(SessionUpdate.agentMessage(text, messageId: Some(this.currentMessageId())))
                            }
                        }
                    case _ => ()
                }
            case _: CompactionEvent => ()
            case u: MessageUpdateEvent =>
                if (u.delta != "") {
                    out.add(SessionUpdate.agentMessage(u.delta, messageId: Some(this.currentMessageId())))
                }
            case e: MessageEndEvent =>
                // 文本增量已逐条发送；此处处理消息携带的工具调用声明
                match (e.message) {
                    case am: AssistantMessage =>
                        let calls = am.toolCalls()
                        for (tc in calls) {
                            out.add(SessionUpdate.toolCall(tc.id, tc.name,
                                kind: Some(toolKindFor(tc.name)),
                                status: Some(ToolStatusPending),
                                rawInput: Some(tc.args)))
                        }
                    case _ => ()
                }
                this.openMessageId = None
            case e: ToolExecutionStartEvent =>
                out.add(SessionUpdate.toolCallUpdate(e.toolCallId, status: Some(ToolStatusInProgress)))
            case e: ToolExecutionUpdateEvent =>
                if (e.progress != "") {
                    let c = ArrayList<ToolCallContent>()
                    c.add(ToolCallContent.ofContent(ContentBlock.ofText(e.progress)))
                    out.add(SessionUpdate.toolCallUpdate(e.toolCallId, content: Some(c)))
                }
            case e: ToolExecutionEndEvent =>
                let c = ArrayList<ToolCallContent>()
                c.add(ToolCallContent.ofContent(ContentBlock.ofText(e.result)))
                out.add(SessionUpdate.toolCallUpdate(e.toolCallId,
                    status: Some(if (e.isError) { ToolStatusFailed } else { ToolStatusCompleted }),
                    content: Some(c)))
            case _ => ()
        }
        out
    }

    // 当前回合 assistant 文本消息 id（首个增量时惰性分配）
    private func currentMessageId(): String {
        match (this.openMessageId) {
            case Some(id) => id
            case None =>
                let id = "msg_t" + this.turnNo.toString()
                this.openMessageId = Some(id)
                id
        }
    }
}

// 工具名 → ACP tool_call kind（启发式；未知归 other）
public func toolKindFor(toolName: String): String {
    let n = toolName
    if (n.contains("read")) { ToolKindRead }
    else if (n.contains("write")) { ToolKindEdit }
    else if (n.contains("edit")) { ToolKindEdit }
    else if (n.contains("bash") || n.contains("exec") || n.contains("run") || n.contains("shell")) { ToolKindExecute }
    else if (n.contains("grep") || n.contains("glob") || n.contains("search")) { ToolKindSearch }
    else if (n.contains("fetch")) { ToolKindFetch }
    else if (n.contains("delete") || n.contains("remove")) { ToolKindDelete }
    else if (n.contains("move") || n.contains("rename")) { ToolKindMove }
    else if (n.contains("think")) { ToolKindThink }
    else { ToolKindOther }
}
