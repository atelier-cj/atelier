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

public struct McpServerConfig {
    public let name: String
    public let transport: String
    public let command: String
    public let url: String
    public let headers: HashMap<String, String>

    public init(name: String, transport: String, command: String, url: String) {
        this.name = name; this.transport = transport; this.command = command; this.url = url; this.headers = HashMap()
    }

    public init(name: String, transport: String, command: String, url: String, headers: HashMap<String, String>) {
        this.name = name; this.transport = transport; this.command = command; this.url = url; this.headers = headers
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

    public func getServer(name: String): Option<McpServerConfig> {
        this.lock.lock()
        try {
            this.servers.get(name)
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

    public func markUsed(name: String): Unit {
        this.lock.lock()
        try {
            this.lastUsed[name] = this.turnCounter
        } finally {
            this.lock.unlock()
        }
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

    public func isActiveTool(toolName: String, cooldownTurns: Int64): Bool {
        let s = this.serverFromToolName(toolName)
        if (s == "") { return false }
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

func createTransport(cfg: McpServerConfig): Option<Transport> {
    let log = getGlobalLogger([("name", "McpManager")])
    try {
        if (cfg.transport == "stdio") {
            if (cfg.command == "") { log.warn("mcp ${cfg.name}: missing command", Array<Attr>()); return Option<Transport>.None }
            Option<Transport>.Some(StdioClientTransport(cfg.command))
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
