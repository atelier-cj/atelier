package atelier.tool

/*
 * **单个工具的失败不应升级为整批失败**。
 *
 * `executeTool` 有两条分支（有/无超时预算）。此前它们对工具异常的处理不一致：
 * 有预算时调用被 `spawn` 包起来、异常在边界上变成一条 isError 结果；无预算时直接
 * 调用，异常原样冒到 `executeBatch`，进而让整批按"框架失败"收尾、整个 run 结束。
 *
 * 预算只该改变「等多久」，不该改变「出错了会怎样」。本文件锁住这条：
 * 两种配置下，工具抛异常都得到一条 isError 结果，且 `executeBatch` **不抛出**。
 *
 * 这也让运行时的 `ToolBatchOutcome.BatchFailed` 退化成"理论上不该发生"的兜底 ——
 * 它的触发条件此后只能是**框架层**异常（执行器自身出问题），而不是工具抛错。
 */

import std.collection.*
import std.core.Duration
import atelier.message.*
import jsonvalue.*

// 执行必抛异常的工具
class IsolationThrowTool <: Tool {
    private let mode: ToolExecutionMode
    public init(mode!: ToolExecutionMode = ToolExecutionMode.Parallel) { this.mode = mode }
    public func name(): String { "throwing" }
    public func description(): String { "always throws" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        throw Exception("tool exploded")
    }
    public func executionMode(): ToolExecutionMode { this.mode }
}

// 让「工具自身的方法」抛异常（而非 execute）—— 排查执行器里其他直通入口
class IsolationBadMetaTool <: Tool {
    public func name(): String { "bad_meta" }
    public func description(): String { "executionMode throws" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { throw Exception("executionMode exploded") }
}

func probeCtx(): ToolContext {
    ToolContext("/tmp", HashMap<String, String>(), "s_probe")
}

func oneCallBatch(name: String): ArrayList<(String, ToolContext, JsonValue)> {
    let batch = ArrayList<(String, ToolContext, JsonValue)>()
    batch.add((name, probeCtx(), JsonValue.Map(HashMap<String, JsonValue>())))
    batch
}

// 核心：**无预算**下工具抛异常 → 得到 isError 结果，不向批次层抛出
@Test
func executeBatch_noBudgetIsolatesToolException() {
    let reg = ToolRegistry()
    reg.register(IsolationThrowTool())
    // 两类预算都 None = 不限时（走无预算分支）
    let exec = ToolExecutor(reg, budget: ToolBudgetPolicy(None, None))

    var threw = false
    var results = ArrayList<ToolResult>()
    try {
        results = exec.executeBatch(oneCallBatch("throwing"))
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, false)
    @Expect(results.size, Int64(1))
    @Expect(results[0].isError, true)
    // 文案带上异常信息（e.toString()，不是可能为空的 e.message）
    @Expect(results[0].text.contains("tool exploded"), true)
}

// 行为一致性：**有预算**下同样得到 isError 结果、同样不抛出
@Test
func executeBatch_withBudgetIsolatesToolException() {
    let reg = ToolRegistry()
    reg.register(IsolationThrowTool())
    let budget = ToolBudgetPolicy(Some(Duration.second * Int64(5)),
        Some(Duration.second * Int64(5)))
    let exec = ToolExecutor(reg, budget: budget)

    var threw = false
    var results = ArrayList<ToolResult>()
    try {
        results = exec.executeBatch(oneCallBatch("throwing"))
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, false)
    @Expect(results.size, Int64(1))
    @Expect(results[0].isError, true)
    @Expect(results[0].text.contains("tool exploded"), true)
}

// Sequential 工具同样隔离（两条分支 × 两种执行模式的组合）
@Test
func executeBatch_sequentialThrowingToolIsolated() {
    let reg = ToolRegistry()
    reg.register(IsolationThrowTool(mode: ToolExecutionMode.Sequential))
    let exec = ToolExecutor(reg, budget: ToolBudgetPolicy(None, None))
    var threw = false
    var results = ArrayList<ToolResult>()
    try {
        results = exec.executeBatch(oneCallBatch("throwing"))
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, false)
    @Expect(results.size, Int64(1))
    @Expect(results[0].isError, true)
}

// 单调用入口（非批次）同样隔离
@Test
func execute_singleCallIsolatesToolException() {
    let reg = ToolRegistry()
    reg.register(IsolationThrowTool())
    let exec = ToolExecutor(reg, budget: ToolBudgetPolicy(None, None))
    var threw = false
    var result = ToolResult("", None, false, false)
    try {
        result = exec.execute("throwing", probeCtx(), JsonValue.Map(HashMap<String, JsonValue>()))
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, false)
    @Expect(result.isError, true)
    @Expect(result.text.contains("tool exploded"), true)
}

// 一个工具抛异常不影响同批的其他工具：批次继续执行，两条结果都在
@Test
func executeBatch_oneThrowingToolDoesNotAbortOthers() {
    let reg = ToolRegistry()
    reg.register(IsolationThrowTool())
    reg.register(IsolationOkTool())
    let exec = ToolExecutor(reg, budget: ToolBudgetPolicy(None, None))
    let batch = ArrayList<(String, ToolContext, JsonValue)>()
    batch.add(("throwing", probeCtx(), JsonValue.Map(HashMap<String, JsonValue>())))
    batch.add(("silent", probeCtx(), JsonValue.Map(HashMap<String, JsonValue>())))

    var threw = false
    var results = ArrayList<ToolResult>()
    try {
        results = exec.executeBatch(batch)
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, false)
    @Expect(results.size, Int64(2))
    @Expect(results[0].isError, true)
    @Expect(results[1].isError, false)
}

class IsolationOkTool <: Tool {
    public func name(): String { "silent" }
    public func description(): String { "returns ok" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

// 工具**元数据方法**（executionMode）抛异常：这条不在 executeTool 的隔离范围内
// （执行器要先问执行模式才能决定怎么跑），属于"框架层异常"，会直通批次层。
//
// **这是 `ToolBatchOutcome.BatchFailed` 此后唯一合法的触发条件**：
// `BatchFailed` 的触发条件是**框架自身**出错（工具的元数据/调度层异常），
// 不是工具执行出错 —— 后者已被 `executeTool` 隔离成单条 isError 结果。
// 因此它直接收尾是刻意的：框架状态可疑时再发一轮请求是带病作业。
@Test
func executeBatch_metadataFailurePropagatesAsFrameworkError() {
    let reg = ToolRegistry()
    reg.register(IsolationBadMetaTool())
    let exec = ToolExecutor(reg, budget: ToolBudgetPolicy(None, None))
    var threw = false
    try {
        let _ = exec.executeBatch(oneCallBatch("bad_meta"))
    } catch (e: Exception) {
        threw = true
    }
    // 记录现状：工具元数据出问题被视为框架层异常（由调用方按 BatchFailed 收尾）
    @Expect(threw, true)
}
