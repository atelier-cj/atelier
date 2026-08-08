package atelier.context

import atelier.skill.*
import atelier.session.*
import std.collection.*
import std.fs.*

public class SystemPromptBuilder {
    public init() {}

    public func build(systemPrompt: String, skillNames: ArrayList<String>,
        skills: SkillRegistry, env: SessionEnvironment): String {
        let sb = StringBuilder()
        if (systemPrompt != "") {
            sb.append(systemPrompt)
            sb.append("\n\n")
        }
        for (name in skillNames) {
            match (skills.get(name)) {
                case Some(skill) =>
                    sb.append(skill.instructions)
                    sb.append("\n\n")
                case None => ()
            }
        }
        if (env.directory != "") {
            try {
                let agentsPath = env.directory + "/AGENTS.md"
                let p = Path(agentsPath)
                if (exists(p)) {
                    let content = readFileText(p)
                    if (content != "") {
                        sb.append("[Project Rules]\n")
                        sb.append(content)
                        sb.append("\n\n")
                    }
                }
            } catch (_: Exception) {}
        }
        if (env.context.size > 0) {
            sb.append("[Session Context]\n")
            for ((k, v) in env.context) {
                sb.append(k)
                sb.append(" = ")
                sb.append(v)
                sb.append("\n")
            }
            sb.append("\n")
        }
        sb.toString()
    }
}

func readFileText(p: Path): String {
    let f = File(p, OpenMode.Read)
    let buf = Array<Byte>(4096, repeat: 0)
    let all = ArrayList<Byte>()
    while (true) {
        let n = f.read(buf)
        if (n <= 0) { break }
        for (i in 0..n) { all.add(buf[Int64(i)]) }
    }
    f.close()
    let raw = Array<Byte>(all.size, repeat: 0)
    for (i in 0..all.size) { raw[i] = all[i] }
    String.fromUtf8(raw)
}
