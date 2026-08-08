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
func mcpManager_activationAndCooldown() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    @Expect(m.isActive("github"), true)
    @Expect(m.isActive("slack"), false)
    var i: Int64 = 0
    while (i < McpManager.COOLDOWN_TURNS) { m.advanceTurn(); i++ }
    @Expect(m.isActive("github"), false)
}

@Test
func mcpManager_markUsedKeepsActive() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    var i: Int64 = 0
    while (i < McpManager.COOLDOWN_TURNS - 1) { m.advanceTurn(); i++ }
    m.markUsed("github")
    m.advanceTurn()
    @Expect(m.isActive("github"), true)
}

@Test
func mcpManager_markUsedToolRefreshes() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    var i: Int64 = 0
    while (i < McpManager.COOLDOWN_TURNS - 1) { m.advanceTurn(); i++ }
    m.markUsedTool("mcp_github_search_repos")
    m.advanceTurn()
    @Expect(m.isActive("github"), true)
}

@Test
func mcpManager_isActiveToolResolvesServer() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    m.activate("github")
    @Expect(m.isActiveTool("mcp_github_search_repos"), true)
    @Expect(m.isActiveTool("mcp_slack_send"), false)
    @Expect(m.isActiveTool("read_file"), false)
}

@Test
func mcpManager_loadToolsetUnknownServer() {
    let m = McpManager()
    let reg = ToolRegistry()
    let r = m.loadToolset(reg, "nope")
    @Expect(r.contains("未知"), true)
    @Expect(m.isActive("nope"), false)
}

@Test
func mcpManager_loadToolsetNotConnected() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    let r = m.loadToolset(reg, "github")
    @Expect(r.contains("未连接"), true)
    @Expect(m.isActive("github"), false)
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
    @Expect(m.isActive("github"), true)
    @Expect(r.contains("已加载"), true)
}

@Test
func mcpManager_loadToolsetAlreadyActiveIdempotent() {
    let m = McpManager()
    m.registerServer(mcpCfg("github"))
    let reg = ToolRegistry()
    m.activate("github")
    let r = m.loadToolset(reg, "github")
    @Expect(r.contains("已加载"), true)
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
