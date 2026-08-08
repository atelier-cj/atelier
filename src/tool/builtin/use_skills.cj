package atelier.tool.builtin

import atelier.skill.*
import atelier.tool.*
import jsonvalue.*
import std.collection.*

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
                let text = "# Skill: " + skill.name + "\n\n" + skill.instructions
                ToolResult(text, None, false, false)
            case None =>
                ToolResult("未知 Skill: " + name, None, true, false)
        }
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }
}
