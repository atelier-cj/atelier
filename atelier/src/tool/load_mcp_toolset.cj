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
        "按需激活一个 MCP 服务，其工具定义进入可用工具列表。参数: server_id（服务标识符，如 \"github\"）。" +
        "激活后该服务的所有 mcp_<server>_<tool> 工具在后续对话中可被调用。"
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
