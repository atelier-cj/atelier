package cli

import std.env.*
import std.collection.*
import std.fs.{Directory, Path, exists}
import atelier.agent.*
import atelier.provider.*
import atelier.provider.EchoProvider
import atelier.a2a.A2aBridge
import server.{AtelierHttpHandler, MountedDistributor}
import stdx.net.http.ServerBuilder
import atelier.config.*
import a2a.*

// atelier a2a [agent] [port]：以 A2A v1 Agent（HTTP 服务端）对外提供服务。
// Agent Card 由 agent 配置 + 技能注册表生成，声明 JSON-RPC 绑定与流式能力；
// 一个 contextId = 一段会话，会话映射与会话数据同目录（跨进程可续聊）。
// workspace：工具工作目录（A2A 请求本身不带 cwd）。
/** A2A 服务装配结果（不启动监听），供独立启动与「挂进 serve」两条路径共用。 */
public class A2aAssembly {
    public let server: A2aServer
    public let agentName: String
    public let listen: String
    public let baseUrl: String

    public init(server: A2aServer, agentName: String, listen: String, baseUrl: String) {
        this.server = server
        this.agentName = agentName
        this.listen = listen
        this.baseUrl = baseUrl
    }
}

// A2A 的路径族：与既有服务（/agent、/session、/ag-ui、/health）无交集，
// 因此共用端口时不需要额外前缀。"/tasks/" 以斜杠结尾表示前缀匹配（带参路径）。
func a2aMountedPaths(): ArrayList<String> {
    ArrayList<String>(["/", "/.well-known/agent-card.json", "/message:send",
        "/message:stream", "/tasks", "/tasks/", "/extendedAgentCard"])
}

/**
 * 装配 A2A 服务（**不**启动监听）：agent 选择、provider 解析、会话目录、认证与卡片
 * 都在这里完成，让 `atelier a2a`（独立端口）与 `atelier serve`（共用端口）共用同一份
 * 装配，避免两条路径的行为漂移。
 *
 * 装配失败（声明认证却没配 token）时返回 None；exitOnFailure 决定是否直接 exit(1)
 * （独立启动必须让编排列程看见失败；挂载场景由调用方决定如何收场）。
 */
public func assembleA2a(spec: HarnessSpec, sessionDir: String, workspace: String,
    agentNameArg: String, a2aCfg: TomlA2a, port: UInt16,
    host!: String = "127.0.0.1", exitOnFailure!: Bool = true): ?A2aAssembly {
    // agent 启动时选择：参数优先，未注册则回退 default（不存在则补建），与 acp 同规则
    let agentReg = spec.agents
    let agentName: String
    if (agentNameArg != "" && agentReg.has(agentNameArg)) {
        agentName = agentNameArg
    } else {
        agentName = "default"
        if (!agentReg.has("default")) {
            agentReg.create("default", AgentConfig.default())
        }
    }
    let cfg = match (agentReg.get(agentName)) {
        case Some(c) => c
        case None => AgentConfig.default()
    }
    // 离线通道：ATELIER_PROVIDER=echo 时用 EchoProvider（e2e/冒烟，不连真实 LLM）；
    // ATELIER_ECHO_DELAY_MS 可加延时供取消路径验证（与 acp 同约定）
    let echoMode = match (getVariable("ATELIER_PROVIDER")) {
        case Some(v) => v == "echo"
        case None => false
    }
    let provider: Provider = if (echoMode) {
        let delayMs = match (getVariable("ATELIER_ECHO_DELAY_MS")) {
            case Some(v) =>
                try { parseInt(v) } catch (_) { 0 }
            case None => 0
        }
        EchoProvider(delayMs)
    } else {
        spec.resolveProvider(cfg)
    }
    if (sessionDir != "" && !exists(Path(sessionDir))) {
        try {
            Directory.create(Path(sessionDir), recursive: true)
        } catch (e: Exception) {
            eprintln("[atelier] a2a session dir create failed (${sessionDir}): ${e.toString()}")
        }
    }
    let mappingFile = if (sessionDir != "") {
        sessionDir + "/a2a-sessions.json"
    } else {
        "a2a-sessions.json"
    }
    let bridge = A2aBridge(spec, cfg, provider, mappingFile, workspace, agentName: agentName)
    // 监听地址与对外地址是两个概念：TLS 通常由 LB/反向代理终止，后端只监听内网，
    // 而卡片必须发布客户端真正连得到的地址（否则发出去的是内网回环地址）。
    let listen = resolveA2aListen(a2aCfg, host)
    let baseUrl = resolveA2aPublicUrl(a2aCfg, "http://${listen}:${port}")
    let card = bridge.agentCard(baseUrl, "0.1.12")
    var options = ServerOptions.of(streaming: true, pushNotifications: false)

    // 入站认证：[a2a].auth = true 时启用「Bearer 或 API Key」双支持。
    // 声明要认证却没配 token 时拒绝启动 —— 否则会起一个 401 掉所有请求的服务，
    // 这种现象从日志上极难定位。
    if (a2aCfg.auth) {
        let tokens = resolveA2aTokens(a2aCfg)
        if (tokens.size == 0) {
            eprintln("[atelier-a2a] auth enabled but no token: set [a2a].token in .atelier.toml " +
                "or the ATELIER_A2A_TOKEN environment variable")
            if (exitOnFailure) {
                // 非 0 退出：启动失败必须让 systemd/容器编排看得见，否则会被当成正常退出。
                exit(1)
            }
            return None
        }
        let apiKeyHeader = resolveA2aApiKeyHeader(a2aCfg)
        card.enableBearerAndApiKeyAuth(apiKeyHeader: apiKeyHeader)
        options.authenticator = Some(StaticTokenAuthenticator(tokens, apiKeyHeader: apiKeyHeader))
        options.apiKeyHeader = apiKeyHeader
        try {
            let err = getStdErr()
            err.write(("[atelier-a2a] auth enabled: Bearer or " + apiKeyHeader +
                " (" + tokens.size.toString() + " token)\n").toArray())
            err.flush()
        } catch (_) { () }
    }
    Some(A2aAssembly(A2aServer(card, bridge, options: options), agentName, listen, baseUrl))
}

public func runA2a(agentNameArg: String, spec: HarnessSpec, sessionDir: String,
    port: UInt16, workspace: String, host!: String = "127.0.0.1",
    a2aCfg!: TomlA2a = TomlA2a()): Unit {
    let assembled = match (assembleA2a(spec, sessionDir, workspace, agentNameArg, a2aCfg, port,
        host: host)) {
        case Some(a) => a
        case None => return
    }
    try {
        let err = getStdErr()
        err.write(("[atelier-a2a] agent='" + assembled.agentName + "' ready: listening on " +
            assembled.listen + ":" + port.toString() + ", advertising " + assembled.baseUrl +
            " (card: " + assembled.baseUrl + AgentCardWellKnownPath + ")\n").toArray())
        err.flush()
    } catch (_) { () }
    assembled.server.serve(assembled.listen, port)
}

/**
 * 把 A2A 挂进 `atelier serve` 的 HTTP 服务（与既有服务共用端口）。
 *
 * 用 MountedDistributor 而不是直接注册：stdx 的注册是精确匹配，表达不了
 * `/tasks/{id}` 这类带参路径；挂载按路径族整体转交，族内精细路由由 A2A 处理器完成。
 */
public func serveWithA2a(handler: AtelierHttpHandler, host: String, port: String,
    a2a: A2aAssembly): Unit {
    let distributor = MountedDistributor()
    distributor.mount(a2aMountedPaths(), a2a.server.handler())
    handler.registerRoutes(distributor)
    let server = ServerBuilder()
        .addr(host)
        .port(UInt16(parseInt(port)))
        .distributor(distributor)
        .build()
    println("Atelier HTTP server listening on ${host}:${port} (a2a mounted: /, /tasks*, /message:*, /.well-known/agent-card.json)")
    println("[atelier-a2a] agent='${a2a.agentName}' advertising ${a2a.baseUrl}")
    server.serve()
}

// 命令行端口解析：非法输入回落到默认端口（命令行用法错误不该让服务静默起在别处）
public func parseA2aPort(raw: String, fallback: UInt16): UInt16 {
    try {
        let v = parseInt(raw)
        if (v <= 0 || v > 65535) {
            return fallback
        }
        UInt16(v)
    } catch (_) {
        fallback
    }
}
