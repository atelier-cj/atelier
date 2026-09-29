package atelier.tool

import jsonvalue.*
import std.collection.*

func archiveArgs(start: Int64, end: Int64, summary: String): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["start_index"] = JsonValue.Number(Float64(start))
    m["end_index"] = JsonValue.Number(Float64(end))
    m["summary"] = JsonValue.String(summary)
    JsonValue.Map(m)
}

@Test
func archiveHistory_validRange() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(3, 8, "关键决策：改用 bstorm"))
    @Expect(r.isError, false)
    @Expect(r.text.contains("已归档"), true)
    @Expect(r.text.contains("3"), true)
    @Expect(r.text.contains("8"), true)
}

@Test
func archiveHistory_negativeStartError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(-1, 8, "s"))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_endBeforeStartError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(8, 3, "s"))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_emptySummaryError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), archiveArgs(3, 8, ""))
    @Expect(r.isError, true)
}

@Test
func archiveHistory_missingParamError() {
    let tool = ArchiveHistoryTool()
    let r = tool.execute(ToolContext("."), JsonValue.Map(HashMap()))
    @Expect(r.isError, true)
}
