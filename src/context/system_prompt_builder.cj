package atelier.context

import atelier.skill.*
import atelier.session.*
import atelier.tool.McpManager
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

    // 渐进披露第 1 层：MCP 服务目录段
    // 全部服务（含未激活）显示 name (version, N 工具) + 工具名: 描述（启动 addServer 已缓存）；
    // 激活服务标注 [已加载]（tools 段才有完整 schema 定义）
    public func buildMcpCatalog(mcpManager: McpManager): String {
        if (mcpManager.serverCount() == 0) { return "" }
        let sb = StringBuilder()
        sb.append("[可用 MCP 服务]\n")
        sb.append("调用 load_mcp_toolset(server_id) 激活服务，激活后其完整工具定义进入可用工具列表。\n")
        for (name in mcpManager.serverNames()) {
            sb.append("- ")
            sb.append(name)
            let version = match (mcpManager.serverVersion(name)) {
                case Some(v) => v
                case None => "?"
            }
            let count = match (mcpManager.serverToolCount(name)) {
                case Some(c) => c.toString()
                case None => "?"
            }
            sb.append(" (v")
            sb.append(version)
            sb.append(", ")
            sb.append(count)
            sb.append(" 个工具)")
            if (mcpManager.isActive(name, 0)) {
                sb.append(" [已加载]")
            }
            for (t in mcpManager.serverToolsOf(name)) {
                sb.append("\n  - ")
                sb.append(t[0])
                if (t[1] != "") {
                    sb.append(": ")
                    sb.append(t[1])
                }
            }
            sb.append("\n")
        }
        sb.append("\n")
        sb.toString()
    }

    // 渐进披露第 1 层：Skill 目录段（name + description + use_skills 引导语；无 skill 返回 ""）
    public func buildSkillCatalog(skillRegistry: SkillRegistry): String {
        let skills = skillRegistry.list()
        if (skills.size == 0) { return "" }
        let sb = StringBuilder()
        sb.append("[可用 Skills]\n")
        sb.append("调用 use_skills(name) 加载对应技能的完整指令。\n")
        for (s in skills) {
            sb.append("- ")
            sb.append(s.name)
            if (s.description != "") {
                sb.append(": ")
                sb.append(s.description)
            }
            sb.append("\n")
        }
        sb.append("\n")
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
