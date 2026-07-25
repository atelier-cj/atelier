package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Write content to a file.
 * Overwrite protection: returns error if file already exists.
 */
public class WriteFileTool <: Tool {
    public func name(): String {
        "write_file"
    }

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
        let fullPath: String = if (ctx.workDir == "") { pathRel } else { ctx.workDir + "/" + pathRel }

        // Overwrite protection: check if file already exists
        if (exists(fullPath)) {
            return ToolResult("File already exists: ${pathRel}. Use edit_file to modify an existing file.", None, true, false)
        }

        // Create parent directories if needed
        var path: Path
        try {
            path = Path(fullPath)
        } catch (_: Exception) {
            return ToolResult("Invalid file path: ${pathRel}", None, true, false)
        }

        let parentPath = path.parent
        let parentStr = parentPath.toString()
        if (parentStr != "" && !exists(parentStr)) {
            try {
                Directory.create(parentStr, recursive: true)
            } catch (e: Exception) {
                return ToolResult("Failed to create parent directories: ${e.message}", None, true, false)
            }
        }

        // Write content to file
        try {
            File.writeTo(fullPath, content.toArray())
        } catch (e: Exception) {
            return ToolResult("Failed to write file: ${e.message}", None, true, false)
        }

        return ToolResult("Successfully wrote ${content.size} bytes to ${pathRel}", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}
