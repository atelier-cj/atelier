package atelier.tool.builtin

import std.fs.*
import std.collection.*
import stdx.encoding.json.stream.*
import jsonvalue.*
import atelier.tool.*

public class ReadFileTool <: Tool {
    public func name(): String { "read_file" }
    public func description(): String {
        "Read file content from disk. Returns text content with line numbers. Supports offset/limit for pagination."
    }
    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("path", "File path to read (relative to working directory)", required: true)
            .addInteger("offset", "Line number to start from (0-indexed)")
            .addInteger("limit", "Maximum number of lines to return")
            .build()
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let p = match (args) {
            case JsonValue.String(s) => JsonValue.toObject<ReadArgs>(JsonValue.parse(s))
            case _ => JsonValue.toObject<ReadArgs>(args)
        }
        let fullPath: String = if (ctx.workDir == "") { p.path } else { ctx.workDir + "/" + p.path }
        if (!exists(fullPath)) {
            return ToolResult("File not found: ${p.path}", None, true, false)
        }
        let bytes = try { File.readFrom(fullPath) } catch (e: Exception) {
            return ToolResult("Failed to read file: ${e.message}", None, true, false)
        }
        let content: String = String.fromUtf8(bytes)
        let lines = content.split("\n")
        let totalLines = lines.size
        let startIdx: Int64 = if (p.offset < 0) { 0 } else if (p.offset >= totalLines) { totalLines - 1 } else { p.offset }
        let endIdx: Int64 = if (p.limit < 0) { totalLines } else {
            let candidate = startIdx + p.limit
            if (candidate > totalLines) { totalLines } else { candidate }
        }
        let output = StringBuilder()
        var idx = startIdx
        while (idx < endIdx) {
            output.append("${idx + 1}: ${lines[Int64(idx)]}")
            if (idx < endIdx - 1) { output.append("\n") }
            idx = idx + 1
        }
        ToolResult(output.toString(), None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

struct ReadArgs <: JsonDeserializable<ReadArgs> {
    var path: String = ""
    var offset: Int64 = 0
    var limit: Int64 = -1
    public init() {}
    public static func fromJson(r: JsonReader): ReadArgs {
        var res = ReadArgs()
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "path" => res.path = r.readValue<String>()
                case "offset" => res.offset = r.readValue<Int64>()
                case "limit" => res.limit = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        res
    }
}
