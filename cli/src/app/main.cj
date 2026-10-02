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

    let trustMgr = TrustManager()
    let skillReg = SkillRegistry()

    let agentReg = AgentRegistry()
    let providerReg = ProviderRegistry.default()

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
    for (p in config.provider) {
        let cfg = toProviderConfig(p)
        try {
            let prov = providerReg.create(cfg)
            providerReg.register(p.name, prov)
        } catch (e: Exception) {
            eprintln("warning: provider '${p.name}' (type '${p.providerType}') skipped: ${e.message}")
        }
    }
    // 装配束：会话存储 / 信任 / 技能 / Agent 注册表 / provider / MCP 一次装齐，
    // 内置工具绑定到**这一份**组件（技能入口、按需 MCP 加载都指向它）
    var spec = HarnessSpec(
        providers: providerReg, store: sessionStore, trust: trustMgr,
        skills: skillReg, agents: agentReg, mcp: mcpMgr)
    spec = HarnessSpec.withBuiltinTools(spec)
    spec = HarnessSpec.withEnvProvider(spec)
    // [[provider.model]] 声明的上下文窗口（未声明的新模型会落回内置表 + 兜底并留痕）
    spec = withTomlProviderModels(spec, config.provider)
    try { skillReg.loadDirectory(configDir + "/.agents/skills") } catch (e: Exception) {
        // 技能目录整体加载失败 = 全部技能静默消失，模型只会「不会用」而无任何线索
        eprintln("[atelier] skills load failed (${configDir}/.agents/skills): ${e.toString()}")
    }
    let toolReg = spec.tools
    let handler = AtelierHttpHandler(spec)
    for (a in config.agent) {
        try { agentReg.create(a.name, agentConfigFrom(a)) } catch (e: Exception) {
            // 配置里的 Agent 建不出来 = 该 Agent 静默不存在，稍后请求只会得到 not found
            eprintln("[atelier] agent '${a.name}' create failed: ${e.toString()}")
        }
    }
    for (ms in config.mcpServer) {
        let cfg = ms.toMcpServerConfig()
        mcpMgr.addServer(toolReg, cfg)
    }

    // 非交互信任通道：CI / 评测框架等没有审批应答通道的调用方，用环境变量显式声明可信工作目录。
    // 未声明时保持原样（未决定 → 询问），TUI 的交互审批不受影响。
    let trustFromEnv = match (getVariable("ATELIER_TRUST_DIR")) {
        case Some(v) => v; case None => ""
    }
    let trustLog = getGlobalLogger([("name", "atelier")])
    for (d in applyTrustFromEnv(trustMgr, trustFromEnv)) {
        trustLog.info("trusted work dir (ATELIER_TRUST_DIR): ${d}", Array<Attr>())
    }

    match (cmd) {
        case "serve" =>
            let port = if (args.size > 2) { args[2] } else { serverCfg.port.toString() }
            // [a2a].mountToServer：把 A2A 与既有服务挂到同一个 HTTP 端口。
            // 装配失败（例如声明了认证却没配 token）时退回纯 HTTP 服务，
            // 不因为可选能力而阻断既有服务。
            if (config.a2a.mountToServer) {
                let a2aWorkspace = match (getVariable("PWD")) {
                    case Some(v) => v
                    case None => "."
                }
                match (assembleA2a(spec, sessionDir, a2aWorkspace, "", config.a2a,
                                   parseA2aPort(port, 8931), host: serverCfg.host,
                                   exitOnFailure: false)) {
                    case Some(a) => serveWithA2a(handler, serverCfg.host, port, a)
                    case None =>
                        eprintln("[atelier] a2a mount skipped (assembly failed)")
                        serve(handler, serverCfg.host, port)
                }
            } else {
                serve(handler, serverCfg.host, port)
            }

        case "acp" =>
            // ACP v1 Agent（stdio 服务端）：被 Zed/opencode 等 ACP Client 拉起；
            // agent 启动时选择（默认 default），运行期一个进程服务一个 agent。
            // 第三参数 sessionDirOverride：远程子进程数据隔离（独立会话/映射目录）
            let acpAgentName = if (args.size > 2) { args[2] } else { "" }
            let acpSessionDirOverride = if (args.size > 3) { args[3] } else { "" }
            runAcp(acpAgentName, spec, sessionDir, acpSessionDirOverride)

        case "a2a" =>
            // A2A v1 Agent（HTTP 服务端）：Agent Card 发现 + JSON-RPC 绑定 + SSE 流式；
            // 第二参数 agent，第三参数端口（缺省 8931）；工作目录取当前目录
            let a2aAgentName = if (args.size > 2) { args[2] } else { "" }
            let a2aPort: UInt16 = if (args.size > 3) { parseA2aPort(args[3], 8931) } else { 8931 }
            let a2aWorkspace = match (getVariable("PWD")) {
                case Some(v) => v
                case None => "."
            }
            runA2a(a2aAgentName, spec, sessionDir, a2aPort, a2aWorkspace, a2aCfg: config.a2a)

        // 交互入口只有一个 TUI；"repl" 是历史命令名（早期另有行式 REPL，已移除）
        case "repl" | "tui" =>
            let agentName = if (args.size > 2) { args[2] } else { "default" }
            let resumeId = if (args.size > 3) { args[3] } else { "" }
            runTui(agentName, resumeId, spec, sessionDir)

        case "" =>
            // 直接 cli.app：进入聊天 TUI（传统 agent 交互）
            runTui("default", "", spec, sessionDir)

        case "run" =>
            if (args.size < 3) {
                println("Usage: atelier run [--json-events] [agent] <prompt>")
                return 1
            }
            // --json-events：stdout 改为逐行 JSON 事件（CI / 评测框架消费），答案在最后一条
            // message 事件里；不加这个开关时 stdout 仍是纯答案文本，老用法不受影响。
            var jsonEvents = false
            var startIdx: Int64 = 2
            if (args[2] == "--json-events") {
                jsonEvents = true
                startIdx = 3
            }
            if (startIdx >= args.size) {
                println("Usage: atelier run [--json-events] [agent] <prompt>")
                return 1
            }
            let agentName: String
            if (agentReg.has(args[startIdx])) {
                agentName = args[startIdx]
                startIdx = startIdx + 1
            } else {
                agentName = "default"
            }
            if (startIdx >= args.size) {
                println("Usage: atelier run [--json-events] [agent] <prompt>")
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
            let runtime = AgentRuntime(spec, cfg)
            let msgs = ArrayList<Message>()
            msgs.add(UserMessage(ContentList.ofText(prompt), 0))
            let stream = runtime.chat(msgs)
            if (jsonEvents) {
                // 进度照旧走 stderr，JSONL 独占 stdout：两边各自可解析
                pumpProgress(stream, { line => eprintln(line) },
                    { ev =>
                        for (line in jsonLinesFromEvent(ev)) { println(line) }
                    })
                let result = stream.result()
                // 兜底：连一条 assistant 消息都没产出时，至少让消费方知道本轮结束了
                if (!hasAssistantMessage(result)) {
                    println(fallbackMessageLine(lastTextFrom(result)))
                }
            } else {
                // 进度走 stderr：stdout 只留答案（一次性运行常被管道/脚本消费）
                pumpProgress(stream, { line => eprintln(line) })
                let result = stream.result()
                println(lastTextFrom(result))
            }

        case _ =>
            println("Atelier Agent Runtime")
            println("Usage:")
            println("  cli.app serve [port]          Start HTTP server")
            println("  cli.app acp [agent]           Serve as ACP v1 agent over stdio (agent picked at startup)")
            println("  cli.app a2a [agent] [port]    Serve as A2A v1 agent over HTTP (Agent Card + SSE, default port 8931)")
            println("  cli.app tui [agent] [sid]     Start interactive TUI (alias: repl; resume session if sid given)")
            println("  cli.app run [agent] <prompt>  Run single prompt")
            println("")
            println("TUI slash commands: /help, /agent, /session, /model, /models, /tools, /subagent, /trust, /untrust, /clear, /exit")
            println("Config: ~/.atelier.toml  — agent, provider, model, server, mcpServer, logging")
            println("Skills: ~/.agents/skills/<name>/SKILL.md")
            println("Logs:   ~/.atelier/atelier.log (set [logging] level = \"debug\")")
            println("Sessions: ~/.atelier/sessions/ (persistent, auto-save after each turn)")
            return 1
    }
    try { sessionStore.close() } catch (_) { () }
    0
}

// 聊天 TUI 装配（无子命令、tui / repl 子命令都走这里）
private func runTui(agentName: String, resumeId: String, spec: HarnessSpec, sessionDir: String): Unit {
    let slashReg = SlashCommandRegistry(spec.trust)
    let cfg = match (spec.agents.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    let tui = ChatTui(agentName, slashReg, cfg, spec, resumeId, sessionDir)
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
