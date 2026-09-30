package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

public class WriteFileTool <: Tool {
    public func name(): String { "write_file" }
    public func description(): String {
        "Write content to a file. Returns an error if the file already exists (overwrite protection)."
    }
    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("path", "File path to write (relative to working directory)", required: true)
            .addString("content", "Content to write to the file", required: true)
            .build()
    }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let pathRel = match (args["path"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: path", None, true, false)
        }
        let content: String = match (args["content"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: content", None, true, false)
        }
        // 绝对路径原样用（拼在 workDir 后面会得到"不存在"的假失败）；相对路径挂 workDir
        let fullPath = resolveToolPath(ctx.workDir, pathRel)
        if (exists(fullPath)) {
            return ToolResult("File already exists: ${pathRel}. Use edit_file to modify an existing file.", None, true, false)
        }
        // 父目录不存在就建：模型写新项目时常直接写 src/x.ts，缺父目录会白跑一次调用
        ensureParentDir(fullPath)
        var path: Path
        try { path = Path(fullPath) } catch (_: Exception) {
            return ToolResult("Invalid file path: ${pathRel}", None, true, false)
        }
        let parentPath = path.parent
        let parentStr = parentPath.toString()
        if (parentStr != "" && !exists(parentStr)) {
            try { Directory.create(parentStr, recursive: true) } catch (e: Exception) {
                return ToolResult("Failed to create parent directories: ${e.message}", None, true, false)
            }
        }
        try { File.writeTo(fullPath, content.toArray()) } catch (e: Exception) {
            return ToolResult("Failed to write file: ${e.message}", None, true, false)
        }
        ToolResult("Successfully wrote ${content.size} bytes to ${pathRel}", None, false, false)
    }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}
