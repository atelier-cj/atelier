package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Read file content from disk.
 * Supports offset/limit for pagination with line numbers.
 */
public class ReadFileTool <: Tool {
    public func name(): String {
        "read_file"
    }

    public func description(): String {
        "Read file content from disk. Returns text content with line numbers. Supports offset/limit for pagination."
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))

        let properties = HashMap<String, JsonValue>()

        let pathProp = HashMap<String, JsonValue>()
        pathProp.add("type", JsonValue.String("string"))
        pathProp.add("description", JsonValue.String("File path to read (relative to working directory)"))
        properties.add("path", JsonValue.Map(pathProp))

        let offsetProp = HashMap<String, JsonValue>()
        offsetProp.add("type", JsonValue.String("integer"))
        offsetProp.add("description", JsonValue.String("Line number to start from (0-indexed)"))
        properties.add("offset", JsonValue.Map(offsetProp))

        let limitProp = HashMap<String, JsonValue>()
        limitProp.add("type", JsonValue.String("integer"))
        limitProp.add("description", JsonValue.String("Maximum number of lines to return"))
        properties.add("limit", JsonValue.Map(limitProp))

        obj.add("properties", JsonValue.Map(properties))

        let required = ArrayList<JsonValue>()
        required.add(JsonValue.String("path"))
        obj.add("required", JsonValue.Array(required))

        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let pathRel = match (args["path"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: path", None, true, false)
        }
        let fullPath: String = if (ctx.workDir == "") { pathRel } else { ctx.workDir + "/" + pathRel }

        // Check if file exists
        if (!exists(fullPath)) {
            return ToolResult("File not found: ${pathRel}", None, true, false)
        }

        let offset: Int64 = match (args["offset"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => 0
        }
        let limit: Int64 = match (args["limit"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => -1
        }

        // Read file content
        let bytes = try {
            File.readFrom(fullPath)
        } catch (e: Exception) {
            return ToolResult("Failed to read file: ${e.message}", None, true, false)
        }

        let content: String = String.fromUtf8(bytes)
        let lines = content.split("\n")

        // Apply offset and limit
        let totalLines = lines.size
        let startIdx: Int64 = if (offset < 0) { 0 } else if (offset >= totalLines) { totalLines - 1 } else { offset }
        let endIdx: Int64 = if (limit < 0) { totalLines } else {
            let candidate = startIdx + limit
            if (candidate > totalLines) { totalLines } else { candidate }
        }

        // Build output with line numbers
        let output = StringBuilder()
        var idx = startIdx
        while (idx < endIdx) {
            output.append("${idx + 1}: ${lines[Int64(idx)]}")
            if (idx < endIdx - 1) {
                output.append("\n")
            }
            idx = idx + 1
        }

        return ToolResult(output.toString(), None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}
