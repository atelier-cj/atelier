package atelier.ptc

import std.unittest.*
import std.unittest.testmacro.*
import std.collection.*
import std.time.*
import jsonvalue.*
import ystyle::xisp.types.*

/**
 * xisp 运行时测试：环境组装、绑定桥、求值、日志与失败分类。
 */
class RuntimeTestHelpers {
    static func emptyRequest(program: String): PtcRunRequest {
        PtcRunRequest(program, ArrayList<PtcBindingNamespace>(), "",
            { => false }, { _ => () })
    }

    static func withTools(name: String, fn: PtcBindingFunction): ArrayList<PtcBindingNamespace> {
        let members = HashMap<String, PtcBindingFunction>()
        members.add(name, fn)
        let namespaces = ArrayList<PtcBindingNamespace>()
        namespaces.add(PtcBindingNamespace("tools", members))
        namespaces
    }

    /** 返回固定值的绑定 */
    static func constant(value: JsonValue): PtcBindingFunction {
        { _ => PtcBindingOutcome.Ok(value) }
    }
}

@Test
func runtime_evaluatesExpression() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(+ 1 2)"))
    @Assert(result.isOk())
    match (result.value) {
        case Some(JsonValue.Number(n)) => @Assert(n == 3.0)
        case other => @Fail("expected 3, got ${other}")
    }
}

@Test
func runtime_lastExpressionIsCompletionValue() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(define x 1) (+ x 41)"))
    @Assert(result.isOk())
    match (result.value) {
        case Some(JsonValue.Number(n)) => @Assert(n == 42.0)
        case other => @Fail("expected 42, got ${other}")
    }
}

@Test
func runtime_nilCompletionValueIsAbsent() {
    // 程序没有产出完成值时 value 留空，而不是伪造一个 null。
    // 用 println 作末表达式：它的返回值确定是 nil（define 返回的是被定义的值）
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(println \"x\")"))
    @Assert(result.isOk())
    @Assert(result.value.isNone())
}

@Test
func runtime_bindingIsCallable() {
    let runtime = XispRuntime()
    let request = PtcRunRequest("(tools::answer)",
        RuntimeTestHelpers.withTools("answer", RuntimeTestHelpers.constant(JsonValue.Number(42.0))),
        "", { => false }, { _ => () })
    let result = runtime.run(request)
    @Assert(result.isOk())
    match (result.value) {
        case Some(JsonValue.Number(n)) => @Assert(n == 42.0)
        case other => @Fail("expected 42, got ${other}")
    }
}

@Test
func runtime_bindingReceivesMapArgument() {
    let runtime = XispRuntime()
    let captured = ArrayList<JsonValue>()
    let binding = { args: JsonValue =>
        captured.add(args)
        PtcBindingOutcome.Ok(JsonValue.String("ok"))
    }
    let request = PtcRunRequest("(tools::read_file {:path \"a.cj\" :limit 10})",
        RuntimeTestHelpers.withTools("read_file", binding), "", { => false }, { _ => () })
    let result = runtime.run(request)
    @Assert(result.isOk())
    @Assert(captured.size == 1)
    match (captured[0]) {
        case JsonValue.Map(m) =>
            match (m.get("path")) {
                case Some(JsonValue.String(s)) => @Assert(s == "a.cj")
                case other => @Fail("path should be a string, got ${other}")
            }
            // 整数值必须还原为 JSON number（内部走 Int，序列化回 number）
            match (m.get("limit")) {
                case Some(JsonValue.Number(n)) => @Assert(n == 10.0)
                case other => @Fail("limit should be a number, got ${other}")
            }
        case other => @Fail("binding should receive a map, got ${other}")
    }
}

@Test
func runtime_bindingFailureBecomesDetectableValue() {
    let runtime = XispRuntime()
    let failing = { _: JsonValue => PtcBindingOutcome.Err("file not found") }
    // 程序捕获失败并返回自己的兜底值：错误是值，不是异常
    let request = PtcRunRequest(
        "(define (try-read) (tools::read_file {:path \"missing\"})) (define r (try-read)) \"fallback\"",
        RuntimeTestHelpers.withTools("read_file", failing), "", { => false }, { _ => () })
    let result = runtime.run(request)
    @Assert(result.isOk())
    match (result.value) {
        case Some(JsonValue.String(s)) => @Assert(s == "fallback")
        case other => @Fail("expected fallback string, got ${other}")
    }
}

@Test
func runtime_bindingFailureSurfacesWhenUnhandled() {
    let runtime = XispRuntime()
    let failing = { _: JsonValue => PtcBindingOutcome.Err("file not found") }
    let request = PtcRunRequest("(tools::read_file {:path \"missing\"})",
        RuntimeTestHelpers.withTools("read_file", failing), "", { => false }, { _ => () })
    let result = runtime.run(request)
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) =>
            match (f.kind) {
                case PtcFailureKind.Exception => @Assert(f.message.contains("file not found"))
                case _ => @Fail("binding failure should classify as Exception")
            }
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_collectsLogs() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(println \"hello\") (println \"world\")"))
    @Assert(result.isOk())
    let joined = String.join(result.logs.toArray(), delimiter: "")
    @Assert(joined.contains("hello"))
    @Assert(joined.contains("world"))
}

@Test
func runtime_truncatesLongLogs() {
    let runtime = XispRuntime()
    let request = PtcRunRequest("(println \"aaaaaaaaaa\") (println \"bbbbbbbbbb\") (println \"cccccccccc\")",
        ArrayList<PtcBindingNamespace>(), "", { => false }, { _ => () },
        maxLogChars: 25)
    let result = runtime.run(request)
    let joined = String.join(result.logs.toArray(), delimiter: "")
    @Assert(joined.contains("truncated"))
    @Assert(!joined.contains("cccccccccc"))
}

@Test
func runtime_syntaxErrorIsReported() {
    // 残缺程序必须报错：宽松解析会把它补全成 (+ 1) 并算出 3
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(+ 1 "))
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) =>
            match (f.kind) {
                case PtcFailureKind.SyntaxError => @Assert(true)
                case _ => @Fail("incomplete input should classify as SyntaxError")
            }
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_runtimeErrorIsReported() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(this-fn-does-not-exist 1)"))
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) =>
            match (f.kind) {
                case PtcFailureKind.Exception => @Assert(true)
                case _ => @Fail("undefined function should classify as Exception")
            }
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_nonSerializableCompletionIsReported() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(lambda (x) x)"))
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) => @Assert(f.message.contains("not representable"))
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_timeoutStopsEvaluation() {
    let runtime = XispRuntime()
    // 零预算：首次中断检查即超时
    let request = PtcRunRequest("(map (lambda (x) (* x 2)) (range 1 1000))",
        ArrayList<PtcBindingNamespace>(), "", { => false }, { _ => () },
        timeout: Duration.millisecond * 0)
    let result = runtime.run(request)
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) =>
            match (f.kind) {
                case PtcFailureKind.Timeout => @Assert(true)
                case _ => @Fail("zero budget should classify as Timeout, got ${f.kind}")
            }
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_cancellationStopsEvaluation() {
    let runtime = XispRuntime()
    let request = PtcRunRequest("(map (lambda (x) (* x 2)) (range 1 1000))",
        ArrayList<PtcBindingNamespace>(), "", { => true }, { _ => () })
    let result = runtime.run(request)
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) =>
            match (f.kind) {
                case PtcFailureKind.Cancelled => @Assert(true)
                case _ => @Fail("cancelled run should classify as Cancelled, got ${f.kind}")
            }
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_stopsDispatchingAfterStop() {
    let runtime = XispRuntime()
    let calls = ArrayList<Int64>()
    // 每次绑定调用消耗 20ms，预算 5ms：第一次调用返回后即应停下
    let slow = { _: JsonValue =>
        calls.add(1)
        sleep(Duration.millisecond * 20)
        PtcBindingOutcome.Ok(JsonValue.Null)
    }
    let request = PtcRunRequest("(begin (tools::slow) (tools::slow) (tools::slow))",
        RuntimeTestHelpers.withTools("slow", slow), "", { => false }, { _ => () },
        timeout: Duration.millisecond * 5)
    let result = runtime.run(request)
    @Assert(!result.isOk())
    // 已经开始的调用不被强制打断，但后续派发必须停止
    @Assert(calls.size == 1)
}

@Test
func runtime_hasNoFileAccess() {
    // 干净环境的核心承诺：文件能力不在环境里，eval/apply 也无从绕过
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(cangjie::read-file \"/etc/passwd\")"))
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) => @Assert(f.message.contains("Undefined function"))
        case None => @Fail("expected a failure")
    }
}

@Test
func runtime_evalCannotEscapeToFiles() {
    let runtime = XispRuntime()
    let result = runtime.run(RuntimeTestHelpers.emptyRequest("(eval '(cangjie::read-file \"/etc/passwd\"))"))
    @Assert(!result.isOk())
}

@Test
func runtime_eachRunGetsFreshEnvironment() {
    // 跨运行不留状态：同一份程序重复执行结果一致
    let runtime = XispRuntime()
    let first = runtime.run(RuntimeTestHelpers.emptyRequest("(define counter 41) (+ counter 1)"))
    @Assert(first.isOk())
    let second = runtime.run(RuntimeTestHelpers.emptyRequest("(+ counter 1)"))
    @Assert(!second.isOk())
}

@Test
func runtime_bindingArityIsEnforced() {
    let runtime = XispRuntime()
    let request = PtcRunRequest("(tools::echo 1 2)",
        RuntimeTestHelpers.withTools("echo", RuntimeTestHelpers.constant(JsonValue.Null)),
        "", { => false }, { _ => () })
    let result = runtime.run(request)
    @Assert(!result.isOk())
    match (result.error) {
        case Some(f) => @Assert(f.message.contains("single map argument"))
        case None => @Fail("expected a failure")
    }
}
