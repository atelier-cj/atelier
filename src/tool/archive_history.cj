package atelier.tool

import jsonvalue.*
import std.collection.*

/**
 * Archive a range of conversation history into a single summary message.
 *
 * This tool marks a range of messages as archived, replacing them with
 * a summary the user provides. It does not delete original session data;
 * persistence keeps archival traces, it only affects the context seen by
 * subsequent LLM turns.
 */
public class ArchiveHistoryTool <: Tool {
    public init() {}

    public func name(): String { "archive_history" }

    public func description(): String {
        "将对话历史中指定的消息范围压缩成一条摘要，下次对话轮次生效。参数: start_index（起始消息序号，0-based）、" +
        "end_index（结束消息序号，包含）、summary（你要保留的摘要文本）。" +
        "注意：此操作不删除原始会话数据（持久化记录保留归档痕迹），只影响后续 LLM 看到的上下文。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addInteger("start_index", "起始消息序号（0-based）", required: true)
            .addInteger("end_index", "结束消息序号（包含）", required: true)
            .addString("summary", "保留的摘要文本", required: true)
            .build()
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let start: Int64 = match (args["start_index"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => return ToolResult("Missing or invalid parameter: start_index", None, true, false)
        }
        let end: Int64 = match (args["end_index"]) {
            case Some(JsonValue.Number(n)) => Int64(n)
            case _ => return ToolResult("Missing or invalid parameter: end_index", None, true, false)
        }
        let summary: String = match (args["summary"]) {
            case Some(JsonValue.String(s)) => s
            case _ => return ToolResult("Missing or invalid parameter: summary", None, true, false)
        }
        if (start < 0) {
            return ToolResult("Invalid range: start_index must be >= 0", None, true, false)
        }
        if (end < start) {
            return ToolResult("Invalid range: end_index must be >= start_index", None, true, false)
        }
        if (summary.trimAscii() == "") {
            return ToolResult("Invalid summary: must not be empty", None, true, false)
        }
        ToolResult("已归档第 " + start.toString() + " 到 " + end.toString() + " 条消息（共 " +
            (end - start + 1).toString() + " 条），摘要: " + summary, None, false, false)
    }

    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}
