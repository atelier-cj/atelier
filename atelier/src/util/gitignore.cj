package atelier.util

import std.collection.*
import std.fs.*
import std.core.*

public class GitIgnoreMatcher {
    let patterns: ArrayList<(String, Bool)>

    public init(rootDir: String) {
        this.patterns = ArrayList<(String, Bool)>()
        this.loadFrom(rootDir)
    }

    public init() {
        this.patterns = ArrayList<(String, Bool)>()
    }

    public func loadFrom(dir: String): Unit {
        let gitIgnorePath = Path(dir + "/.gitignore")
        if (!exists(gitIgnorePath)) { return }
        try {
            let data = File.readFrom(gitIgnorePath)
            let text = String.fromUtf8(data)
            for (lineRaw in text.split("\n")) {
                let line = trim2(lineRaw)
                if (line == "" || line.startsWith("#")) { continue }
                let negate = line.startsWith("!")
                let pattern = if (negate) { subStr2(line, 1, line.size) } else { line }
                this.patterns.add((pattern, negate))
            }
        } catch (e: Exception) {
            // 读失败若不留痕，表现是「这个项目的 .gitignore 形同不存在」：
            // 工具会照读本该被忽略的文件（可能含密钥），而用户看不到任何线索
            eprintln("[atelier] .gitignore load failed (${gitIgnorePath}): ${e.toString()}")
        }
    }

    public func isIgnored(path: String): Bool {
        if (this.patterns.size == 0) { return false }
        var ignored = false
        for ((pattern, negate) in this.patterns) {
            if (matchPath(path, pattern)) {
                ignored = !negate
            }
        }
        ignored
    }
}

func matchPath(path: String, pattern: String): Bool {
    let fileName = lastSegment(path)
    if (pattern.startsWith("/")) {
        let p = if (path.startsWith("/")) { subStr2(path, 1, path.size) } else { path }
        return matchSimple(p, subStr2(pattern, 1, pattern.size))
    }
    if (pattern.endsWith("/")) {
        if (!path.endsWith("/")) { return false }
        return matchSimple(path, pattern)
    }
    if (matchSimple(fileName, pattern)) { return true }
    matchSimple(path, pattern)
}

func matchSimple(name: String, pattern: String): Bool {
    if (!pattern.contains("*") && !pattern.contains("?")) {
        return name == pattern
    }
    simpleWildcard(name, pattern)
}

func simpleWildcard(name: String, pattern: String): Bool {
    let np = name.toArray()
    let pp = pattern.toArray()
    let n = Int64(np.size)
    let m = Int64(pp.size)
    var i: Int64 = 0; var j: Int64 = 0
    var starI: Int64 = -1; var starJ: Int64 = -1
    while (i < n) {
        if (j < m && (pp[Int64(j)] == np[Int64(i)] || pp[Int64(j)] == 63)) { i++; j++ }
        else if (j < m && pp[Int64(j)] == 42) { starI = i; starJ = j; j++ }
        else if (starJ >= 0) { i = starI + 1; starI = i; j = starJ + 1 }
        else { return false }
    }
    while (j < m && pp[Int64(j)] == 42) { j++ }
    j == m
}

func lastSegment(path: String): String {
    let idx = lastIndexOf2(path, "/")
    match (idx) {
        case Some(p) => subStr2(path, p + 1, path.size)
        case None => path
    }
}

func lastIndexOf2(s: String, c: String): Option<Int64> {
    let bytes = s.toArray()
    let tb = c.toArray()
    if (tb.size == 0) { return None }
    var i = bytes.size - 1
    while (i >= 0) {
        if (bytes[Int64(i)] == tb[0]) { return Some(i) }
        i--
    }
    None
}

func subStr2(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let buf = ArrayList<Byte>()
    for (i in start..end) { buf.add(bytes[Int64(i)]) }
    let raw = Array<Byte>(buf.size, repeat: 0)
    for (i in 0..buf.size) { raw[i] = buf[Int64(i)] }
    String.fromUtf8(raw)
}

func trim2(s: String): String {
    let bytes = s.toArray()
    var start: Int64 = 0
    var end = Int64(bytes.size) - 1
    while (start <= end && bytes[Int64(start)] <= 32) { start++ }
    while (end >= start && bytes[Int64(end)] <= 32) { end-- }
    if (start > end) { return "" }
    let raw = Array<Byte>(end - start + 1, repeat: 0)
    for (i in start..=end) { raw[Int64(i - start)] = bytes[Int64(i)] }
    String.fromUtf8(raw)
}
