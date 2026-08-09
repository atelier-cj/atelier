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
        if (resumeSessionId != "") {
            this.sessionId = resumeSessionId
            this.messages = try {
                let loaded = this.sessionStore.load(resumeSessionId)
                if (loaded.size > MaxLoadMessages) {
                    let recent = ArrayList<Message>()
                    let start = loaded.size - MaxLoadMessages
                    for (i in start..loaded.size) { recent.add(loaded[Int64(i)]) }
                    recent
                } else { loaded }
            } catch (_) { ArrayList<Message>() }
        } else {
            this.sessionId = "sess_" + nextId()
            this.messages = ArrayList<Message>()
        }
    }

    private func loadSessionMessages(id: String): ArrayList<Message> {
        let msgs = try { this.sessionStore.load(id) } catch (_) { return ArrayList<Message>() }
        if (msgs.size > MaxLoadMessages) {
            let recent = ArrayList<Message>()
            let start = msgs.size - MaxLoadMessages
            for (i in start..msgs.size) { recent.add(msgs[Int64(i)]) }
            recent
        } else { msgs }
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
            match (this.registry.dispatch(line)) {
                case Some("exit") => this.running = false
                case Some(msg) => println(msg)
                case None => ()
            }
            return
        }

        let runtime = this.makeRuntime()
        this.messages.add(UserMessage(ContentList.ofText(line), 0))
        let stream = runtime.chat(this.messages)

        let allMsgs = try {
            stream.result()
        } catch (e: Exception) {
            println("Error: " + e.message)
            return
        }
        this.messages = allMsgs
        // Persist after each turn
        try {
            let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
            this.sessionStore.save(this.sessionId, header, this.messages)
        } catch (_) { () }

        let lastText = lastAssistantText(allMsgs)
        if (lastText != "") {
            println(lastText)
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
            if (this.messages.size > 0) {
                try {
                    let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
                    this.sessionStore.save(this.sessionId, header, this.messages)
                } catch (_) { () }
            }
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
            if (this.messages.size > 0) {
                try {
                    let header = SessionHeader(1, this.sessionId, 0, 0, "", "", "", None)
                    this.sessionStore.save(this.sessionId, header, this.messages)
                } catch (_) { () }
            }
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

func textFromContent(cl: ContentList): String {
    var r = ""
    for (b in cl.blocks()) {
        match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
    }
    r
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
