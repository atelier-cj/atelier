package atelier.ptc

import jsonvalue.*
import std.collection.*
import std.time.*
import ystyle::xisp.types.*
import ystyle::xisp.core.eval.*
import ystyle::xisp.core.builtin.*
import ystyle::xisp.parser.*
import ystyle::xisp.bridge.Bridge

/**
 * 日志收集：按发出顺序累积脚本输出，超过上限后停止累积并附截断提示。
 *
 * 用类而不是闭包内可变变量：脚本可以无限 println，必须有界。
 */
class LogCollector {
    let logs = ArrayList<String>()
    private let limit: Int64
    private var chars: Int64 = 0
    private var truncated: Bool = false

    init(limit: Int64) {
        this.limit = limit
    }

    func accept(text: String): Unit {
        if (this.truncated) {
            return
        }
        this.chars = this.chars + Int64(text.size)
        if (this.chars > this.limit) {
            this.truncated = true
            this.logs.add("\n[output truncated: exceeded ${this.limit} characters]\n")
        } else {
            this.logs.add(text)
        }
    }
}

/**
 * 一次运行的终止状态。
 *
 * 中断只表达「停下」，不区分原因；取消与超时共用同一条中断路径，
 * 因此需要单独记录是哪一种，才能给出正确的失败分类。
 */
class RunStop {
    var cancelled: Bool = false
    var timedOut: Bool = false

    func stopped(): Bool {
        this.cancelled || this.timedOut
    }
}

/**
 * xisp 程序执行引擎。
 *
 * 每次运行使用**全新**的干净环境：只注册审核过的纯函数子集与本次可见的工具绑定，
 * 不注册文件、进程、模块能力。边界用「不注册」表达而不是「注册后过滤」——
 * 权限检查对 `eval` / `apply` / `map` 等特殊形式无效（它们先于检查执行），
 * 且函数值可作为参数传递，只有「环境里不存在」才是可靠的禁止。
 *
 * 只在本调用线程内求值，不创建线程：取消与超时通过 xisp 的求值检查点生效。
 */
public class XispRuntime {

    public init() {}

    /**
     * 执行一段程序。
     *
     * 任何失败都以 `PtcRunResult.error` 返回，不抛异常——报告失败是调用方的职责。
     */
    public func run(request: PtcRunRequest): PtcRunResult {
        let collector = LogCollector(request.maxLogChars)
        let stop = RunStop()
        let started = MonoTime.now()

        // 1) 组装干净环境：纯函数子集 + 输出接管
        let env = Environment()
        BuiltinFunctions.registerPure(env, output: { s => collector.accept(s) })

        // 2) 注册工具绑定：显式全名，避开 xisp 内两套命名空间分隔符的分歧
        for (namespace in request.bindings) {
            for ((name, fn) in namespace.functions) {
                Bridge.registerFunc(env, "${namespace.global}::${name}",
                    makeHandler(name, fn, stop))
            }
        }

        // 3) 严格解析：残缺程序必须报错，不能补全后照常运行
        let parsed = Parser.parseChecked(request.program)
        match (parsed.error) {
            case Some(e) =>
                return PtcRunResult(None, collector.logs,
                    Some(PtcRunFailure(PtcFailureKind.SyntaxError, e.message)))
            case None => ()
        }

        // 4) 求值：中断检查回调同时覆盖取消与超时
        let evaluator = Evaluator(env)
        evaluator.setInterruptChecker({
            =>
            if (request.cancelled()) {
                stop.cancelled = true
                return true
            }
            match (request.timeout) {
                case Some(budget) =>
                    let elapsed = (MonoTime.now() - started).toMilliseconds()
                    if (elapsed >= budget.toMilliseconds()) {
                        stop.timedOut = true
                        return true
                    }
                    false
                case None => false
            }
        })

        var last: LispValue = LispValue.Nil
        try {
            for (expr in parsed.exprs) {
                last = evaluator.eval(expr)
                // 只有中断才提前收场：普通错误是**值**，程序可以绑定它、
                // 判断它、走兜底分支，这正是 SDK 承诺的用法。
                if (JsonBridge.isInterrupt(last) || stop.stopped()) {
                    break
                }
            }
        } catch (e: Exception) {
            // 求值器自身的异常（栈溢出、内存耗尽等）也要变成结果字段
            return PtcRunResult(None, collector.logs,
                Some(PtcRunFailure(PtcFailureKind.Exception, "evaluation aborted: ${e.message}")))
        }

        // 5) 分类失败
        match (last) {
            case LispValue.Error(_) =>
                if (JsonBridge.isInterrupt(last)) {
                    if (stop.cancelled) {
                        return PtcRunResult(None, collector.logs,
                            Some(PtcRunFailure(PtcFailureKind.Cancelled, "run cancelled")))
                    }
                    if (stop.timedOut) {
                        return PtcRunResult(None, collector.logs,
                            Some(PtcRunFailure(PtcFailureKind.Timeout,
                                "run exceeded its time budget; effects already committed are not replayed")))
                    }
                    // 中断位由外部检查器置位但两个标志都没置：按取消处理
                    return PtcRunResult(None, collector.logs,
                        Some(PtcRunFailure(PtcFailureKind.Cancelled, "evaluation interrupted")))
                }
                match (JsonBridge.errorMessage(last)) {
                    case Some(msg) =>
                        return PtcRunResult(None, collector.logs,
                            Some(PtcRunFailure(PtcFailureKind.Exception, msg)))
                    case None => ()
                }
            case _ => ()
        }

        // 6) 完成值：最后一个顶层表达式的值，且需能跨 JSON 边界
        match (last) {
            // Nil 视为「没有完成值」，与「返回了 null」不作区分（Lisp 里本就同形）
            case LispValue.Nil => PtcRunResult(None, collector.logs, None)
            case _ =>
                match (JsonBridge.toJson(last)) {
                    case Some(value) => PtcRunResult(Some(value), collector.logs, None)
                    case None =>
                        PtcRunResult(None, collector.logs,
                            Some(PtcRunFailure(PtcFailureKind.Exception,
                                "completion value is not representable as JSON: ${last.toString()}")))
                }
        }
    }

    /**
     * 把一个宿主绑定包装成 xisp 原生函数。
     *
     * 参数约定：单个 hashmap 字面量（即 SDK 声明的 `(tools::name {...})`）；
     * 无参时按 null 传入。返回 `Ok` 转成 Lisp 值，`Err` 转成可检出的错误值。
     */
    private func makeHandler(
        toolName: String,
        fn: PtcBindingFunction,
        stop: RunStop
    ): (ArrayList<LispValue>) -> LispValue {
        { args =>
            // 运行已结束（取消/超时）：不再派发任何工具，已提交的副作用不回滚
            if (stop.stopped()) {
                return LispValue.Error(XispError(ErrorType.RuntimeError,
                    "run is over; ${toolName} not dispatched"))
            }

            let jsonArgs: JsonValue = if (args.size == 0) {
                JsonValue.Null
            } else if (args.size == 1) {
                match (JsonBridge.toJson(args[0])) {
                    case Some(j) => j
                    case None =>
                        return LispValue.Error(XispError(ErrorType.TypeError,
                            "${toolName}: arguments are not representable as JSON"))
                }
            } else {
                return LispValue.Error(XispError(ErrorType.ArityMismatch,
                    "${toolName}: expected a single map argument, got ${args.size}"))
            }

            match (fn(jsonArgs)) {
                case PtcBindingOutcome.Ok(value) => JsonBridge.toLisp(value)
                case PtcBindingOutcome.Err(message) =>
                    LispValue.Error(XispError(ErrorType.RuntimeError, message))
            }
        }
    }
}
