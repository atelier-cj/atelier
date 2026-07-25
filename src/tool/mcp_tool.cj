package atelier.tool

import jsonvalue.*
import std.collection.*
import mcp.McpClient
import mcp.types.{Tool as McpToolDef, CallToolResult, ContentBlock, ToolInputSchema}
import mcp.types.TextContent
import ystyle::jsonrpc.Result

public class MCPToolWrapper <: Tool {
    private let client: McpClient
    private let toolDef: McpToolDef
    private let execMode: ToolExecutionMode

    public init(client: McpClient, toolDef: McpToolDef, execMode!: ToolExecutionMode = ToolExecutionMode.Parallel) {
        this.client = client
        this.toolDef = toolDef
        this.execMode = execMode
    }

    public func name(): String { this.toolDef.name }

    public func description(): String { this.toolDef.description }

    public func schema(): JsonValue {
        let def = this.toolDef.inputSchema
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String(def.typ))
        obj.add("properties", JsonValue.Map(def.properties))
        if (!def.required.isEmpty()) {
            let req = ArrayList<JsonValue>()
            for (r in def.required) { req.add(JsonValue.String(r)) }
            obj.add("required", JsonValue.Array(req))
        }
        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let argsMap = match (args) {
            case JsonValue.Map(m) => m
            case _ => return ToolResult("Invalid arguments: expected object", None, true, false)
        }
        match (this.client.callTool(this.toolDef.name, arguments: argsMap)) {
            case Result.Ok(callResult) =>
                let text = extractText(callResult)
                ToolResult(text, None, callResult.isError, false)
            case Result.Err(e) =>
                ToolResult("MCP tool call failed: ${e}", None, true, false)
        }
    }

    public func executionMode(): ToolExecutionMode { this.execMode }
}

func extractText(result: CallToolResult): String {
    let buf = StringBuilder()
    for (block in result.content) {
        match (block) {
            case ContentBlock.Text(tc) =>
                if (buf.size > 0) { buf.append("\n") }
                buf.append(tc.text)
            case _ => ()
        }
    }
    buf.toString()
}
