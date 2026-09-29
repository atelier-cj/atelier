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

        // Split pattern into directory and file pattern parts
        let parts = pattern.split("/")
        let filePattern = parts[parts.size - 1]

        // Build the directory prefix from all parts except the last
        var searchRoot: String
        if (parts.size > 1) {
            var dirBuilder = ""
            for (i in 0..parts.size - 1) {
                if (i > 0) { dirBuilder = dirBuilder + "/" }
                dirBuilder = dirBuilder + parts[Int64(i)]
            }
            searchRoot = if (ctx.workDir == "") { dirBuilder } else { ctx.workDir + "/" + dirBuilder }
        } else {
            searchRoot = if (ctx.workDir == "") { "." } else { ctx.workDir }
        }

        if (!exists(searchRoot)) {
            return ToolResult("Search path does not exist: ${searchRoot}", None, true, false)
        }

        let ign = if (noIgnore) { GitIgnoreMatcher() } else { GitIgnoreMatcher(searchRoot) }

        // Collect matching files
        let matches = ArrayList<String>()
        globMatchFiles(searchRoot, filePattern, ign, matches)

        if (matches.size == 0) {
            return ToolResult("No files matching pattern: ${pattern}", None, false, false)
        }

        let output = StringBuilder()
        for (i in 0..matches.size) {
            if (i > 0) { output.append("\n") }
            output.append(matches[i])
        }

        return ToolResult(output.toString(), None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

func globMatchFiles(root: String, pattern: String, ign: GitIgnoreMatcher, result: ArrayList<String>): Unit {
    if (!exists(root)) {
        return
    }

    let rootPath = try {
        Path(root)
    } catch (_: Exception) {
        return
    }

    let hasWildcard = pattern.contains("*")

    let entries = try {
        Directory.readFrom(rootPath)
    } catch (_: Exception) {
        return
    }

    for (entry in entries) {
        let childPath = rootPath.join(entry.name).toString()
        if (ign.isIgnored(entry.name) || ign.isIgnored(relativePath(root, childPath))) {
            continue
        }
        if (entry.isDirectory()) {
            globMatchFiles(childPath, pattern, ign, result)
        } else {
            if (hasWildcard) {
                if (simpleGlobMatch(entry.name, pattern)) {
                    result.add(childPath)
                }
            } else {
                if (entry.name == pattern) {
                    result.add(childPath)
                }
            }
        }
    }
}

func relativePath(base: String, target: String): String {
    if (target.startsWith(base)) {
        let r = subStrGit(target, base.size, target.size)
        if (r.startsWith("/")) { subStrGit(r, 1, r.size) } else { r }
    } else { target }
}

func subStrGit(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let buf = ArrayList<Byte>()
    for (i in start..end) { buf.add(bytes[Int64(i)]) }
    let raw = Array<Byte>(buf.size, repeat: 0)
    for (i in 0..buf.size) { raw[i] = buf[Int64(i)] }
    String.fromUtf8(raw)
}

func simpleGlobMatch(name: String, pattern: String): Bool {
    let starIdx = pattern.indexOf("*", 0)
    match (starIdx) {
        case None =>
            return name == pattern
        case Some(pos) =>
            let prefix = takePrefix(pattern, pos)
            let suffix = takeSuffix(pattern, pos + 1)

            if (prefix != "" && !name.startsWith(prefix)) {
                return false
            }

            if (suffix != "" && !name.endsWith(suffix)) {
                return false
            }

            if (prefix == "" || suffix == "") {
                return true
            }

            // For "prefix*suffix", ensure prefix appears before suffix
            let prefixFound = name.indexOf(prefix, 0)
            match (prefixFound) {
                case None => return false
                case Some(prefixPos) =>
                    let afterPrefix = prefixPos + prefix.size
                    let suffixFound = name.indexOf(suffix, afterPrefix)
                    match (suffixFound) {
                        case None => return false
                        case Some(_) => return true
                    }
            }
    }
}

// Helper: get string prefix up to position pos (exclusive)
func takePrefix(s: String, pos: Int64): String {
    let bytes = s.toArray()
    let prefixBytes = bytes.slice(0, pos)
    String.fromUtf8(prefixBytes)
}

// Helper: get string suffix from position pos (inclusive)
func takeSuffix(s: String, pos: Int64): String {
    let bytes = s.toArray()
    let remaining = bytes.size - pos
    if (remaining <= 0) { return "" }
    let suffixBytes = bytes.slice(pos, remaining)
    String.fromUtf8(suffixBytes)
}
