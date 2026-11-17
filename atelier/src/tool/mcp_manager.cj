package atelier.tool

import mcp.McpClient
import mcp.transport.StdioClientTransport
import mcp.transport.StatelessHttpClient_2026_07_28
import mcp.transport.StreamableHttpClient_2025_11_25
import mcp.types.Implementation
import mcp.types.{Tool as McpToolDef}
import ystyle::jsonrpc.Result
import ystyle::jsonrpc.Transport
import jsonvalue.*
import std.collection.*
import std.sync.Mutex
import stdx.log.*
import std.env.{getVariable, getVariables}

public struct McpServerConfig {
    public let name: String
    public let transport: String
    public let command: String
    public let url: String
    public let headers: HashMap<String, String>
    // stdio 子进程额外环境。std launch 的 environment=Some 是整体替换语义，
    // createTransport 用 stdioEnvironment 合成「当前进程环境 + 本表」，本表优先
    public let env: HashMap<String, String>

    public init(name: String, transport: String, command: String, url: String) {
        this.name = name; this.transport = transport; this.command = command; this.url = url
        this.headers = HashMap(); this.env = HashMap()
    }

    public init(name: String, transport: String, command: String, url: String, headers: HashMap<String, String>) {
        this.name = name; this.transport = transport; this.command = command; this.url = url
        this.headers = headers; this.env = HashMap()
    }

    public init(name: String, transport: String, command: String, url: String,
        headers: HashMap<String, String>, env: HashMap<String, String>) {
        this.name = name; this.transport = transport; this.command = command; this.url = url
        this.headers = headers; this.env = env
    }
}

public class McpManager {
    let servers = HashMap<String, McpServerConfig>()
    let clients = HashMap<String, McpClient>()
    let activeServers = HashSet<String>()
    let lastUsed = HashMap<String, Int64>()
    let serverVersions = HashMap<String, String>()
    let serverToolCounts = HashMap<String, Int64>()
    let serverTools = HashMap<String, ArrayList<(String, String)>>()
    var turnCounter: Int64 = 0
    // 状态机锁：HTTP 多请求并发共享（Mutex 可重入，嵌套调用需成对 lock/unlock）
    let lock = Mutex()

    public init() {}

    // 服务名含 _ 会与工具名前缀解析（mcp_<server>_<tool>）冲突，拒绝注册
    public func registerServer(cfg: McpServerConfig): Unit {
        this.lock.lock()
        try {
            if (cfg.name.contains("_")) {
                getGlobalLogger([("name", "McpManager")]).warn("mcp 服务名不能包含下划线，拒绝注册: ${cfg.name}", Array<Attr>())
                return
            }
            this.servers[cfg.name] = cfg
        } finally {
            this.lock.unlock()
        }
    }

    public func hasServer(name: String): Bool {
        this.lock.lock()
        try {
            this.servers.contains(name)
        } finally {
            this.lock.unlock()
        }
    }

    public func serverNames(): ArrayList<String> {
        this.lock.lock()
        try {
            let r = ArrayList<String>()
            for ((name, _) in this.servers) { r.add(name) }
            r
        } finally {
            this.lock.unlock()
        }
    }

    public func serverCount(): Int64 {
        this.lock.lock()
        try {
            Int64(this.servers.size)
        } finally {
            this.lock.unlock()
        }
    }

    // ---- 激活/冷却状态机（进程级，不持久化） ----

    public func advanceTurn(): Unit {
        this.lock.lock()
        try {
            this.turnCounter++
        } finally {
            this.lock.unlock()
        }
    }

    public func activate(name: String): Unit {
        this.lock.lock()
        try {
            this.doActivate(name)
        } finally {
            this.lock.unlock()
        }
    }

    // 无锁激活：供加锁上下文（loadToolset）内部调用，避免重入嵌套
    func doActivate(name: String): Unit {
        this.activeServers.add(name)
        this.lastUsed[name] = this.turnCounter
    }

    // 工具名 mcp_<server>_<tool> → 服务名（mcp_ 前缀后第一个 _ 之前；非 mcp_ 前缀返回空）
    public func serverFromToolName(toolName: String): String {
        if (!toolName.startsWith("mcp_")) { return "" }
        let rest = toolName.removePrefix("mcp_")
        match (rest.indexOf("_")) {
            case Some(idx) => rest[0..idx]
            case None => ""
        }
    }

    public func markUsedTool(toolName: String): Unit {
        this.lock.lock()
        try {
            let s = this.serverFromToolName(toolName)
            if (this.activeServers.contains(s)) { this.lastUsed[s] = this.turnCounter }
        } finally {
            this.lock.unlock()
        }
    }

    // cooldownTurns <= 0：不启用冷却（默认，一直活跃）；>0：N 轮未用自动卸载
    public func isActive(name: String, cooldownTurns: Int64): Bool {
        this.lock.lock()
        try {
            if (!this.activeServers.contains(name)) { return false }
            if (cooldownTurns <= 0) { return true }
            match (this.lastUsed.get(name)) {
                case Some(t) => this.turnCounter - t < cooldownTurns
                case None => false
            }
        } finally {
            this.lock.unlock()
        }
    }

    // 工具级活跃判定：非 mcp_ 前缀工具（serverFromToolName 为空）不受 MCP 冷却管辖，始终视为活跃；
    // mcp_ 工具按所属服务（含冷却）判定
    public func isActiveTool(toolName: String, cooldownTurns: Int64): Bool {
        let s = this.serverFromToolName(toolName)
        if (s == "") { return true }
        this.isActive(s, cooldownTurns)
    }

    // ---- 协议/工具目录缓存（addServer 连接成功后记录；目录段展示） ----

    public func updateServerInfo(name: String, version: String, toolCount: Int64): Unit {
        this.lock.lock()
        try {
            this.serverVersions[name] = version
            this.serverToolCounts[name] = toolCount
        } finally {
            this.lock.unlock()
        }
    }

    public func serverVersion(name: String): Option<String> {
        this.lock.lock()
        try {
            this.serverVersions.get(name)
        } finally {
            this.lock.unlock()
        }
    }

    public func serverToolCount(name: String): Option<Int64> {
        this.lock.lock()
        try {
            this.serverToolCounts.get(name)
        } finally {
            this.lock.unlock()
        }
    }

    // 工具目录缓存：同时写 serverToolCounts（与 updateServerInfo 的 toolCount 重叠，两者同值；
    // addServer 成功路径两者先后写入，保持一致，供目录段展示工具数）
    public func cacheServerTools(name: String, tools: ArrayList<(String, String)>): Unit {
        this.lock.lock()
        try {
            this.serverTools[name] = tools
            this.serverToolCounts[name] = Int64(tools.size)
        } finally {
            this.lock.unlock()
        }
    }

    public func serverToolsOf(name: String): ArrayList<(String, String)> {
        this.lock.lock()
        try {
            match (this.serverTools.get(name)) {
                case Some(t) => t
                case None => ArrayList<(String, String)>()
            }
        } finally {
            this.lock.unlock()
        }
    }

    // ---- 按需激活（无网络：启动 addServer 已连接注册，这里只翻状态） ----

    // 返回 (isError, text)：错误信息与成功结果结构化，消费方不靠字符串匹配
    public func loadToolset(reg: ToolRegistry, name: String): (Bool, String) {
        this.lock.lock()
        try {
            match (this.servers.get(name)) {
                case None => (true, "未知 MCP 服务: ${name}")
                case Some(_) =>
                    if (this.activeServers.contains(name)) {
                        let names = this.activeToolNames(reg, name)
                        return (false, "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}")
                    }
                    if (!this.serverTools.contains(name)) {
                        return (true, "MCP 服务 '${name}' 未连接（启动连接失败或未配置）")
                    }
                    this.doActivate(name)
                    let names = this.activeToolNames(reg, name)
                    (false, "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}")
            }
        } finally {
            this.lock.unlock()
        }
    }

    func activeToolNames(reg: ToolRegistry, name: String): ArrayList<String> {
        let r = ArrayList<String>()
        let prefix = "mcp_" + name + "_"
        for (t in reg.list()) {
            if (t.name().startsWith(prefix)) { r.add(t.name()) }
        }
        r
    }

    // ---- 启动连接 + 注册 + 缓存（保留原 addServer 语义，成功后缓存协议信息与工具目录） ----

    public func addServer(reg: ToolRegistry, cfg: McpServerConfig): Unit {
        let log = getGlobalLogger([("name", "McpManager")])
        if (cfg.name.contains("_")) {
            log.warn("mcp 服务名不能包含下划线，拒绝注册: ${cfg.name}", Array<Attr>())
            return
        }
        this.servers[cfg.name] = cfg
        let transportObj = createTransport(cfg)
        match (transportObj) {
            case Some(t) =>
                let client = McpClient(t)
                let info = Implementation("atelier", "0.1.0")
                match (client.connect(info)) {
                    case Result.Ok(initResult) =>
                        log.info("mcp ${cfg.name} connected: ${initResult.serverInfo.name}", Array<Attr>())
                        match (client.listTools()) {
                            case Result.Ok(result) =>
                                for (toolDef in result.tools) {
                                    let prefixed = "mcp_" + cfg.name + "_" + toolDef.name
                                    let wrapper = MCPToolWrapper(client, toolDef, toolName: prefixed)
                                    reg.register(wrapper)
                                    log.info("mcp ${cfg.name}: registered ${prefixed}", Array<Attr>())
                                }
                                this.clients[cfg.name] = client
                                this.updateServerInfo(cfg.name, initResult.serverInfo.version, Int64(result.tools.size))
                                let toolList = ArrayList<(String, String)>()
                                for (toolDef in result.tools) {
                                    toolList.add((toolDef.name, toolDef.description))
                                }
                                this.cacheServerTools(cfg.name, toolList)
                            case Result.Err(e) =>
                                log.error("mcp ${cfg.name} listTools failed: ${e}", Array<Attr>())
                                client.close()
                        }
                    case Result.Err(e) =>
                        log.error("mcp ${cfg.name} connect failed: ${e}", Array<Attr>())
                }
            case None => ()
        }
    }

    public func closeAll(): Unit {
        this.lock.lock()
        try {
            for ((_, client) in this.clients) {
                try { client.close() } catch (_) { () }
            }
            this.clients.clear()
        } finally {
            this.lock.unlock()
        }
    }
}

// stdio 子进程环境：当前进程环境 + 自定义变量（自定义优先）。
//
// 为什么总是显式给环境，而不是「无自定义时传 None 继承父进程」：mcp 的
// StdioClientTransport 只有 env=Some 分支按空白拆 argv，env=None 分支把整串 command
// 当单个可执行路径 launch。而 atelier 的 McpServerConfig.command 是「可执行 参数...」
// 单串模型（本地 [[mcpServer]] 与 ACP mcpServers 都走它），env=None 时带参命令必然启动失败。
// 因此这里始终合成一份完整环境，保证 launched argv 正确、且子进程仍拿到父进程的环境。
func stdioEnvironment(custom: HashMap<String, String>): HashMap<String, String> {
    let merged = HashMap<String, String>()
    try {
        for ((k, v) in getVariables()) { merged[k] = v }
    } catch (_) { () }
    // 兜底关键变量：命令名解析、动态库查找、用户目录都依赖它们
    for (k in ["PATH", "LD_LIBRARY_PATH", "HOME"]) {
        if (!merged.contains(k)) {
            match (getVariable(k)) {
                case Some(v) => merged[k] = v
                case None => ()
            }
        }
    }
    for ((k, v) in custom) { merged[k] = v }
    merged
}

func createTransport(cfg: McpServerConfig): Option<Transport> {
    let log = getGlobalLogger([("name", "McpManager")])
    try {
        if (cfg.transport == "stdio") {
            if (cfg.command == "") { log.warn("mcp ${cfg.name}: missing command", Array<Attr>()); return Option<Transport>.None }
            Option<Transport>.Some(StdioClientTransport(cfg.command, env: Some(stdioEnvironment(cfg.env))))
        } else if (cfg.transport == "streamable-http") {
            if (cfg.url == "") { log.warn("mcp ${cfg.name}: missing url", Array<Attr>()); return Option<Transport>.None }
            let t = StatelessHttpClient_2026_07_28(cfg.url)
            if (cfg.headers.size > 0) { t.setCustomHeaders(cfg.headers) }
            Option<Transport>.Some(t)
        } else if (cfg.transport == "session-http") {
            if (cfg.url == "") { log.warn("mcp ${cfg.name}: missing url", Array<Attr>()); return Option<Transport>.None }
            let t = if (cfg.headers.size > 0) { StreamableHttpClient_2025_11_25(cfg.url, cfg.headers) }
                else { StreamableHttpClient_2025_11_25(cfg.url) }
            Option<Transport>.Some(t)
        } else {
            log.warn("mcp ${cfg.name}: unknown transport ${cfg.transport}", Array<Attr>())
            Option<Transport>.None
        }
    } catch (e: Exception) {
        log.error("mcp ${cfg.name}: transport creation failed: ${e.message}", Array<Attr>())
        Option<Transport>.None
    }
}
