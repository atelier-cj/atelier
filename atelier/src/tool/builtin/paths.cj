package atelier.tool.builtin

import std.collection.*
import std.fs.*

// 内置工具的路径与通配匹配公共逻辑。
//
// 两处历史坑：
// 1. 路径一律写成 `workDir + "/" + 传入值` —— 传入**绝对路径**时会被拼成
//    `<workDir>/<绝对路径>`，文件明明存在却报「不存在」；
// 2. 通配只取最后一段做匹配、目录前缀直接当搜索根 —— 于是 `src/**/*`、`**/*.mjs`
//    这类「目录前缀里也有通配」的写法一律报「搜索路径不存在」，而它们是最常用的写法。

// 把工具参数里的路径解析成实际路径：绝对路径原样用，相对路径挂到 workDir 下。
public func resolveToolPath(workDir: String, p: String): String {
    if (p == "") { return p }
    if (p.startsWith("/")) { return p }
    if (workDir == "") { return p }
    if (workDir.endsWith("/")) { return workDir + p }
    workDir + "/" + p
}

// 通配匹配：`*`（段内任意字符）、`?`（段内单字符）、`**`（跨任意层目录）、`{a,b}`（择一）。
// pattern 与 relPath 都是相对 workDir 的路径（用 `/` 分隔）。
public func globMatchPath(pattern: String, relPath: String): Bool {
    let pat = splitSegments(pattern)
    let seg = splitSegments(relPath)
    return matchSegments(pat, 0, seg, 0)
}

func splitSegments(s: String): ArrayList<String> {
    let out = ArrayList<String>()
    for (part in s.split("/")) {
        if (part != "") { out.add(part) }
    }
    out
}

func matchSegments(pat: ArrayList<String>, pi: Int64, seg: ArrayList<String>, si: Int64): Bool {
    if (pi >= pat.size) { return si >= seg.size }
    let p = pat[Int64(pi)]
    if (p == "**") {
        // ** 可以吃掉 0..N 层
        var k = si
        while (k <= seg.size) {
            if (matchSegments(pat, pi + 1, seg, k)) { return true }
            k++
        }
        return false
    }
    if (si >= seg.size) { return false }
    if (!matchOneSegment(p, seg[Int64(si)])) { return false }
    return matchSegments(pat, pi + 1, seg, si + 1)
}

// 单段匹配：先展开 {a,b}（择一），再按 * / ? 通配
func matchOneSegment(pat: String, s: String): Bool {
    for (alt in expandBraces(pat)) {
        if (wildcardMatch(alt, s)) { return true }
    }
    false
}

// {ts,md} → ["ts", "md"]；无花括号时返回自身。只支持一层（够用且可预期）。
func expandBraces(pat: String): ArrayList<String> {
    let out = ArrayList<String>()
    let open = pat.indexOf("{")
    match (open) {
        case Some(i) =>
            let close = pat.indexOf("}", i)
            match (close) {
                case Some(j) =>
                    let head = pat[0..i]
                    let body = pat[i + 1..j]
                    let tail = pat[j + 1..pat.size]
                    for (item in body.split(",")) {
                        for (rest in expandBraces(tail)) {
                            out.add(head + item + rest)
                        }
                    }
                case None => out.add(pat)
            }
        case None => out.add(pat)
    }
    out
}

// 段内通配：* 与 ?（回溯实现，长的 * 不会退化成指数）
func wildcardMatch(pat: String, s: String): Bool {
    let p = pat.toArray()
    let t = s.toArray()
    var pi: Int64 = 0
    var si: Int64 = 0
    var star: Int64 = -1
    var mark: Int64 = 0
    while (si < t.size) {
        if (pi < p.size && (p[pi] == b'?' || p[pi] == t[si])) {
            pi++
            si++
        } else if (pi < p.size && p[pi] == b'*') {
            star = pi
            mark = si
            pi++
        } else if (star >= 0) {
            pi = star + 1
            mark++
            si = mark
        } else {
            return false
        }
    }
    while (pi < p.size && p[pi] == b'*') { pi++ }
    pi >= p.size
}

// 写文件前确保父目录存在：模型写一个新项目时常常直接写 `src/x.ts`，
// 父目录不存在就失败（一次白跑的工具调用，还容易让它改成先 mkdir 再写）。
public func ensureParentDir(fullPath: String): Unit {
    let idx = fullPath.lastIndexOf("/")
    match (idx) {
        case Some(i) =>
            if (i <= 0) { return }
            let parent = fullPath[0..i]
            if (parent == "" || parent == ".") { return }
            if (exists(parent)) { return }
            try {
                Directory.create(Path(parent), recursive: true)
            } catch (_: Exception) {
                // 建不出来就交给后续写操作报错（错误信息更贴近真实原因）
                ()
            }
        case None => ()
    }
}
// 相对路径：target 去掉 base 前缀（glob 匹配以 workDir 为基准，便于 pattern 直配）
func relativePath(base: String, target: String): String {
    if (target.startsWith(base)) {
        let r = subStrGit(target, base.size, target.size)
        if (r.startsWith("/")) { subStrGit(r, 1, r.size) } else { r }
    } else { target }
}

// 字节切片（String 的 [] 是 Byte，按字节安全截取）
func subStrGit(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let buf = ArrayList<Byte>()
    for (i in start..end) { buf.add(bytes[Int64(i)]) }
    let raw = Array<Byte>(buf.size, repeat: 0)
    for (i in 0..buf.size) { raw[i] = buf[Int64(i)] }
    String.fromUtf8(raw)
}
