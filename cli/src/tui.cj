package cli

import ystyle::xisp_terminal.*
import cjterm_stream.*
import opencj::ulid.nextId
import std.core.Duration
import std.core.sleep
import std.time.MonoTime
import std.sync.*
import std.env.*
import std.collection.*
import std.fs.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.session.exportToJsonl
import atelier.session.exportToHtml
import atelier.trust.*
import atelier.skill.*
import atelier.ptc.{JsonBridge, RunXispTool}
import atelier.interaction.*

// ═══════ 纯逻辑（包级，可单测）══════════════════════════════

// 按显示宽度（CJK 宽字符计 2）把文本拆成行
public func wrapText(s: String, width: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    if (width <= 0) {
        out.add(s)
        return out
    }
    let runes = s.toRuneArray()
    var line = ArrayList<Rune>()
    var w: Int64 = 0
    for (i in 0..runes.size) {
        let r = runes[Int64(i)]
        let dw = runeDisplayWidth(r)
        if (w + dw > width && line.size > 0) {
            out.add(String(line))
            line = ArrayList<Rune>()
            w = 0
        }
        line.add(r)
        w = w + dw
    }
    out.add(String(line))
    out
}

// 提取消息正文（只取文本块）
public func messageText(m: Message): String {
    match (m) {
        case um: UserMessage => contentText(um.content)
        case am: AssistantMessage => contentText(am.content)
        case _ => ""
    }
}

public func contentText(c: ContentList): String {
    var s = ""
    for (b in c.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => s = s + t
            case _ => ()
        }
    }
    s
}

public func chatLinePrefix(role: MessageRole): String {
    match (role) {
        case MessageRole.User => "you: "
        case _ => "ai:  "
    }
}

// 输入缓冲区的显示宽度（光标定位用）
public func runeWidthSum(runes: Array<Rune>): Int64 {
    var w: Int64 = 0
    for (r in runes) { w = w + runeDisplayWidth(r) }
    w
}

// 按显示宽度截断为单行，超出补 "..."（工具调用结果摘要用）
public func truncateLine(s: String, width: Int64): String {
    if (width <= 0) { return "" }
    let runes = s.toRuneArray()
    var out = ArrayList<Rune>()
    var w: Int64 = 0
    for (r in runes) {
        let dw = runeDisplayWidth(r)
        if (w + dw > width) {
            for (i in 0..3) { out.add(Rune(UInt32(0x2E))) }   // "..."
            return String(out)
        }
        out.add(r)
        w = w + dw
    }
    s
}

// 工具调用显示行：`tool: <名称>[ ⚠][  <结果摘要>]`
public func toolLineText(tr: ToolResultMessage, width: Int64): String {
    let head = if (tr.isError) { "tool: " + tr.toolName + " ⚠" } else { "tool: " + tr.toolName }
    let resultText = contentText(tr.content)
    if (resultText == "") { return head }
    let maxResult = width - 8
    if (maxResult <= 0) { return head }
    head + "  " + truncateLine(resultText, maxResult)
}

// ═══════ 暗色主题颜色与消息装饰 ═══════════════════════════════

public let C_RESET: String = "\u{1b}[0m"
public let C_BOLD: String = "\u{1b}[1m"
public let C_DIM: String = "\u{1b}[2m"
public let C_USER: String = "\u{1b}[36m"      // 用户：青
public let C_AI: String = "\u{1b}[97m"        // AI：亮白
public let C_TOOL: String = "\u{1b}[33m"      // 工具：黄
public let C_HEADER: String = "\u{1b}[1;36m"  // 头部：粗青
public let C_STATUS: String = "\u{1b}[2;90m"  // 状态：暗灰
public let C_ERROR: String = "\u{1b}[1;31m"   // 错误：亮红
public let C_PROMPT: String = "\u{1b}[32m"    // 输入提示：绿

public func colorize(text: String, color: String): String {
    color + text + C_RESET
}

// 消息装饰：前缀着色 + 正文按宽度换行（先 wrap 再着色，避免 ANSI 码干扰宽度计算）
public func decorateMessageLines(m: Message, width: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    match (m) {
        case um: UserMessage =>
            let content = contentText(um.content)
            if (content != "") {
                let lines = markdownToLines(content, width, 5)
                for (i in 0..lines.size) {
                    if (i == 0) { out.add(colorize("you: ", C_USER) + lines[Int64(i)]) }
                    else { out.add(lines[Int64(i)]) }
                }
            }
        case am: AssistantMessage =>
            let content = contentText(am.content)
            if (content != "") {
                let lines = markdownToLines(content, width, 5)
                for (i in 0..lines.size) {
                    if (i == 0) { out.add(colorize("ai:  ", C_AI) + lines[Int64(i)]) }
                    else { out.add(lines[Int64(i)]) }
                }
            }
            // 工具调用：模型侧的意图必须可见——PTC 下它承载整段程序，native 下它承载
            // 调用参数，两者都是理解后续结果的前提
            for (tc in am.content.toolCalls()) {
                for (l in toolCallLines(tc, width)) { out.add(l) }
            }
        case tr: ToolResultMessage =>
            if (tr.toolName == RunXispTool.TOOL_NAME) {
                // 程序输出是「日志 + 完成值」，压成一行等于没显示
                for (l in runXispResultLines(tr, width)) { out.add(l) }
            } else {
                out.add(colorize(toolLineText(tr, width), C_TOOL))
            }
        case _ => ()
    }
    out
}

// String → 输入缓冲（ArrayList<Rune>）
public func toRunes(s: String): ArrayList<Rune> {
    let out = ArrayList<Rune>()
    for (r in s.toRuneArray()) { out.add(r) }
    out
}

// ═══════ 输入历史（包级，可单测）═══════════════════════════════
// ↑/↓ 遍历已提交输入；首次按 ↑ 保存当前草稿，↓ 越过最新一条时恢复草稿。
public class ChatHistory {
    private var entries: ArrayList<String>
    private var idx: Int64
    private var draft: String

    public init() {
        this.entries = ArrayList<String>()
        this.idx = 0
        this.draft = ""
    }

    // 提交一行：入历史（相邻去重），重置浏览位置到最新
    public func push(line: String): Unit {
        if (line == "") { return }
        if (this.entries.size > 0 && this.entries[this.entries.size - 1] == line) { return }
        this.entries.add(line)
        this.idx = this.entries.size
    }

    // 上一条：首次进入浏览时把当前输入存为草稿
    public func up(current: String): Option<String> {
        if (this.entries.size == 0) { return None }
        if (this.idx >= this.entries.size) {
            this.draft = current
            this.idx = this.entries.size - 1
        } else if (this.idx > 0) {
            this.idx = this.idx - 1
        }
        Some(this.entries[this.idx])
    }

    // 下一条：越过最新一条时恢复草稿
    public func down(): Option<String> {
        if (this.entries.size == 0) { return None }
        if (this.idx >= this.entries.size - 1) {
            this.idx = this.entries.size
            return Some(this.draft)
        }
        this.idx = this.idx + 1
        Some(this.entries[this.idx])
    }
}

// ═══════ 会话选择器（包级，可单测）═══════════════════════════════
// /session list 进入交互选择：↑/↓ 移动、Enter 选中、Esc 取消。
public class SessionPicker {
    private var ids: ArrayList<String>
    private var idx: Int64

    public init(ids: ArrayList<String>) {
        this.ids = ids
        this.idx = 0
    }

    public func moveUp(): Unit {
        if (this.idx > 0) { this.idx = this.idx - 1 }
    }

    public func moveDown(): Unit {
        if (this.idx < this.ids.size - 1) { this.idx = this.idx + 1 }
    }

    public func selected(): String { this.ids[this.idx] }
    public func size(): Int64 { this.ids.size }
    public func idAt(i: Int64): String { this.ids[Int64(i)] }
    public func index(): Int64 { this.idx }
}

// ═══════ 会话信息条与状态净化（纯逻辑，可单测）═══════════════════

public func countUserTurns(messages: ArrayList<Message>): Int64 {
    var n: Int64 = 0
    for (m in messages) {
        match (m) {
            case um: UserMessage => n++
            case _ => ()
        }
    }
    n
}

public func contextChars(messages: ArrayList<Message>): Int64 {
    var n: Int64 = 0
    for (m in messages) { n = n + messageText(m).toRuneArray().size }
    n
}

// LLM 上报的真实上下文消耗：累加各条 AssistantMessage 的 token 用量（llm_api 返回）
public func sessionTokens(messages: ArrayList<Message>): (Int64, Int64) {
    var input: Int64 = 0
    var output: Int64 = 0
    for (m in messages) {
        match (m) {
            case am: AssistantMessage =>
                input = input + am.usage.inputTokens
                output = output + am.usage.outputTokens
            case _ => ()
        }
    }
    (input, output)
}

public func sessionInfoText(agentName: String, model: String, turns: Int64,
    ctxChars: Int64, inputTokens: Int64, outputTokens: Int64): String {
    "Agent: " + agentName + "  |  Model: " + model + "  |  Turns: " + turns.toString() +
        "  |  Ctx: " + ctxChars.toString() + " chars" +
        "  |  Tokens: " + inputTokens.toString() + "/" + outputTokens.toString()
}

// 状态行净化：换行拍平 + 按宽度截断（多行文本不会炸布局）
public func flattenStatus(s: String, width: Int64): String {
    truncateLine(s.replace("\n", " | "), width)
}

// ═══════ 配置模型清单（包级，可单测）═════════════════════════════
// 从 agent 配置里收集去重后的模型（按出现顺序）
public func uniqueModels(agents: ArrayList<(String, AgentConfig)>): ArrayList<String> {
    let out = ArrayList<String>()
    for ((_, cfg) in agents) {
        var seen = false
        for (m in out) {
            if (m == cfg.model) { seen = true; break }
        }
        if (!seen) { out.add(cfg.model) }
    }
    out
}

// ═══════ /help 命令清单（包级，可单测）═══════════════════════════
public func helpLines(): ArrayList<String> {
    let out = ArrayList<String>()
    out.add("/help                 本清单（任意键返回）")
    out.add("/agent [name]         切换 Agent（无参=交互选择）")
    out.add("/session [new|list|switch <id>|export <id> <jsonl|html>]")
    out.add("/model <name>         切换模型")
    out.add("/models               列出配置的所有模型")
    out.add("/tools                列出当前 agent 工具")
    out.add("/compact              压缩当前会话（手动触发，绕过阈值）")
    out.add("/subagent [list|poll|start [--remote] <agent> <prompt>|send <id> <text>|respond <id> <text>|close <id>]")
    out.add("/trust <path>         信任目录（平行工具免审）")
    out.add("/untrust <path>       撤销信任")
    out.add("/new                  新建会话（= /session new）")
    out.add("/clear                清空会话")
    out.add("/exit /quit           退出")
    out
}

// ═══════ 会话渲染：轮次分隔线 ═════════════════════════════════
// 用户消息前（上一轮为助手回复时）画暗色分隔线，标记轮次边界。
public func turnLine(width: Int64): String {
    let sb = StringBuilder()
    for (i in 0..width) { sb.append("─") }
    C_DIM + sb.toString() + C_RESET
}

public func conversationLines(messages: ArrayList<Message>, width: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    var prevIsAssistant = false
    for (m in messages) {
        let role = m.role()
        if (prevIsAssistant && match (role) { case MessageRole.User => true; case _ => false }) {
            out.add(turnLine(width))
        }
        let lines = decorateMessageLines(m, width)
        for (l in lines) { out.add(l) }
        prevIsAssistant = match (role) { case MessageRole.Assistant => true; case _ => false }
    }
    out
}

// ═══════ PTC / 工具调用的呈现 ═══════════════════════════════
// 工具呈现为「调用」与「结果」两段。PTC 模式下模型写的程序、以及程序产生的日志
// 与完成值都在这两段里——压成一行就完全看不出它在做什么，因此按多行渲染。

/** 程序体与结果正文的显示行数上限，超出部分折叠成一行提示。 */
public let PTC_MAX_BODY_LINES: Int64 = 40

/**
 * 助手消息里的一个工具调用。
 *
 * `run_xisp` 的程序是本次调用的主体，展开显示；其余工具显示一行参数摘要。
 */
public func toolCallLines(tc: ToolCallBlock, width: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    if (tc.name == RunXispTool.TOOL_NAME) {
        let desc = match (JsonBridge.stringField(tc.args, "description")) {
            case Some(s) => s
            case None => ""
        }
        let head = if (desc == "") { "tool→ run_xisp" } else { "tool→ run_xisp  " + desc }
        out.add(colorize(head, C_TOOL))
        match (JsonBridge.stringField(tc.args, "code")) {
            case Some(code) => appendBodyLines(out, code, width)
            case None => ()
        }
    } else {
        let summary = truncateLine(JsonBridge.render(tc.args), width - 8)
        out.add(colorize("tool→ " + tc.name + "  " + summary, C_TOOL))
    }
    out
}

/** `run_xisp` 的结果：日志与完成值按行原样显示，错误单独标注。 */
public func runXispResultLines(tr: ToolResultMessage, width: Int64): ArrayList<String> {
    let out = ArrayList<String>()
    let head = if (tr.isError) { "tool← run_xisp ⚠" } else { "tool← run_xisp" }
    out.add(colorize(head, C_TOOL))
    appendBodyLines(out, contentText(tr.content), width)
    out
}

/** 逐行加入缩进正文；超过上限时折叠为一行提示。 */
private func appendBodyLines(out: ArrayList<String>, body: String, width: Int64): Unit {
    if (body == "") { return }
    let lines = body.split("\n")
    var shown: Int64 = 0
    for (line in lines) {
        if (shown >= PTC_MAX_BODY_LINES) { break }
        out.add(colorize("  │ " + truncateLine(line, width - 4), C_TOOL))
        shown = shown + 1
    }
    let hidden = lines.size - shown
    if (hidden > 0) {
        out.add(colorize("  │ … 还有 " + hidden.toString() + " 行", C_DIM))
    }
}

// ═══════ 提问：交给主线程读答案 ═══════════════════════════════
// agent 回合跑在另一个线程里，它不能自己读 stdin——主线程的 readKey 正在读同一个
// fd，两边抢输入会让答案永远读不到；也不能自己写提示后调 render——那会被随后的
// 整帧重绘覆盖。因此把提问投递给主线程，由它在正常的输入行里收答案，
// 运行线程在这里等待。提问怎么收敛（选项怎么挑、表单怎么填）在 ask.cj，可单测。

// ═══════ 聊天 TUI ══════════════════════════════════════════

// raw mode + ANSI。输入侧复用 xisp 的 terminal（POSIX 已实测；Windows 实现存在但未验证）；
// 输出侧走 cjterm_stream（整帧缓冲一次写，避免逐行 print 在真终端/慢控制台上的卡顿）。
// v1 约束：readKey 无超时 + chat 阻塞 → 生成期间界面冻结（显示状态行），流式渲染留待后续。
public class ChatTui {
    private var agentName: String
    private let registry: SlashCommandRegistry
    private var agentConfig: AgentConfig
    private var provider: Provider
    // 装配束：组件与子 Agent 管理器都从这里来
    private let spec: HarnessSpec
    private let sessionDir: String
    private var sessionId: String
    // messages 包内可见：测试要断言"提问期间打的字没有变成用户消息"
    var messages: ArrayList<Message>
    // input / busy / submit / runCommand 为包内可见：TUI 的驱动入口是按键循环，
    // 交互式回合无法从外部同步驱动，测试需要在包内直接提交并等待回合结束。
    var input: ArrayList<Rune>
    private var scroll: Int64
    private var status: String
    private var running: Bool
    private var modelOverride: String
    private let subMgr: SubAgentManager
    private var hist: ChatHistory
    private var picker: Option<SessionPicker>
    private var pickerKind: String
    private var helpMode: Bool
    private var out: AutoStream
    /** 待回答的提问；非空时按键全部先喂给它（提问是模态，回车不是新消息）。 */
    private var pendingAsk: ?AskPrompt = None
    private let askLock = Mutex()
    /** 回合是否在后台线程里进行中（防止并发提交写同一份历史）。 */
    let busy = AtomicBool(false)
    /** 本回合的实时活动（工具/子调用/脚本输出），只在回合进行中显示。 */
    private let activity = TurnActivity()

    public init(agentName: String, registry: SlashCommandRegistry, agentConfig: AgentConfig,
        spec: HarnessSpec, resumeSessionId: String, sessionDir: String) {
        this.agentName = agentName
        this.registry = registry
        this.agentConfig = agentConfig
        this.provider = spec.resolveProvider(agentConfig)
        this.spec = spec
        this.sessionDir = sessionDir
        this.input = ArrayList<Rune>()
        this.scroll = 0
        this.status = ""
        this.running = true
        this.modelOverride = ""
        this.hist = ChatHistory()
        this.picker = None
        this.pickerKind = ""
        this.helpMode = false
        this.out = AutoStream.stdout()
        // 可持续子 Agent：回合内工具 + /subagent 命令
        this.subMgr = SubAgentManager(spec)
        registerParentSubagentTools(spec.tools, this.subMgr)
        if (resumeSessionId != "") {
            this.sessionId = resumeSessionId
            this.messages = try {
                this.spec.store.load(resumeSessionId)
            } catch (e: Exception) {
                this.status = "会话恢复失败: " + e.message
                ArrayList<Message>()
            }
        } else {
            this.sessionId = "sess_" + nextId()
            this.messages = ArrayList<Message>()
        }
    }

    public func run(): Unit {
        let t = createTerminal()
        if (!t.isTTY()) {
            println("ChatTui 需要交互式终端（stdin 非 tty）。单次运行请用 cli.app run <prompt>")
            return
        }
        t.enableRawMode()
        this.out = AutoStream.stdout()
        this.writeRaw("\u{1b}[?1049h")   // alternate screen
        this.writeRaw("\u{1b}[?25l")     // cursor hide
        this.runWith(t)
    }

    // 事件循环（拆出便于测试注入 FakeTerminal）
    func runWith(t: Terminal): Unit {
        try {
            this.render(t)
            while (this.running) {
                match (t.readKey()) {
                    case Some(ke) => this.handleKey(ke, t)
                    case None => ()
                }
            }
        } finally {
            // 退出前等后台回合收尾，否则这一轮的落库可能还没发生就退出了。
            // 有上限：卡在询问上的回合不该把退出也一起卡住。
            var guard = 0
            while (this.busy.load() && guard < 150) {
                sleep(Duration.millisecond * 20)
                guard = guard + 1
            }
            this.writeRaw("\u{1b}[?25h")
            this.writeRaw("\u{1b}[?1049l")
            t.disableRawMode()
        }
    }

    // ── 输出（整帧缓冲一次写）──────────────────────────────

    private func writeRaw(s: String): Unit {
        this.out.write(s.toArray())
        this.out.flush()
    }

    // 0 基坐标 → ANSI 定位（与 xisp moveTo 同语义：+1 转 1 基）
    private func csiMove(col: Int64, row: Int64): String {
        "\u{1b}[${row + 1};${col + 1}H"
    }

    // 全量重绘（消息区/状态/输入行），用于：初始、提交后、滚动、恢复
    private func render(t: Terminal): Unit {
        let (cols, rows) = t.getTerminalSize()
        let c = if (cols > 0) { cols } else { 80 }
        let r = if (rows > 0) { rows } else { 24 }
        let sb = StringBuilder()
        sb.append(csiMove(0, 0))
        sb.append("\u{1b}[2K")
        sb.append(colorize("Atelier TUI — Agent: " + this.agentName + "  Session: " + this.sessionId + "   /help", C_HEADER))
        let msgRows = r - 4
        if (this.helpMode) {
            // 帮助清单逐行显示
            let lines = helpLines()
            for (i in 0..msgRows) {
                sb.append(csiMove(0, i + 1))
                sb.append("\u{1b}[2K")
                if (i < lines.size) { sb.append(lines[Int64(i)]) }
            }
        } else {
            match (this.picker) {
            case Some(p) =>
                // 会话选择列表：窗口跟随选择行
                let start = p.index() - msgRows / 2
                let wStart = if (start < 0) { 0 } else { start }
                for (i in 0..msgRows) {
                    sb.append(csiMove(0, i + 1))
                    sb.append("\u{1b}[2K")
                    let idx = wStart + i
                    if (idx >= 0 && idx < p.size()) {
                        let cur = if (this.pickerKind == "agent") {
                            if (p.idAt(idx) == this.agentName) { " (current)" } else { "" }
                        } else {
                            if (p.idAt(idx) == this.sessionId) { " (current)" } else { "" }
                        }
                        if (idx == p.index()) {
                            sb.append("\u{1b}[7m" + "→ " + p.idAt(idx) + cur + C_RESET)
                        } else {
                            sb.append("  " + p.idAt(idx) + cur)
                        }
                    }
                }
            case None =>
                let lines = this.messageLines(c)
                let start = if (lines.size > msgRows) { lines.size - msgRows - this.scroll } else { 0 }
                for (i in 0..msgRows) {
                    sb.append(csiMove(0, i + 1))
                    sb.append("\u{1b}[2K")
                    let idx = start + i
                    if (idx >= 0 && idx < lines.size) { sb.append(lines[Int64(idx)]) }
                }
            }
        }
        // 会话信息条（Agent / 模型 / 轮次 / 上下文长度）
        let model = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        let (tokIn, tokOut) = sessionTokens(this.messages)
        let info = sessionInfoText(this.agentName, model,
            countUserTurns(this.messages), contextChars(this.messages), tokIn, tokOut)
        sb.append(csiMove(0, r - 3))
        sb.append("\u{1b}[2K")
        sb.append(colorize(truncateLine(info, c - 2), C_DIM))
        // 状态行（净化：换行拍平 + 截断）
        sb.append(csiMove(0, r - 2))
        sb.append("\u{1b}[2K")
        if (this.hasPendingAsk() || this.status.startsWith("Error") || this.status.startsWith("[atelier]")) {
            sb.append(colorize(flattenStatus(this.status, c - 2), C_ERROR))
        } else {
            sb.append(colorize(flattenStatus(this.status, c - 2), C_STATUS))
        }
        sb.append(csiMove(0, r - 1))
        sb.append("\u{1b}[2K")
        sb.append(colorize("> ", C_PROMPT) + String(this.input))
        sb.append(csiMove(runeWidthSum(this.input.toArray()) + 2, r - 1))
        this.out.write(sb.toString().toArray())
        this.out.flush()
    }

    // 输入行增量更新（打字时只重写输入行 + 光标，不动消息区 → 不卡）
    private func renderInputOnly(t: Terminal): Unit {
        let (cols, rows) = t.getTerminalSize()
        let r = if (rows > 0) { rows } else { 24 }
        let sb = StringBuilder()
        sb.append(csiMove(0, r - 1))
        sb.append("\u{1b}[2K")
        sb.append(colorize("> ", C_PROMPT) + String(this.input))
        sb.append(csiMove(runeWidthSum(this.input.toArray()) + 2, r - 1))
        this.out.write(sb.toString().toArray())
        this.out.flush()
    }

    // 消息区 = 会话尾部 + （回合进行中时）活动块。活动块跟着尾部滚动，
    // 回合结束即消失：那时会话区已经有 tool→/tool← 的完整记录。
    func messageLines(c: Int64): ArrayList<String> {
        let lines = conversationLines(this.messages, c)
        if (this.busy.load()) {
            for (line in this.activity.snapshotLines(MonoTime.now(), c)) {
                lines.add(line)
            }
        }
        // 提问面板接在会话末尾：审批要看上下文、选择要看候选，两者都得在同一屏里
        match (this.pendingAskSnapshot()) {
            case Some(p) =>
                for (line in p.panelLines(c)) { lines.add(line) }
            case None => ()
        }
        lines
    }

    // ── 按键 ──────────────────────────────────────────────

    private func handleKey(ke: KeyEvent, t: Terminal): Unit {
        // 帮助面板：任意键返回
        if (this.helpMode) {
            this.helpMode = false
            this.status = ""
            this.render(t)
            return
        }
        // 提问是模态：在答完之前，按键一律归它 —— 否则用户会在"选择"里打出半条消息
        if (this.hasPendingAsk()) {
            this.handleAskKey(ke, t)
            return
        }
        // 会话选择模式优先：↑/↓ 选择、Enter 切换、Esc 取消
        match (this.picker) {
            case Some(p) =>
                match (ke.code) {
                    case KeyCode.Up => p.moveUp(); this.render(t)
                    case KeyCode.Down => p.moveDown(); this.render(t)
                    case KeyCode.Enter =>
                        let target = p.selected()
                        this.picker = None
                        if (this.pickerKind == "agent") {
                            this.switchAgent(target)
                        } else {
                            this.switchToSession(target)
                        }
                        this.pickerKind = ""
                        this.render(t)
                    case KeyCode.Esc =>
                        this.picker = None
                        this.pickerKind = ""
                        this.status = ""
                        this.render(t)
                    case _ => ()
                }
                return
            case None => ()
        }
        match (ke.code) {
            case KeyCode.Char(r) =>
                if (ke.modifiers.contains(KeyModifiers.CONTROL)) {
                    if (r == Rune(UInt32(99))) { this.running = false }   // Ctrl+C
                } else {
                    this.input.add(r)
                    this.renderInputOnly(t)
                }
            case KeyCode.Backspace =>
                if (this.input.size > 0) {
                    this.input.remove(this.input.size - 1..this.input.size)
                    this.renderInputOnly(t)
                }
            case KeyCode.Enter =>
                this.submit(t)
            case KeyCode.Up =>
                match (this.hist.up(String(this.input))) {
                    case Some(text) => this.input = toRunes(text); this.renderInputOnly(t)
                    case None => ()
                }
            case KeyCode.Down =>
                match (this.hist.down()) {
                    case Some(text) => this.input = toRunes(text); this.renderInputOnly(t)
                    case None => ()
                }
            case KeyCode.PageUp => this.scroll = this.scroll + 1; this.render(t)
            case KeyCode.PageDown =>
                if (this.scroll > 0) { this.scroll = this.scroll - 1 }
                this.render(t)
            case KeyCode.Esc => this.running = false
            case _ => ()
        }
    }

    func submit(t: Terminal): Unit {
        let line = String(this.input)
        this.input = ArrayList<Rune>()
        if (line == "") { return }
        this.hist.push(line)
        if (line.startsWith("/")) {
            this.runCommand(line)
            this.render(t)
            return
        }
        if (this.busy.load()) {
            // 回合仍在进行：并发提交会让两个回合写同一份历史
            this.status = "上一轮仍在进行中（等它结束，或 Ctrl+C 退出）"
            this.render(t)
            return
        }

        this.messages.add(UserMessage(ContentList.ofText(line), 0))
        this.status = "生成中…"
        this.busy.store(true)
        this.render(t)
        let oldMsgs = this.messages
        let sessionId = this.sessionId
        // 回合跑在后台线程：主线程必须继续读键盘，否则信任闸门的询问永远等不到回答
        // （readKey 是阻塞读，主线程一旦进入等待循环就再也不处理输入）
        spawn { this.runTurn(t, sessionId, oldMsgs) }
    }

    /** 后台回合：等待流收敛、收尾、落库、重绘。 */
    private func runTurn(t: Terminal, sessionId: String, oldMsgs: ArrayList<Message>): Unit {
        try {
            let runtime = this.makeRuntime(t)
            let stream = runtime.chatWithSessionId(sessionId, oldMsgs, SessionEnvironment())
            var waited: Int64 = 0
            var lastPaint = MonoTime.now()
            var done = false
            while (!done) {
                match (stream.receive(500 * Duration.millisecond)) {
                    case Some(e) =>
                        // 事件流是唯一的实时进度来源：工具开始/结束、PTC 子调用、脚本
                        // println 都在这里。只把它当"有动静"的滴答用，界面上就只剩读秒——
                        // 「工具卡住」与「模型在思考」长得一模一样。
                        this.activity.onEvent(e, MonoTime.now())
                        // 事件可能很密（脚本一次打印很多行）：按 60ms 合帧，避免刷屏
                        if ((MonoTime.now() - lastPaint).toMilliseconds() >= 60) {
                            lastPaint = MonoTime.now()
                            this.render(t)
                        }
                    case None =>
                        if (stream.isClosed()) {
                            done = true
                        } else {
                            waited = waited + 1
                            // 有待回答的询问时不要用读秒覆盖它——那正是用户此刻唯一要看的信息
                            if (!this.hasPendingAsk()) {
                                this.status = "生成中… (" + Int64(waited / 2).toString() + "s)"
                            }
                            this.render(t)
                        }
                }
            }
            // 收尾即清空活动块：随后这一次重绘要给的是完整会话
            this.activity.clear()
            let allMsgs = try {
                stream.result()
            } catch (e: Exception) {
                this.status = "Error: " + e.message
                this.render(t)
                return
            }
            // 分层：运行时会把系统提示（UserMessage）注入工作列表头部——显示与落库都不该
            // 包含它。会话 = 旧消息 + 本轮新增（复用存储层 extractNewMessages 语义）。
            let turnNew = extractNewMessages(oldMsgs, allMsgs)
            this.messages = ArrayList<Message>()
            for (m in oldMsgs) { this.messages.add(m) }
            for (m in turnNew) { this.messages.add(m) }
            this.persistTurn(oldMsgs)
            // 子 Agent 状态回报
            let pending = this.subMgr.pollChildren(sessionId)
            if (pending.size > 0) {
                let sb = StringBuilder()
                for (i in 0..pending.size) {
                    if (i > 0) { sb.append("  ") }
                    let m = pending[Int64(i)]
                    sb.append("[subagent:${m.from}] ${m.kind}: ${m.text}")
                }
                this.status = sb.toString()
            } else {
                let subCount = this.subMgr.activeCountFor(sessionId)
                if (subCount > 0) {
                    this.status = "[subagent] " + subCount.toString() + " 个子 Agent 运行中 —— /subagent list 查看"
                } else {
                    this.status = ""
                }
            }
            this.render(t)
        } finally {
            this.busy.store(false)
        }
    }

    private func makeRuntime(t: Terminal): AgentRuntime {
        let model = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        // 模型切换走配置派生：手工重建会漏带末尾可选参数（上下文窗口等），丢了不报错
        let cfg = this.agentConfig.withModel(model)
        // 提问全部走结构化通道：信任闸门审批、ask_user 的问答都在这里收按键
        let runSpec = this.spec.withAsk({ req: UserRequest => this.askHost(t, req) })
        AgentRuntime(runSpec, cfg)
    }

    /**
     * 提问（信任闸门 / ask_user / 将来的任何提问）。
     *
     * 本方法跑在 agent 回合的线程上：只登记提问、重绘一次让面板与状态行可见，然后等待——
     * 答案由主线程在输入行里收（见 handleAskKey）。收敛规则在 ask.cj，那里可单测。
     *
     * 包内可见：这条路径跨两个线程（回合线程登记并等待、主线程收按键），只能在 TUI 里
     * 跑到，测试要能直接驱动它（见 tui_test.cj）。
     */
    func askHost(t: Terminal, req: UserRequest): UserAnswer {
        let prompt = AskPrompt(req)
        synchronized(this.askLock) {
            this.pendingAsk = Some(prompt)
        }
        this.status = prompt.statusText()
        this.render(t)
        // 初始化即定论（客户端工具、无候选项）时不必等按键：等下去没人会按
        let answer = if (prompt.done()) {
            match (prompt.answer()) {
                case Some(a) => a
                case None => UserAnswer(req.id, UserAnswerStatus.Cancelled)
            }
        } else {
            prompt.waitAnswer()
        }
        synchronized(this.askLock) {
            this.pendingAsk = None
        }
        this.status = ""
        this.render(t)
        answer
    }

    /** 提问模态：方向键移动、空格多选、回车提交、Esc 取消、Ctrl+C 退出。包内可见供测试喂按键。 */
    func handleAskKey(ke: KeyEvent, t: Terminal): Unit {
        let p = match (this.pendingAskSnapshot()) {
            case Some(x) => x
            case None => return
        }
        match (ke.code) {
            case KeyCode.Up => p.moveUp(); this.render(t)
            case KeyCode.Down => p.moveDown(); this.render(t)
            case KeyCode.Char(r) =>
                if (ke.modifiers.contains(KeyModifiers.CONTROL)) {
                    if (r == Rune(UInt32(99))) { this.running = false }
                } else if (r == Rune(UInt32(32)) && p.allowsToggle()) {
                    p.toggle()
                    this.render(t)
                } else {
                    this.input.add(r)
                    this.renderInputOnly(t)
                }
            case KeyCode.Backspace =>
                if (this.input.size > 0) {
                    this.input.remove(this.input.size - 1..this.input.size)
                    this.renderInputOnly(t)
                }
            case KeyCode.Enter =>
                let text = String(this.input)
                this.input = ArrayList<Rune>()
                let accepted = p.submit(text)
                if (p.done()) {
                    this.finishAsk(t, p)
                } else {
                    // 被打回时把原文放回输入行：用户改一个字符就能重来，不必整段重打
                    if (!accepted && text != "") { this.input = toRunes(text) }
                    this.status = p.statusText()
                    this.render(t)
                }
            case KeyCode.Esc =>
                p.cancel()
                this.finishAsk(t, p)
            case _ => ()
        }
    }

    /** 交出答复并唤醒回合线程：先登记答复再撤下面板，面板消失时回合已经能继续。 */
    private func finishAsk(t: Terminal, p: AskPrompt): Unit {
        match (p.answer()) {
            case Some(a) => p.deliver(a)
            case None => ()
        }
        synchronized(this.askLock) {
            this.pendingAsk = None
        }
        this.status = ""
        this.render(t)
    }

    /** 是否正有提问待答（包内可见：测试要等它出现/消失来定位时序）。 */
    func hasPendingAsk(): Bool {
        synchronized(this.askLock) {
            this.pendingAsk.isSome()
        }
    }

    private func pendingAskSnapshot(): ?AskPrompt {
        synchronized(this.askLock) {
            this.pendingAsk
        }
    }

    // 单落库：appendBranch，末 entry 作父叶（差集由 extractNewMessages 给出）
    private func persistTurn(oldMsgs: ArrayList<Message>): Unit {
        let newMsgs = extractNewMessages(oldMsgs, this.messages)
        if (newMsgs.size == 0) { return }
        let lastLeaf: Option<String> = try {
            let data = this.spec.store.loadEntries(this.sessionId)
            if (data.entries.size > 0) { Some(data.entries[data.entries.size - 1].id) } else { None }
        } catch (e: Exception) {
            None
        }
        match (lastLeaf) {
            case Some(leaf) =>
                try { this.spec.store.appendBranch(this.sessionId, leaf, newMsgs) } catch (e: Exception) {
                    this.status = "会话落盘失败: " + e.message
                }
            case None =>
                try {
                    let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
                    this.spec.store.save(this.sessionId, header, this.messages)
                } catch (e: Exception) {
                    this.status = "会话落盘失败: " + e.message
                }
        }
    }

    private func handleModelsCommand(): Unit {
        let models = uniqueModels(this.spec.agents.list())
        if (models.size == 0) {
            this.status = "没有配置模型"
            return
        }
        let sb = StringBuilder()
        sb.append("Models: ")
        for (i in 0..models.size) {
            if (i > 0) { sb.append(", ") }
            sb.append(models[Int64(i)])
        }
        let current = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        sb.append("（当前: " + current + "）")
        this.status = sb.toString()
    }

    private func handleAgentCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size > 1) {
            this.switchAgent(parts[1])
            return
        }
        // 无参：交互选择
        let agents = this.spec.agents.list()
        if (agents.size <= 1) {
            this.status = "Agent: " + this.agentName + "（只有一个 agent 可切换）"
            return
        }
        let names = ArrayList<String>()
        for ((n, _) in agents) { names.add(n) }
        this.picker = Some(SessionPicker(names))
        this.pickerKind = "agent"
        this.status = "↑/↓ 选择 Agent · Enter 切换 · Esc 取消"
    }

    // 切换 Agent：换配置 + 重解析 provider + 开新会话（新上下文）
    private func switchAgent(name: String): Unit {
        match (this.spec.agents.get(name)) {
            case Some(cfg) =>
                this.agentName = name
                this.agentConfig = cfg
                this.provider = this.spec.resolveProvider(cfg)
                this.sessionId = "sess_" + nextId()
                this.messages = ArrayList<Message>()
                this.scroll = 0
                this.status = "Switched to agent: " + name + "（新会话 " + this.sessionId + "）"
            case None =>
                this.status = "Agent not found: " + name
        }
    }

    private func switchToSession(targetId: String): Unit {
        this.persistTurn(this.messages)
        this.messages = try { this.spec.store.load(targetId) } catch (e: Exception) {
            this.status = "[atelier] session load failed (sessionId=" + targetId + "): " + e.message
            ArrayList<Message>()
        }
        if (this.messages.size == 0) {
            this.status = "Session not found: " + targetId
            return
        }
        this.sessionId = targetId
        this.scroll = 0
        this.status = "Switched to session: " + targetId + "  Messages: " + this.messages.size.toString()
    }

    // ═══ 斜杠命令（输出统一进状态行）═══

    func runCommand(line: String): Unit {
        if (line == "/models") { this.handleModelsCommand(); return }
        // /new 别名：新建会话
        if (line == "/new") {
            this.handleSessionCommand("/session new")
            return
        }
        if (line == "/help" || line == "help") {
            this.helpMode = true
            this.status = "任意键返回对话"
            return
        }
        if (line.startsWith("/agent")) { this.handleAgentCommand(line); return }
        if (line.startsWith("/session")) { this.handleSessionCommand(line); return }
        if (line == "/tools") { this.handleToolsCommand(); return }
        if (line == "/compact") { this.handleCompactCommand(); return }
        if (line.startsWith("/model")) { this.handleModelCommand(line); return }
        if (line.startsWith("/subagent")) { this.handleSubagentCommand(line); return }
        match (this.registry.dispatch(line)) {
            case Some("exit") => this.running = false
            case Some(msg) => this.status = msg
            case None => ()
        }
    }

    /**
     * `/compact`：手动压缩当前会话（绕过阈值，仍守保留策略与不变量）。
     *
     * 历史被改写，落库必须**整份 save**而不是 appendBranch —— 追加式会把检查点与旧头部
     * 叠在一起（同一段历史在会话里出现两次）。压缩失败/压无可压时历史与落库都不动。
     */
    private func handleCompactCommand(): Unit {
        if (this.busy.load()) {
            this.status = "上一轮仍在进行中（等它结束再压缩）"
            return
        }
        if (this.messages.size == 0) {
            this.status = "当前会话没有可压缩的消息"
            return
        }
        let model = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        // 不挂提问通道：压缩不向用户提问
        let runtime = AgentRuntime(this.spec, this.agentConfig.withModel(model))
        let report = runtime.compactNow(this.sessionId, this.messages, SessionEnvironment())
        if (!report.compacted) {
            let why = if (report.reason == "") { "无可压缩的头部" } else { report.reason }
            this.status = "未压缩：" + why
            return
        }
        this.messages = report.messages
        this.scroll = 0
        let header = try {
            this.spec.store.loadEntries(this.sessionId).header
        } catch (e: Exception) {
            SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
        }
        try {
            this.spec.store.save(this.sessionId, header, this.messages)
        } catch (e: Exception) {
            this.status = "已压缩但会话落盘失败: " + e.message
            return
        }
        this.status = "已压缩：" + report.messagesBefore.toString() + " → " +
            report.messagesAfter.toString() + " 条，" + report.tokensBefore.toString() + " → " +
            report.tokensAfter.toString() + " tokens"
    }

    private func handleSessionCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size == 1) {
            this.status = "Session: " + this.sessionId + "  Messages: " + this.messages.size.toString()
            return
        }
        let cmd = parts[1]
        if (cmd == "new") {
            // 当前会话消息已逐轮落库；此处不重复（extractNewMessages 为空）
            this.persistTurn(this.messages)
            this.sessionId = "sess_" + nextId()
            this.messages = ArrayList<Message>()
            this.scroll = 0
            this.status = "New session: " + this.sessionId
        } else if (cmd == "list") {
            let sessions = try { this.spec.store.list() } catch (e: Exception) {
                this.status = "[atelier] session list failed: " + e.message
                ArrayList<SessionHeader>()
            }
            if (sessions.size == 0) {
                this.status = "No saved sessions"
            } else {
                // 交互式选择：消息区列会话，↑/↓ 选择、Enter 切换、Esc 取消
                let ids = ArrayList<String>()
                for (i in 0..sessions.size) { ids.add(sessions[Int64(i)].id) }
                this.picker = Some(SessionPicker(ids))
                this.pickerKind = "session"
                this.status = "↑/↓ 选择 · Enter 切换 · Esc 取消"
            }
        } else if (cmd == "switch" && parts.size > 2) {
            this.switchToSession(parts[2])
        } else if (cmd == "export" && parts.size > 2) {
            let targetId = parts[2]
            let fmt = if (parts.size > 3) { parts[3] } else { "jsonl" }
            let msgs = try { this.spec.store.load(targetId) } catch (e: Exception) {
                this.status = "Session not found: " + targetId
                ArrayList<Message>()
            }
            if (msgs.size == 0) {
                this.status = "Session not found: " + targetId
                return
            }
            if (fmt == "jsonl") {
                let text = exportToJsonl(msgs)
                try {
                    let path = this.sessionId + "_" + targetId + ".jsonl"
                    File.writeTo(Path(path), text.toArray())
                    this.status = "Exported to: " + path
                } catch (e: Exception) {
                    this.status = "Export failed: " + e.message
                }
            } else if (fmt == "html") {
                let text = exportToHtml(msgs)
                try {
                    let path = this.sessionId + "_" + targetId + ".html"
                    File.writeTo(Path(path), text.toArray())
                    this.status = "Exported to: " + path
                } catch (e: Exception) {
                    this.status = "Export failed: " + e.message
                }
            } else {
                this.status = "Unknown format: " + fmt + " (use jsonl or html)"
            }
        } else {
            this.status = "/session [new|list|switch <id>|export <id> <jsonl|html>]"
        }
    }

    private func handleToolsCommand(): Unit {
        let tools = this.agentConfig.tools
        if (tools.size == 0) {
            this.status = "No tools configured for agent: " + this.agentName
        } else {
            let sb = StringBuilder()
            sb.append("Tools (" + tools.size.toString() + "): ")
            for (i in 0..tools.size) {
                if (i > 0) { sb.append("  ") }
                sb.append(tools[Int64(i)])
            }
            this.status = sb.toString()
        }
    }

    private func handleModelCommand(line: String): Unit {
        let parts = line.split(" ")
        let currentModel = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        if (parts.size == 1) {
            this.status = "Current model: " + currentModel + "  （/model <name> 切换）"
        } else {
            this.modelOverride = parts[1]
            this.status = "Model switched to: " + parts[1]
        }
    }

    private func handleSubagentCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size < 2) {
            this.status = "Usage: /subagent list | poll | start [--remote] <agent> <prompt> | send <id> <text> | respond <id> <text> | close <id>"
            return
        }
        let sub = parts[1]
        if (sub == "list" || sub == "status") {
            let list = this.subMgr.listForParent(this.sessionId)
            if (list.size == 0) {
                this.status = "没有子 Agent（回合内可用 subagent_start 工具启动；远程子经 /subagent start --remote）"
                return
            }
            let sb = StringBuilder()
            for (i in 0..list.size) {
                let h = list[Int64(i)]
                if (i > 0) { sb.append("  ") }
                let st = match (h.state()) {
                    case SubagentState.Idle => "idle"
                    case SubagentState.Running => "running"
                    case SubagentState.Closed => "closed"
                }
                sb.append(h.subSessionId + "  " + st)
            }
            this.status = sb.toString()
            return
        }
        if (sub == "poll") {
            let got = this.subMgr.pollChildren(this.sessionId)
            if (got.size == 0) {
                this.status = "没有未读子消息"
                return
            }
            let sb = StringBuilder()
            for (i in 0..got.size) {
                let m = got[Int64(i)]
                if (i > 0) { sb.append("  ") }
                sb.append("[" + m.from + "] " + m.kind.toString() + ": " + m.text)
            }
            this.status = sb.toString()
            return
        }
        if (sub == "start") {
            let (remote, agent, promptText) = parseSubStartArgs(parts)
            if (agent == "") {
                this.status = "Usage: /subagent start [--remote] <agent> <prompt>"
                return
            }
            if (remote) {
                this.startRemoteByName(agent, promptText)
            } else {
                match (this.subMgr.startByName(agent, this.sessionId, promptText)) {
                    case Some(h) => this.status = "已启动子 Agent：" + h.subSessionId
                    case None => this.status = "子 agent '" + agent + "' 未注册或 provider 不可用"
                }
            }
            return
        }
        if (parts.size < 3) {
            this.status = "Usage: /subagent send <id> <text> | respond <id> <text> | close <id>"
            return
        }
        let target = parts[2]
        match (sub) {
            case "close" =>
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.close()
                        this.status = "已请求关闭 " + target
                    case None => this.status = "未知子 Agent id：" + target
                }
            case "send" =>
                if (parts.size < 4) { this.status = "Usage: /subagent send <id> <text>"; return }
                let text = joinWords(parts, 3)
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.send(AgentMail(this.sessionId, h.subSessionId, AgentMailKindUserText, text))
                        this.status = "已向 " + target + " 投递消息"
                    case None => this.status = "未知子 Agent id：" + target
                }
            case "respond" =>
                if (parts.size < 4) { this.status = "Usage: /subagent respond <id> <text>"; return }
                let text = joinWords(parts, 3)
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.respond(text)
                        this.status = "已回复 " + target
                    case None => this.status = "未知子 Agent id：" + target
                }
            case _ => this.status = "未知子命令：" + sub
        }
    }

    // /subagent start --remote：独立 `cli.app acp` 进程承载（数据隔离于 <sessionDir>/remote-sub/<childId>）
    private func startRemoteByName(agentName: String, prompt: String): Unit {
        let exe = currentExePath()
        let cwd = try { getWorkingDirectory().toString() } catch (_) { "." }
        let childDir = this.sessionDir + "/remote-sub/" + nextId()
        try { Directory.create(Path(childDir), recursive: true) } catch (e: Exception) {
            this.status = "[atelier] remote sub agent dir create failed (" + childDir + "): " + e.message
        }
        match (this.subMgr.startRemote(exe, agentName, this.sessionId, prompt, cwd, childDir)) {
            case Some(h) => this.status = "已启动远程子 Agent：" + h.subSessionId + "（进程 " + exe + "）"
            case None => this.status = "远程子启动失败：agent '" + agentName + "' 未注册或进程不可用"
        }
    }
}
