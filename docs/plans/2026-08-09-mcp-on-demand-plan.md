# MCP 按服务加载实施计划（P1）

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 减少 LLM 请求中 tools 定义段的 token 占用：启动仍连接所有 MCP 服务（连接不花 LLM token，且能拿到协议信息），但工具定义**不进入 LLM tools 段**；`load_mcp_toolset(server_id)` 工具按需**激活**服务，`resolveTools` 只暴露激活且未过冷却期的服务工具。

**Architecture:** `McpManager` 保留 `addServer`（启动连接 + 注册 + 缓存协议信息/工具目录），新增激活状态机（进程级 `activeServers`/`lastUsed`/`turnCounter`，不持久化）；`loadToolset` 改为**纯激活**（无网络）；**冷却自动卸载为 agent 级配置、默认关闭**（`AgentConfig.mcpCooldownTurns`，0=不启用，>0=N 轮未用卸载）；新建 `LoadMcpToolsetTool`；`SystemPromptBuilder` 增加 MCP 服务目录段（全部服务显示工具名+描述——启动已缓存）；`AgentRuntime` 持有 `McpManager`，每轮推进 turn、`resolveTools` 按激活状态过滤（冷却阈值取 config）、mcp 工具执行后标记使用；调用点（main/repl/handler）接线。

**Tech Stack:** 仓颉（cjpm）、ystyle::mcp、无新外部依赖。

**与设计文档的差异（已确认）：**
- 激活状态为**进程级**（McpManager 持有）而非会话级——AgentRuntime 每次 chat 新建、无会话对象可挂状态；进程级共享对 CLI/HTTP 均成立
- **服务描述来自协议而非配置**：MCP 协议无服务器级 description（Implementation 仅 name+version，mcp-cj types.cj:15-20），工具级才有。`McpServerConfig`/`TomlMcpServer` **不加 description 字段**
- **启动连接保留**（addServer 增强而非删除）：连接不占 LLM token，且启动即拿到 version/工具数/工具名+描述缓存；`load_mcp_toolset` 纯激活（无网络）；连接失败的服务启动时 log 警告，激活时报"未连接"
- **冷却默认关闭、agent 级配置**：`AgentConfig.mcpCooldownTurns: Int64`（0=永不卸载默认，>0=N 轮未用卸载）；`McpManager.isActive(name, cooldownTurns)` 阈值由调用方（runtime）传入，进程级共享不互相干扰
- **服务名校验**：`registerServer`/`addServer` 拒绝含 `_` 的服务名（工具名 `mcp_<server>_<tool>` 靠前缀解析服务，下划线会歧义）
- **loadToolset 返回 `(Bool, String)`**（isError, text），消费方不靠字符串匹配判断错误
- **目录段统一展示**：全部服务（含未激活）显示 "name (version, N 工具)" + 工具名+描述列表（来自启动缓存；描述约 30-50 token/工具，远小于 tools schema 定义）

**前置：** P0 已合并（master 6f9d11d）。开分支 `git checkout -b feat/mcp-on-demand`。

---

### Task 1: McpManager 改造（addServer 增强 + 激活/冷却状态机 + loadToolset 纯激活）

**Files:**
- Modify: `src/tool/mcp_manager.cj`
- Test: `src/tool/mcp_manager_test.cj`（新建）

**Step 1: 写失败测试**

创建 `src/tool/mcp_manager_test.cj`（package atelier.tool）：

```cangjie
package atelier.tool

import std.collection.*

func mcpCfg(name: String): McpServerConfig {
    McpServerConfig(name, "stdio", "echo", "")
}

@Test
func mcpManager_registerAndList() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.registerServer(mcpCfg("slack"))
    @Expect(m.hasServer("github"), true)
    @Expect(m.hasServer("unknown"), false)
    @Expect(m.serverNames().size, 2)
    @Expect(m.serverCount(), 2)
}

@Test
func mcpManager_underscoreNameRejected() {
    let m = McpManager()
    m.registerServer(mcpCfg("my_server"))
    @Expect(m.hasServer("my_server"), false)
}

@Test
func mcpManager_serverFromToolName() {
    let m = McpManager()
    @Expect(m.serverFromToolName("mcp_github_search_repos"), "github")
    @Expect(m.serverFromToolName("mcp_slack_send"), "slack")
    @Expect(m.serverFromToolName("read_file"), "")
}

@Test
func mcpManager_noCooldownStaysActive() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    var i: Int64 = 0
    while (i < 100) { m.advanceTurn(); i++ }
    @Expect(m.isActive("github", 0), true)
}

@Test
func mcpManager_activationAndCooldown() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    @Expect(m.isActive("github", 20), true)
    @Expect(m.isActive("slack", 20), false)
    var i: Int64 = 0
    while (i < 20) { m.advanceTurn(); i++ }
    @Expect(m.isActive("github", 20), false)
}

@Test
func mcpManager_markUsedKeepsActive() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    var i: Int64 = 0
    while (i < 19) { m.advanceTurn(); i++ }
    m.markUsed("github")
    m.advanceTurn()
    @Expect(m.isActive("github", 20), true)
}

@Test
func mcpManager_markUsedToolRefreshes() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    var i: Int64 = 0
    while (i < 19) { m.advanceTurn(); i++ }
    m.markUsedTool("mcp_github_search_repos")
    m.advanceTurn()
    @Expect(m.isActive("github", 20), true)
}

@Test
func mcpManager_isActiveToolResolvesServer() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    @Expect(m.isActiveTool("mcp_github_search_repos", 20), true)
    @Expect(m.isActiveTool("mcp_slack_send", 20), false)
    @Expect(m.isActiveTool("read_file", 20), false)
}

@Test
func mcpManager_loadToolsetUnknownServer() {
    let m = McpManager()
    let reg = ToolRegistry()
    let r = m.loadToolset(reg, "nope")
    @Expect(r[0], true)
    @Expect(r[1].contains("未知"), true)
    @Expect(m.isActive("nope", 0), false)
}

@Test
func mcpManager_loadToolsetNotConnected() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    let r = m.loadToolset(reg, "github")
    @Expect(r[0], true)
    @Expect(r[1].contains("未连接"), true)
    @Expect(m.isActive("github", 0), false)
}

@Test
func mcpManager_loadToolsetActivates() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    let toolList = ArrayList<(String, String)>()
    toolList.add(("search_repos", "在 GitHub 上搜索仓库"))
    m.cacheServerTools("github", toolList)
    let r = m.loadToolset(reg, "github")
    @Expect(r[0], false)
    @Expect(m.isActive("github", 0), true)
    @Expect(r[1].contains("已加载"), true)
}

@Test
func mcpManager_loadToolsetAlreadyActiveIdempotent() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    m.activate("github")
    let r = m.loadToolset(reg, "github")
    @Expect(r[0], false)
    @Expect(r[1].contains("已加载"), true)
}

@Test
func mcpManager_protocolInfoCache() {
    let m = McpManager()
    m.updateServerInfo("github", "1.2.3", 12)
    @Expect(m.serverVersion("github"), Some("1.2.3"))
    @Expect(m.serverToolCount("github"), Some(12))
    @Expect(m.serverVersion("nope"), None)
}

@Test
func mcpManager_toolCatalogCache() {
    let m = McpManager()
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "在 GitHub 上搜索仓库"))
    tools.add(("list_issues", "列出仓库 issues"))
    m.cacheServerTools("github", tools)
    let cached = m.serverToolsOf("github")
    @Expect(cached.size, 2)
    @Expect(cached[0][0], "search_repos")
    @Expect(cached[0][1], "在 GitHub 上搜索仓库")
    @Expect(m.serverToolsOf("nope").size, 0)
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*mcpManager*'`
Expected: 编译失败（McpManager 缺方法）。

**Step 3: 实现 `src/tool/mcp_manager.cj`**

保持 `McpServerConfig`（2 构造）、`createTransport` 不动。`addServer` **保留**（增强：成功后缓存协议信息与工具目录）。新增状态机与激活逻辑：

```cangjie
public class McpManager {
    let servers = HashMap<String, McpServerConfig>()
    let clients = HashMap<String, McpClient>()
    let activeServers = HashSet<String>()
    let lastUsed = HashMap<String, Int64>()
    let serverVersions = HashMap<String, String>()
    let serverTools = HashMap<String, ArrayList<(String, String)>>()
    var turnCounter: Int64 = 0
    let serverToolCounts = HashMap<String, Int64>()
    let serverTools = HashMap<String, ArrayList<(String, String)>>()
    var turnCounter: Int64 = 0

    public init() {}

    // 服务名含 _ 会与工具名前缀解析（mcp_<server>_<tool>）冲突，拒绝注册
    public func registerServer(cfg: McpServerConfig): Unit {
        if (cfg.name.contains("_")) {
            getGlobalLogger([("name", "McpManager")]).warn("mcp 服务名不能包含下划线，拒绝注册: ${cfg.name}", Array<Attr>())
            return
        }
        this.servers[cfg.name] = cfg
    }

    public func hasServer(name: String): Bool { this.servers.contains(name) }

    public func serverNames(): ArrayList<String> {
        let r = ArrayList<String>()
        for ((name, _) in this.servers) { r.add(name) }
        r
    }

    public func serverCount(): Int64 { Int64(this.servers.size) }

    public func getServer(name: String): Option<McpServerConfig> { this.servers.get(name) }

    // ---- 激活/冷却状态机（进程级，不持久化） ----

    public func advanceTurn(): Unit { this.turnCounter++ }

    public func activate(name: String): Unit {
        this.activeServers.add(name)
        this.lastUsed[name] = this.turnCounter
    }

    public func markUsed(name: String): Unit { this.lastUsed[name] = this.turnCounter }

    // 工具名 mcp_<server>_<tool> → 服务名（mcp_ 前缀后第一个 _ 之前）
    public func serverFromToolName(toolName: String): String {
        let rest = toolName.removePrefix("mcp_")
        match (rest.indexOf("_")) {
            case Some(idx) => rest[0..idx]
            case None => ""
        }
    }

    public func markUsedTool(toolName: String): Unit {
        let s = this.serverFromToolName(toolName)
        if (this.activeServers.contains(s)) { this.lastUsed[s] = this.turnCounter }
    }

    // cooldownTurns <= 0：不启用冷却（默认，一直活跃）；>0：N 轮未用自动卸载
    public func isActive(name: String, cooldownTurns: Int64): Bool {
        if (!this.activeServers.contains(name)) { return false }
        if (cooldownTurns <= 0) { return true }
        match (this.lastUsed.get(name)) {
            case Some(t) => this.turnCounter - t < cooldownTurns
            case None => false
        }
    }

    public func isActiveTool(toolName: String, cooldownTurns: Int64): Bool {
        let s = this.serverFromToolName(toolName)
        if (s == "") { return false }
        this.isActive(s, cooldownTurns)
    }

    // ---- 协议/工具目录缓存（addServer 连接成功后记录；目录段展示） ----

    public func updateServerInfo(name: String, version: String, toolCount: Int64): Unit {
        this.serverVersions[name] = version
        this.serverToolCounts[name] = toolCount
    }

    public func serverVersion(name: String): Option<String> { this.serverVersions.get(name) }

    public func serverToolCount(name: String): Option<Int64> { this.serverToolCounts.get(name) }

    public func cacheServerTools(name: String, tools: ArrayList<(String, String)>): Unit {
        this.serverTools[name] = tools
    }

    public func serverToolsOf(name: String): ArrayList<(String, String)> {
        match (this.serverTools.get(name)) {
            case Some(t) => t
            case None => ArrayList<(String, String)>()
        }
    }

    // ---- 按需激活（无网络：启动 addServer 已连接注册，这里只翻状态） ----

    public func loadToolset(reg: ToolRegistry, name: String): String {
        match (this.servers.get(name)) {
            case None => "未知 MCP 服务: ${name}"
            case Some(_) =>
                if (!this.clients.contains(name)) {
                    return "MCP 服务 '${name}' 未连接（启动连接失败或未配置）"
                }
                if (this.activeServers.contains(name)) {
                    let names = this.activeToolNames(reg, name)
                    return "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}"
                }
                this.activate(name)
                let names = this.activeToolNames(reg, name)
                "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}"
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

    public func closeAll(): Unit {
        for ((_, client) in this.clients) {
            try { client.close() } catch (_) { () }
        }
        this.clients.clear()
    }
}
```

`addServer` 增强（保留原连接+注册逻辑，成功后追加缓存）：

```cangjie
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
```

注意：`mcpManager_loadToolsetActivates` 测试调用 `m.addServer(reg, ...)` 会真实尝试连接（stdio "echo" 会失败）——测试会走 connect 失败分支，不影响断言（activate 由测试后置调用链保证？不对——该测试先 cacheServerTools 再 addServer（连接失败）再 loadToolset（clients 无 → "未连接"）→ 断言 isActive 失败！**修正**：该测试移除 addServer 调用，直接注入连接成功标志。为可测性，增加一个测试辅助注入：

```cangjie
    // 测试注入：模拟 addServer 连接成功（无网络）
    public func markConnected(name: String): Unit {
        this.clients[name] = McpClient(createTransport(mcpCfg(name)).getOrThrow())
    }
```

等等——McpClient 构造需要 Transport 且会尝试连接？McpClient(t) 构造可能不连接（connect 才连）。但 createTransport 需要真实 transport。更简单：**clients 改为可注入的集合**：`public func simulateConnected(name: String): Unit` 用 `HashMap<String, McpClient>()` 存一个 fake？McpClient 类型无法伪造……

**最终方案**：loadToolset 的"未连接"判断不用 `clients.contains`，改用 `serverTools.contains(name)`（连接成功才有工具目录缓存）。测试里 `cacheServerTools` 即模拟连接成功。修改 loadToolset：

```cangjie
    // 返回 (isError, text)：错误信息与成功结果结构化，消费方不靠字符串匹配
    public func loadToolset(reg: ToolRegistry, name: String): (Bool, String) {
        match (this.servers.get(name)) {
            case None => (true, "未知 MCP 服务: ${name}")
            case Some(_) =>
                if (!this.serverTools.contains(name)) {
                    return (true, "MCP 服务 '${name}' 未连接（启动连接失败或未配置）")
                }
                if (this.activeServers.contains(name)) {
                    let names = this.activeToolNames(reg, name)
                    return (false, "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}")
                }
                this.activate(name)
                let names = this.activeToolNames(reg, name)
                (false, "已加载 MCP 服务 '${name}'，共 ${names.size} 个工具：${String.join(names.toArray(), delimiter: ", ")}")
        }
    }
```

这样 `mcpManager_loadToolsetActivates` 测试：registerServer + cacheServerTools（模拟连接成功）+ loadToolset → activate + "已加载" + 工具名（activeToolNames 从 reg 找 mcp_github_ 前缀——reg 里没有注册工具，names 空！断言 `r.contains("search_repos")` 失败）。修正断言：只断言 `m.isActive("github")` 和 `r.contains("已加载")`，不断言工具名（工具注册需要真实连接）。同时 `mcpManager_loadToolsetNotConnected` 测试：registerServer（无 cacheServerTools）→ "未连接" ✅。

**修正后的测试**（mcpManager_loadToolsetActivates）：

```cangjie
@Test
func mcpManager_loadToolsetActivates() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    let toolList = ArrayList<(String, String)>()
    toolList.add(("search_repos", "在 GitHub 上搜索仓库"))
    m.cacheServerTools("github", toolList)
    let r = m.loadToolset(reg, "github")
    @Expect(m.isActive("github"), true)
    @Expect(r.contains("已加载"), true)
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*mcpManager*'`
Expected: 11 个测试全 PASSED（编译会过——addServer 保留，main.cj 不再报错）。

**Step 5: 编译 + 全量回归**

Run: `cjpm build -j 16` → success
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（基线 162 + 新增 ~13）

**Step 6: Commit**

```bash
git add src/tool/mcp_manager.cj src/tool/mcp_manager_test.cj
git commit -m "feat(mcp): McpManager 启动连接缓存协议信息 + 激活/冷却状态机 + loadToolset 纯激活"
```

---

### Task 2: LoadMcpToolsetTool + 系统提示目录段 + ContextBuilder 集成

**Files:**
- Create: `src/tool/load_mcp_toolset.cj`
- Modify: `src/context/system_prompt_builder.cj`（加 `buildMcpCatalog`）
- Modify: `src/context/builder.cj`（加 mcpManager 字段 + 目录段拼接）
- Test: `src/tool/mcp_manager_test.cj`（追加）、`src/context/builder_test.cj`（追加）

**Step 1: 写失败测试**

追加到 `src/tool/mcp_manager_test.cj`：

```cangjie
import jsonvalue.*

@Test
func loadMcpToolset_unknownServerError() {
    let m = McpManager()
    let reg = ToolRegistry()
    reg.register(LoadMcpToolsetTool(m, reg))
    let t = match (reg.get("load_mcp_toolset")) {
        case Some(x) => x
        case None => throw Exception("tool not registered")
    }
    let args = HashMap<String, JsonValue>()
    args["server_id"] = JsonValue.String("nope")
    let r = t.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, true)
    @Expect(r.text.contains("未知"), true)
}


@Test
func loadMcpToolset_alreadyActiveInfo() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    let reg = ToolRegistry()
    reg.register(LoadMcpToolsetTool(m, reg))
    let t = match (reg.get("load_mcp_toolset")) {
        case Some(x) => x
        case None => throw Exception("tool not registered")
    }
    let args = HashMap<String, JsonValue>()
    args["server_id"] = JsonValue.String("github")
    let r = t.execute(ToolContext("."), JsonValue.Map(args))
    @Expect(r.isError, false)
    @Expect(r.text.contains("已加载"), true)
}

@Test
func loadMcpToolset_missingParamError() {
    let m = McpManager()
    let reg = ToolRegistry()
    reg.register(LoadMcpToolsetTool(m, reg))
    let t = match (reg.get("load_mcp_toolset")) {
        case Some(x) => x
        case None => throw Exception("tool not registered")
    }
    let r = t.execute(ToolContext("."), JsonValue.Map(HashMap()))
    @Expect(r.isError, true)
}
```

追加到 `src/context/builder_test.cj`（注意 import atelier.tool.* 与 atelier.session.* 已有；McpServerConfig/McpManager 在 atelier.tool 包）：

```cangjie
import atelier.tool.*

func mcpManagerWithTools(name: String): McpManager {
    let m = McpManager()
    m.registerServer(McpServerConfig(name, "stdio", "echo", ""))
    m.updateServerInfo(name, "1.2.3", 2)
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "在 GitHub 上搜索仓库"))
    tools.add(("list_issues", "列出仓库 issues"))
    m.cacheServerTools(name, tools)
    m
}

@Test
func sysPrompt_mcpCatalogInjected() {
    let spb = SystemPromptBuilder()
    let out = spb.buildMcpCatalog(mcpManagerWithTools("github"))
    @Expect(out.contains("load_mcp_toolset"), true)
    @Expect(out.contains("github (v1.2.3, 2 个工具)"), true)
    @Expect(out.contains("search_repos"), true)
    @Expect(out.contains("在 GitHub 上搜索仓库"), true)
}

@Test
func sysPrompt_mcpCatalogActiveMarked() {
    let m = mcpManagerWithTools("github")
    m.activate("github")
    let spb = SystemPromptBuilder()
    let out = spb.buildMcpCatalog(m)
    @Expect(out.contains("已加载"), true)
}

@Test
func sysPrompt_mcpCatalogEmptyWithoutServers() {
    let spb = SystemPromptBuilder()
    @Expect(spb.buildMcpCatalog(McpManager()), "")
}

@Test
func ctxBuilder_mcpCatalogInSystemMessage() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment(), mcpManagerWith("github"))
    let msgs = b.initMessages("sys", ArrayList(), ArrayList())
    @Expect(msgs.size, 1)
    match (msgs[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) =>
                    @Expect(t.contains("load_mcp_toolset"), true)
                    @Expect(t.contains("github"), true)
                case _ => @Expect(false, true)
            }
        case _ => @Expect(false, true)
    }
}

@Test
func ctxBuilder_noMcpNoCatalog() {
    let b = ContextBuilder(SkillRegistry(), SessionEnvironment())
    let msgs = b.initMessages("sys", ArrayList(), ArrayList())
    @Expect(msgs.size, 1)
    match (msgs[0]) {
        case um: UserMessage =>
            match (um.content.blocks()[0]) {
                case ContentBlock.TextBlock(t) => @Expect(t.contains("load_mcp_toolset"), false)
                case _ => @Expect(false, true)
            }
        case _ => @Expect(false, true)
    }
}
```

**Step 2: 跑测试确认失败**

Run: `cjpm test -j 16 --filter '*mcp*'` 和 `cjpm test -j 16 --filter '*sysPrompt*'`
Expected: 编译失败（`LoadMcpToolsetTool` 未定义；`buildMcpCatalog` 不存在；`ContextBuilder` 3 参构造不存在）。

**Step 3: 实现**

创建 `src/tool/load_mcp_toolset.cj`：

```cangjie
package atelier.tool

import jsonvalue.*
import std.collection.*

public class LoadMcpToolsetTool <: Tool {
    private let mcpManager: McpManager
    private let toolRegistry: ToolRegistry

    public init(mcpManager: McpManager, toolRegistry: ToolRegistry) {
        this.mcpManager = mcpManager
        this.toolRegistry = toolRegistry
    }

    public func name(): String { "load_mcp_toolset" }

    public func description(): String {
        "按需加载一个 MCP 服务的完整工具集。参数: server_id（服务标识符，如 \"github\"）。" +
        "加载后该服务的所有 mcp_<server>_<tool> 工具在后续对话中可用。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("server_id", "MCP 服务标识符", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let serverId: String = match (args["server_id"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: server_id", None, true, false)
        }
        let (isErr, text) = this.mcpManager.loadToolset(this.toolRegistry, serverId)
        ToolResult(text, None, isErr, false)
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}
```

检查 `SchemaBuilder.addString` 签名（src/tool/schema.cj:12）：`addString(name, desc, required!: Bool = false)`——命名参数。上面的调用如签名不符按实际调整。

`SystemPromptBuilder` 追加方法（`src/context/system_prompt_builder.cj`）：

```cangjie
import atelier.tool.McpManager

    // 渐进披露第 1 层：MCP 服务目录段
    // 全部服务（含未激活）显示 name (version, N 工具) + 工具名: 描述（启动 addServer 已缓存）；
    // 激活服务标注「已加载」（tools 段才有完整 schema 定义）
    public func buildMcpCatalog(mcpManager: McpManager): String {
        if (mcpManager.serverCount() == 0) { return "" }
        let sb = StringBuilder()
        sb.append("[可用 MCP 服务]\n")
        sb.append("调用 load_mcp_toolset(server_id) 激活服务，激活后其完整工具定义进入可用工具列表。\n")
        for (name in mcpManager.serverNames()) {
            sb.append("- ")
            sb.append(name)
            match (mcpManager.serverVersion(name)) {
                case Some(v) =>
                    let count = match (mcpManager.serverToolCount(name)) {
                        case Some(c) => c.toString()
                        case None => "?"
                    }
                    sb.append(" (v")
                    sb.append(v)
                    sb.append(", ")
                    sb.append(count)
                    sb.append(" 个工具)")
                case None => ()
            }
            if (mcpManager.isActive(name)) {
                sb.append(" [已加载]")
            }
            for (t in mcpManager.serverToolsOf(name)) {
                sb.append("\n  - ")
                sb.append(t[0])
                if (t[1] != "") {
                    sb.append(": ")
                    sb.append(t[1])
                }
            }
            sb.append("\n")
        }
        sb.append("\n")
        sb.toString()
    }
```

注意 `case Some(d) if (d != "")`——仓颉 match 守卫语法若不可用，改为 `case Some(d) => if (d != "") { ... }`。

`ContextBuilder` 改造（`src/context/builder.cj`）：

```cangjie
import atelier.tool.McpManager

public class ContextBuilder {
    private let skills: SkillRegistry
    private let env: SessionEnvironment
    private let mcpManager: Option<McpManager>
    private let promptBuilder: SystemPromptBuilder

    public init(skills: SkillRegistry, env: SessionEnvironment) {
        this.skills = skills; this.env = env
        this.mcpManager = None
        this.promptBuilder = SystemPromptBuilder()
    }

    public init(skills: SkillRegistry, env: SessionEnvironment, mcpManager: McpManager) {
        this.skills = skills; this.env = env
        this.mcpManager = Some(mcpManager)
        this.promptBuilder = SystemPromptBuilder()
    }

    public func initMessages(systemPrompt: String, skillNames: ArrayList<String>,
        history: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        var text = this.promptBuilder.build(systemPrompt, skillNames, this.skills, this.env)
        match (this.mcpManager) {
            case Some(m) =>
                let catalog = this.promptBuilder.buildMcpCatalog(m)
                if (catalog != "") { text = text + catalog }
            case None => ()
        }
        if (text != "") {
            result.add(UserMessage(ContentList.ofText(text), 0))
        }
        for (m in history) { result.add(m) }
        result
    }
    // buildChatRequest 不变
}
```

**Step 4: 跑测试确认通过**

Run: `cjpm test -j 16 --filter '*mcp*'`、`cjpm test -j 16 --filter '*sysPrompt*'`、`cjpm test -j 16 --filter '*ctxBuilder*'`
Expected: 全部 PASSED。

**Step 5: Commit**

```bash
git add src/tool/load_mcp_toolset.cj src/tool/mcp_manager_test.cj src/context/system_prompt_builder.cj src/context/builder.cj src/context/builder_test.cj
git commit -m "feat(mcp): load_mcp_toolset 工具 + 系统提示 MCP 服务目录段 + ContextBuilder 集成"
```

---

### Task 3: AgentRuntime + AgentConfig 冷却配置 + 调用点接线（main/repl/handler）

**Files:**
- Modify: `src/agent/config.cj`（AgentConfig.mcpCooldownTurns: Int64 = 0，序列化兼容）
- Modify: `src/agent/runtime.cj`（mcpManager 字段 + 构造重载 + resolveTools 过滤传冷却阈值 + advanceTurn + markUsedTool + 状态机加锁）
- Modify: `src/tool/mcp_manager.cj`（状态机方法加 Mutex 锁——HTTP 并发）
- Modify: `src/server/handler.cj`（mcpManager 字段 + setter + 3 处 runtime 构造）
- Modify: `src/cli/repl.cj`（构造加 mcpManager + makeRuntime 传参）
- Modify: `src/cli/main.cj`（接线：addServer 保留、LoadMcpToolsetTool 注册、handler.setMcpManager、run/REPL 传参）
- Test: `src/agent/config_test.cj`（mcpCooldownTurns 序列化往返 + 默认值）
**Step 1: 实现**（`TomlMcpServer`/`McpServerConfig` **不加 description 字段**——协议信息连接后获取）

1. `src/server/config.cj` **不改**（toMcpServerConfig 保持现有调用）。

2. `src/agent/config.cj`：`AgentConfig` 增加 `public let mcpCooldownTurns: Int64`（默认 0=不启用冷却）。注意：构造参数 +1（在 tools/skills 之后合适位置插入），`default()` 传 0，`toJson` 加 `w.writeName("mcpCooldownTurns").writeValue(this.mcpCooldownTurns)`，`fromJson` 加 `case "mcpCooldownTurns" => mcpCooldownTurns = r.readValue<Int64>()`（默认 0，旧配置兼容）。**所有 AgentConfig 显式构造调用点需同步更新**（搜索 `AgentConfig(`：repl.cj 的 makeRuntime、config_test.cj、server 相关）。配 `config_test.cj` 新增测试：默认 0、序列化往返。

3. `src/agent/runtime.cj` + `src/agent/agent_tool.cj`（子 agent 共享状态）：
   - `AgentTool` 构造加 `mcpManager: McpManager` 参数（父 runtime 在 resolveTools 创建 AgentTool 时传 `this.mcpManager`），AgentTool 内部创建的子 AgentRuntime 也传同一实例——子 agent 与父 agent 共享 MCP 激活状态（进程级本来就共享）
   - `AgentRuntime` 新增带 `mcpManager` 的构造重载（8 参→9 参、10 参→11 参、12 参→13 参），旧构造委托新构造传 `McpManager()`（hook_test.cj 等既有调用不破坏）
   - import 加 `import atelier.tool.McpManager`
   - 字段 `private let mcpManager: McpManager`
   - 现有 3 个构造（8 参/10 参/12 参）加 mcpManager 参数；**同时保留旧签名重载**（委托新签名传 `McpManager()`）——为控制改动面，新增带 mcpManager 的完整构造，旧构造委托：

```cangjie
    public init(config: AgentConfig, provider: Provider,
        toolRegistry: ToolRegistry, sessionStore: SessionStore,
        trustManager: TrustManager, skillRegistry: SkillRegistry,
        agentRegistry: AgentRegistry, providerRegistry: ProviderRegistry,
        mcpManager: McpManager) {
        // 与 8 参构造相同，仅多 this.mcpManager = mcpManager
    }
```

   具体做法：在 8 参构造基础上加 9 参重载；10 参（hooks, askUser）加 11 参重载；12 参（hooks, askUser, sessionEnv）加 13 参重载。旧构造委托：`this(config, provider, ..., hooks, askUser, McpManager())`——注意仓颉构造委托用 `this(args)`。为简单可靠，改为：所有构造统一收口到最全签名，旧签名委托最全签名传 `McpManager()`。
   - chatWithEnv 中 turnCount++ 后加 `this.mcpManager.advanceTurn()`
   - resolveTools 的 `_*` 通配分支加 mcp 过滤：

```cangjie
            } else if (name.endsWith("_*")) {
                let prefix = name[0..name.size - 2]
                for (t in this.toolRegistry.list()) {
                    if (t.name().startsWith(prefix)) {
                        if (t.name().startsWith("mcp_") &&
                            !this.mcpManager.isActiveTool(t.name(), this.config.mcpCooldownTurns)) {
                            continue
                        }
                        result.add(OpenAITool(t.name(), t.description(), t.schema()))
                    }
                }
            }
```

   - 工具执行后标记使用：`let results = try { this.toolExecutor.executeBatch(batch) } ...` 之后的 results 循环（None 分支，即真实执行了）里加：

```cangjie
                                            this.mcpManager.markUsedTool(tc.name)
```

3. `src/tool/mcp_manager.cj`：状态机方法加锁（HTTP 多请求并发共享）——`import std.sync.Mutex`，类字段 `let lock = Mutex()`；`advanceTurn`/`activate`/`markUsed`/`markUsedTool`/`isActive`/`isActiveTool`/`registerServer`/`loadToolset` 用 `lock.lock()` + try/finally `lock.unlock()` 包裹（具体 API 以仓颉 std.sync 文档为准，若 Mutex 不支持则用 lockGuard 或 RecursiveMutex——注意 loadToolset 内部调用 activate，避免重复加锁，可拆内部不加锁私有方法）。

5. `src/server/handler.cj`：
   - 字段 `private var mcpManager: McpManager = McpManager()`
   - 方法 `public func setMcpManager(m: McpManager): Unit { this.mcpManager = m }`
   - 3 处 `AgentRuntime(...)` 构造追加 `this.mcpManager` 参数（10 参 → 11 参，8 参 → 9 参）

4. `src/cli/repl.cj`：
   - REPL 类构造加 `mcpManager: McpManager` 参数（看现有构造签名，追加到末尾），字段保存
   - makeRuntime 的 AgentRuntime 构造追加 this.mcpManager

6. `src/cli/main.cj`：
   - **`addServer` 循环保留**（原样，启动连接+注册+缓存），仅调整顺序：mcpMgr 创建提前到 handler 创建之前（handler 需要它）；注册 LoadMcpToolsetTool；handler.setMcpManager：

```cangjie
    let mcpMgr = McpManager()
    let handler = AtelierHttpHandler(agentReg, toolReg, sessionStore, trustMgr, skillReg)
    handler.setProviderRegistry(providerReg)
    handler.setMcpManager(mcpMgr)
    toolReg.register(LoadMcpToolsetTool(mcpMgr, toolReg))
    for (ms in config.mcpServer) {
        let cfg = ms.toMcpServerConfig()
        mcpMgr.addServer(toolReg, cfg)
    }
```

   - run 命令的 AgentRuntime 构造（128 行）追加 mcpMgr
   - REPL 构造（92-94 行）追加 mcpMgr

**Step 3: 编译 + 全量回归**

Run: `cjpm build -j 16` → success
Run: `cjpm test -j 16 --no-progress` → 全部 PASSED（基线 162 + 新增 ~10）

**Step 4: Commit**

```bash
git add src/agent/runtime.cj src/server/handler.cj src/cli/repl.cj src/cli/main.cj src/server/config.cj src/server/config_test.cj
git commit -m "feat(mcp): AgentRuntime 接线（advanceTurn/工具过滤/使用标记）+ main/repl/handler 全链路"
```

---

### Task 4: 文档同步 + 最终验证 + 合并

**Files:**
- Modify: `docs/plans/2026-08-09-context-extension-design.md`（5.2 节更新 + 9.1 卡片 + 10.3 勾选）
- Modify: `docs/configuration.md`（mcpServer 配置 + load_mcp_toolset 用法）

**Step 1: 设计文档更新（spec 约定 ✅=已实现）**

- 5.2 节标注「✅ P1 已实现」：目录段（全部服务显示 version + 工具数 + 工具名/描述，激活标注）、`load_mcp_toolset` 纯激活、进程级激活状态（与参考设计的会话级差异注明）、冷却期 20 轮
- 5.1 节更新：`addServer` 保留（增强：连接成功后缓存协议信息与工具目录），`loadToolset` 为纯激活（无网络）
- 9.1 模块卡片：`tool/mcp_manager.cj` 描述更新（registerServer/loadToolset/激活状态机）；`tool/load_mcp_toolset.cj` 🚧→✅
- 10.3 P1 任务标注「✅ 已完成（2026-08-09）」

**Step 2: configuration.md 更新**

- 说明：启动仍连接全部 MCP 服务（连接不占 LLM token），但工具定义不进入 tools 段；LLM 需先调用 `load_mcp_toolset(server_id)` 激活服务（无网络、立即生效）；工具白名单需含 `load_mcp_toolset` 与 `mcp_*` 通配；目录段显示全部服务工具清单 + 激活标记

**Step 3: 最终验证**

Run: `cjpm test -j 16 --no-progress` → 全部 PASSED

**Step 4: Commit + 合并**

```bash
git add docs/plans/2026-08-09-context-extension-design.md docs/configuration.md
git commit -m "docs: P1 MCP 按服务加载完成，同步设计文档与配置文档"

git checkout master && git pull
git merge --no-ff feat/mcp-on-demand -m "merge: P1 MCP 按服务加载（load_mcp_toolset + 激活状态机 + 目录段）"
git push
git branch -d feat/mcp-on-demand
```

---

## 验收清单（✅ 已完成，2026-08-09）

- [x] `cjpm test -j 16 --no-progress`：基线 162 + 新增测试全 PASSED
- [ ] McpManager 13 单测：注册/列表、下划线服务名拒绝、serverFromToolName 解析、冷却 0 不卸载、冷却 20 卸载、markUsed 刷新、markUsedTool 刷新、isActiveTool 解析、未知服务报错、未连接报错、激活成功、已激活幂等、协议信息缓存、工具目录缓存
- [x] LoadMcpToolsetTool 3 单测：未知服务 isError、已激活 info、缺参 isError（消费 (Bool, String) 结构化返回）
- [x] 目录段 5 单测：全部服务（含未激活）显示 version/工具数/工具名/描述、激活标注 [已加载]、无服务空、ContextBuilder 首条含目录段、无 mcp 不拼接
- [x] AgentConfig.mcpCooldownTurns：默认 0、序列化往返、旧配置兼容（fromJson 缺字段=0）
- [x] McpManager 状态机 Mutex 加锁（HTTP 并发安全）
- [x] main.cj 启动行为：addServer 保留（启动连接），仅新增 LoadMcpToolsetTool 注册 + handler/REPL/runtime 接线
- [ ] main/repl/handler 三处 AgentRuntime 构造均传 mcpManager；启动不再连接 MCP（registerServer 仅保存配置）
- [ ] 旧构造重载保留（库用户不破坏）
