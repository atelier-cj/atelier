package atelier.ptc

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.sync.*
import std.time.*
import jsonvalue.*
import atelier.tool.*

/**
 * run_xisp 工具测试：参数校验、执行、子调用事件与安全声明。
 */
class RunXispTestHelpers {

    static func toolArgs(code: String, description: String): JsonValue {
        let m = HashMap<String, JsonValue>()
        m.add("code", JsonValue.String(code))
        m.add("description", JsonValue.String(description))
        JsonValue.Map(m)
    }

    static func makeEnv(
        events: ArrayList<PtcEvent>,
        denyReason: Option<String>,
        maxSubCalls!: Int64 = 10,
        timeout!: Option<Duration> = None,
        toolBudget!: ToolBudgetPolicy = ToolBudgetPolicy(None, None)
    ): PtcRunEnv {
        let auth: PtcAuthorizer = { _, _ =>
            match (denyReason) {
                case Some(reason) => PtcAuthDecision.Deny(reason)
                case None => PtcAuthDecision.Allow
            }
        }
        PtcRunEnv("", "sess-1",
            { => false },
            { e => events.add(e) },
            auth,
            maxSubCalls: maxSubCalls,
            timeout: timeout,
            toolBudget: toolBudget)
    }

    static func tools(items: Array<Tool>): ArrayList<Tool> {
        let list = ArrayList<Tool>()
        for (item in items) {
            list.add(item)
        }
        list
    }
}

@Test
func runXisp_schemaRequiresCodeAndDescription() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    @Assert(tool.name() == "run_xisp")

    match (tool.schema()) {
        case JsonValue.Map(m) =>
            match (m.get("required")) {
                case Some(JsonValue.Array(req)) =>
                    @Assert(req.size == 2)
                case other => @Fail("required should list both params, got ${other}")
            }
            match (m.get("properties")) {
                case Some(JsonValue.Map(props)) =>
                    @Assert(props.contains("code"))
                    @Assert(props.contains("description"))
                case other => @Fail("properties missing, got ${other}")
            }
        case other => @Fail("schema should be an object, got ${other}")
    }
}

@Test
func runXisp_declaresSequentialForTrustGate() {
    // ToolExecutionMode 同时是信任闸门的判据：Parallel 会被直接放行（不过闸门），
    // 而 PTC 的子调用是连续执行的，交互审批只在工具粒度生效——
    // 因此本工具必须是 Sequential，否则 PTC 成为绕过审批的通道。
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    match (tool.executionMode()) {
        case ToolExecutionMode.Sequential => @Assert(true)
        case ToolExecutionMode.Parallel => @Fail("run_xisp must not be Parallel")
    }
}

@Test
func runXisp_rejectsMissingCode() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let args = HashMap<String, JsonValue>()
    args.add("description", JsonValue.String("desc"))
    let result = tool.execute(ToolContext(""), JsonValue.Map(args))
    @Assert(result.isError)
    @Assert(result.text.contains("code"))
}

@Test
func runXisp_rejectsBlankDescription() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(+ 1 2)", "   "))
    @Assert(result.isError)
    @Assert(result.text.contains("description"))
}

@Test
func runXisp_executesProgramAndReturnsValue() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(+ 40 2)", "compute"))
    @Assert(!result.isError)
    @Assert(result.text.contains("42"))
}

@Test
func runXisp_includesLogsInResultText() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(println \"progress\") \"done\"", "logging"))
    @Assert(!result.isError)
    @Assert(result.text.contains("progress"))
    @Assert(result.text.contains("done"))
}

@Test
func runXisp_reportsNoOutput() {
    // 无日志且完成值为 nil 时给出明确的占位文本。
    // 注意：xisp 的布尔字面量是 #t / #f（Scheme 风格），写 false 会得到
    // 未绑定符号（错误值），而错误值在 if 里是真值——因此这里必须用 #f。
    // 同理 (define x 1) 返回被定义的值而不是 nil。
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(if #f 1)", "no output"))
    @Assert(!result.isError)
    @Assert(result.text.contains("no output"))
}

@Test
func runXisp_booleanLiteralsAreSchemeStyle() {
    // 固定这条语法事实：true / false 未绑定，#t / #f 才是布尔字面量
    let runtime = XispRuntime()
    let truthy = runtime.run(RuntimeTestHelpers.emptyRequest("(if #t 1 2)"))
    @Assert(truthy.isOk())
    match (truthy.value) {
        case Some(JsonValue.Number(n)) => @Assert(n == 1.0)
        case other => @Fail("expected 1 for #t, got ${other}")
    }

    let falsy = runtime.run(RuntimeTestHelpers.emptyRequest("(if #f 1 2)"))
    @Assert(falsy.isOk())
    match (falsy.value) {
        case Some(JsonValue.Number(n)) => @Assert(n == 2.0)
        case other => @Fail("expected 2 for #f, got ${other}")
    }
}

@Test
func runXisp_syntaxErrorIsAnError() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(+ 1 ", "incomplete"))
    @Assert(result.isError)
    @Assert(result.text.contains("syntax_error"))
}

@Test
func runXisp_runtimeErrorIsAnError() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(nope 1)", "bad call"))
    @Assert(result.isError)
}

@Test
func runXisp_timeoutIsAnError() {
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None,
            timeout: Duration.millisecond * 0))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(map (lambda (x) x) (range 1 100))", "slow"))
    @Assert(result.isError)
    @Assert(result.text.contains("timeout"))
}

@Test
func runXisp_dispatchesVisibleTools() {
    let events = ArrayList<PtcEvent>()
    let echo = MockTool("echo", ToolResult("tool-said-hi", None, false, false))
    let tool = RunXispTool(RunXispTestHelpers.tools([echo]),
        RunXispTestHelpers.makeEnv(events, None))

    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(tools::echo {:x 1})", "call a tool"))
    @Assert(!result.isError)
    @Assert(result.text.contains("tool-said-hi"))
    @Assert(echo.execCount == 1)

    // 子调用必须发开始/结束事件，且编号以父调用为前缀
    var starts = 0
    var ends = 0
    for (e in events) {
        match (e) {
            case PtcEvent.DispatchStart(callId, name) =>
                starts = starts + 1
                @Assert(callId == "run_xisp#1:ptc:1")
                @Assert(name == "echo")
            case PtcEvent.DispatchEnd(callId, name, _, isError) =>
                ends = ends + 1
                @Assert(callId == "run_xisp#1:ptc:1")
                @Assert(!isError)
            case PtcEvent.Log(_, _) => ()
        }
    }
    @Assert(starts == 1)
    @Assert(ends == 1)
}

@Test
func runXisp_deniedToolAbortsProgram() {
    let tool = RunXispTool(RunXispTestHelpers.tools([
        MockTool("danger", ToolResult("done", None, false, false))
    ]), RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), Some("denied by trust gate")))

    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(tools::danger {})", "denied"))
    @Assert(result.isError)
    @Assert(result.text.contains("denied"))
}

@Test
func runXisp_unknownToolIsAnError() {
    // 不可见的工具不在环境里：调用会报未定义函数，而不是悄悄失败
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(tools::hidden {})", "not visible"))
    @Assert(result.isError)
}

@Test
func runXisp_enforcesSubCallBudget() {
    let events = ArrayList<PtcEvent>()
    let echo = MockTool("echo", ToolResult("x", None, false, false))
    let tool = RunXispTool(RunXispTestHelpers.tools([echo]),
        RunXispTestHelpers.makeEnv(events, None, maxSubCalls: 2))

    // 第 3 次调用应被预算拒绝
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(begin (tools::echo {}) (tools::echo {}) (tools::echo {}))", "budget"))
    @Assert(result.isError)
    @Assert(result.text.contains("budget"))
    @Assert(echo.execCount == 2)
}

@Test
func runXisp_logsAreStreamedThroughEvents() {
    let events = ArrayList<PtcEvent>()
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(events, None))
    tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(println \"streamed\")", "logging"))

    var sawLog = false
    for (e in events) {
        match (e) {
            // 日志带运行级标识：不归属某一次子调用（脚本代码只在两次子调用之间跑）
            case PtcEvent.Log(callId, text) =>
                @Assert(callId == "run_xisp#1")
                if (text.contains("streamed")) {
                    sawLog = true
                }
            case _ => ()
        }
    }
    @Assert(sawLog)
}

@Test
func runXisp_handlerNeverThrows() {
    // 工具抛出的异常必须被转成失败结果，不能穿过求值器
    let events = ArrayList<PtcEvent>()
    let tool = RunXispTool(RunXispTestHelpers.tools([ThrowingTool()]),
        RunXispTestHelpers.makeEnv(events, None))
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(tools::boom {})", "throwing tool"))
    @Assert(result.isError)
    @Assert(result.text.contains("tool error"))
}

/** 每次执行都抛异常的工具。 */
class ThrowingTool <: Tool {
    public func name(): String {
        "boom"
    }

    public func description(): String {
        "always throws"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        throw Exception("kaboom")
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

/**
 * 子调用预算：卡住的工具不能把整个脚本拖死，也不能让模型只看到一句
 * 笼统的「工具超时」——失败要带着原因回到程序（进而回到模型）。
 */
class BlockingTool <: Tool {
    let gate: AtomicBool

    init(gate: AtomicBool) {
        this.gate = gate
    }

    public func name(): String {
        "blocker"
    }

    public func description(): String {
        "blocks until released"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        var waited: Int64 = 0
        while (waited < 30000 && !this.gate.load()) {
            sleep(Duration.millisecond * 10)
            waited += 10
        }
        ToolResult("never-blocked", None, false, false)
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

@Test
func runXisp_subCallTimeoutFailsTheProgram() {
    let gate = AtomicBool(false)
    let tool = RunXispTool(RunXispTestHelpers.tools([BlockingTool(gate)]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None,
            timeout: Duration.second * 30,
            toolBudget: ToolBudgetPolicy(
                Some(Duration.millisecond * 300), Some(Duration.millisecond * 300))))

    let start = MonoTime.now()
    let result = tool.execute(ToolContext(""),
        RunXispTestHelpers.toolArgs("(tools::blocker {})", "blocked sub-call"))
    let elapsed = (MonoTime.now() - start).toMilliseconds()
    gate.store(true)

    @Assert(result.isError)
    @Assert(result.text.contains("[tool timeout]"))
    // 子调用预算 300ms：远早于程序自己的 30s 预算，说明是子调用被兜住，
    // 而不是整个程序被外层掐断
    if (elapsed >= 10000) {
        @Fail("expected the sub-call budget to fire, waited ${elapsed}ms")
    }
}

@Test
func runXisp_timeoutBudgetLeavesRoomForInnerFailure() {
    // 程序 30s + 一次在途子调用 20s + 宽限：外层必须比内层晚，否则脚本
    // 永远给不出自己的失败原因
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None,
            timeout: Duration.second * 30,
            toolBudget: ToolBudgetPolicy(Some(Duration.second * 1), Some(Duration.second * 20))))
    match (tool.timeoutBudget()) {
        case ToolBudget.Limit(value) =>
            // 30s 程序预算 + 20s（更宽的那类子调用）+ 5s 宽限
            @Expect(value.toMilliseconds(), 55000)
        case other => @Fail("expected a declared budget, got ${other}")
    }
}

@Test
func runXisp_timeoutBudgetIsNoneWhenSubCallsAreUnbounded() {
    // 子调用自己都不限时 → 外层也不设限（掐断只会让仍在跑的脚本失去汇报）
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None,
            timeout: Duration.second * 30,
            toolBudget: ToolBudgetPolicy(Some(Duration.second * 1), None)))
    match (tool.timeoutBudget()) {
        case ToolBudget.Unbounded => ()
        case other => @Fail("unbounded sub-calls must leave the outer budget unbounded, got ${other}")
    }
}

@Test
func runXisp_timeoutBudgetIsNoneWithoutAnySubCallBudget() {
    // 完全没配子调用预算：外层也不设限——用无界的项相加得不到有界的和，
    // 硬给一个数只会变成「掐断仍在跑的脚本」
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None,
            timeout: Duration.second * 30))
    match (tool.timeoutBudget()) {
        case ToolBudget.Unbounded => ()
        case other => @Fail("no sub-call budget must leave the outer budget unbounded, got ${other}")
    }
}

@Test
func runXisp_timeoutBudgetIsNoneWithoutProgramBudget() {
    // 程序不限时 → 不替它声明外层预算，交回框架配置
    let tool = RunXispTool(RunXispTestHelpers.tools([]),
        RunXispTestHelpers.makeEnv(ArrayList<PtcEvent>(), None))
    match (tool.timeoutBudget()) {
        // 程序自己没预算 = 没意见，交给框架策略（run_xisp 是 Sequential → 写类额度）
        case ToolBudget.Default => ()
        case other => @Fail("expected Default when the program has no budget, got ${other}")
    }
}
