package atelier.tool.builtin

import atelier.skill.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*
import std.fs.*

public class UseSkillsTool <: Tool {
    private let skillRegistry: SkillRegistry

    public init(skillRegistry: SkillRegistry) {
        this.skillRegistry = skillRegistry
    }

    public func name(): String { "use_skills" }

    public func description(): String {
        "按名称加载一个 Skill 的完整指令到对话上下文。参数: name（技能名，如 \"code-review\"）。" +
        "加载后指令立即生效，后续对话按技能流程执行。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("name", "Skill 名称", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let name: String = match (args["name"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: name", None, true, false)
        }
        match (this.skillRegistry.get(name)) {
            case Some(skill) =>
                let resources = listSkillResources(skill.dirPath)
                var text = "# Skill: " + skill.name + "\n\n" + skill.instructions
                if (resources.size > 0) {
                    text = text + "\n\n## 资源文件\n（可用 read_file 按需读取）\n"
                    for (r in resources) {
                        text = text + "- " + r + "\n"
                    }
                }
                ToolResult(text, None, false, false)
            case None =>
                ToolResult("未知 Skill: " + name, None, true, false)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}

// 列出 skill 目录下第一层子目录（references/scripts/assets 等）中的资源文件相对路径
func listSkillResources(skillDir: String): ArrayList<String> {
    let result = ArrayList<String>()
    if (skillDir == "") { return result }
    let root = Path(skillDir)
    if (!exists(root)) { return result }
    let entries = try { Directory.readFrom(root) } catch (_) { return result }
    for (info in entries) {
        if (info.isDirectory()) {
            let sub = Path(skillDir + "/" + info.name)
            let files = try { Directory.readFrom(sub) } catch (_) { continue }
            for (f in files) {
                if (!f.isDirectory()) {
                    result.add(info.name + "/" + f.name)
                }
            }
        }
    }
    result
}
