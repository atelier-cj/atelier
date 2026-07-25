package atelier.skill

import std.fs.*
import std.collection.*

public class SkillLoader {
    public init() {}

    public func loadDir(dir: String): ArrayList<Skill> {
        let result = ArrayList<Skill>()
        let path = Path(dir)
        if (!exists(path)) { return result }
        let entries = Directory.readFrom(path)
        for (info in entries) {
            if (info.isDirectory()) {
                let skillPath = Path(dir + "/" + info.name)
                let skill = try { loadSkill(skillPath.toString()) } catch (_) { continue }
                result.add(skill)
            }
        }
        result
    }

    public func loadSkill(dir: String): Skill {
        let skillFile = Path(dir + "/SKILL.md")
        if (!exists(skillFile)) { throw Exception("SKILL.md not found in " + dir) }
        let data = File.readFrom(skillFile)
        let text = String.fromUtf8(data)
        let (frontmatter, body) = parseFrontmatter(text)
        let name = getOr(frontmatter.get("name"), "")
        validateName(name, dir)
        let desc = getOr(frontmatter.get("description"), "")
        Skill(name, desc,
            frontmatter.get("license"),
            frontmatter.get("compatibility"),
            parseMetadata(getOr(frontmatter.get("metadata"), "")),
            parseAllowedTools(getOr(frontmatter.get("allowed-tools"), "")),
            body, dir)
    }
}

func getOr(v: Option<String>, def: String): String {
    match (v) { case Some(s) => s; case None => def }
}

func parseFrontmatter(text: String): (HashMap<String, String>, String) {
    let map = HashMap<String, String>()
    let lines = text.split("\n")
    if (lines.size < 2) { return (map, text) }
    if (trim(lines[0]) != "---") { return (map, text) }
    var i: Int64 = 1
    while (i < lines.size) {
        if (trim(lines[Int64(i)]) == "---") { i++; break }
        let line = lines[Int64(i)]
        let colonIdx = indexOf(line, ":")
        if (colonIdx > 0) {
            let key = trim(subStr(line, 0, colonIdx))
            let value = trim(subStr(line, colonIdx + 1, line.size))
            if (key != "" && value != "") { map[key] = value }
        }
        i++
    }
    let bodyParts = ArrayList<String>()
    while (i < lines.size) { bodyParts.add(lines[Int64(i)]); i++ }
    (map, joinLines(bodyParts))
}

func indexOf(s: String, c: String): Int64 {
    let bytes = s.toArray()
    let target = c.toArray()
    if (target.size == 0) { return -1 }
    let tb = target[0]
    for (j in 0..bytes.size) {
        if (bytes[Int64(j)] == tb) { return j }
    }
    -1
}

func subStr(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let result = ArrayList<Byte>()
    for (j in start..end) { result.add(bytes[Int64(j)]) }
    let raw = Array<Byte>(result.size, repeat: 0)
    for (j in 0..result.size) { raw[j] = result[j] }
    String.fromUtf8(raw)
}

func joinLines(parts: ArrayList<String>): String {
    var r = ""
    var first = true
    for (p in parts) {
        if (!first) { r = r + "\n" }
        r = r + p
        first = false
    }
    r
}

func trim(s: String): String {
    if (s == "") { return s }
    let bytes = s.toArray()
    var start: Int64 = 0
    var end = Int64(bytes.size) - 1
    while (start <= end && (bytes[Int64(start)] == 32 || bytes[Int64(start)] == 9 || bytes[Int64(start)] == 13)) { start++ }
    while (end >= start && (bytes[Int64(end)] == 32 || bytes[Int64(end)] == 9 || bytes[Int64(end)] == 10 || bytes[Int64(end)] == 13)) { end-- }
    if (start > end) { return "" }
    subStr(s, start, end + 1)
}

func validateName(name: String, dir: String): Unit {
    if (name == "") { return }
    let bytes = name.toArray()
    for (b in bytes) {
        if (!((b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 45)) {
            throw Exception("Invalid name '" + name + "': use lowercase alphanumeric + hyphens")
        }
    }
}

func parseMetadata(s: String): HashMap<String, String> {
    let map = HashMap<String, String>()
    var t = trim(s)
    if (t.startsWith("{") && t.endsWith("}")) {
        t = trim(subStr(t, 1, t.size - 1))
        for (pair in t.split(",")) {
            let colon = indexOf(pair, ":")
            if (colon > 0) {
                let k = trim(subStr(pair, 0, colon))
                let v = trim(subStr(pair, colon + 1, pair.size))
                if (k != "") { map[k] = v }
            }
        }
    }
    map
}

func parseAllowedTools(s: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (t in s.split(" ")) {
        let trimmed = trim(t)
        if (trimmed != "") { result.add(trimmed) }
    }
    result
}
