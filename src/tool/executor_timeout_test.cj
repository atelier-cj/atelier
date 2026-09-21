package atelier.tool

import std.collection.*
import std.sync.*
import std.time.*
import jsonvalue.*
import std.unittest.*
import std.unittest.testmacro.*

/**
 * 工具预算（`AgentConfig.toolTimeout`）的行为验证。
 *
 * 时间断言一律留大余量：这些用例要证明的是「预算生效、回合不被拖死」，
 * 而不是测调度精度。
 */

// ── Helpers ──────────────────────────────────────────────────

/** 可控闸门：慢工具的等待体，用例收尾时放行，避免留下长跑线程。 */
class BudgetGate {
    let open = AtomicBool(false)

    func release(): Unit {
        this.open.store(true)
    }

    /** 等到放行或到达上限（上限只是兜底，防止用例写错时线程永远留着）。 */
    func waitUpTo(millis: Int64): Unit {
        var waited: Int64 = 0
        while (waited < millis && !this.open.load()) {
            sleep(Duration.millisecond * 10)
            waited += 10
        }
    }
}

/** 记录「在哪个线程上跑的」的工具：用来区分同步执行与另起线程。 */
class ThreadProbeTool <: Tool {
    let toolName: String
    let reply: ToolResult
    var threadId: Int64 = -1

    init(name: String, reply: ToolResult) {
        this.toolName = name
        this.reply = reply
    }

    public func name(): String {
        this.toolName
    }

    public func description(): String {
        "records the executing thread"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.threadId = Thread.currentThread.id
        this.reply
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

/** 阻塞到闸门放行（或上限）才返回的工具。 */
class GatedTool <: Tool {
    let toolName: String
    let mode: ToolExecutionMode
    let gate: BudgetGate
    let holdMillis: Int64
    var execCount: Int64 = 0

    init(name: String, mode: ToolExecutionMode, gate: BudgetGate, holdMillis: Int64) {
        this.toolName = name
        this.mode = mode
        this.gate = gate
        this.holdMillis = holdMillis
    }

    public func name(): String {
        this.toolName
    }

    public func description(): String {
        "blocks until released"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.execCount = this.execCount + 1
        this.gate.waitUpTo(this.holdMillis)
        ToolResult("slow-done", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        this.mode
    }
}

/** 固定睡一段时间再返回的工具（用于「工具自己声明预算」的对照）。 */
class SleepingTool <: Tool {
    let sleepMillis: Int64
    let declared: Option<Duration>

    init(sleepMillis: Int64, declared: Option<Duration>) {
        this.sleepMillis = sleepMillis
        this.declared = declared
    }

    public func name(): String {
        "sleeper"
    }

    public func description(): String {
        "sleeps then returns"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        sleep(Duration.millisecond * this.sleepMillis)
        ToolResult("awake", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }

    public func timeoutBudget(): Option<Duration> {
        this.declared
    }
}

/** 抛异常的工具；`own` 决定抛的是自己的 TimeoutException 还是普通异常。 */
class ThrowingProbeTool <: Tool {
    let own: Bool

    init(own: Bool) {
        this.own = own
    }

    public func name(): String {
        "boom"
    }

    public func description(): String {
        "throws"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        if (this.own) {
            throw TimeoutException("thrown by the tool itself")
        }
        throw Exception("kaboom")
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

func budgetArgs(): JsonValue {
    JsonValue.Map(HashMap<String, JsonValue>())
}

func budgetBatch(names: Array<String>): ArrayList<(String, ToolContext, JsonValue)> {
    let batch = ArrayList<(String, ToolContext, JsonValue)>()
    for (name in names) {
        batch.add((name, ToolContext(""), budgetArgs()))
    }
    batch
}

// ── executeTool：预算语义 ────────────────────────────────────

@Test
func executeTool_returnsResultWithinBudget() {
    let probe = ThreadProbeTool("probe", ToolResult("ok", None, false, false))
    let result = executeTool(probe, ToolContext(""), budgetArgs(),
        Some(Duration.millisecond * 5000))
    @Expect(result.text, "ok")
    @Expect(result.isError, false)
}

@Test
func executeTool_timesOutBlockedTool() {
    let gate = BudgetGate()
    let tool = GatedTool("slow", ToolExecutionMode.Sequential, gate, 30000)
    let start = MonoTime.now()
    let result = executeTool(tool, ToolContext(""), budgetArgs(),
        Some(Duration.millisecond * 300))
    let elapsed = (MonoTime.now() - start).toMilliseconds()
    gate.release()

    @Expect(result.isError, true)
    @Expect(result.terminate, false)
    @Assert(result.text.contains("[tool timeout]"))
    @Assert(result.text.contains("'slow'"))
    @Assert(result.text.contains("300ms"))
    // 预算 300ms，远早于工具的等待上限：说明是预算生效，而不是工具自己返回了
    if (elapsed >= 10000) {
        @Fail("expected prompt timeout, waited ${elapsed}ms")
    }
    @Expect(tool.execCount, 1)
}

@Test
func executeTool_noBudgetRunsOnCallerThread() {
    let probe = ThreadProbeTool("probe", ToolResult("ok", None, false, false))
    executeTool(probe, ToolContext(""), budgetArgs(), None)
    @Expect(probe.threadId, Thread.currentThread.id)
}

@Test
func executeTool_budgetRunsOnWorkerThread() {
    let probe = ThreadProbeTool("probe", ToolResult("ok", None, false, false))
    executeTool(probe, ToolContext(""), budgetArgs(),
        Some(Duration.millisecond * 5000))
    if (probe.threadId == Thread.currentThread.id) {
        @Fail("bounded calls must run off the caller thread")
    }
}

@Test
func executeTool_zeroBudgetRunsOnCallerThread() {
    let probe = ThreadProbeTool("probe", ToolResult("ok", None, false, false))
    let result = executeTool(probe, ToolContext(""), budgetArgs(), Some(Duration.Zero))
    @Expect(result.text, "ok")
    @Expect(probe.threadId, Thread.currentThread.id)
}

@Test
func executeTool_propagatesToolException() {
    let tool = ThrowingProbeTool(false)
    var caught = ""
    try {
        executeTool(tool, ToolContext(""), budgetArgs(), Some(Duration.millisecond * 5000))
        @Fail("expected the tool exception to propagate")
    } catch (e: Exception) {
        caught = e.message
    }
    @Expect(caught, "kaboom")
}

@Test
func executeTool_propagatesToolOwnTimeoutException() {
    // 工具自己抛的 TimeoutException 不能被误判成框架超时：
    // 前者该原样冒泡（调用方可能正等着它），后者才需要变成失败结果
    let tool = ThrowingProbeTool(true)
    var caught = ""
    try {
        executeTool(tool, ToolContext(""), budgetArgs(), Some(Duration.millisecond * 5000))
        @Fail("expected the tool's own TimeoutException to propagate")
    } catch (e: TimeoutException) {
        caught = e.message
    }
    @Expect(caught, "thrown by the tool itself")
}

// ── toolBudget：工具声明优先 ─────────────────────────────────

@Test
func toolBudget_prefersDeclaredOverFallback() {
    let declared = SleepingTool(1, Some(Duration.millisecond * 7000))
    let fallback = Some(Duration.millisecond * 300)
    match (toolBudget(declared, fallback)) {
        case Some(value) => @Expect(value.toMilliseconds(), 7000)
        case None => @Fail("declared budget should win")
    }
}

@Test
func toolBudget_fallsBackWhenToolDeclaresNothing() {
    let plain = GatedTool("slow", ToolExecutionMode.Sequential, BudgetGate(), 10)
    match (toolBudget(plain, Some(Duration.millisecond * 300))) {
        case Some(value) => @Expect(value.toMilliseconds(), 300)
        case None => @Fail("expected the fallback budget")
    }
    match (toolBudget(plain, None)) {
        case None => ()
        case Some(_) => @Fail("no fallback means no budget")
    }
}

@Test
func describeDuration_formatsSecondsAndMillis() {
    @Expect(describeDuration(Duration.second * 30), "30s")
    @Expect(describeDuration(Duration.millisecond * 1500), "1500ms")
}

// ── ToolExecutor：批处理路径 ─────────────────────────────────

@Test
func executor_batchSequentialAppliesBudgetToEveryCall() {
    let reg = ToolRegistry()
    let first = GatedTool("slow-a", ToolExecutionMode.Sequential, BudgetGate(), 30000)
    let second = GatedTool("slow-b", ToolExecutionMode.Sequential, BudgetGate(), 30000)
    reg.register(first)
    reg.register(second)
    let exec = ToolExecutor(reg, toolTimeout: Some(Duration.millisecond * 300))

    let start = MonoTime.now()
    let results = exec.executeBatch(budgetBatch(["slow-a", "slow-b"]))
    let elapsed = (MonoTime.now() - start).toMilliseconds()
    first.gate.release()
    second.gate.release()

    // 预算是「每次调用」的：两个串行慢工具各等满一次，但都在预算内收场
    @Expect(results.size, 2)
    @Expect(results[0].isError, true)
    @Expect(results[1].isError, true)
    if (elapsed >= 10000) {
        @Fail("expected prompt timeout, waited ${elapsed}ms")
    }
}

@Test
func executor_singleExecuteAppliesBudget() {
    let reg = ToolRegistry()
    let tool = GatedTool("slow", ToolExecutionMode.Sequential, BudgetGate(), 30000)
    reg.register(tool)
    let exec = ToolExecutor(reg, toolTimeout: Some(Duration.millisecond * 300))

    let result = exec.execute("slow", ToolContext(""), budgetArgs())
    tool.gate.release()
    @Expect(result.isError, true)
    @Assert(result.text.contains("[tool timeout]"))
}

@Test
func executor_batchParallelAppliesBudget() {
    let reg = ToolRegistry()
    let first = GatedTool("slow-a", ToolExecutionMode.Parallel, BudgetGate(), 30000)
    let second = GatedTool("slow-b", ToolExecutionMode.Parallel, BudgetGate(), 30000)
    reg.register(first)
    reg.register(second)
    let exec = ToolExecutor(reg, toolTimeout: Some(Duration.millisecond * 300))

    let start = MonoTime.now()
    let results = exec.executeBatch(budgetBatch(["slow-a", "slow-b"]))
    let elapsed = (MonoTime.now() - start).toMilliseconds()
    first.gate.release()
    second.gate.release()

    @Expect(results.size, 2)
    @Expect(results[0].isError, true)
    @Expect(results[1].isError, true)
    if (elapsed >= 10000) {
        @Fail("expected prompt timeout, waited ${elapsed}ms")
    }
}

@Test
func executor_timeoutDoesNotSkipRemainingSequentialTools() {
    let reg = ToolRegistry()
    let slow = GatedTool("slow", ToolExecutionMode.Sequential, BudgetGate(), 30000)
    reg.register(slow)
    reg.register(ThreadProbeTool("probe", ToolResult("ok", None, false, false)))
    let exec = ToolExecutor(reg, toolTimeout: Some(Duration.millisecond * 300))

    let results = exec.executeBatch(budgetBatch(["slow", "probe"]))
    slow.gate.release()

    @Expect(results.size, 2)
    @Expect(results[0].isError, true)
    // 超时不是 terminate：后面的工具照常执行，回合继续
    @Expect(results[1].isError, false)
    @Expect(results[1].text, "ok")
}

@Test
func executor_declaredBudgetOverridesConfigFallback() {
    let reg = ToolRegistry()
    // 工具自己声明 5s，配置只给 300ms：以工具声明为准，慢 1s 的调用应当跑完
    reg.register(SleepingTool(1000, Some(Duration.millisecond * 5000)))
    let exec = ToolExecutor(reg, toolTimeout: Some(Duration.millisecond * 300))

    let results = exec.executeBatch(budgetBatch(["sleeper"]))
    @Expect(results.size, 1)
    @Expect(results[0].isError, false)
    @Expect(results[0].text, "awake")
}

@Test
func executor_noBudgetKeepsToolsInline() {
    let reg = ToolRegistry()
    let probe = ThreadProbeTool("probe", ToolResult("ok", None, false, false))
    reg.register(probe)
    let exec = ToolExecutor(reg)

    exec.executeBatch(budgetBatch(["probe"]))
    @Expect(probe.threadId, Thread.currentThread.id)
}
