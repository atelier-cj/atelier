package atelier.tool

import jsonvalue.*
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

func mcpManagerActiveWithTools(name: String): McpManager {
    let m = McpManager()
    m.registerServer(McpServerConfig(name, "stdio", "echo", ""))
    m.updateServerInfo(name, "1.2.3", 2)
    let tools = ArrayList<(String, String)>()
    tools.add(("search_repos", "在 GitHub 上搜索仓库"))
    tools.add(("list_issues", "列出仓库 issues"))
    m.cacheServerTools(name, tools)
    m.activate(name)
    m
}

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
    let m = mcpManagerActiveWithTools("github")
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
