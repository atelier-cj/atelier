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
}
