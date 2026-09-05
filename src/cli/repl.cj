package atelier.cli

import std.env.*
import std.collection.*
import std.fs.*
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

// ===================== /subagent start 参数解析（file-only，供单测） =====================

// parts = "/subagent start ..." 切词结果：返回 (isRemote, agentName, prompt)
// agentName == "" = 缺 agent（调用方打印用法）。prompt 允许空串（与旧行为一致由调用方容忍）。
func parseSubStartArgs(parts: Array<String>): (Bool, String, String) {
    if (parts.size < 3) { return (false, "", "") }
    if (parts[2] == "--remote") {
        if (parts.size < 4) { return (true, "", "") }
        (true, parts[3], joinWords(parts, 4))
    } else {
        (false, parts[2], joinWords(parts, 3))
    }
}

func joinWords(parts: Array<String>, from: Int64): String {
    var out = ""
    for (i in from..parts.size) {
        if (out != "") { out = out + " " }
        out = out + parts[Int64(i)]
    }
    out
}

// 当前可执行文件真实路径：Linux /proc/self/exe 符号链接递归解析；
// 解析失败回退 "atelier.cli"（依赖 PATH/相对路径——远程子进程由此启动）。
func currentExePath(): String {
    try {
        let p = SymbolicLink.readFrom(Path("/proc/self/exe"), recursive: true)
        if (p.toString() != "") { return p.toString() }
    } catch (_) { () }
    "atelier.cli"
}

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
    // 会话数据目录（远程子进程隔离目录的基座：<sessionDir>/remote-sub/<childId>）
    private let sessionDir: String

    public init(agentName: String, registry: SlashCommandRegistry,
        agentConfig: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        resumeSessionId: String, mcpManager: McpManager, sessionDir: String) {
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
        let pending = this.subMgr.pollChildren(this.sessionId)
        for (m in pending) {
            println("  [subagent:${m.from}] ${m.kind}: ${m.text}")
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

    // /subagent 命令区（file-only 解析函数在同文件尾部上方，见 parseSubStartArgs/currentExePath）

    // /subagent start [--remote] <agent> <prompt>：默认本地子；--remote 启动独立
    // `atelier acp` 进程承载的跨进程子（数据隔离于 <sessionDir>/remote-sub/<childId>）
    private func startRemoteByName(agentName: String, prompt: String): Unit {
        let exe = currentExePath()
        let cwd = try { getWorkingDirectory().toString() } catch (_) { "." }
        // 隔离目录：子进程 bstorm/映射文件不与会话目录争用（同 startRemote 库语义）
        let childDir = this.sessionDir + "/remote-sub/" + nextId()
        try { Directory.create(Path(childDir), recursive: true) } catch (_) { () }
        match (this.subMgr.startRemote(exe, agentName, this.sessionId, prompt, cwd, childDir)) {
            case Some(h) =>
                println("已启动远程子 Agent：${h.subSessionId}（进程 ${exe}，目录 ${childDir}）")
            case None =>
                println("远程子启动失败：agent '${agentName}' 未注册或进程不可用")
        }
    }

    // /subagent list|status|poll|start [--remote] <agent> <prompt>|send|respond|close
    private func handleSubagentCommand(line: String): Unit {
        let parts = line.split(" ")
        if (parts.size < 2) {
            println("Usage: /subagent list | poll | start [--remote] <agent> <prompt> | send <id> <text> | respond <id> <text> | close <id>")
            return
        }
        let sub = parts[1]
        if (sub == "list" || sub == "status") {
            let list = this.subMgr.listForParent(this.sessionId)
            if (list.size == 0) {
                println("没有子 Agent（回合内可用 subagent_start 工具启动；远程子经 /subagent start --remote）")
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
        if (sub == "poll") {
            let got = this.subMgr.pollChildren(this.sessionId)
            if (got.size == 0) {
                println("没有未读子消息")
                return
            }
            for (m in got) {
                println("  [${m.from}] ${m.kind}: ${m.text}")
            }
            return
        }
        if (sub == "start") {
            // /subagent start [--remote] <agent> <prompt>：默认本地子；--remote 启动独立
            // `atelier acp` 进程承载的跨进程子（数据隔离于 <sessionDir>/remote-sub/<childId>）
            let (remote, agent, promptText) = parseSubStartArgs(parts)
            if (agent == "") { println("Usage: /subagent start [--remote] <agent> <prompt>"); return }
            if (remote) {
                this.startRemoteByName(agent, promptText)
            } else {
                match (this.subMgr.startByName(agent, this.sessionId, promptText)) {
                    case Some(h) => println("已启动子 Agent：${h.subSessionId}")
                    case None => println("子 agent '${agent}' 未注册或 provider 不可用")
                }
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
