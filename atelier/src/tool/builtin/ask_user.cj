package atelier.tool.builtin

import atelier.tool.*
import atelier.interaction.*
import atelier.util.toJsonString
import jsonvalue.*
import std.collection.*

public class AskUserTool <: Tool {
    public func name(): String { "ask_user" }

    public func description(): String {
        "Ask the user and wait for the answer. Three shapes: plain question (just `question`), " +
        "single/multi choice (`options` [+`multi`]), or a structured form (`fields`). " +
        "Use when you need clarification, a decision, or additional structured information."
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("question", "The question to ask the user", required: true)
            .addString("options", "For a choice: JSON array of option ids, or of objects " +
                "{id,label,description}. Omit for a plain question.")
            .addEnum("multi", "For a choice: allow selecting several options",
                ArrayList<String>(["true", "false"]))
            .addString("fields", "For a form: JSON array of {name,label,type,required,options,default}; " +
                "type is one of text|number|bool|select|multi_select")
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let question: String = match (args["question"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: question", None, true, false)
        }
        // 确定性 id：同一处提问在恢复（重放）时必须得到同一个 id，宿主才能把答复对上
        let reqId = "ask:${ctx.sessionId}:tool:${ctx.toolCallId}"

        let fields = parseFields(args["fields"])
        let options = parseOptions(args["options"])
        let multi = match (args["multi"]) {
            case Some(JsonValue.Boolean(b)) => b
            case Some(JsonValue.String(s)) => s == "true"
            case _ => false
        }

        let req = if (fields.size > 0) {
            formRequest(reqId, question, fields)
        } else if (options.size > 0) {
            choiceRequest(reqId, question, options, multi: multi)
        } else {
            // 普通提问：用单字段表单表达（结构化答复里没有"纯文本"这一种，表单是它的自然载体）
            let one = ArrayList<UserField>()
            one.add(UserField("answer", "answer", UserFieldType.Text, required: true))
            formRequest(reqId, question, one)
        }

        let ans = ctx.ask(req)
        match (ans.status) {
            case UserAnswerStatus.Cancelled => return ToolResult(
                "User cancelled without answering.", None, true, false)
            case UserAnswerStatus.TimedOut => return ToolResult(
                "User did not answer in time.", None, true, false)
            case UserAnswerStatus.Pending => return ToolResult("", None, false, false,
                // 挂起：本次调用没有结果，等宿主在后续输入里带回（与前端工具同一条路径）
                // 原始提问一并带出：候选/字段/类型是答复契约的一部分，
                // 丢了前端就只剩一句提示语，收什么形状只能靠猜
                external: Some(ExternalRequest(req.id, "input_required", req.message,
                    toolCallId: ctx.toolCallId, request: Some(req))))
            case UserAnswerStatus.Answered => ()
        }

        // 校验在 runtime 侧统一做；不合格时退化为"把原文交给模型"（宿主可能是纯文本通道，
        // 没有渲染选项/表单的能力），并明确标注降级，避免模型以为拿到了结构化结果
        let invalid = validateAnswer(req, ans)
        let rendered = renderAnswer(req, ans)
        match (invalid) {
            case Some(err) =>
                if (ans.text != "") {
                    return ToolResult("${ans.text}\n(host returned free text; not validated: ${err})",
                        None, false, false)
                }
                ToolResult("User answer failed validation: ${err}", None, true, false)
            case None => ToolResult(rendered, None, false, false)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }

    /**
     * 不限时：本工具的时间花在**等人回答**上。
     *
     * 框架预算的用途是兜住「工具卡死」，而人思考多久都不算卡死——套上预算的
     * 后果是：用户想了 31 秒，模型却收到一句「超时、调用已被放弃」。
     */
    public func timeoutBudget(): ToolBudget {
        ToolBudget.Unbounded
    }
}

// ── 入参解析（工具参数天然是动态 JSON，故按 JsonValue 逐字段取）─────────────────

// options：["a","b"] 或 [{id,label,description}] 两种写法都收
func parseOptions(raw: Option<JsonValue>): ArrayList<UserOption> {
    let out = ArrayList<UserOption>()
    match (raw) {
        case Some(JsonValue.Array(items)) =>
            for (item in items) {
                match (item) {
                    case JsonValue.String(s) => out.add(UserOption(s, s))
                    case JsonValue.Map(m) =>
                        let id = strOf(m.get("id"))
                        if (id == "") { continue }
                        let label = match (m.get("label")) {
                            case Some(JsonValue.String(s)) => s
                            case _ => id
                        }
                        out.add(UserOption(id, label, description: strOf(m.get("description"))))
                    case _ => ()
                }
            }
        case _ => ()
    }
    out
}

func parseFields(raw: Option<JsonValue>): ArrayList<UserField> {
    let out = ArrayList<UserField>()
    match (raw) {
        case Some(JsonValue.Array(items)) =>
            for (item in items) {
                match (item) {
                    case JsonValue.Map(m) =>
                        let name = strOf(m.get("name"))
                        if (name == "") { continue }
                        let label = match (m.get("label")) {
                            case Some(JsonValue.String(s)) => s
                            case _ => name
                        }
                        let ftype = match (strOf(m.get("type"))) {
                            case "number" => UserFieldType.Number
                            case "bool" => UserFieldType.Boolean
                            case "select" => UserFieldType.Select
                            case "multi_select" => UserFieldType.MultiSelect
                            case _ => UserFieldType.Text
                        }
                        let required = match (m.get("required")) {
                            case Some(JsonValue.Boolean(b)) => b
                            case _ => false
                        }
                        let opts = parseOptions(m.get("options"))
                        out.add(UserField(name, label, ftype, required: required, options: opts,
                            defaultValue: strOf(m.get("default"))))
                    case _ => ()
                }
            }
        case _ => ()
    }
    out
}

func strOf(v: Option<JsonValue>): String {
    match (v) {
        case Some(JsonValue.String(s)) => s
        case _ => ""
    }
}

// 答复 → 给模型看的文本：表单按 name=value 罗列，选择列 id（有 label 时附上）
func renderAnswer(req: UserRequest, ans: UserAnswer): String {
    let sb = StringBuilder()
    match (req.kind) {
        case UserRequestKind.Form =>
            for (f in req.fields) {
                let v = match (ans.values.get(f.name)) {
                    case Some(JsonValue.String(s)) => s
                    case Some(other) => toJsonString(other)
                    case None => f.defaultValue
                }
                if (sb.size > 0) { sb.append("\\n") }
                sb.append("${f.name}=${v}")
            }
            if (sb.size == 0 && ans.text != "") { sb.append(ans.text) }
        case UserRequestKind.Choice =>
            for (i in 0..ans.selected.size) {
                if (i > 0) { sb.append(", ") }
                let id = ans.selected[Int64(i)]
                var label = id
                for (o in req.options) {
                    if (o.id == id) { label = o.label }
                }
                sb.append(label)
            }
        case UserRequestKind.Approval =>
            sb.append(match (ans.approvalDecision()) {
                case Some(d) => d
                case None => "no decision"
            })
        case UserRequestKind.ToolExecution =>
            sb.append(ans.text)
    }
    sb.toString()
}
