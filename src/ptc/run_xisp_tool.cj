package atelier.ptc

import jsonvalue.*
import std.collection.*
import std.time.*
import atelier.tool.*

/**
 * `run_xisp`：把「写一段程序组合调用工具」作为一种工具呈现给模型。
 *
 * 程序在干净的 xisp 环境里执行，只能看到构造时传入的**可见工具**；
 * 子调用逐个经过与模型直调相同的策略链（见 {@link PtcSubCallHost}）。
 */
public class RunXispTool <: Tool {

    /** 保留的工具名。 */
    public static let TOOL_NAME: String = "run_xisp"

    /** 本次暴露给程序的工具集。 */
    private let visibleTools: ArrayList<Tool>
    /** 本回合的执行环境。 */
    private let env: PtcRunEnv
    private let runtime = XispRuntime()
    /**
     * 本实例内的调用序号。
     *
     * 子调用编号需要以「哪一次 run_xisp」为前缀，而模型的 callId 只在 execute
     * 时才知道，因此在此处递增。Sequential 声明保证同一实例不会被并发调用。
     */
    private var runSeq: Int64 = 0

    private static let CODE_PARAM_DESCRIPTION: String =
        "要执行的 xisp 程序。最后一个表达式的值作为本次调用的返回值；" +
        "(println ...) 的内容会作为日志一并返回。"
    private static let DESC_PARAM_DESCRIPTION: String =
        "本次调用的简短说明，用于界面标注。"
    /** 外层兜底预算在内层预算之外多给的宽限（毫秒）。 */
    static let TIMEOUT_GRACE_MS: Int64 = 5000

    public init(visibleTools: ArrayList<Tool>, env: PtcRunEnv) {
        this.visibleTools = visibleTools
        this.env = env
    }

    public func name(): String {
        RunXispTool.TOOL_NAME
    }

    public func description(): String {
        "用 xisp（Lisp 方言）编写一段程序来组合调用其它工具，只把需要的结果返回。" +
        "适合需要遍历结果集、按中间值分支、扇出后汇合的场合。"
    }

    public func schema(): JsonValue {
        SchemaBuilder()
            .addString("code", RunXispTool.CODE_PARAM_DESCRIPTION, required: true)
            .addString("description", RunXispTool.DESC_PARAM_DESCRIPTION, required: true)
            .build()
    }

    /**
     * 声明为 Sequential。
     *
     * `ToolExecutionMode` 同时充当信任闸门的判据：`Parallel` 会被直接放行，
     * 而本工具内部的子调用是连续执行的，交互审批只在工具粒度生效——
     * 因此外层调用必须走闸门，否则 PTC 就是绕过审批的通道。
     */
    public func executionMode(): ToolExecutionMode {
        ToolExecutionMode.Sequential
    }

    /**
     * 外层预算 = 程序自身预算 + 一次在途子调用的最大超出 + 宽限。
     *
     * 程序卡在子调用里时，求值器的中断检查拿不到执行权，因此程序真正可能跑到的
     * 时刻是「程序预算 + 那个子调用剩下的时间」。外层若按程序预算掐断，脚本就
     * 永远给不出自己的失败原因（只剩一句笼统的工具超时），所以外层放宽到那之后：
     * 先让内层报错，实在不动了才由外层兜底。
     */
    public func timeoutBudget(): Option<Duration> {
        match (this.env.timeout) {
            case None => None
            case Some(program) =>
                let inFlight = match (this.env.toolTimeout) {
                    case Some(sub) => sub
                    case None => Duration.Zero
                }
                let ms = program.toMilliseconds() + inFlight.toMilliseconds() +
                    RunXispTool.TIMEOUT_GRACE_MS
                Some(Duration.millisecond * ms)
        }
    }

    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        let code = match (JsonBridge.stringField(args, "code")) {
            case Some(value) => value
            case None => return RunXispTool.invalidArg("code")
        }
        if (code.trimAscii() == "") {
            return RunXispTool.invalidArg("code")
        }
        let description = match (JsonBridge.stringField(args, "description")) {
            case Some(value) => value
            case None => return RunXispTool.invalidArg("description")
        }
        if (description.trimAscii() == "") {
            return RunXispTool.invalidArg("description")
        }

        // 绑定只按「本次可见」注册：不注册再过滤，因为权限检查对特殊形式无效
        this.runSeq = this.runSeq + 1
        let parentCallId = "${RunXispTool.TOOL_NAME}#${this.runSeq}"
        let namespaces = ArrayList<PtcBindingNamespace>()
        namespaces.add(PtcBindings.forTools(this.visibleTools, RunXispHost(this.env, ctx, parentCallId)))

        let request = PtcRunRequest(code, namespaces, this.env.workDir,
            this.env.cancelled,
            { text => this.env.emit(PtcEvent.Log(parentCallId, text)) },
            timeout: this.env.timeout,
            maxLogChars: this.env.maxLogChars)
        let result = this.runtime.run(request)

        match (result.error) {
            case Some(failure) =>
                let text = "[${failure.kind}] ${failure.message}"
                let withLogs = RunXispTool.attachLogs(text, result.logs)
                return ToolResult(withLogs, None, true, false)
            case None => ()
        }

        let rendered = match (result.value) {
            case Some(value) => JsonBridge.render(value)
            case None => ""
        }
        let body = RunXispTool.attachLogs(rendered, result.logs)
        let text = if (body == "") {
            "(run_xisp completed with no output)"
        } else {
            body
        }
        ToolResult(text, None, false, false)
    }

    /** 缺参或参数类型错误的统一返回。 */
    private static func invalidArg(name: String): ToolResult {
        ToolResult("invalid arguments: '${name}' must be a non-empty string", None, true, false)
    }

    /** 把脚本日志拼在结果之前；两者都为空时返回空串。 */
    private static func attachLogs(body: String, logs: ArrayList<String>): String {
        let logged = String.join(logs.toArray(), delimiter: "")
        if (logged == "") {
            return body
        }
        if (body == "") {
            return logged
        }
        "${logged}\n${body}"
    }
}

/**
 * 把子调用派发回宿主。
 *
 * 每次 `run_xisp` 执行构造一个：它持有该次执行的计数器与上下文，
 * 策略判断则委托给执行环境提供的授权函数。
 */
class RunXispHost <: PtcSubCallHost {
    private let env: PtcRunEnv
    private let ctx: ToolContext
    private let parentCallId: String
    private var counter: Int64 = 0

    init(env: PtcRunEnv, ctx: ToolContext, parentCallId: String) {
        this.env = env
        this.ctx = ctx
        this.parentCallId = parentCallId
    }

    public func authorize(tool: Tool, args: JsonValue): PtcAuthDecision {
        if (this.counter >= this.env.maxSubCalls) {
            return PtcAuthDecision.Deny("sub-call budget exhausted (${this.env.maxSubCalls} calls)")
        }
        this.env.authorize(tool, args)
    }

    public func dispatch(tool: Tool, args: JsonValue, callId: String): ToolResult {
        this.env.emit(PtcEvent.DispatchStart(callId, tool.name()))
        let result = try {
            // 子调用与模型直调受同一个预算约束：卡住的工具不能把整个脚本一起拖死
            executeTool(tool, this.ctx, args, toolBudget(tool, this.env.toolTimeout))
        } catch (e: Exception) {
            // 工具抛出的异常不能穿过求值器：转成普通的失败结果
            ToolResult("[tool error: ${e.message}]", None, true, false)
        }
        this.env.emit(PtcEvent.DispatchEnd(callId, tool.name(), result.text, result.isError))
        result
    }

    public func nextCallId(): String {
        this.counter = this.counter + 1
        "${this.parentCallId}:ptc:${this.counter}"
    }
}
