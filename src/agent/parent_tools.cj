package atelier.agent

import std.collection.*
import std.core.Duration
import jsonvalue.*
import atelier.tool.*

// ===================== 父端子 Agent 调度工具集 =====================
// 供父 agent 会话在回合内自主调度可持续子 agent（对齐 dsh send_message 语义：父端 send_message）：
//   send_message {id, text}                 投递 follow-up（唤醒空闲子开新回合；追问已完成子）
//   subagent_start {agent, prompt}          启动（立即返回 id，子异步跑）
//   subagent_reply {id, text}               回复子回合内 waitReply 提问（即时解锁；空闲=follow-up 唤醒）
//   subagent_await {id, timeoutMs}          阻塞收指定子来信（当前回合继续）
//   subagent_watch {timeoutMs}              阻塞收任一子来信（父级聚合收件箱）
//   subagent_close {id}                     请求终止子 worker（历史保留）
// 工具需在会话上下文中执行（ToolContext.sessionId 非空：parentSessionId）。
// 注：send_message 与子端工具同名不同上下文（子回合工具表复制父表后被子版覆盖，见 SubAgentManager.runTurn）。

public class SubagentStartTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    public func name(): String { "subagent_start" }
    public func description(): String {
        "启动一个可持续子 Agent（异步）：立即返回子 id，子 Agent 独立线程运行，完成后可被消息唤醒继续。agent 为 ~/.atelier.toml 中注册的 agent 名。"
    }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let a = HashMap<String, JsonValue>()
        a.add("type", JsonValue.String("string"))
        a.add("description", JsonValue.String("子 agent 注册名"))
        props.add("agent", JsonValue.Map(a))
        let p = HashMap<String, JsonValue>()
        p.add("type", JsonValue.String("string"))
        p.add("description", JsonValue.String("初始任务描述"))
        props.add("prompt", JsonValue.Map(p))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("agent"))
        req.add(JsonValue.String("prompt"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        if (ctx.sessionId == "") {
            return ToolResult("subagent_start 需要会话上下文（sessionId）", None, true, false)
        }
        let agent: String = match (args["agent"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: agent", None, true, false)
        }
        let prompt: String = match (args["prompt"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: prompt", None, true, false)
        }
        match (this.manager.startByName(agent, ctx.sessionId, prompt)) {
            case Some(h) => ToolResult("已启动子 Agent：${h.subSessionId}", None, false, false)
            case None => ToolResult("子 agent '${agent}' 未注册或 provider 不可用", None, true, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

public class SubagentSendTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    // dsh 对齐：父 Agent 上下文（子 Agent 上下文同名工具方向相反——子端发往父）。
    public func name(): String { "send_message" }
    public func description(): String {
        "向子 Agent 发送 follow-up 消息（父 Agent 上下文 send_message，id 指定子；" +
        "子端同名工具方向相反——发往父）：子空闲时被唤醒开新回合处理，可追问已汇报完成的子；已终止子 no-op"
    }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let a = HashMap<String, JsonValue>()
        a.add("type", JsonValue.String("string"))
        a.add("description", JsonValue.String("子 Agent id（subagent_start 返回）"))
        props.add("id", JsonValue.Map(a))
        let p = HashMap<String, JsonValue>()
        p.add("type", JsonValue.String("string"))
        p.add("description", JsonValue.String("消息内容"))
        props.add("text", JsonValue.Map(p))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("id"))
        req.add(JsonValue.String("text"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let id: String = match (args["id"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: id", None, true, false)
        }
        let text: String = match (args["text"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: text", None, true, false)
        }
        match (this.manager.get(id)) {
            case Some(h) =>
                h.send(AgentMail(ctx.sessionId, h.subSessionId, AgentMailKindUserText, text))
                ToolResult("已向子 Agent ${id} 投递消息", None, false, false)
            case None => ToolResult("未知子 Agent id：${id}", None, true, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 父 LLM 回合内应答子 waitReply 提问（等价句柄 respond，状态感知分派见 SubAgentHandle.respond）
public class SubagentReplyTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    public func name(): String { "subagent_reply" }
    public func description(): String {
        "回复子 Agent：若子正阻塞在 send_message(waitReply=true) 提问（其回合内等待），" +
        "回复即时送达并继续其当前回合；若子空闲或未在等待，等效发送 follow-up 消息唤醒其开新回合"
    }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let a = HashMap<String, JsonValue>()
        a.add("type", JsonValue.String("string"))
        a.add("description", JsonValue.String("子 Agent id（send_message/subagent_start 返回）"))
        props.add("id", JsonValue.Map(a))
        let p = HashMap<String, JsonValue>()
        p.add("type", JsonValue.String("string"))
        p.add("description", JsonValue.String("回复内容"))
        props.add("text", JsonValue.Map(p))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("id"))
        req.add(JsonValue.String("text"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let id: String = match (args["id"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: id", None, true, false)
        }
        let text: String = match (args["text"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: text", None, true, false)
        }
        match (this.manager.get(id)) {
            case Some(h) =>
                h.respond(text)
                ToolResult("已回复子 Agent ${id}", None, false, false)
            case None => ToolResult("未知子 Agent id：${id}", None, true, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

public class SubagentAwaitTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    public func name(): String { "subagent_await" }
    public func description(): String {
        "阻塞等待指定子 Agent 的消息（done/reply/progress）返回；当前回合在收到后继续。" +
        "超时（timeoutMs，默认 300000）无消息返回提示，可稍后再次等待。"
    }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let a = HashMap<String, JsonValue>()
        a.add("type", JsonValue.String("string"))
        a.add("description", JsonValue.String("子 Agent id"))
        props.add("id", JsonValue.Map(a))
        let t = HashMap<String, JsonValue>()
        t.add("type", JsonValue.String("integer"))
        t.add("description", JsonValue.String("等待超时毫秒（默认 300000）"))
        props.add("timeoutMs", JsonValue.Map(t))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("id"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let id: String = match (args["id"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: id", None, true, false)
        }
        let timeoutMs: Int64 = match (args["timeoutMs"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => 300000
        }
        match (this.manager.get(id)) {
            case Some(h) =>
                match (h.recv(timeout: Duration.millisecond * timeoutMs)) {
                    case Some(m) => ToolResult("[${m.kind}] ${m.text}", None, false, false)
                    case None => ToolResult("等待子 Agent ${id} 超时（${timeoutMs}ms），可稍后再试", None, false, false)
                }
            case None => ToolResult("未知子 Agent id：${id}", None, true, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

public class SubagentWatchTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    public func name(): String { "subagent_watch" }
    public func description(): String {
        "阻塞等待本会话任一子 Agent 的消息（done/reply/progress）；收到后当前回合继续。" +
        "子 Agent 的最终报告（done）与中间汇报都会经此唤醒父。"
    }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let t = HashMap<String, JsonValue>()
        t.add("type", JsonValue.String("integer"))
        t.add("description", JsonValue.String("等待超时毫秒（默认 300000）"))
        props.add("timeoutMs", JsonValue.Map(t))
        obj.add("properties", JsonValue.Map(props))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        if (ctx.sessionId == "") {
            return ToolResult("subagent_watch 需要会话上下文（sessionId）", None, true, false)
        }
        let timeoutMs: Int64 = match (args["timeoutMs"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => 300000
        }
        match (this.manager.awaitChildren(ctx.sessionId, timeout: Duration.millisecond * timeoutMs)) {
            case Some(m) => ToolResult("[${m.kind}] ${m.text}", None, false, false)
            case None => ToolResult("等待子 Agent 汇报超时（${timeoutMs}ms），可稍后再试", None, false, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

public class SubagentCloseTool <: Tool {
    private let manager: SubAgentManager
    public init(manager: SubAgentManager) { this.manager = manager }

    public func name(): String { "subagent_close" }
    public func description(): String { "终止指定子 Agent（会话历史保留，可重建续用）；幂等" }
    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))
        let props = HashMap<String, JsonValue>()
        let a = HashMap<String, JsonValue>()
        a.add("type", JsonValue.String("string"))
        a.add("description", JsonValue.String("子 Agent id"))
        props.add("id", JsonValue.Map(a))
        obj.add("properties", JsonValue.Map(props))
        let req = ArrayList<JsonValue>()
        req.add(JsonValue.String("id"))
        obj.add("required", JsonValue.Array(req))
        JsonValue.Map(obj)
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let id: String = match (args["id"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: id", None, true, false)
        }
        match (this.manager.get(id)) {
            case Some(h) =>
                h.close()
                ToolResult("已请求关闭子 Agent ${id}", None, false, false)
            case None => ToolResult("未知子 Agent id：${id}", None, true, false)
        }
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 把父端调度工具集注册进工具注册表
public func registerParentSubagentTools(reg: ToolRegistry, manager: SubAgentManager): Unit {
    reg.register(SubagentStartTool(manager))
    reg.register(SubagentSendTool(manager))
    reg.register(SubagentReplyTool(manager))
    reg.register(SubagentAwaitTool(manager))
    reg.register(SubagentWatchTool(manager))
    reg.register(SubagentCloseTool(manager))
}
