package atelier.ptc

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import jsonvalue.*
import atelier.tool.*

/**
 * 绑定桥测试：授权、派发、结果映射与端到端串联。
 */
class MockTool <: Tool {
    let toolName: String
    let reply: ToolResult
    var execCount: Int64 = 0
    var lastArgs: Option<JsonValue> = None

    init(name: String, reply: ToolResult) {
        this.toolName = name
        this.reply = reply
    }

    public func name(): String {
        this.toolName
    }

    public func description(): String {
        "mock tool for tests"
    }

    public func schema(): JsonValue {
        JsonValue.Map(HashMap<String, JsonValue>())
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.execCount = this.execCount + 1
        this.lastArgs = Some(args)
        this.reply
    }

    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }
}

class MockHost <: PtcSubCallHost {
    let deny: Option<String>
    var counter: Int64 = 0
    let dispatched = ArrayList<String>()
    let seenArgs = ArrayList<JsonValue>()

    init(deny: Option<String>) {
        this.deny = deny
    }

    public func authorize(tool: Tool, args: JsonValue): PtcAuthDecision {
        match (this.deny) {
            case Some(reason) => PtcAuthDecision.Deny(reason)
            case None => PtcAuthDecision.Allow
        }
    }

    public func dispatch(tool: Tool, args: JsonValue, callId: String): ToolResult {
        this.dispatched.add(callId)
        this.seenArgs.add(args)
        tool.execute(ToolContext(""), args)
    }

    public func nextCallId(): String {
        this.counter = this.counter + 1
        "call:ptc:${this.counter}"
    }
}

func bindingHelpers_makeTools(tool: Tool): ArrayList<Tool> {
    let tools = ArrayList<Tool>()
    tools.add(tool)
    tools
}

@Test
func binding_namespaceShape() {
    let tool = MockTool("read_file", ToolResult("content", None, false, false))
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), MockHost(None))
    @Assert(ns.global == "tools")
    @Assert(ns.functions.size == 1)
    @Assert(ns.functions.contains("read_file"))
}

@Test
func binding_returnsToolText() {
    let tool = MockTool("echo", ToolResult("hello", None, false, false))
    let host = MockHost(None)
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), host)

    match (ns.functions.get("echo")) {
        case Some(fn) =>
            match (fn(JsonValue.Null)) {
                case PtcBindingOutcome.Ok(JsonValue.String(s)) => @Assert(s == "hello")
                case other => @Fail("expected tool text, got ${other}")
            }
        case None => @Fail("missing binding")
    }
    @Assert(tool.execCount == 1)
    @Assert(host.dispatched.size == 1)
}

@Test
func binding_deniedByAuthorizeDoesNotDispatch() {
    let tool = MockTool("rm_rf", ToolResult("done", None, false, false))
    let host = MockHost(Some("tool not allowed: workDir is untrusted"))
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), host)

    match (ns.functions.get("rm_rf")) {
        case Some(fn) =>
            match (fn(JsonValue.Null)) {
                case PtcBindingOutcome.Err(msg) => @Assert(msg.contains("untrusted"))
                case other => @Fail("expected denial, got ${other}")
            }
        case None => @Fail("missing binding")
    }
    // 拒绝必须在派发之前生效
    @Assert(tool.execCount == 0)
    @Assert(host.dispatched.size == 0)
}

@Test
func binding_toolErrorBecomesErr() {
    let tool = MockTool("bash", ToolResult("permission denied", None, true, false))
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), MockHost(None))

    match (ns.functions.get("bash")) {
        case Some(fn) =>
            match (fn(JsonValue.Null)) {
                case PtcBindingOutcome.Err(msg) => @Assert(msg.contains("permission denied"))
                case other => @Fail("tool error should map to Err, got ${other}")
            }
        case None => @Fail("missing binding")
    }
}

@Test
func binding_passesArgumentsThrough() {
    let tool = MockTool("grep", ToolResult("hits", None, false, false))
    let host = MockHost(None)
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), host)

    let argsMap = HashMap<String, JsonValue>()
    argsMap.add("pattern", JsonValue.String("foo"))
    let args = JsonValue.Map(argsMap)

    match (ns.functions.get("grep")) {
        case Some(fn) => fn(args)
        case None => @Fail("missing binding")
    }

    @Assert(host.seenArgs.size == 1)
    match (host.seenArgs[0]) {
        case JsonValue.Map(m) =>
            match (m.get("pattern")) {
                case Some(JsonValue.String(s)) => @Assert(s == "foo")
                case other => @Fail("pattern should pass through, got ${other}")
            }
        case other => @Fail("args should be a map, got ${other}")
    }
}

@Test
func binding_callIdsAreSequential() {
    let tool = MockTool("echo", ToolResult("ok", None, false, false))
    let host = MockHost(None)
    let ns = PtcBindings.forTools(bindingHelpers_makeTools(tool), host)

    match (ns.functions.get("echo")) {
        case Some(fn) =>
            fn(JsonValue.Null)
            fn(JsonValue.Null)
            fn(JsonValue.Null)
        case None => @Fail("missing binding")
    }
    @Assert(host.dispatched.size == 3)
    @Assert(host.dispatched[0] == "call:ptc:1")
    @Assert(host.dispatched[2] == "call:ptc:3")
}

@Test
func binding_multipleToolsShareNamespace() {
    let tools = ArrayList<Tool>()
    tools.add(MockTool("read_file", ToolResult("r", None, false, false)))
    tools.add(MockTool("write_file", ToolResult("w", None, false, false)))
    let ns = PtcBindings.forTools(tools, MockHost(None))
    @Assert(ns.functions.size == 2)
    @Assert(ns.functions.contains("read_file"))
    @Assert(ns.functions.contains("write_file"))
}

@Test
func binding_endToEndThroughRuntime() {
    // 脚本调用工具、拿到文本、返回它——把 runtime 与 binding 串起来
    let tool = MockTool("echo", ToolResult("hello from tool", None, false, false))
    let host = MockHost(None)
    let namespaces = ArrayList<PtcBindingNamespace>()
    namespaces.add(PtcBindings.forTools(bindingHelpers_makeTools(tool), host))

    let request = PtcRunRequest("(tools::echo {:x 1})", namespaces, "",
        { => false }, { _ => () })
    let result = XispRuntime().run(request)

    @Assert(result.isOk())
    match (result.value) {
        case Some(JsonValue.String(s)) => @Assert(s == "hello from tool")
        case other => @Fail("expected tool text, got ${other}")
    }
    @Assert(tool.execCount == 1)
}

@Test
func binding_deniedToolAbortsProgram() {
    // 被拒绝的调用以错误值表达，而错误值出现在**参数位置会短路传播**
    // （xisp 既有语义，等价于异常向上抛），所以程序会中止而不是走条件分支。
    // 这与 native 模式下「工具失败、模型看到错误再决定下一步」的行为一致。
    let tool = MockTool("rm_rf", ToolResult("done", None, false, false))
    let host = MockHost(Some("denied by trust gate"))
    let namespaces = ArrayList<PtcBindingNamespace>()
    namespaces.add(PtcBindings.forTools(bindingHelpers_makeTools(tool), host))

    let request = PtcRunRequest("(define r (tools::rm_rf {})) (+ r 1)",
        namespaces, "", { => false }, { _ => () })
    let result = XispRuntime().run(request)

    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) => @Assert(f.message.contains("denied"))
        case None => @Fail("expected a failure")
    }
    // 拒绝必须在派发之前生效
    @Assert(tool.execCount == 0)
}

@Test
func binding_errorValueShortCircuitsArgumentPosition() {
    // 显式记录这条语义：错误值一旦进入参数位置就短路，后续函数不再执行。
    // 它决定了 SDK 只能承诺「工具失败即中止」，不能承诺「可被条件分支捕获」。
    let tool = MockTool("f", ToolResult("boom", None, true, false))
    let namespaces = ArrayList<PtcBindingNamespace>()
    namespaces.add(PtcBindings.forTools(bindingHelpers_makeTools(tool), MockHost(None)))

    // null? 不会有机会执行：参数里的错误值直接成为调用结果
    let request = PtcRunRequest("(null? (tools::f {}))", namespaces, "",
        { => false }, { _ => () })
    let result = XispRuntime().run(request)

    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) => @Assert(f.message.contains("boom"))
        case None => @Fail("expected the tool error to propagate")
    }
}
