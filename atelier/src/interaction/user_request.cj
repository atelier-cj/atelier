package atelier.interaction

import std.collection.*
import stdx.encoding.json.stream.*
import jsonvalue.JsonValue

// 全功能提问：审批 / 选择 / 表单统一成「runtime 发请求 → run 挂起 → 答复作为下一次输入」。
//
// 为什么不是 (String) -> String：
// · 阻塞回调没法表达"这次 run 结束了、在等输入"，协议层（AG-UI 中断、ACP elicitation）接不上；
// · 字符串菜单 + 魔法字符串比对散落在三个调用点，改一处漏一处；
// · 空串同时表示"拒绝/答了空/传输失败/能力缺失"，消费方无法区分。
//
// 答复结构化：UserAnswer 扁平（便于跨协议序列化），status 区分 已答/挂起中/取消/超时。
// 校验放在这里（runtime 侧），宿主只负责渲染——否则 TUI / AG-UI / ACP 三端行为会分叉。
//
// 设计见 docs/plans/2026-10-01-user-interaction-refactor.md。

// ── 请求 ────────────────────────────────────────────────────────────────────

// 问什么：三种形态共用一套请求，kind 决定哪些字段有意义
public enum UserRequestKind {
    | Approval        // 审批某次工具调用（或 PTC 子调用）
    | Choice          // 从候选项里选（单选/多选）
    | Form            // 结构化表单
    | ToolExecution   // 交给外部执行工具（客户端工具；答复即工具结果）
}

public class UserOption <: JsonSerializable {
    public let id: String          // 回填值："allow_once" / "deny" / "opt-a" ...
    public let label: String
    public let description: String
    public let danger: Bool        // 前端可标红（删除类操作）

    public init(id: String, label: String, description!: String = "", danger!: Bool = false) {
        this.id = id; this.label = label
        this.description = description; this.danger = danger
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("label").writeValue(this.label)
        if (this.description != "") { w.writeName("description").writeValue(this.description) }
        if (this.danger) { w.writeName("danger").writeValue(true) }
        w.endObject()
    }
}

public enum UserFieldType {
    | Text | Number | Boolean | Select | MultiSelect
}

public class UserField <: JsonSerializable {
    public let name: String
    public let label: String
    public let fieldType: UserFieldType
    public let required: Bool
    public let options: ArrayList<UserOption>
    public let defaultValue: String
    public let placeholder: String

    public init(name: String, label: String, fieldType: UserFieldType, required!: Bool = false,
        options!: ArrayList<UserOption> = ArrayList(), defaultValue!: String = "",
        placeholder!: String = "") {
        this.name = name; this.label = label; this.fieldType = fieldType
        this.required = required; this.options = options
        this.defaultValue = defaultValue; this.placeholder = placeholder
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("name").writeValue(this.name)
        w.writeName("label").writeValue(this.label)
        w.writeName("type").writeValue(fieldTypeName(this.fieldType))
        if (this.required) { w.writeName("required").writeValue(true) }
        if (this.options.size > 0) { w.writeName("options").writeValue(this.options) }
        if (this.defaultValue != "") { w.writeName("default").writeValue(this.defaultValue) }
        if (this.placeholder != "") { w.writeName("placeholder").writeValue(this.placeholder) }
        w.endObject()
    }
}

public func fieldTypeName(t: UserFieldType): String {
    match (t) {
        case UserFieldType.Text => "text"
        case UserFieldType.Number => "number"
        case UserFieldType.Boolean => "bool"
        case UserFieldType.Select => "select"
        case UserFieldType.MultiSelect => "multi_select"
    }
}

public class UserRequest <: JsonSerializable {
    // **确定性** id：恢复（重放同一回合）时同一处提问必须得到同一个 id，宿主/前端才能对上答复。
    // 建议构造：ask:<sessionId>:<turn>:<toolCallId|"gate">:<kind>
    public let id: String
    public let kind: UserRequestKind
    public let message: String            // 给人看的一句话（前端兜底渲染）
    public let detail: String             // 补充说明（多行；如参数预览）
    public let toolCallId: String         // Approval / ToolExecution 绑定
    public let toolName: String
    public let args: Option<JsonValue>    // 审批时展示被批准的操作
    public let options: ArrayList<UserOption>
    public let multi: Bool                // Choice 是否多选
    public let fields: ArrayList<UserField>

    public init(id: String, kind: UserRequestKind, message: String, detail!: String = "",
        toolCallId!: String = "", toolName!: String = "", args!: Option<JsonValue> = None,
        options!: ArrayList<UserOption> = ArrayList(), multi!: Bool = false,
        fields!: ArrayList<UserField> = ArrayList()) {
        this.id = id; this.kind = kind; this.message = message; this.detail = detail
        this.toolCallId = toolCallId; this.toolName = toolName; this.args = args
        this.options = options; this.multi = multi; this.fields = fields
    }

    public func kindName(): String {
        match (this.kind) {
            case UserRequestKind.Approval => "approval"
            case UserRequestKind.Choice => "choice"
            case UserRequestKind.Form => "form"
            case UserRequestKind.ToolExecution => "tool_execution"
        }
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("id").writeValue(this.id)
        w.writeName("kind").writeValue(this.kindName())
        w.writeName("message").writeValue(this.message)
        if (this.detail != "") { w.writeName("detail").writeValue(this.detail) }
        if (this.toolCallId != "") { w.writeName("toolCallId").writeValue(this.toolCallId) }
        if (this.toolName != "") { w.writeName("toolName").writeValue(this.toolName) }
        match (this.args) {
            case Some(v) => w.writeName("args").writeValue(v)
            case None => ()
        }
        if (this.options.size > 0) { w.writeName("options").writeValue(this.options) }
        if (this.multi) { w.writeName("multi").writeValue(true) }
        if (this.fields.size > 0) { w.writeName("fields").writeValue(this.fields) }
        w.endObject()
    }
}

// ── 三种提问的构造（把"菜单怎么写"从 runtime 各处收拢到这里）─────────────────

// 审批：三态固定（本次允许 / 本目录永久允许 / 拒绝），带被批准的操作供展示
public func approvalRequest(id: String, toolName: String, args: JsonValue,
    message: String, toolCallId!: String = ""): UserRequest {
    let opts = ArrayList<UserOption>()
    opts.add(UserOption("allow_once", "允许这一次", description: "只对本次调用生效"))
    opts.add(UserOption("allow_always", "总是允许", description: "本目录下不再询问"))
    opts.add(UserOption("deny", "拒绝", description: "本次调用不执行", danger: true))
    UserRequest(id, UserRequestKind.Approval, message,
        toolCallId: toolCallId, toolName: toolName, args: Some(args), options: opts)
}

public func choiceRequest(id: String, message: String, options: ArrayList<UserOption>,
    multi!: Bool = false, detail!: String = ""): UserRequest {
    UserRequest(id, UserRequestKind.Choice, message, detail: detail,
        options: options, multi: multi)
}

public func formRequest(id: String, message: String, fields: ArrayList<UserField>,
    detail!: String = ""): UserRequest {
    UserRequest(id, UserRequestKind.Form, message, detail: detail, fields: fields)
}

// 客户端工具：交外部执行，答复即工具结果
public func toolExecutionRequest(id: String, toolName: String, args: JsonValue,
    message: String): UserRequest {
    UserRequest(id, UserRequestKind.ToolExecution, message,
        toolCallId: id, toolName: toolName, args: Some(args))
}

// ── 答复 ────────────────────────────────────────────────────────────────────

public enum UserAnswerStatus {
    | Answered    // 有答复（内容看各字段）
    | Pending     // 宿主决定挂起：runtime 据此结束本次 run，等下一次输入
    | Cancelled   // 用户放弃，无有效输入
    | TimedOut
}

public class UserAnswer <: JsonSerializable {
    public let requestId: String
    public let status: UserAnswerStatus
    public let selected: ArrayList<String>          // 选项 id（审批：allow_once/allow_always/deny）
    public let text: String                         // 自由文本
    public let values: HashMap<String, JsonValue>   // 表单值
    public let editedArgs: Option<JsonValue>        // 审批并改参数（批准时可选）

    public init(requestId: String, status: UserAnswerStatus,
        selected!: ArrayList<String> = ArrayList(), text!: String = "",
        values!: HashMap<String, JsonValue> = HashMap(), editedArgs!: Option<JsonValue> = None) {
        this.requestId = requestId; this.status = status
        this.selected = selected; this.text = text
        this.values = values; this.editedArgs = editedArgs
    }

    public func statusName(): String {
        match (this.status) {
            case UserAnswerStatus.Answered => "answered"
            case UserAnswerStatus.Pending => "pending"
            case UserAnswerStatus.Cancelled => "cancelled"
            case UserAnswerStatus.TimedOut => "timed_out"
        }
    }

    // 审批结论：只认选项 id（不再比对 "y"/"yes"/"a" 这些魔法字符串）
    public func approvalDecision(): Option<String> {
        // 仓颉枚举不支持 ==／!=：用 match 判别
        let answered = match (this.status) {
            case UserAnswerStatus.Answered => true
            case _ => false
        }
        if (!answered) { return None }
        if (this.selected.size == 0) { return None }
        Some(this.selected[0])
    }

    public func isAllowOnce(): Bool {
        match (this.approvalDecision()) {
            case Some(d) => d == "allow_once"
            case None => false
        }
    }

    public func isAllowAlways(): Bool {
        match (this.approvalDecision()) {
            case Some(d) => d == "allow_always"
            case None => false
        }
    }

    public func isDenied(): Bool {
        match (this.status) {
            case UserAnswerStatus.Cancelled => true
            case UserAnswerStatus.TimedOut => true
            case _ =>
                match (this.approvalDecision()) {
                    case Some(d) => d == "deny"
                    case None => false
                }
        }
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("requestId").writeValue(this.requestId)
        w.writeName("status").writeValue(this.statusName())
        if (this.selected.size > 0) { w.writeName("selected").writeValue(this.selected) }
        if (this.text != "") { w.writeName("text").writeValue(this.text) }
        if (this.values.size > 0) { w.writeName("values").writeValue(this.values) }
        match (this.editedArgs) {
            case Some(v) => w.writeName("editedArgs").writeValue(v)
            case None => ()
        }
        w.endObject()
    }

    public static func pending(requestId: String): UserAnswer {
        UserAnswer(requestId, UserAnswerStatus.Pending)
    }
}

// ── 校验（runtime 侧唯一入口，宿主不自行判断）─────────────────────────────────

// 返回 None = 通过；Some(原因) = 不合格（调用方据此回结构化错误，而不是静默接受）
public func validateAnswer(req: UserRequest, ans: UserAnswer): Option<String> {
    if (ans.requestId != req.id) {
        return Some("answer does not match request: ${ans.requestId} != ${req.id}")
    }
    match (ans.status) {
        case UserAnswerStatus.Pending => return None      // 挂起不是错误
        case UserAnswerStatus.Cancelled => return None
        case UserAnswerStatus.TimedOut => return None
        case UserAnswerStatus.Answered => ()
    }
    match (req.kind) {
        case UserRequestKind.Approval =>
            if (req.options.size == 0) { return Some("approval request has no options") }
            if (ans.selected.size != 1) {
                return Some("approval answer must select exactly one option (got ${ans.selected.size})")
            }
            for (o in req.options) {
                if (o.id == ans.selected[0]) { return None }
            }
            Some("unknown option: ${ans.selected[0]}")
        case UserRequestKind.Choice =>
            if (ans.selected.size == 0) { return Some("choice answer is empty") }
            if (!req.multi && ans.selected.size > 1) {
                return Some("choice is single-select but ${ans.selected.size} options were chosen")
            }
            for (chosen in ans.selected) {
                var known = false
                for (o in req.options) {
                    if (o.id == chosen) { known = true }
                }
                if (!known) { return Some("unknown option: ${chosen}") }
            }
            None
        case UserRequestKind.Form =>
            for (f in req.fields) {
                let raw = f.defaultValue
                var has = false
                var v = JsonValue.Null
                match (ans.values.get(f.name)) {
                    case Some(got) =>
                        has = true
                        v = got
                    case None =>
                        // 缺省值可以顶上
                        if (raw != "") { has = true }
                }
                if (f.required && !has) { return Some("missing required field: ${f.name}") }
                if (!has) { continue }
                match (validateField(f, v)) {
                    case Some(err) => return Some("${f.name}: ${err}")
                    case None => ()
                }
            }
            None
        case UserRequestKind.ToolExecution =>
            None      // 工具结果的合法性与具体工具有关，由工具自己判
    }
}

func validateField(f: UserField, v: JsonValue): Option<String> {
    match (f.fieldType) {
        case UserFieldType.Number =>
            match (v) {
                case JsonValue.Number(_) => None
                case JsonValue.String(s) =>
                    // 表单从协议上来多半是字符串，能解析成数字才算合格
                    if (isNumeric(s)) { None } else { Some("not a number") }
                case _ => Some("not a number")
            }
        case UserFieldType.Boolean =>
            match (v) {
                case JsonValue.Boolean(_) => None
                case JsonValue.String(s) =>
                    if (s == "true" || s == "false") { None } else { Some("not a bool") }
                case _ => Some("not a bool")
            }
        case UserFieldType.Select =>
            match (v) {
                case JsonValue.String(s) =>
                    for (o in f.options) {
                        if (o.id == s) { return None }
                    }
                    Some("unknown option: ${s}")
                case _ => Some("not an option id")
            }
        case UserFieldType.MultiSelect =>
            match (v) {
                case JsonValue.Array(items) =>
                    for (item in items) {
                        match (item) {
                            case JsonValue.String(s) =>
                                var known = false
                                for (o in f.options) {
                                    if (o.id == s) { known = true }
                                }
                                if (!known) { return Some("unknown option: ${s}") }
                            case _ => return Some("not an option id")
                        }
                    }
                    None
                case _ => Some("not a list of option ids")
            }
        case UserFieldType.Text => None
    }
}

func isNumeric(s: String): Bool {
    if (s == "") { return false }
    var seenDigit = false
    var seenDot = false
    for (b in s.toArray()) {
        if (b >= 48 && b <= 57) { seenDigit = true; continue }
        if (b == 45 && !seenDigit) { continue }
        if (b == 46 && !seenDot) { seenDot = true; continue }
        return false
    }
    seenDigit
}
