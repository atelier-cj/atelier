package atelier.cli

import std.env.*
import std.collection.*
import std.fs.{File, Path}
import stdx.log.*
import atelier.agent.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.tool.builtin.*
import atelier.session.*
import atelier.session.exportToJsonl
import atelier.session.exportToHtml
import atelier.trust.*
import atelier.skill.*
import opencj::ulid.nextId

public class REPL {
    private let MaxLoadMessages: Int64 = 15
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
    private var running: Bool = true
    private var sessionId: String
    private var messages: ArrayList<Message>
    private var sessionCounter: Int64
    private var modelOverride: String
    private let subMgr: SubAgentManager

    public init(agentName: String, registry: SlashCommandRegistry,
        agentConfig: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        resumeSessionId: String, mcpManager: McpManager) {
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
        this.sessionCounter = 1
        this.modelOverride = ""
        // 可持续子 Agent：REPL 会话内的父端调度（回合内工具 + /subagent 命令）
        this.subMgr = SubAgentManager(toolRegistry, trustManager, skillRegistry,
            agentRegistry, providerRegistry, sessionStore, mcpManager)
        registerParentSubagentTools(toolRegistry, this.subMgr)
        if (resumeSessionId != "") {
            this.sessionId = resumeSessionId
            this.messages = try {
                let loaded = this.sessionStore.load(resumeSessionId)
                truncateRecent(loaded, MaxLoadMessages)
            } catch (_) { ArrayList<Message>() }
        } else {
            this.sessionId = "sess_" + nextId()
            this.messages = ArrayList<Message>()
        }
    }

    private func loadSessionMessages(id: String): ArrayList<Message> {
        let msgs = try { this.sessionStore.load(id) } catch (_) { return ArrayList<Message>() }
        truncateRecent(msgs, MaxLoadMessages)
    }

    private func makeRuntime(): AgentRuntime {
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
                println("\n[Ask User] " + q)
                print("> ")
                readLine()
            }, this.mcpManager)
    }

    public func run(): Unit {
        println("Atelier REPL — Agent: " + this.agentName)
        println("Session: " + this.sessionId)
        println("Type /help for available commands")
        while (this.running) {
            print("> ")
            let line = getLine()
            if (line == "") { continue }
            handleInput(line)
        }
        // Session persists across restarts
    }

    private func getLine(): String {
        try {
            let input = getStdIn()
            let buf = Array<Byte>(1, repeat: 0)
            let chars = ArrayList<Byte>()
            while (true) {
                let n = input.read(buf)
                if (n <= 0) { break }
                if (buf[0] == 10) { break }
                chars.add(buf[0])
            }
            let raw = Array<Byte>(chars.size, repeat: 0)
            for (i in 0..chars.size) { raw[i] = chars[i] }
            String.fromUtf8(raw)
        } catch (_) { "" }
    }

    private func handleInput(line: String): Unit {
        if (line.startsWith("/")) {
            if (line.startsWith("/session")) {
                handleSessionCommand(line)
                return
            }
            if (line == "/tools") {
                handleToolsCommand()
                return
            }
            if (line.startsWith("/model")) {
                handleModelCommand(line)
                return
            }
            if (line.startsWith("/subagent")) {
                handleSubagentCommand(line)
                return
            }
            match (this.registry.dispatch(line)) {
                case Some("exit") => this.running = false
                case Some(msg) => println(msg)
                case None => ()
            }
            return
        }

        let runtime = this.makeRuntime()
        this.messages.add(UserMessage(ContentList.ofText(line), 0))
        let stream = runtime.chatWithSessionId(this.sessionId, this.messages, SessionEnvironment())

        let allMsgs = try {
            stream.result()
        } catch (e: Exception) {
            println("Error: " + e.message)
            return
        }
        let oldMsgs = this.messages
        this.messages = allMsgs
        // 单落库职责：REPL 统一持久化（runtime 不落库），本轮新消息追加到 store
        this.persistCurrentSession(oldMsgs)

        let lastText = lastAssistantText(allMsgs)
        if (lastText != "") {
            println(lastText)
        }
        let subCount = this.subMgr.activeCountFor(this.sessionId)
        if (subCount > 0) {
            println("  [subagent] ${subCount} 个子 Agent 运行中 —— /subagent list 查看")
        }
    }

    // 单落库职责：每轮 run 后把本轮新消息追加到 store（首轮无会话用 save 创建）。
    // 每次落库前从 store 取末 entry 作 parentLeafId，链自然线性，无双写分叉。
    private func persistCurrentSession(oldMsgs: ArrayList<Message>): Unit {
        let newMsgs = extractNewMessages(oldMsgs, this.messages)
        if (newMsgs.size == 0) { return }
        let lastLeaf: Option<String> = try {
            let data = this.sessionStore.loadEntries(this.sessionId)
            if (data.entries.size > 0) { Some(data.entries[data.entries.size - 1].id) } else { None }
        } catch (_) { None }
        match (lastLeaf) {
            case Some(leaf) =>
                try { this.sessionStore.appendBranch(this.sessionId, leaf, newMsgs) } catch (_) { () }
            case None =>
                try {
                    let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
                    this.sessionStore.save(this.sessionId, header, this.messages)
                } catch (_) { () }
        }
    }

    // /subagent list|status|send <id> <text>|respond <id> <text>|close <id>
    private func handleSubagentCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size < 2) {
            println("Usage: /subagent list | send <id> <text> | respond <id> <text> | close <id>")
            return
        }
        let sub = parts[1]
        if (sub == "list" || sub == "status") {
            let list = this.subMgr.listForParent(this.sessionId)
            if (list.size == 0) {
                println("没有子 Agent（回合内可用 subagent_start 工具启动）")
                return
            }
            for (h in list) {
                let st = match (h.state()) {
                    case SubagentState.Idle => "idle"
                    case SubagentState.Running => "running"
                    case SubagentState.Closed => "closed"
                }
                println("  ${h.subSessionId}  ${st}")
            }
            return
        }
        if (parts.size < 3) {
            println("Usage: /subagent send <id> <text> | respond <id> <text> | close <id>")
            return
        }
        let target = parts[2]
        match (sub) {
            case "close" =>
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.close()
                        println("已请求关闭 ${target}")
                    case None => println("未知子 Agent id：${target}")
                }
            case "send" =>
                if (parts.size < 4) { println("Usage: /subagent send <id> <text>"); return }
                var text = ""
                for (i in 3..parts.size) {
                    if (text != "") { text = text + " " }
                    text = text + parts[Int64(i)]
                }
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.send(AgentMail(this.sessionId, h.subSessionId, AgentMailKindUserText, text))
                        println("已向 ${target} 投递消息")
                    case None => println("未知子 Agent id：${target}")
                }
            case "respond" =>
                if (parts.size < 4) { println("Usage: /subagent respond <id> <text>"); return }
                var text = ""
                for (i in 3..parts.size) {
                    if (text != "") { text = text + " " }
                    text = text + parts[Int64(i)]
                }
                match (this.subMgr.get(target)) {
                    case Some(h) =>
                        h.respond(text)
                        println("已回复 ${target}")
                    case None => println("未知子 Agent id：${target}")
                }
            case _ => println("未知子命令：${sub}")
        }
    }

    private func handleSessionCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size == 1) {
            println("Session: " + this.sessionId + "  Messages: " + this.messages.size.toString())
            return
        }
        let cmd = parts[1]
        if (cmd == "new") {
            // 当前会话消息已由主循环逐轮落库；此处不重复落库（extractNewMessages 为空），
            // 避免 save 覆盖破坏归档链
            this.persistCurrentSession(this.messages)
            this.sessionCounter++
            this.sessionId = "sess_" + this.sessionCounter.toString()
            this.messages = ArrayList<Message>()
            println("New session: " + this.sessionId)
        } else if (cmd == "list") {
            let sessions = try { this.sessionStore.list() } catch (_) { ArrayList<SessionHeader>() }
            if (sessions.size == 0) {
                println("No saved sessions")
            } else {
                println("Saved sessions (" + sessions.size.toString() + "):")
                for (s in sessions) {
                    println("  " + s.id + (if (s.id == this.sessionId) { " (current)" } else { "" }))
                }
            }
        } else if (cmd == "switch" && parts.size > 2) {
            let targetId = parts[2]
            // 当前会话消息已在主循环逐轮落库；此处不重复落库（extractNewMessages 为空），
            // 避免 save 覆盖破坏归档链
            this.persistCurrentSession(this.messages)
            this.messages = this.loadSessionMessages(targetId)
            if (this.messages.size == 0) {
                println("Session not found: " + targetId)
                return
            }
            this.sessionId = targetId
            println("Switched to session: " + targetId + "  Messages: " + this.messages.size.toString())
            // Display conversation history
            for (m in this.messages) {
                match (m) {
                    case um: UserMessage =>
                        let text = textFromContent(um.content)
                        if (text != "") { println("> " + text) }
                    case am: AssistantMessage =>
                        let text = textFromContent(am.content)
                        if (text != "") { println(text + "\n") }
                    case _ => ()
                }
            }
        } else if (cmd == "export" && parts.size > 2) {
            let targetId = parts[2]
            let fmt = if (parts.size > 3) { parts[3] } else { "jsonl" }
            let msgs = this.loadSessionMessages(targetId)
            if (msgs.size == 0) {
                println("Session not found: " + targetId)
                return
            }
            if (fmt == "jsonl") {
                let text = exportToJsonl(msgs)
                try {
                    let path = this.sessionId + "_" + targetId + ".jsonl"
                    File.writeTo(Path(path), text.toArray())
                    println("Exported to: " + path)
                } catch (e: Exception) {
                    println("Export failed: " + e.message)
                }
            } else if (fmt == "html") {
                let text = exportToHtml(msgs)
                try {
                    let path = this.sessionId + "_" + targetId + ".html"
                    File.writeTo(Path(path), text.toArray())
                    println("Exported to: " + path)
                } catch (e: Exception) {
                    println("Export failed: " + e.message)
                }
            } else {
                println("Unknown format: " + fmt + " (use jsonl or html)")
            }
        } else {
            println("Usage: /session          Show current session")
            println("       /session new      Create new session")
            println("       /session list     List all sessions")
            println("       /session switch <id>  Switch to session")
            println("       /session export <id> <jsonl|html>  Export session")
        }
    }

    private func handleToolsCommand(): Unit {
        let tools = this.agentConfig.tools
        if (tools.size == 0) {
            println("No tools configured for agent: " + this.agentName)
        } else {
            println("Tools (" + tools.size.toString() + "):")
            for (t in tools) {
                println("  - " + t)
            }
        }
    }

    private func handleModelCommand(line: String): Unit {
        let parts = line.split(" ")
        let currentModel = if (this.modelOverride != "") { this.modelOverride } else { this.agentConfig.model }
        if (parts.size == 1) {
            println("Current model: " + currentModel)
            println("Usage: /model <name>  to switch model")
        } else {
            this.modelOverride = parts[1]
            println("Model switched to: " + parts[1])
        }
    }
}

func lastAssistantText(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[Int64(i)]) {
            case am: AssistantMessage =>
                return textFromContent(am.content)
            case _ => ()
        }
        i--
    }
    ""
}

// 截断保留最近 max 条；窗口外的 ArchiveMessage（历史归档标记）保留在最前，
// 防绝对序号错位导致 applyArchiveMarks 误跳（resume/switch 场景）
func truncateRecent(messages: ArrayList<Message>, max: Int64): ArrayList<Message> {
    if (messages.size <= max) { return messages }
    let recent = ArrayList<Message>()
    let start = messages.size - max
    for (i in 0..start) {
        match (messages[Int64(i)]) {
            case am: ArchiveMessage => recent.add(messages[Int64(i)])
            case _ => ()
        }
    }
    for (i in start..messages.size) { recent.add(messages[Int64(i)]) }
    recent
}

func readLine(): String {
    try {
        let input = getStdIn()
        let buf = Array<Byte>(1, repeat: 0)
        let chars = ArrayList<Byte>()
        while (true) {
            let n = input.read(buf)
            if (n <= 0) { break }
            if (buf[0] == 10) { break }
            chars.add(buf[0])
        }
        let raw = Array<Byte>(chars.size, repeat: 0)
        for (i in 0..chars.size) { raw[i] = chars[i] }
        String.fromUtf8(raw)
    } catch (_) { "" }
}
