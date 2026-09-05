package atelier.agent

import std.collection.*
import jsonvalue.*
import atelier.tool.*
import stdx.log.*

// 子 Agent 主动向父发消息的工具（替代单向 report；由 SubAgentWorker 注入子回合工具表）。
// —— 子 Agent 上下文工具（发往父）。父 Agent 上下文另有同名 send_message{id,text}（发往子，
//    parent_tools.cj）与 subagent_reply（即时应答本工具的 waitReply 提问）；两上下文经注册表隔离。
// - kind=progress（默认）：通知父，不等待；
// - waitReply=true：先投递（父可见），再阻塞等待父回复后继续本回合（AskUser 同款同步等待链）；
//   timeoutMs（可选，默认 300000）到期返回超时提示，子可自行决定如何继续。
// 工具为 Parallel 执行模式：信任闸门对 Parallel 直接放行（子回合无人批准流程），
// execute 内部自行阻塞不影响并发正确性（每工具独立线程）。
public class SendMessageTool <: Tool {
    // 向父投递消息（text, kind）
    private let postFn: (String, String) -> Unit
    // 阻塞等待父回复（毫秒），None = 超时/未回复
    private let waitFn: (Int64) -> ?String

    public init(postFn: (String, String) -> Unit, waitFn: (Int64) -> ?String) {
        this.postFn = postFn
        this.waitFn = waitFn
    }

    public func name(): String { "send_message" }

    public func description(): String {
        "向父 Agent 发送消息（子 Agent 上下文 send_message）。kind：progress=进度汇报（父可见但不等待）；" +
        "reply=请求父回复。waitReply=true 时发送后阻塞等待父回复（父经 subagent_reply/宿主 respond 即时答复），" +
        "收到后继续本回合；超时由你自决继续。父端同名 send_message{id,text} 方向相反（父发往子）。"
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()

        let textProp = HashMap<String, JsonValue>()
        textProp.add("type", JsonValue.String("string"))
        textProp.add("description", JsonValue.String("消息内容"))
        props.add("text", JsonValue.Map(textProp))

        let kindProp = HashMap<String, JsonValue>()
        kindProp.add("type", JsonValue.String("string"))
        kindProp.add("description", JsonValue.String("消息类型：progress（默认）/ reply"))
        props.add("kind", JsonValue.Map(kindProp))

        let waitProp = HashMap<String, JsonValue>()
        waitProp.add("type", JsonValue.String("boolean"))
        waitProp.add("description", JsonValue.String("是否阻塞等待父回复（默认 false）"))
        props.add("waitReply", JsonValue.Map(waitProp))

        let toProp = HashMap<String, JsonValue>()
        toProp.add("type", JsonValue.String("integer"))
        toProp.add("description", JsonValue.String("waitReply 时的等待超时（毫秒，默认 300000）"))
        props.add("timeoutMs", JsonValue.Map(toProp))

        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("text"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let log = getGlobalLogger([("name", "SendMessage")])
        let text: String = match (args["text"]) {
            case Some(JsonValue.String(s)) => s
            case _ =>
                return ToolResult("Missing required parameter: text", None, true, false)
        }
        let kind: String = match (args["kind"]) {
            case Some(JsonValue.String(s)) => s
            case _ => "progress"
        }
        let waitReply: Bool = match (args["waitReply"]) {
            case Some(JsonValue.Boolean(b)) => b
            case _ => false
        }
        let timeoutMs: Int64 = match (args["timeoutMs"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => 300000
        }
        log.info("send_message kind=${kind} wait=${waitReply}", Array<Attr>())
        this.postFn(text, kind)
        if (!waitReply) {
            return ToolResult("消息已发送给父 Agent", None, false, false)
        }
        // 阻塞等待父回复（父 respond 后本回合继续）
        match (this.waitFn(timeoutMs)) {
            case Some(reply) =>
                log.info("send_message got reply", Array<Attr>())
                ToolResult("父 Agent 回复：" + reply, None, false, false)
            case None =>
                log.warn("send_message reply timeout after ${timeoutMs}ms", Array<Attr>())
                ToolResult("等待父 Agent 回复超时（${timeoutMs}ms），请决定如何继续", None, false, false)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}
