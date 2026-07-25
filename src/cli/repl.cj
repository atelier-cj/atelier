package atelier.cli

import std.env.*
import std.collection.*
import atelier.agent.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*

public class REPL {
    private let agentName: String
    private let registry: SlashCommandRegistry
    private let runtimeFactory: (String) -> AgentRuntime
    private var running: Bool = true

    public init(agentName: String, registry: SlashCommandRegistry,
        runtimeFactory: (String) -> AgentRuntime) {
        this.agentName = agentName
        this.registry = registry
        this.runtimeFactory = runtimeFactory
    }

    public func run(): Unit {
        println("Atelier REPL — Agent: " + this.agentName)
        println("Type /help for available commands")
        while (this.running) {
            print("> ")
            let line = getLine()
            if (line == "") { continue }
            handleInput(line)
        }
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
        let msgs = ArrayList<Message>()
        msgs.add(UserMessage(ContentList.ofText(line), 0))
        let stream = runtime.chat(msgs)

        var done = false
        while (!done) {
            match (stream.receive(500 * Duration.millisecond)) {
                case Some(ev) =>
                    match (ev) {
                        case ue: MessageUpdateEvent => print(ue.delta)
                        case te: TurnEndEvent => done = true
                        case ae: AgentEndEvent => done = true
                        case _ => ()
                    }
                case None =>
                    // Try to get result
                    try { let _ = stream.result(); done = true } catch (_) { done = true }
            }
        }
        println("")
    }
}
