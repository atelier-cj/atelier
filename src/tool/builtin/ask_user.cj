package atelier.tool.builtin

import atelier.tool.*
import jsonvalue.*
import std.collection.*

public class AskUserTool <: Tool {
    public func name(): String { "ask_user" }

    public func description(): String {
        "Ask the user a question and wait for their response. Use this when you need clarification, confirmation, or additional information from the user."
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("question", "The question to ask the user", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let question: String = match (args["question"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing required parameter: question", None, true, false)
        }
        let answer = ctx.askUser(question)
        ToolResult(answer, None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Parallel
    }

    /**
     * 不限时：本工具的时间花在**等人回答**上。
     *
     * 框架预算的用途是兜住「工具卡死」，而人思考多久都不算卡死——套上预算的
     * 后果是：用户想了 31 秒，模型却收到一句「超时、调用已被放弃」。
     */
    public func timeoutBudget(): ToolBudget {
        ToolBudget.Unbounded
    }
}
