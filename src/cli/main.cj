package atelier.cli

import std.env.*
import std.collection.*
import stdx.net.http.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.tool.builtin.*
import atelier.session.*
import atelier.trust.*
import atelier.server.*

main(): Int64 {
    let args = getCommandLine()
    let cmd = if (args.size > 1) { args[1] } else { "" }

    let toolReg = ToolRegistry()
    registerBuiltins(toolReg)

    let sessionStore: SessionStore = MemorySessionStore()
    let trustMgr = TrustManager()
    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry()

    let handler = AtelierHttpHandler(agentReg, toolReg, sessionStore, trustMgr)
    handler.setProviderRegistry(providerReg)

    match (cmd) {
        case "serve" =>
            let port = if (args.size > 2) { args[2] } else { "8080" }
            serve(handler, port)

        case "repl" =>
            let agentName = if (args.size > 2) { args[2] } else { "default" }
            let slashReg = SlashCommandRegistry()
            let repl = REPL(agentName, slashReg, { name =>
                let cfg = match (agentReg.get(name)) {
                    case Some(c) => c
                    case None => AgentConfig.default()
                }
                let prov = resolveDefault(cfg.model)
                AgentRuntime(cfg, prov, toolReg, sessionStore, trustMgr)
            })
            repl.run()

        case "run" =>
            if (args.size < 3) {
                println("Usage: atelier run <prompt>")
                return 1
            }
            var prompt = ""
            for (i in 2..args.size) {
                if (i > 2) { prompt = prompt + " " }
                prompt = prompt + args[Int64(i)]
            }
            let cfg = match (agentReg.get("default")) {
                case Some(c) => c
                case None =>
                    let c = AgentConfig.default()
                    agentReg.create("default", c)
                    c
            }
            let prov = resolveDefault(cfg.model)
            let runtime = AgentRuntime(cfg, prov, toolReg, sessionStore, trustMgr)
            let msgs = ArrayList<Message>()
            msgs.add(UserMessage(ContentList.ofText(prompt), 0))
            let stream = runtime.chat(msgs)
            let result = stream.result()
            let last = lastTextFrom(result)
            println(last)

        case _ =>
            println("Atelier Agent Runtime")
            println("Usage:")
            println("  atelier serve [port]   Start HTTP server")
            println("  atelier repl [agent]    Start interactive REPL")
            println("  atelier run <prompt>    Run single prompt")
            return 1
    }
    0
}

func registerBuiltins(reg: ToolRegistry): Unit {
    reg.register(ReadFileTool())
    reg.register(WriteFileTool())
    reg.register(EditFileTool())
    reg.register(BashTool())
    reg.register(GrepTool())
    reg.register(GlobTool())
    reg.register(TodoTool())
}

func resolveDefault(model: String): Provider {
    let cfg = resolveProvider(model)
    OpenAIProvider(cfg.name, cfg.baseURL, cfg.apiKey)
}

func serve(handler: AtelierHttpHandler, port: String): Unit {
    let server = ServerBuilder()
        .addr("0.0.0.0")
        .port(UInt16(parseInt(port)))
        .build()
    handler.registerRoutes(server.distributor)
    println("Atelier HTTP server listening on port " + port)
    server.serve()
}

func parseInt(s: String): Int64 {
    var r: Int64 = 0
    for (c in s.toArray()) {
        if (c >= 48 && c <= 57) { r = r * 10 + Int64(c - 48) }
        else { break }
    }
    r
}

func lastTextFrom(msgs: ArrayList<Message>): String {
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
