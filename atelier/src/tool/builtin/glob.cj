package atelier.tool.builtin

import std.collection.*
import std.fs.*
import jsonvalue.*
import atelier.tool.*
import atelier.util.GitIgnoreMatcher

/**
 * List files matching a glob pattern.
 */
public class GlobTool <: Tool {
    public func name(): String {
        "glob"
    }

    public func description(): String {
        "List files matching a glob pattern. Returns matching file paths."
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("pattern", "Glob pattern to match files", required: true)
            .addEnum("noIgnore", "Skip .gitignore rules",
                ArrayList<String>(["true", "false"]), required: false)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let pattern: String = match (args["pattern"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: pattern", None, true, false)
        }

        let noIgnore: Bool = match (args["noIgnore"]) {
            case Some(JsonValue.String(s)) => s == "true"
            case _ => false
        }

        // 目录前缀里**没有**通配时，直接把前缀当搜索根（省一次全树扫描）；
        // 有通配（`src/**/*`、`**/*.mjs`）时必须从 workDir 整树走 ——
        // 否则会把 `src/**` 当成字面目录去 exists()，得到「搜索路径不存在」这种假失败。
        let segments = splitSegments(pattern)
        let root = if (ctx.workDir == "") { "." } else { ctx.workDir }
        var dirPrefix = ""
        if (segments.size > 1) {
            let head = ArrayList<String>()
            var wildcardInHead = false
            for (i in 0..segments.size - 1) {
                let seg = segments[Int64(i)]
                if (seg.contains("*") || seg.contains("?") || seg.contains("{")) { wildcardInHead = true }
                head.add(seg)
            }
            if (!wildcardInHead) { dirPrefix = String.join(head.toArray(), delimiter: "/") }
        }
        var searchRoot = root
        if (dirPrefix != "") {
            searchRoot = resolveToolPath(ctx.workDir, dirPrefix)
            if (!exists(searchRoot)) {
                return ToolResult("Search path does not exist: ${dirPrefix}", None, true, false)
            }
        }
        if (!exists(searchRoot)) {
            return ToolResult("Search path does not exist: ${searchRoot}", None, true, false)
        }

        let ign = if (noIgnore) { GitIgnoreMatcher() } else { GitIgnoreMatcher(searchRoot) }

        let matches = ArrayList<String>()
        globMatchFiles(root, searchRoot, pattern, ign, matches)
        matches.sort()

        if (matches.size == 0) {
            // 没匹配不是错误：模型据此判断"这个路径下确实没有"，报错会让它反复换写法重试
            return ToolResult("No files matching pattern: ${pattern}", None, false, false)
        }

        let output = StringBuilder()
        for (i in 0..matches.size) {
            if (i > 0) { output.append("\n") }
            output.append(matches[Int64(i)])
        }

        return ToolResult(output.toString(), None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

// 递归遍历：对每个文件用**整段 pattern** 匹配它的相对路径（支持 `**` 跨层）。
// searchRoot 只是扫描起点（有字面前缀时用来省扫描），匹配始终以 workDir 为基准。
func globMatchFiles(root: String, searchRoot: String, pattern: String, ign: GitIgnoreMatcher,
    result: ArrayList<String>): Unit {
    if (!exists(searchRoot)) { return }
    let rootPath = try {
        Path(searchRoot)
    } catch (_: Exception) {
        return
    }
    let entries = try {
        Directory.readFrom(rootPath)
    } catch (_: Exception) {
        return
    }
    for (entry in entries) {
        let childPath = rootPath.join(entry.name).toString()
        let rel = relativePath(root, childPath)
        if (ign.isIgnored(entry.name) || ign.isIgnored(rel)) { continue }
        if (entry.isDirectory()) {
            globMatchFiles(root, childPath, pattern, ign, result)
        } else if (globMatchPath(pattern, rel)) {
            result.add(rel)
        }
    }
}
