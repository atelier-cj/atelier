package atelier.cli

import std.env.*
import std.collection.*
import std.fs.*
import stdx.net.http.*
import stdx.log.*
import stdx.logger.*
import atelier.message.*
import atelier.agent.*
import atelier.provider.*
import atelier.tool.*
import atelier.tool.builtin.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.tool.McpManager
import atelier.tool.McpServerConfig
import atelier.server.*

main(): Int64 {
    let args = getCommandLine()
    let cmd = if (args.size > 1) { args[1] } else { "" }

    let toolReg = ToolRegistry()
    registerBuiltins(toolReg)

    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()

    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry.default()

    let providerRegForCli = providerReg

    // Load ~/.atelier.toml config
    let configDir = match (getVariable("HOME")) {
        case Some(h) => h
        case None => "."
    }

    let config = loadToml(configDir + "/.atelier.toml")
    let serverCfg = config.server.toServerConfig()

    // Session store
    let sessionDir = if (serverCfg.sessionDir != "") { serverCfg.sessionDir }
        else { configDir + "/.atelier/sessions" }
    try { Directory.create(Path(sessionDir)) } catch (_) { () }
    let sessionStore: SessionStore = StormSessionStore(sessionDir)

    // Apply server config log level if not set by logging section
    if (config.logging.level == "" && serverCfg.logLevel != "") {
        config.logging.level = serverCfg.logLevel
    }
    initLogger(config.logging)

    let mcpMgr = McpManager()
    let handler = AtelierHttpHandler(agentReg, toolReg, sessionStore, trustMgr, skillReg)
    handler.setProviderRegistry(providerReg)
    handler.setMcpManager(mcpMgr)
    toolReg.register(LoadMcpToolsetTool(mcpMgr, toolReg))
    try { skillReg.loadDirectory(configDir + "/.agents/skills") } catch (_) { () }
    toolReg.register(UseSkillsTool(skillReg))
    for (a in config.agent) {
        try { agentReg.create(a.name, agentConfigFrom(a)) } catch (_) { () }
    }
    for (p in config.provider) {
        let cfg = toProviderConfig(p)
        try {
            let prov = providerReg.create(cfg)
            providerReg.register(p.name, prov)
        } catch (e: Exception) {
            eprintln("warning: provider '${p.name}' (type '${p.providerType}') skipped: ${e.message}")
        }
    }
    for (ms in config.mcpServer) {
        let cfg = ms.toMcpServerConfig()
        mcpMgr.addServer(toolReg, cfg)
    }

    match (cmd) {
        case "serve" =>
            let port = if (args.size > 2) { args[2] } else { serverCfg.port.toString() }
            serve(handler, serverCfg.host, port)

        case "acp" =>
            // ACP v1 Agent（stdio 服务端）：被 Zed/opencode 等 ACP Client 拉起；
            // agent 启动时选择（默认 default），运行期一个进程服务一个 agent。
            // 第三参数 sessionDirOverride：远程子进程数据隔离（独立会话/映射目录）
            let acpAgentName = if (args.size > 2) { args[2] } else { "" }
            let acpSessionDirOverride = if (args.size > 3) { args[3] } else { "" }
            runAcp(acpAgentName, toolReg, trustMgr, skillReg,
                agentReg, providerRegForCli, sessionStore, mcpMgr, sessionDir,
                acpSessionDirOverride)

        case "repl" =>
            let agentName = if (args.size > 2) { args[2] } else { "default" }
            let resumeId = if (args.size > 3) { args[3] } else { "" }
            let slashReg = SlashCommandRegistry(trustMgr)
            let cfg = match (agentReg.get(agentName)) {
                case Some(c) => c
                case None => AgentConfig.default()
            }
            let prov = resolveProviderFor(cfg, providerRegForCli)
            let repl = REPL(agentName, slashReg, cfg, prov,
                toolReg, sessionStore, trustMgr, skillReg,
                agentReg, providerRegForCli, resumeId, mcpMgr)
            repl.run()

        case "run" =>
            if (args.size < 3) {
                println("Usage: atelier run [agent] <prompt>")
                return 1
            }
            var startIdx: Int64 = 2
            let agentName: String
            if (agentReg.has(args[2])) {
                agentName = args[2]
                startIdx = 3
            } else {
                agentName = "default"
                startIdx = 2
            }
            if (startIdx >= args.size) {
                println("Usage: atelier run [agent] <prompt>")
                return 1
            }
            var prompt = ""
            for (i in startIdx..args.size) {
                if (i > startIdx) { prompt = prompt + " " }
                prompt = prompt + args[Int64(i)]
            }
            let cfg = match (agentReg.get(agentName)) {
                case Some(c) => c
                case None =>
                    let c = AgentConfig.default()
                    agentReg.create("default", c)
                    c
            }
            let prov = resolveProviderFor(cfg, providerRegForCli)
            let runtime = AgentRuntime(cfg, prov, toolReg, sessionStore, trustMgr, skillReg, agentReg, providerRegForCli, mcpMgr)
            let msgs = ArrayList<Message>()
            msgs.add(UserMessage(ContentList.ofText(prompt), 0))
            let stream = runtime.chat(msgs)
            let result = stream.result()
            let last = lastTextFrom(result)
            println(last)

        case _ =>
            println("Atelier Agent Runtime")
            println("Usage:")
            println("  atelier serve [port]          Start HTTP server")
            println("  atelier acp [agent]           Serve as ACP v1 agent over stdio (agent picked at startup)")
            println("  atelier repl [agent] [sid]    Start interactive REPL (resume session if sid given)")
            println("  atelier run [agent] <prompt>  Run single prompt")
            println("")
            println("REPL slash commands: /help, /trust, /untrust, /session (new/list/switch), /clear, /exit")
            println("Config: ~/.atelier.toml  — agent, provider, server, mcpServer, logging")
            println("Skills: ~/.agents/skills/<name>/SKILL.md")
            println("Logs:   ~/.atelier/atelier.log (set [logging] level = \"debug\")")
            println("Sessions: ~/.atelier/sessions/ (persistent, auto-save after each turn)")
            return 1
    }
    try { sessionStore.close() } catch (_) { () }
    0
}

func initLogger(cfg: TomlLogging): Unit {
    if (cfg.level == "") { return }
    let level = match (cfg.level) {
        case "trace" => LogLevel.TRACE
        case "debug" => LogLevel.DEBUG
        case "info" => LogLevel.INFO
        case "warn" => LogLevel.WARN
        case "error" => LogLevel.ERROR
        case "fatal" => LogLevel.FATAL
        case _ => return
    }
    let logDir = match (getVariable("HOME")) {
        case Some(h) => h + "/.atelier"
        case None => "/tmp/.atelier"
    }
    try { Directory.create(Path(logDir)) } catch (_) { () }
    let logFile = try { File(logDir + "/atelier.log", OpenMode.Append) } catch (_) { return }
    let logger = SimpleLogger(logFile)
    logger.level = level
    setGlobalLogger(logger)
}

func registerBuiltins(reg: ToolRegistry): Unit {
    reg.register(ReadFileTool())
    reg.register(WriteFileTool())
    reg.register(EditFileTool())
    reg.register(BashTool())
    reg.register(GrepTool())
    reg.register(GlobTool())
    reg.register(TodoTool())
    reg.register(AskUserTool())
}

func resolveProviderFor(cfg: AgentConfig, reg: ProviderRegistry): Provider {
    let providerName = match (cfg.provider) { case Some(v) => v; case None => "default" }
    match (reg.get(providerName)) {
        case Some(p) => p
        case None =>
            // Fallback: create from env
            let baseURL = match (getVariable("OPENAI_BASE_URL")) {
                case Some(v) => v; case None => "https://api.openai.com/v1"
            }
            let apiKey = match (getVariable("OPENAI_API_KEY")) {
                case Some(v) => v; case None => ""
            }
            OpenAIProvider(providerName, baseURL, apiKey)
    }
}

func serve(handler: AtelierHttpHandler, host: String, port: String): Unit {
    let server = ServerBuilder()
        .addr(host)
        .port(UInt16(parseInt(port)))
        .build()
    handler.registerRoutes(server.distributor)
    println("Atelier HTTP server listening on ${host}:${port}")
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
