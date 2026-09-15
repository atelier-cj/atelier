package cli

import ystyle::xisp.terminal.*
import cjterm_stream.*
import opencj::ulid.nextId
import std.core.Duration
import std.env.*
import std.collection.*
import std.fs.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*

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

// ═══════ 聊天 TUI ══════════════════════════════════════════

// raw mode + ANSI。输入侧复用 xisp 的 terminal（POSIX 已实测；Windows 实现存在但未验证）；
// 输出侧走 cjterm_stream（整帧缓冲一次写，避免逐行 print 在真终端/慢控制台上的卡顿）。
// v1 约束：readKey 无超时 + chat 阻塞 → 生成期间界面冻结（显示状态行），流式渲染留待后续。
public class ChatTui {
    private let agentName: String
    private let registry: SlashCommandRegistry
    private let agentConfig: AgentConfig
    private let provider: Provider
    private let toolRegistry: ToolRegistry
    private let sessionStore: SessionStore
    private let trustManager: TrustManager
    private let skillRegistry: SkillRegistry
    private let agentRegistry: AgentRegistry
    private let providerRegistry: ProviderRegistry
    private let mcpManager: McpManager
    private let sessionDir: String
    private var sessionId: String
    private var messages: ArrayList<Message>
    private var input: ArrayList<Rune>
    private var scroll: Int64
    private var status: String
    private var running: Bool
    private var out: AutoStream

    public init(agentName: String, registry: SlashCommandRegistry, agentConfig: AgentConfig,
        provider: Provider, toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry, agentRegistry: AgentRegistry,
        providerRegistry: ProviderRegistry, resumeSessionId: String, mcpManager: McpManager,
        sessionDir: String) {
        this.agentName = agentName
        this.registry = registry
        this.agentConfig = agentConfig
        this.provider = provider
        this.toolRegistry = toolRegistry
        this.sessionStore = sessionStore
        this.trustManager = trustManager
        this.skillRegistry = skillRegistry
        this.agentRegistry = agentRegistry
        this.providerRegistry = providerRegistry
        this.mcpManager = mcpManager
        this.sessionDir = sessionDir
        this.input = ArrayList<Rune>()
        this.scroll = 0
        this.status = ""
        this.running = true
        this.out = AutoStream.stdout()
        if (resumeSessionId != "") {
            this.sessionId = resumeSessionId
            this.messages = try {
                this.sessionStore.load(resumeSessionId)
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
        sb.append("Atelier TUI — Agent: " + this.agentName + "  Session: " + this.sessionId + "   /help")
        let lines = this.messageLines(c)
        let msgRows = r - 3
        let start = if (lines.size > msgRows) { lines.size - msgRows - this.scroll } else { 0 }
        for (i in 0..msgRows) {
            sb.append(csiMove(0, i + 1))
            sb.append("\u{1b}[2K")
            let idx = start + i
            if (idx >= 0 && idx < lines.size) { sb.append(lines[Int64(idx)]) }
        }
        sb.append(csiMove(0, r - 2))
        sb.append("\u{1b}[2K")
        sb.append(this.status)
        sb.append(csiMove(0, r - 1))
        sb.append("\u{1b}[2K")
        sb.append("> " + String(this.input))
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
        sb.append("> " + String(this.input))
        sb.append(csiMove(runeWidthSum(this.input.toArray()) + 2, r - 1))
        this.out.write(sb.toString().toArray())
        this.out.flush()
    }

    private func messageLines(c: Int64): ArrayList<String> {
        let out = ArrayList<String>()
        for (m in this.messages) {
            let lines = wrapText(chatLinePrefix(m.role()) + messageText(m), c)
            for (l in lines) { out.add(l) }
        }
        out
    }

    // ── 按键 ──────────────────────────────────────────────

    private func handleKey(ke: KeyEvent, t: Terminal): Unit {
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
            case KeyCode.Enter => this.submit(t)
            case KeyCode.Up => this.scroll = this.scroll + 1; this.render(t)
            case KeyCode.Down =>
                if (this.scroll > 0) { this.scroll = this.scroll - 1 }
                this.render(t)
            case KeyCode.Esc => this.running = false
            case _ => ()
        }
    }

    private func submit(t: Terminal): Unit {
        let line = String(this.input)
        this.input = ArrayList<Rune>()
        if (line == "") { return }
        if (line.startsWith("/")) {
            this.runCommand(line)
            this.render(t)
            return
        }

        this.messages.add(UserMessage(ContentList.ofText(line), 0))
        this.status = "生成中…"
        this.render(t)
        let runtime = this.makeRuntime(t)
        let stream = runtime.chatWithSessionId(this.sessionId, this.messages, SessionEnvironment())
        // 带超时轮询：每 500ms 显示一次生成秒数（"生成中… (Ns)"），避免阻塞无反馈
        // 像"回车没效果"；收尾哨兵（isClosed）收敛循环，也为后续流式渲染留位。
        var waited: Int64 = 0
        var done = false
        while (!done) {
            match (stream.receive(500 * Duration.millisecond)) {
                case Some(_) => ()
                case None =>
                    if (stream.isClosed()) {
                        done = true
                    } else {
                        waited = waited + 1
                        this.status = "生成中… (" + Int64(waited / 2).toString() + "s)"
                        this.render(t)
                    }
            }
        }
        let allMsgs = try {
            stream.result()
        } catch (e: Exception) {
            this.status = "Error: " + e.message
            this.render(t)
            return
        }
        let oldMsgs = this.messages
        this.messages = allMsgs
        this.persistTurn(oldMsgs)
        this.status = ""
        this.render(t)
    }

    private func makeRuntime(t: Terminal): AgentRuntime {
        let cfg = AgentConfig(
            this.agentConfig.name, this.agentConfig.description,
            this.agentConfig.systemPrompt, this.agentConfig.userPromptTemplate,
            this.agentConfig.model, this.agentConfig.provider,
            this.agentConfig.tools, this.agentConfig.skills,
            this.agentConfig.mcpCooldownTurns,
            this.agentConfig.maxTurns, this.agentConfig.temperature,
            this.agentConfig.maxOutputTokens, this.agentConfig.thinkingLevel,
            this.agentConfig.compactionEnabled,
            this.agentConfig.compactionReserveTokens,
            this.agentConfig.keepRecentTokens,
            None,
            this.agentConfig.maxToolCalls,
            this.agentConfig.toolTimeout,
            this.agentConfig.minToolInterval,
            this.agentConfig.tags, this.agentConfig.createdBy,
            this.agentConfig.createdAt, this.agentConfig.updatedAt)
        AgentRuntime(cfg, this.provider, this.toolRegistry, this.sessionStore,
            this.trustManager, this.skillRegistry, this.agentRegistry, this.providerRegistry,
            ArrayList<Hook>(), { q =>
                // 信任闸门提问：退 raw、显示问题、读一行、恢复 raw（在运行时子线程内执行）
                this.writeRaw("\u{1b}[?25h")
                this.writeRaw(csiMove(0, 0))
                this.writeRaw("\u{1b}[2K")
                this.writeRaw("[Ask User] " + q)
                this.status = "等待确认: " + q
                this.render(t)
                t.disableRawMode()
                let answer = readLine()
                t.enableRawMode()
                this.writeRaw("\u{1b}[?25l")
                answer
            }, this.mcpManager)
    }

    // 单落库：与 REPL 的 persistCurrentSession 同语义（appendBranch，末 entry 作父叶）
    private func persistTurn(oldMsgs: ArrayList<Message>): Unit {
        let newMsgs = extractNewMessages(oldMsgs, this.messages)
        if (newMsgs.size == 0) { return }
        let lastLeaf: Option<String> = try {
            let data = this.sessionStore.loadEntries(this.sessionId)
            if (data.entries.size > 0) { Some(data.entries[data.entries.size - 1].id) } else { None }
        } catch (e: Exception) {
            None
        }
        match (lastLeaf) {
            case Some(leaf) =>
                try { this.sessionStore.appendBranch(this.sessionId, leaf, newMsgs) } catch (e: Exception) {
                    this.status = "会话落盘失败: " + e.message
                }
            case None =>
                try {
                    let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
                    this.sessionStore.save(this.sessionId, header, this.messages)
                } catch (e: Exception) {
                    this.status = "会话落盘失败: " + e.message
                }
        }
    }

    private func runCommand(line: String): Unit {
        if (line == "/clear") {
            this.messages = ArrayList<Message>()
            this.scroll = 0
            this.status = ""
        } else if (line == "/exit") {
            this.running = false
        } else if (line == "/help") {
            this.status = "/clear 清屏 · /exit 退出 · 方向键上下滚动 · Ctrl+C 退出；resume 会话用 cli.app repl <agent> <sid>"
        } else if (line.startsWith("/session")) {
            this.status = "TUI v1 只服务当前会话；切换会话请退出后用 cli.app repl <agent> <sid>"
        } else {
            this.status = "未知命令: " + line + "（/help 查看）"
        }
    }
}
