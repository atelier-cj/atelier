package server

// 配置模型（TOML → AgentConfig / ProviderConfig / McpServerConfig）已挪进核心：
// 下游宿主需要它，而 server 成员不参与发布（workspace 只发布 atelier 库）。
// 这里再导出一次，`import server.*` 的既有代码（含 CLI）不受影响。
public import atelier.config.*
