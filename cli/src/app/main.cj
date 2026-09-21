package cli.app

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
import cli.*
import server.*

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
    // Directory.create 对「目录已存在」也抛 FSException（见 std.fs 文档），所以先判存在再建：
    // 否则 catch 里分不清「本来就有」与「权限/磁盘导致建不出来」——后者的假象是
    // 会话库随后打不开、根因丢失
    if (!exists(Path(sessionDir))) {
        try { Directory.create(Path(sessionDir), recursive: true) } catch (e: Exception) {
            eprintln("[atelier] session dir create failed (${sessionDir}): ${e.toString()}")
        }
    }
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
    try { skillReg.loadDirectory(configDir + "/.agents/skills") } catch (e: Exception) {
        // 技能目录整体加载失败 = 全部技能静默消失，模型只会「不会用」而无任何线索
        eprintln("[atelier] skills load failed (${configDir}/.agents/skills): ${e.toString()}")
    }
    toolReg.register(UseSkillsTool(skillReg))
    for (a in config.agent) {
        try { agentReg.create(a.name, agentConfigFrom(a)) } catch (e: Exception) {
            // 配置里的 Agent 建不出来 = 该 Agent 静默不存在，稍后请求只会得到 not found
            eprintln("[atelier] agent '${a.name}' create failed: ${e.toString()}")
        }
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

        // 交互入口只有一个 TUI；"repl" 是历史命令名（早期另有行式 REPL，已移除）
        case "repl" | "tui" =>
            let agentName = if (args.size > 2) { args[2] } else { "default" }
            let resumeId = if (args.size > 3) { args[3] } else { "" }
            runTui(agentName, resumeId, toolReg, trustMgr, skillReg, agentReg,
                providerRegForCli, sessionStore, mcpMgr, sessionDir)

        case "" =>
            // 直接 cli.app：进入聊天 TUI（传统 agent 交互）
            runTui("default", "", toolReg, trustMgr, skillReg, agentReg,
                providerRegForCli, sessionStore, mcpMgr, sessionDir)

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
            // 进度走 stderr：stdout 只留答案（一次性运行常被管道/脚本消费）
            pumpProgress(stream, { line => eprintln(line) })
            let result = stream.result()
            let last = lastTextFrom(result)
            println(last)

        case _ =>
            println("Atelier Agent Runtime")
            println("Usage:")
            println("  cli.app serve [port]          Start HTTP server")
            println("  cli.app acp [agent]           Serve as ACP v1 agent over stdio (agent picked at startup)")
            println("  cli.app tui [agent] [sid]     Start interactive TUI (alias: repl; resume session if sid given)")
            println("  cli.app run [agent] <prompt>  Run single prompt")
            println("")
            println("TUI slash commands: /help, /agent, /session, /model, /models, /tools, /subagent, /trust, /untrust, /clear, /exit")
            println("Config: ~/.atelier.toml  — agent, provider, server, mcpServer, logging")
            println("Skills: ~/.agents/skills/<name>/SKILL.md")
            println("Logs:   ~/.atelier/atelier.log (set [logging] level = \"debug\")")
            println("Sessions: ~/.atelier/sessions/ (persistent, auto-save after each turn)")
            return 1
    }
    try { sessionStore.close() } catch (_) { () }
    0
}

// 聊天 TUI 装配（无子命令、tui / repl 子命令都走这里）
private func runTui(agentName: String, resumeId: String, toolReg: ToolRegistry,
    trustMgr: TrustManager, skillReg: SkillRegistry, agentReg: AgentRegistry,
    providerReg: ProviderRegistry, sessionStore: SessionStore, mcpMgr: McpManager,
    sessionDir: String): Unit {
    let slashReg = SlashCommandRegistry(trustMgr)
    let cfg = match (agentReg.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    let prov = resolveProviderFor(cfg, providerReg)
    let tui = ChatTui(agentName, slashReg, cfg, prov, toolReg, sessionStore, trustMgr, skillReg,
        agentReg, providerReg, resumeId, mcpMgr, sessionDir)
    tui.run()
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
    // 同上：已存在也会抛，不先判存在就会在每次启动时打一条假的「创建失败」
    if (!exists(Path(logDir))) {
        try { Directory.create(Path(logDir), recursive: true) } catch (e: Exception) {
            eprintln("[atelier] log dir create failed (${logDir}): ${e.toString()}")
        }
    }
    let logFile = try { File(logDir + "/atelier.log", OpenMode.Append) } catch (e: Exception) {
        // 连日志文件都打不开时，stderr 是最后的可观测通道（否则本轮起全程无日志）
        eprintln("[atelier] log file open failed (${logDir}/atelier.log), logging disabled: ${e.toString()}")
        return
    }
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

// 共享装配助手（resolveProviderFor / serve / parseInt）已移至 cli/src/shared.cj

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
