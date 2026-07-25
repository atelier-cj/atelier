package atelier.tool.builtin

import std.fs.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * Search files matching a glob pattern for a pattern string.
 * Returns matching file paths with line numbers.
 */
public class GrepTool <: Tool {
    public func name(): String {
        "grep"
    }

    public func description(): String {
        "Search files matching a glob pattern for a text pattern. Returns matching file paths with line numbers."
    }

    public func schema(): JsonValue {
        let obj = HashMap<String, JsonValue>()
        obj.add("type", JsonValue.String("object"))

        let properties = HashMap<String, JsonValue>()

        let patternProp = HashMap<String, JsonValue>()
        patternProp.add("type", JsonValue.String("string"))
        patternProp.add("description", JsonValue.String("Pattern to search for"))
        properties.add("pattern", JsonValue.Map(patternProp))

        let pathGlobProp = HashMap<String, JsonValue>()
        pathGlobProp.add("type", JsonValue.String("string"))
        pathGlobProp.add("description", JsonValue.String("Glob pattern for files to search (default: \".\")"))
        properties.add("pathGlob", JsonValue.Map(pathGlobProp))

        obj.add("properties", JsonValue.Map(properties))

        let required = ArrayList<JsonValue>()
        required.add(JsonValue.String("pattern"))
        obj.add("required", JsonValue.Array(required))

        JsonValue.Map(obj)
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let pattern: String = match (args["pattern"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: pattern", None, true, false)
        }
        let pathGlob: String = match (args["pathGlob"]) {
            case Some(JsonValue.String(s)) => s
            case _ => "."
        }

        // Determine search root
        let searchRoot: String = if (ctx.workDir == "") { pathGlob } else {
            if (pathGlob == "." || pathGlob == "") {
                ctx.workDir
            } else {
                ctx.workDir + "/" + pathGlob
            }
        }

        if (!exists(searchRoot)) {
            return ToolResult("Search path does not exist: ${pathGlob}", None, true, false)
        }

        // Collect files to search recursively
        let files = ArrayList<String>()
        collectFiles(searchRoot, files)

        // Search each file for the pattern
        let outputLines = ArrayList<String>()

        for (filePath in files) {
            let bytes = try {
                File.readFrom(filePath)
            } catch (_: Exception) {
                continue
            }
            let content = String.fromUtf8(bytes)
            let lines = content.split("\n")

            var lineNum: Int64 = 1
            for (i in 0..lines.size) {
                let line = lines[Int64(i)]
                if (line.contains(pattern)) {
                    outputLines.add("${filePath}:${lineNum}: ${line}")
                }
                lineNum = lineNum + 1
            }
        }

        if (outputLines.size == 0) {
            return ToolResult("No matches found for pattern: ${pattern}", None, false, false)
        }

        let output = StringBuilder()
        for (i in 0..outputLines.size) {
            if (i > 0) { output.append("\n") }
            output.append(outputLines[i])
        }

        return ToolResult(output.toString(), None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

func collectFiles(root: String, result: ArrayList<String>): Unit {
    if (!exists(root)) {
        return
    }

    let rootPath = try {
        Path(root)
    } catch (_: Exception) {
        return
    }

    let entries = try {
        Directory.readFrom(rootPath)
    } catch (_: FSException) {
        result.add(root)
        return
    } catch (_: Exception) {
        return
    }

    for (entry in entries) {
        let childPath = rootPath.join(entry.name).toString()
        if (entry.isDirectory()) {
            collectFiles(childPath, result)
        } else {
            result.add(childPath)
        }
    }
}
