package atelier.context

import atelier.skill.*
import atelier.session.*
import atelier.tool.McpManager
import std.collection.*
import std.fs.*

/**
 * 提示段的**缓存稳定性**：决定它被排在系统提示的哪一段。
 *
 * 为什么需要这个标记：provider 的**前缀缓存**按「缓存前缀单元完整匹配」计费
 * （DeepSeek 官方口径），命中与未命中单价差一个数量级。系统提示里只要混进
 * 每次都变的内容（时间戳、面板状态、记忆概览），它**之后的所有内容**都会退化为未命中。
 * 所以稳定内容必须全部排在前面，动态内容一律后置。
 *
 * 判据：**「同一宿主、同一 agent，连续多次 run 之间是否逐字相同」**
 * —— 相同 → `Stable`；每次可能不同 → `Dynamic`。
 */
public enum SegmentStability {
    | Stable
    | Dynamic
}

// 宿主自定义系统提示段贡献者（扩展点：租户/合规/项目元数据/审计声明等）。
// 追加在 [Session Context] 之后、MCP/Skill 目录段之前；返回 "" 表示无内容跳过。
// 段文本自带标题格式（如 "[Tenant Rules]")——库不约束。
//
// 段按 [stability] 排序：所有 `Stable` 段在前，`Dynamic` 段在后（各自保持注入顺序）。
// 默认 `Stable`：既有实现无需改动即保持原有相对次序与语义。
public interface PromptSegmentContributor {
    func render(env: SessionEnvironment): String

    /**
     * 本段的缓存稳定性，默认 [SegmentStability.Stable]。
     *
     * 若实现返回的内容**每次 run 都可能不同**（时间戳、实时指标、面板渲染、
     * 记忆摘要……），**必须**覆写为 `Dynamic`，否则它会把后面所有内容的缓存前缀打掉。
     */
    func stability(): SegmentStability { SegmentStability.Stable }
}

public class SystemPromptBuilder {
    public init() {}

    public func build(systemPrompt: String, skillNames: ArrayList<String>,
        skills: SkillRegistry, env: SessionEnvironment,
        contributors!: ArrayList<PromptSegmentContributor> = ArrayList()): String {
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
            } catch (e: Exception) {
                // 项目规则读取失败（文件存在但不可读）：不留痕则表现为「规则莫名不生效」
                eprintln("[atelier] AGENTS.md load failed (${env.directory}): ${e.toString()}")
            }
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
        // 先稳定后动态：动态段一旦插在中间，它之后的所有内容都会退化为缓存未命中。
        // 两遍渲染而不是一趟排序——保持同类段之间的注入顺序（稳定排序）。
        for (c in contributors) {
            match (c.stability()) {
                case SegmentStability.Stable => appendSegment(sb, c.render(env))
                case _ => ()
            }
        }
        for (c in contributors) {
            match (c.stability()) {
                case SegmentStability.Dynamic => appendSegment(sb, c.render(env))
                case _ => ()
            }
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

// 追加一段贡献：空串跳过，末尾缺换行则补齐，并留一个空行分隔（既有格式不变）
func appendSegment(sb: StringBuilder, seg: String): Unit {
    if (seg == "") { return }
    sb.append(seg)
    if (!seg.endsWith("\n")) { sb.append("\n") }
    sb.append("\n")
}
