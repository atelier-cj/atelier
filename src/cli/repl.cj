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
