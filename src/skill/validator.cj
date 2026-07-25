package atelier.skill

import std.fs.*
import std.collection.*

public class SkillValidator {
    public init() {}

    public func validate(dir: String): ArrayList<String> {
        let errors = ArrayList<String>()
        let skillFile = Path(dir + "/SKILL.md")
        if (!exists(skillFile)) {
            errors.add("SKILL.md not found in " + dir)
            return errors
        }
        let data = try { File.readFrom(skillFile) } catch (_) {
            errors.add("Cannot read SKILL.md in " + dir)
            return errors
        }
        let text = String.fromUtf8(data)
        let lines = text.split("\n")
        if (lines.size < 2 || trim2(lines[0]) != "---") {
            errors.add("SKILL.md: missing YAML frontmatter (must start with ---)")
            return errors
        }
        var i: Int64 = 1
        var found: HashMap<String, Bool> = HashMap()
        while (i < lines.size) {
            let line = trim2(lines[Int64(i)])
            if (line == "---") { break }
            let colon = indexOf2(line, ":")
            if (colon > 0) {
                let key = trim2(subStr2(line, 0, colon))
                found[key] = true
            }
            i++
        }
        if (!found.contains("name")) { errors.add("SKILL.md: missing required 'name' field") }
        if (!found.contains("description")) { errors.add("SKILL.md: missing required 'description' field") }
        if (i >= lines.size) { errors.add("SKILL.md: frontmatter not closed (missing closing ---)") }
        errors
    }
}

func trim2(s: String): String {
    if (s == "") { return s }
    let bytes = s.toArray()
    var st: Int64 = 0
    var en = Int64(bytes.size) - 1
    while (st <= en && (bytes[Int64(st)] == 32 || bytes[Int64(st)] == 9 || bytes[Int64(st)] == 13)) { st++ }
    while (en >= st && (bytes[Int64(en)] == 32 || bytes[Int64(en)] == 9 || bytes[Int64(en)] == 10 || bytes[Int64(en)] == 13)) { en-- }
    if (st > en) { return "" }
    subStr2(s, st, en + 1)
}

func indexOf2(s: String, c: String): Int64 {
    let bytes = s.toArray()
    let target = c.toArray()
    if (target.size == 0) { return -1 }
    let tb = target[0]
    for (j in 0..bytes.size) { if (bytes[Int64(j)] == tb) { return j } }
    -1
}

func subStr2(s: String, start: Int64, end: Int64): String {
    let bytes = s.toArray()
    if (start < 0 || start >= end || end > Int64(bytes.size)) { return "" }
    let result = ArrayList<Byte>()
    for (j in start..end) { result.add(bytes[Int64(j)]) }
    let raw = Array<Byte>(result.size, repeat: 0)
    for (j in 0..result.size) { raw[j] = result[j] }
    String.fromUtf8(raw)
}
