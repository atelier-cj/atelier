package cli

import std.collection.*
import std.core.Duration
import std.core.sleep
import std.sync.*
import atelier.interaction.*
import jsonvalue.JsonValue

// ═══════ 结构化提问（纯逻辑，可单测）═══════════════════════════
//
// 一次提问可能要多步才收敛：审批要挑一个结论、选择要在候选里挑、表单要逐字段填。
// 本文件把「问什么 → 收什么 → 够不够 → 下一步问什么」这套规则收在一处，与终端无关
// （终端只做两件事：把它给的行画出来、把按键喂进来），因此能脱离 TTY 单测。
//
// 三类提问的收敛方式：
// · 审批 / 选择：候选列表上移动光标，回车提交；多选时空格勾选
// · 表单：逐字段推进，bool / select / multi_select 字段复用上面的列表交互，
//   text / number 走输入行
// · 客户端工具（ToolExecution）：本端没有执行外部工具的通道，如实回报取消
//
// 取消一律给 Cancelled，**不是**空答复：空答复同时表示「拒绝 / 答了个空 / 压根没通道」，
// 下游无法区分（见 docs/plans/2026-10-01-user-interaction-refactor.md）。

public enum AskPhase {
    | Choosing     // 候选列表（审批 / 选择 / bool、select、multi_select 字段）
    | Typing       // 输入行（text / number 字段）
    | Finished     // 已有答复（含取消）
}

public class AskPrompt {
    public let req: UserRequest
    private var phase: AskPhase
    private var cursor: Int64
    private var picked: ArrayList<String>            // 多选：已勾选的选项 id（按勾选顺序）
    private var fieldIdx: Int64
    private let values: HashMap<String, JsonValue>   // 表单已填值
    private var note: String                         // 上一次提交被打回的原因（状态行原样显示）
    private var result: Option<UserAnswer>
    private let lock = Mutex()
    private var delivered: Option<UserAnswer>

    public init(req: UserRequest) {
        this.req = req
        this.phase = AskPhase.Choosing
        this.cursor = 0
        this.picked = ArrayList<String>()
        this.fieldIdx = 0
        this.values = HashMap<String, JsonValue>()
        this.note = ""
        this.result = None
        this.delivered = None
        match (req.kind) {
            case UserRequestKind.ToolExecution =>
                // 客户端工具要由前端执行；本端没有这条通道，等下去只会把回合卡到天荒地老
                this.phase = AskPhase.Finished
                this.result = Some(UserAnswer(req.id, UserAnswerStatus.Cancelled))
                this.note = "本端不执行客户端工具，已取消该请求"
            case _ =>
                if (req.fields.size > 0) {
                    this.enterField()
                } else if (req.options.size == 0) {
                    // 没有候选项的选择/审批无从作答：与其让用户对着空列表敲回车，不如如实取消
                    this.phase = AskPhase.Finished
                    this.result = Some(UserAnswer(req.id, UserAnswerStatus.Cancelled))
                    this.note = "请求未带候选项，无法作答"
                } else {
                    this.phase = AskPhase.Choosing
                }
        }
    }

    // ── 状态 ──────────────────────────────────────────────

    public func done(): Bool {
        let fin = match (this.phase) {
            case AskPhase.Finished => true
            case _ => false
        }
        fin
    }

    public func answer(): Option<UserAnswer> { this.result }
    public func currentNote(): String { this.note }
    public func currentPhase(): AskPhase { this.phase }
    public func cursorIndex(): Int64 { this.cursor }
    public func fieldIndex(): Int64 { this.fieldIdx }

    /** 当前步骤待选的候选（顶层提问的选项，或当前字段的候选）。 */
    public func currentOptions(): ArrayList<UserOption> {
        if (this.req.fields.size == 0) { return this.req.options }
        match (this.phase) {
            case AskPhase.Choosing =>
                let f = this.req.fields[this.fieldIdx]
                match (f.fieldType) {
                    // 布尔字段没有候选项列表，这里合成两项 —— 让"选择"这条交互对所有非文本字段统一
                    case UserFieldType.Boolean =>
                        let out = ArrayList<UserOption>()
                        out.add(UserOption("true", "是"))
                        out.add(UserOption("false", "否"))
                        return out
                    case _ => return f.options
                }
            case _ => return ArrayList<UserOption>()
        }
    }

    /** 当前步骤是否多选（空格勾选有意义）。 */
    public func allowsToggle(): Bool {
        if (this.req.fields.size == 0) {
            match (this.req.kind) {
                case UserRequestKind.Choice => return this.req.multi
                case _ => return false
            }
        }
        match (this.phase) {
            case AskPhase.Choosing =>
                match (this.req.fields[this.fieldIdx].fieldType) {
                    case UserFieldType.MultiSelect => return true
                    case _ => return false
                }
            case _ => return false
        }
    }

    public func isPicked(id: String): Bool {
        for (p in this.picked) {
            if (p == id) { return true }
        }
        false
    }

    // ── 交互 ──────────────────────────────────────────────

    public func moveUp(): Unit {
        if (this.cursor > 0) { this.cursor = this.cursor - 1 }
    }

    public func moveDown(): Unit {
        let n = this.currentOptions().size
        if (this.cursor < n - 1) { this.cursor = this.cursor + 1 }
    }

    /** 空格：多选时切换光标处的勾选状态。单选/审批下无副作用。 */
    public func toggle(): Unit {
        if (!this.allowsToggle()) { return }
        let opts = this.currentOptions()
        if (opts.size == 0) { return }
        let id = opts[this.cursor].id
        var at: Int64 = -1
        for (i in 0..this.picked.size) {
            if (this.picked[Int64(i)] == id) { at = i }
        }
        if (at >= 0) {
            this.picked.remove(at..(at + 1))
        } else {
            this.picked.add(id)
        }
    }

    /** 回车提交一行输入。返回 false = 被打回，原因见 statusText/currentNote，停在原步骤。 */
    public func submit(text: String): Bool {
        let ok = match (this.phase) {
            case AskPhase.Finished => true
            case AskPhase.Typing => this.submitTyped(text)
            case AskPhase.Choosing => this.submitChoice()
        }
        ok
    }

    /** Esc：取消本次提问。幂等；已有答复（含初始化即取消的）不被覆盖。 */
    public func cancel(): Unit {
        match (this.result) {
            case Some(_) => ()
            case None =>
                this.result = Some(UserAnswer(this.req.id, UserAnswerStatus.Cancelled))
                this.phase = AskPhase.Finished
        }
    }

    // ── 收敛到答复 ────────────────────────────────────────

    private func submitTyped(raw: String): Bool {
        let f = this.req.fields[this.fieldIdx]
        let text = raw.trimAscii()
        if (text == "") {
            if (f.defaultValue != "") { return this.putTextValue(f, f.defaultValue) }
            if (f.required) {
                this.note = "「${fieldLabel(f)}」是必填项"
                return false
            }
            this.note = ""
            this.advanceField()
            return true
        }
        match (f.fieldType) {
            case UserFieldType.Number =>
                if (!isNumericText(text)) {
                    this.note = "「${fieldLabel(f)}」需要一个数字"
                    return false
                }
                this.putTextValue(f, text)
            case _ => this.putTextValue(f, text)
        }
    }

    private func putTextValue(f: UserField, text: String): Bool {
        // 表单值一律按字符串存：跨协议（AG-UI / ACP / TUI）来的表单本来就都是字符串，
        // 校验侧也接受「能解析成数字的字符串」，三端口径一致才不会互相打架。
        this.values[f.name] = JsonValue.String(text)
        this.note = ""
        this.advanceField()
        true
    }

    private func submitChoice(): Bool {
        let opts = this.currentOptions()
        if (opts.size == 0) {
            this.note = "当前步骤没有候选项"
            return false
        }
        if (!this.allowsToggle()) {
            let one = ArrayList<String>()
            one.add(opts[this.cursor].id)
            return this.putChoiceValue(one)
        }
        // 多选：勾了就以勾的为准；一项没勾时回车视作"选中光标项"，
        // 否则用户会以为回车坏了（对多选只想要一项的人来说也少一步）
        let chosen = ArrayList<String>()
        for (p in this.picked) { chosen.add(p) }
        if (chosen.size == 0) { chosen.add(opts[this.cursor].id) }
        this.putChoiceValue(chosen)
    }

    private func putChoiceValue(ids: ArrayList<String>): Bool {
        if (this.req.fields.size == 0) {
            return this.settle(UserAnswer(this.req.id, UserAnswerStatus.Answered, selected: ids))
        }
        let f = this.req.fields[this.fieldIdx]
        match (f.fieldType) {
            case UserFieldType.Boolean =>
                this.values[f.name] = JsonValue.Boolean(ids[0] == "true")
            case UserFieldType.MultiSelect =>
                let arr = ArrayList<JsonValue>()
                for (id in ids) { arr.add(JsonValue.String(id)) }
                this.values[f.name] = JsonValue.Array(arr)
            case _ =>
                this.values[f.name] = JsonValue.String(ids[0])
        }
        this.note = ""
        this.advanceField()
        true
    }

    private func advanceField(): Unit {
        this.fieldIdx = this.fieldIdx + 1
        this.cursor = 0
        this.picked = ArrayList<String>()
        this.enterField()
    }

    private func enterField(): Unit {
        while (this.fieldIdx < this.req.fields.size) {
            match (this.req.fields[this.fieldIdx].fieldType) {
                case UserFieldType.Text | UserFieldType.Number =>
                    this.phase = AskPhase.Typing
                    return
                case _ =>
                    this.phase = AskPhase.Choosing
                    return
            }
        }
        // 字段走完：整表交给同一套校验（runtime 侧那份），过不了说明本端漏了什么，
        // 就地停住并说明 —— 送出去只会被 runtime 拒绝，而用户已经白填一遍
        this.settle(UserAnswer(this.req.id, UserAnswerStatus.Answered, values: this.values))
    }

    private func settle(ans: UserAnswer): Bool {
        match (validateAnswer(this.req, ans)) {
            case Some(err) =>
                this.note = "答复不合格: " + err
                false
            case None =>
                this.result = Some(ans)
                this.phase = AskPhase.Finished
                true
        }
    }

    // ── 渲染（纯文本；颜色/反显由终端决定）──────────────────

    /** 状态行文案：只有一行，必须自述"现在按什么键"。 */
    public func statusText(): String {
        if (this.note != "") { return this.note }
        match (this.phase) {
            case AskPhase.Finished => "提问已结束"
            case AskPhase.Typing =>
                let f = this.req.fields[this.fieldIdx]
                let what = match (f.fieldType) {
                    case UserFieldType.Number => "数字"
                    case _ => "文本"
                }
                "填写「${fieldLabel(f)}」（${what}，回车提交，Esc 取消）: " + firstLine(this.req.message)
            case AskPhase.Choosing =>
                let verb = if (this.allowsToggle()) {
                    "↑/↓ 移动，空格勾选（可多选），回车提交，Esc 取消"
                } else {
                    "↑/↓ 选择，回车提交，Esc 取消"
                }
                let head = match (this.req.kind) {
                    case UserRequestKind.Approval => "等待确认"
                    case _ => "请作答"
                }
                "${head}（${verb}）: " + firstLine(this.req.message)
        }
    }

    /** 会话区里的提问面板：问题、被批准的操作、候选列表、表单进度。 */
    public func panelLines(width: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        out.add("── 提问 · ${kindLabel(this.req.kind)} ──")
        for (line in wrapText(this.req.message, width)) {
            if (line != "") { out.add("  " + line) }
        }
        for (line in wrapText(this.req.detail, width)) {
            if (line != "") { out.add("  " + line) }
        }
        let opts = this.currentOptions()
        for (i in 0..opts.size) {
            let o = opts[Int64(i)]
            var line = "  "
            line = line + (if (i == this.cursor) { "→ " } else { "   " })
            if (this.allowsToggle()) {
                line = line + (if (this.isPicked(o.id)) { "[x] " } else { "[ ] " })
            }
            line = line + o.label
            if (o.description != "") { line = line + "  " + o.description }
            if (o.danger) { line = line + "  ⚠" }
            out.add(truncateLine(line, width))
        }
        let n = this.req.fields.size
        if (n > 0) {
            for (i in 0..n) {
                let f = this.req.fields[Int64(i)]
                var shown = "待填"
                match (this.values.get(f.name)) {
                    case Some(v) => shown = valueText(v)
                    case None => ()
                }
                var line = "  ${fieldLabel(f)}: ${shown}"
                if (i == this.fieldIdx && !this.done()) { line = line + " ←" }
                if (f.required) { line = line + "（必填）" }
                out.add(truncateLine(line, width))
            }
        }
        if (this.note != "") { out.add("  ! " + this.note) }
        out
    }

    // ── 跨线程投递（回合线程等待，主线程回填）─────────────

    /** 回合线程：等主线程把答复填进来。50ms 轮询，对人工交互足够。 */
    public func waitAnswer(): UserAnswer {
        var got: Option<UserAnswer> = None
        while (got.isNone()) {
            synchronized(this.lock) {
                got = this.delivered
            }
            if (got.isNone()) { sleep(Duration.millisecond * 50) }
        }
        match (got) {
            case Some(a) => a
            case None => UserAnswer(this.req.id, UserAnswerStatus.Cancelled)
        }
    }

    /** 主线程：回填答复。幂等，重复投递只保留第一次。 */
    public func deliver(ans: UserAnswer): Unit {
        synchronized(this.lock) {
            match (this.delivered) {
                case Some(_) => ()
                case None => this.delivered = Some(ans)
            }
        }
    }
}

// ── 辅助（包级，可单测）─────────────────────────────────────────

public func firstLine(s: String): String {
    let lines = s.split("\n")
    if (lines.size == 0) { return s.trimAscii() }
    lines[0].trimAscii()
}

public func kindLabel(k: UserRequestKind): String {
    match (k) {
        case UserRequestKind.Approval => "审批"
        case UserRequestKind.Choice => "选择"
        case UserRequestKind.Form => "表单"
        case UserRequestKind.ToolExecution => "客户端工具"
    }
}

/** 字段显示名：label 为空时退回 name，免得面板上出现一行没有主语的值。 */
public func fieldLabel(f: UserField): String {
    if (f.label != "") { return f.label }
    f.name
}

public func valueText(v: JsonValue): String {
    match (v) {
        case JsonValue.String(s) => s
        case JsonValue.Boolean(b) => if (b) { "是" } else { "否" }
        case JsonValue.Number(n) => n.toString()
        case JsonValue.Array(items) =>
            let sb = StringBuilder()
            for (item in items) {
                if (sb.size > 0) { sb.append(", ") }
                sb.append(valueText(item))
            }
            sb.toString()
        case JsonValue.Null => "(空)"
        case _ => "(…)"
    }
}

/** 数字文本判定：与校验侧 isNumeric 同口径（整数、小数、前导负号）。 */
public func isNumericText(s: String): Bool {
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
