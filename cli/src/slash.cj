package cli

import std.collection.*
import atelier.trust.*

public type SlashHandler = (args: ArrayList<String>) -> String

public class SlashCommandRegistry {
    public let commands = HashMap<String, SlashHandler>()
    public let helpTexts = HashMap<String, String>()
    private let trustManager: TrustManager

    public init(trustManager: TrustManager) {
        this.trustManager = trustManager
        register("help", "Show this help message", { args => showHelp(this) })
        register("clear", "Clear conversation history", { args => "Conversation cleared" })
        register("trust", "Trust a directory: /trust <path>. Parallel(read-only) tools always allowed, sequential(side-effect) tools need trust.", { args =>
            if (args.size == 0) { "Usage: /trust <directory-path>" }
            else {
                trustManager.setTrust(args[0], TrustState.Trusted)
                "Trusted: " + args[0] + ". Sequential tools in this directory will now be allowed."
            }
        })
        register("untrust", "Revoke trust for a directory: /untrust <path>", { args =>
            if (args.size == 0) { "Usage: /untrust <path>" }
            else {
                trustManager.setTrust(args[0], TrustState.Untrusted)
                "Untrusted: " + args[0]
            }
        })
        register("session", "Show current session info", { args =>
            "Session commands: /session (show current), /session new (create new)"
        })
        register("clear", "Clear conversation history", { args => "Conversation cleared" })
        register("exit", "Exit the REPL", { args => "exit" })
        register("quit", "Alias for /exit", { args => "exit" })
    }

    public func register(name: String, help: String, handler: SlashHandler): Unit {
        this.commands[name] = handler
        this.helpTexts[name] = help
    }

    public func dispatch(line: String): Option<String> {
        if (!line.startsWith("/")) { return None }
        let rest = subStr3(line, 1, line.size)
        let parts = rest.split(" ")
        if (parts.size == 0) { return Some("Unknown command. Try /help") }
        let cmd = parts[0]
        let args = ArrayList<String>()
        for (i in 1..parts.size) { args.add(parts[Int64(i)]) }
        match (this.commands.get(cmd)) {
            case Some(h) => Some(h(args))
            case None => Some("Unknown command: " + cmd + ". Try /help")
        }
    }

    public func has(name: String): Bool { this.commands.contains(name) }
}

func showHelp(reg: SlashCommandRegistry): String {
    var r = "Available commands:\n"
    for ((name, help) in reg.helpTexts) {
        r = r + "  /" + name + "  " + help + "\n"
    }
    r
}

func subStr3(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let result = ArrayList<Byte>()
    for (j in start..end) { result.add(bytes[Int64(j)]) }
    let raw = Array<Byte>(result.size, repeat: 0)
    for (j in 0..result.size) { raw[j] = result[j] }
    String.fromUtf8(raw)
}
