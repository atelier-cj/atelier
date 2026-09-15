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
import atelier.session.exportToJsonl
import atelier.session.exportToHtml
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
                let lines = wrapText(content, width - 5)
                for (i in 0..lines.size) {
                    if (i == 0) { out.add(colorize("you: ", C_USER) + lines[Int64(i)]) }
                    else { out.add("     " + lines[Int64(i)]) }
                }
            }
        case am: AssistantMessage =>
            let content = contentText(am.content)
            if (content != "") {
                let lines = wrapText(content, width - 5)
                for (i in 0..lines.size) {
                    if (i == 0) { out.add(colorize("ai:  ", C_AI) + lines[Int64(i)]) }
                    else { out.add("     " + lines[Int64(i)]) }
                }
            }
        case tr: ToolResultMessage =>
            out.add(colorize(toolLineText(tr, width), C_TOOL))
        case _ => ()
    }
    out
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
    private var modelOverride: String
    private let subMgr: SubAgentManager
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
        this.modelOverride = ""
        this.out = AutoStream.stdout()
        // 可持续子 Agent：回合内工具 + /subagent 命令（与 REPL 同装配）
        this.subMgr = SubAgentManager(toolRegistry, trustManager, skillRegistry,
            agentRegistry, providerRegistry, sessionStore, mcpManager)
        registerParentSubagentTools(toolRegistry, this.subMgr)
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
            let lines = decorateMessageLines(m, c)
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
        // 分层：运行时会把系统提示（UserMessage）注入工作列表头部——显示与落库都不该
        // 包含它。会话 = 旧消息 + 本轮新增（复用存储层 extractNewMessages 语义）。
        let oldMsgs = this.messages
        let turnNew = extractNewMessages(oldMsgs, allMsgs)
        this.messages = ArrayList<Message>()
        for (m in oldMsgs) { this.messages.add(m) }
        for (m in turnNew) { this.messages.add(m) }
        this.persistTurn(oldMsgs)
        // 子 Agent 状态回报（与 REPL 同语义）
        let pending = this.subMgr.pollChildren(this.sessionId)
        if (pending.size > 0) {
            let sb = StringBuilder()
            for (i in 0..pending.size) {
                if (i > 0) { sb.append("  ") }
                let m = pending[Int64(i)]
                sb.append("[subagent:${m.from}] ${m.kind}: ${m.text}")
            }
            this.status = sb.toString()
        } else {
            let subCount = this.subMgr.activeCountFor(this.sessionId)
            if (subCount > 0) {
                this.status = "[subagent] " + subCount.toString() + " 个子 Agent 运行中 —— /subagent list 查看"
            } else {
                this.status = ""
            }
        }
        this.render(t)
    }

    private func makeRuntime(t: Terminal): AgentRuntime {
        let model = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        let cfg = AgentConfig(
            this.agentConfig.name, this.agentConfig.description,
            this.agentConfig.systemPrompt, this.agentConfig.userPromptTemplate,
            model, this.agentConfig.provider,
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

    // ═══ 斜杠命令（与 REPL 同命令面；输出统一进状态行）═══

    private func runCommand(line: String): Unit {
        if (line.startsWith("/session")) { this.handleSessionCommand(line); return }
        if (line == "/tools") { this.handleToolsCommand(); return }
        if (line.startsWith("/model")) { this.handleModelCommand(line); return }
        if (line.startsWith("/subagent")) { this.handleSubagentCommand(line); return }
        match (this.registry.dispatch(line)) {
            case Some("exit") => this.running = false
            case Some(msg) => this.status = msg
            case None => ()
        }
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
            let sessions = try { this.sessionStore.list() } catch (e: Exception) {
                this.status = "[atelier] session list failed: " + e.message
                ArrayList<SessionHeader>()
            }
            if (sessions.size == 0) {
                this.status = "No saved sessions"
            } else {
                let sb = StringBuilder()
                sb.append("Saved sessions (" + sessions.size.toString() + "): ")
                for (i in 0..sessions.size) {
                    let s = sessions[Int64(i)]
                    if (i > 0) { sb.append("  ") }
                    sb.append(s.id + (if (s.id == this.sessionId) { " (current)" } else { "" }))
                }
                this.status = sb.toString()
            }
        } else if (cmd == "switch" && parts.size > 2) {
            let targetId = parts[2]
            this.persistTurn(this.messages)
            this.messages = try { this.sessionStore.load(targetId) } catch (e: Exception) {
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
        } else if (cmd == "export" && parts.size > 2) {
            let targetId = parts[2]
            let fmt = if (parts.size > 3) { parts[3] } else { "jsonl" }
            let msgs = try { this.sessionStore.load(targetId) } catch (e: Exception) {
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
