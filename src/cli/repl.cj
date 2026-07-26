package atelier.cli

import std.env.*
import std.collection.*
import stdx.log.*
import atelier.agent.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*

public class REPL {
    private let agentName: String
    private let registry: SlashCommandRegistry
    private let runtimeFactory: (String) -> AgentRuntime
    private let sessionStore: SessionStore
    private var running: Bool = true
    private var sessionId: String
    private var messages: ArrayList<Message>
    private var sessionCounter: Int64

    public init(agentName: String, registry: SlashCommandRegistry,
        runtimeFactory: (String) -> AgentRuntime, sessionStore: SessionStore,
        resumeSessionId: String) {
        this.agentName = agentName
        this.registry = registry
        this.runtimeFactory = runtimeFactory
        this.sessionStore = sessionStore
        this.sessionCounter = 1
        if (resumeSessionId != "") {
            this.sessionId = resumeSessionId
            this.messages = try { this.sessionStore.load(resumeSessionId) } catch (_) { ArrayList<Message>() }
        } else {
            this.sessionId = "sess_1"
            this.messages = ArrayList<Message>()
        }
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

        let runtime = this.runtimeFactory(this.agentName)
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
            this.messages = try { this.sessionStore.load(targetId) } catch (_) {
                println("Session not found: " + targetId)
                return
            }
            this.sessionId = targetId
            println("Switched to session: " + targetId + "  Messages: " + this.messages.size.toString())
        } else {
            println("Usage: /session          Show current session")
            println("       /session new      Create new session")
            println("       /session list     List all sessions")
            println("       /session switch <id>  Switch to session")
        }
    }

    private func handleToolsCommand(): Unit {
        let runtime = this.runtimeFactory(this.agentName)
        let tools = runtime.toolNames()
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
        if (parts.size == 1) {
            println("Model switching is not supported at runtime. Configure model in ~/.atelier.toml")
        } else {
            println("Model switching is not supported at runtime. Edit ~/.atelier.toml to change model")
        }
    }
}

func lastAssistantText(msgs: ArrayList<Message>): String {
    var i = msgs.size - 1
    while (i >= 0) {
        match (msgs[Int64(i)]) {
            case am: AssistantMessage =>
                var r = ""
                for (b in am.content.blocks()) {
                    match (b) { case ContentBlock.TextBlock(t) => r = r + t; case _ => () }
                }
                return r
            case _ => ()
        }
        i--
    }
    ""
}
