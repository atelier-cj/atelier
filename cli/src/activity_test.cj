package cli

import atelier.agent.*
import atelier.message.*
import std.collection.*
import std.time.MonoTime
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 回合活动归约与渲染。
 *
 * 时间全部由用例给定（`MonoTime + Duration`），不依赖真实时钟，因此断言可以精确。
 */

/** 找含指定片段的行（渲染带 ANSI 颜色，按片段断言而不是整行相等）。 */
func findLine(lines: ArrayList<String>, needle: String): String {
    for (line in lines) {
        if (line.contains(needle)) {
            return line
        }
    }
    ""
}

func hasLine(lines: ArrayList<String>, needle: String): Bool {
    findLine(lines, needle) != ""
}

func toolStart(callId: String, name: String): AgentEvent {
    ToolExecutionStartEvent(callId, name)
}

func toolEnd(callId: String, isError: Bool): AgentEvent {
    ToolExecutionEndEvent(callId, "result", isError)
}

func progress(callId: String, text: String): AgentEvent {
    ToolExecutionUpdateEvent(callId, text)
}

// ── 经过时间格式 ───────────────────────────────────────────────

@Test
func formatElapsed_buckets() {
    @Expect(formatElapsed(0), "0ms")
    @Expect(formatElapsed(999), "999ms")
    @Expect(formatElapsed(1000), "1.0s")
    @Expect(formatElapsed(1250), "1.2s")
    @Expect(formatElapsed(9949), "9.9s")
    @Expect(formatElapsed(10000), "10s")
}

// ── 快照（TUI） ───────────────────────────────────────────────

@Test
func activity_snapshotIsEmptyWithoutActivity() {
    let a = TurnActivity()
    let t = MonoTime.now()
    @Expect(a.snapshotLines(t, 80).size, 0)
    // 与本回合无关的事件不产生活动
    a.onEvent(AgentStartEvent("s"), t)
    a.onEvent(MessageStartEvent(UserMessage(ContentList.ofText("hi"), 0)), t)
    @Expect(a.snapshotLines(t, 80).size, 0)
}

@Test
func activity_runningToolShowsElapsed() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "read_file"), t0)

    let lines = a.snapshotLines(t0 + Duration.millisecond * 1250, 80)
    @Assert(hasLine(lines, "· 工具 1 次 · 进行中 1"))
    @Assert(hasLine(lines, "  ▶ read_file  (1.2s)"))
}

@Test
func activity_subCallIsNestedAndDistinct() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "run_xisp"), t0)
    a.onEvent(toolStart("run_xisp#1:ptc:1", "glob"), t0 + Duration.millisecond * 100)

    let lines = a.snapshotLines(t0 + Duration.millisecond * 600, 80)
    @Assert(hasLine(lines, "  ▶ run_xisp  (600ms)"))
    @Assert(hasLine(lines, "    ↳ glob  (500ms)"))
    @Assert(hasLine(lines, "· 工具 2 次 · 进行中 2"))
}

@Test
func activity_endDropsTheRunningLineButKeepsTheCount() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "read_file"), t0)
    a.onEvent(toolEnd("call_1", false), t0 + Duration.millisecond * 300)

    let lines = a.snapshotLines(t0 + Duration.millisecond * 900, 80)
    @Assert(hasLine(lines, "· 工具 1 次"))
    @Assert(findLine(lines, "进行中") == "")
    @Assert(findLine(lines, "▶") == "")
}

@Test
func activity_logsShowTailAndCountHidden() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "run_xisp"), t0)
    for (i in 0..8) {
        a.onEvent(progress("run_xisp#1", "line-${i}"), t0)
    }

    let lines = a.snapshotLines(t0, 80)
    // 只显示最近 5 行，更早的折成一行提示（活动区不能把会话挤掉）
    @Assert(hasLine(lines, "前面还有 3 行"))
    for (i in 3..8) {
        @Assert(hasLine(lines, "  │ line-${i}"))
    }
    @Assert(findLine(lines, "line-2") == "")
}

@Test
func activity_logsAreBoundedInMemory() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    // 保留上限 40：喂 100 行后只剩最近 40 行（l60..l99），快照显示「最近 5 行 + 隐藏 35 行」
    for (i in 0..100) {
        a.onEvent(progress("run_xisp#1", "l${i}"), t0)
    }
    let lines = a.snapshotLines(t0, 80)
    @Assert(hasLine(lines, "前面还有 35 行"))
    @Assert(hasLine(lines, "  │ l99"))
    @Assert(findLine(lines, "l1") == "")
}

@Test
func activity_multiLineLogIsSplitIntoLines() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(progress("run_xisp#1", "first\nsecond"), t0)

    let lines = a.snapshotLines(t0, 80)
    @Assert(hasLine(lines, "  │ first"))
    @Assert(hasLine(lines, "  │ second"))
}

@Test
func activity_turnStartResetsEverything() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "read_file"), t0)
    a.onEvent(progress("run_xisp#1", "stale"), t0)
    a.onEvent(TurnStartEvent(), t0 + Duration.millisecond * 10)

    @Expect(a.snapshotLines(t0, 80).size, 0)
    @Expect(a.drainNewLines().size, 0)
}

@Test
func activity_subCallEndKeepsNesting() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("run_xisp#1:ptc:1", "glob"), t0)
    a.onEvent(toolEnd("run_xisp#1:ptc:1", true), t0 + Duration.millisecond * 2100)

    let lines = a.drainNewLines()
    @Assert(hasLine(lines, "    ↳ glob"))
    @Assert(hasLine(lines, "    ✗ glob  (2.1s)"))
}

// ── 增量（只追加的呈现：pumpProgress / 一次性运行） ─────────────

@Test
func activity_drainNewLinesIsIncremental() {
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolStart("call_1", "read_file"), t0)
    let first = a.drainNewLines()
    @Expect(first.size, 1)
    @Assert(hasLine(first, "  ▶ read_file"))
    // 取走之后不再重复
    @Expect(a.drainNewLines().size, 0)

    a.onEvent(toolEnd("call_1", false), t0 + Duration.millisecond * 450)
    let second = a.drainNewLines()
    @Expect(second.size, 1)
    @Assert(hasLine(second, "  ✓ read_file  (450ms)"))
    @Expect(a.drainNewLines().size, 0)
}

@Test
func activity_endWithoutStartStillReports() {
    // 兜底：结束事件对应的开始事件可能没被观察到，不能因此丢信息或崩
    let a = TurnActivity()
    let t0 = MonoTime.now()
    a.onEvent(toolEnd("call_9", false), t0)
    @Assert(hasLine(a.drainNewLines(), "  ✓ call_9"))
}
