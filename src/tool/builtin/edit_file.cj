package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Edit a file by replacing oldString with newString.
 * Checks uniqueness: if oldString matches more than once, returns an error.
 * If oldString not found, returns an error.
 */
public class EditFileTool <: Tool {
    public func name(): String {
        "edit_file"
    }

    public func description(): String {
        "Edit a file by replacing oldString with newString. Only works if oldString matches exactly once."
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))

        let properties = HashMap<String, JsonValue>()

        let pathProp = HashMap<String, JsonValue>()
        pathProp.add("type", JsonValue.String("string"))
        pathProp.add("description", JsonValue.String("File path to edit (relative to working directory)"))
        properties.add("path", JsonValue.Map(pathProp))

        let oldStringProp = HashMap<String, JsonValue>()
        oldStringProp.add("type", JsonValue.String("string"))
        oldStringProp.add("description", JsonValue.String("Text to replace"))
        properties.add("oldString", JsonValue.Map(oldStringProp))

        let newStringProp = HashMap<String, JsonValue>()
        newStringProp.add("type", JsonValue.String("string"))
        newStringProp.add("description", JsonValue.String("Replacement text"))
        properties.add("newString", JsonValue.Map(newStringProp))

        obj.add("properties", JsonValue.Map(properties))

        let required = ArrayList<JsonValue>()
        required.add(JsonValue.String("path"))
        required.add(JsonValue.String("oldString"))
        required.add(JsonValue.String("newString"))
        obj.add("required", JsonValue.Array(required))

        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let pathRel = match (args["path"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: path", None, true, false)
        }
        let oldString: String = match (args["oldString"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: oldString", None, true, false)
        }
        let newString: String = match (args["newString"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: newString", None, true, false)
        }
        let fullPath: String = if (ctx.workDir == "") { pathRel } else { ctx.workDir + "/" + pathRel }

        // Check if file exists
        if (!exists(fullPath)) {
            return ToolResult("File not found: ${pathRel}", None, true, false)
        }

        // Read file content
        let bytes = try {
            File.readFrom(fullPath)
        } catch (e: Exception) {
            return ToolResult("Failed to read file: ${e.message}", None, true, false)
        }

        let content: String = String.fromUtf8(bytes)

        // Count occurrences of oldString
        var count: Int64 = 0
        var searchFrom: Int64 = 0
        let contentLen = content.size
        let oldLen = oldString.size

        while (searchFrom < contentLen) {
            let idx = content.indexOf(oldString, searchFrom)
            match (idx) {
                case Some(pos) =>
                    count = count + 1
                    searchFrom = pos + oldLen
                case None =>
                    break
            }
        }

        if (count == 0) {
            return ToolResult("oldString not found in file: ${pathRel}", None, true, false)
        }
        if (count > 1) {
            return ToolResult("Found multiple matches (${count}) of oldString in file: ${pathRel}. Edit requires exactly one match.", None, true, false)
        }

        // Perform the replacement
        let newContent = content.replace(oldString, newString)

        // Write the modified content back
        try {
            File.writeTo(fullPath, newContent.toArray())
        } catch (e: Exception) {
            return ToolResult("Failed to write file after edit: ${e.message}", None, true, false)
        }

        return ToolResult("Successfully replaced 1 occurrence in ${pathRel}", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}
