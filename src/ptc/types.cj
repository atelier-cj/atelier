package atelier.ptc

import jsonvalue.*
import std.collection.*
import std.time.*
import atelier.tool.*

/**
 * 工具呈现模式。
 *
 * native schema 与 SDK 声明是同一个可见工具集的两种投影，不是两次独立注册：
 * 切换模式只改变「通告给模型什么」，不改变工具本身的可用性。
 */
public enum ToolPresentationMode <: ToString & Equatable<ToolPresentationMode> {
    /** 默认：工具以 JSON Schema 逐次通告（现网行为）。 */
    | Native
    /** 只通告 run_xisp，工具经 SDK 绑定暴露。 */
    | Ptc
    /** 原生 schema 与 SDK 并存。提示词成本翻倍，仅用于灰度对比。 */
    | Both

    public func toString(): String {
        match (this) {
            case Native => "native"
            case Ptc => "ptc"
            case Both => "both"
        }
    }

    public operator func ==(right: ToolPresentationMode): Bool {
        this.toString() == right.toString()
    }

    public operator func !=(right: ToolPresentationMode): Bool {
        !(this == right)
    }

    /**
     * 从配置文本解析；无法识别时回落到 `Native`（现网行为）。
     *
     * 不做严格拒绝：配置里的拼写错误应当退化为「保持现状」而不是让整个
     * Agent 起不来；需要显式发现拼写问题的地方用 `toString()` 回读比对。
     */
    public static func fromString(text: String): ToolPresentationMode {
        match (text) {
            case "ptc" => Ptc
            case "both" => Both
            case _ => Native
        }
    }
}

/**
 * 绑定调用的结果。
 *
 * 失败以值表达，而不是抛异常穿过求值器：脚本侧表现为可检出的错误值，
 * 与 xisp 的「错误即值」模型一致，程序可以用条件分支决定是否继续。
 */
public enum PtcBindingOutcome <: ToString {
    | Ok(JsonValue)
    | Err(String)

    public func toString(): String {
        match (this) {
            // 成功值不展开打印：它可能很大，且仅在诊断时用到
            case Ok(_) => "ok"
            case Err(message) => "err(${message})"
        }
    }
}

/**
 * 一个宿主绑定：接收 JSON 参数，同步返回结果。
 *
 * 同步是因为 atelier 的工具本身就是同步的（`Tool.execute`），
 * 绑定直接调用即可，无需协程或回调桥。
 */
public type PtcBindingFunction = (JsonValue) -> PtcBindingOutcome

/**
 * 一个绑定命名空间，在程序里表现为同名全局对象。
 *
 * 当前只有一个命名空间 `tools`，程序写作 `(tools::read_file {...})`。
 */
public struct PtcBindingNamespace {
    /** 程序里可见的命名空间名。 */
    public let global: String
    /** 成员名 → 绑定。成员名即工具名，原样使用，不做别名改写。 */
    public let functions: HashMap<String, PtcBindingFunction>

    public init(global: String, functions: HashMap<String, PtcBindingFunction>) {
        this.global = global
        this.functions = functions
    }
}

/**
 * 一次程序执行的全部输入。
 */
public struct PtcRunRequest {
    /** 程序源码（xisp）。 */
    public let program: String
    /** 宿主绑定。 */
    public let bindings: ArrayList<PtcBindingNamespace>
    /** 执行时的工作目录（绑定内的工具据此解析相对路径）。 */
    public let workDir: String
    /** 经过时间预算；None 用 PTC 配置里的默认值。 */
    public let timeout: Option<Duration>
    /** 外层取消检查；返回 true 时求值尽快停止。 */
    public let cancelled: () -> Bool
    /** 脚本输出（print / println 等）的落点。 */
    public let onLog: (String) -> Unit
    /** 日志累计上限（字符数）；超出后停止累积并附截断提示。 */
    public let maxLogChars: Int64

    public init(
        program: String,
        bindings: ArrayList<PtcBindingNamespace>,
        workDir: String,
        cancelled: () -> Bool,
        onLog: (String) -> Unit,
        timeout!: Option<Duration> = None,
        maxLogChars!: Int64 = 32768
    ) {
        this.program = program
        this.bindings = bindings
        this.workDir = workDir
        this.timeout = timeout
        this.cancelled = cancelled
        this.onLog = onLog
        this.maxLogChars = maxLogChars
    }
}

/**
 * 失败分类。
 *
 * 各类别互不蕴含：超时不等于异常，取消不等于超时，语法错误也不等于运行时错误。
 * 与「程序正常返回 nil」严格可区分——后者是 `value = None, error = None`。
 */
public enum PtcFailureKind <: ToString {
    /** 脚本运行时错误（含 eval 产生的 Error 值）。 */
    | Exception
    /** 解析失败：输入不完整或存在语法错误。 */
    | SyntaxError
    /** 经过时间预算耗尽。 */
    | Timeout
    /** 外层取消。 */
    | Cancelled
    /** 日志或完成值超出上限。 */
    | OutputLimit

    /** 稳定的短标识，用于日志与事件（不是给模型看的 prose）。 */
    public func toString(): String {
        match (this) {
            case Exception => "exception"
            case SyntaxError => "syntax_error"
            case Timeout => "timeout"
            case Cancelled => "cancelled"
            case OutputLimit => "output_limit"
        }
    }
}

/**
 * 一次失败的原因。
 */
public struct PtcRunFailure {
    public let kind: PtcFailureKind
    /** 供模型自我修正的可读信息。 */
    public let message: String

    public init(kind: PtcFailureKind, message: String) {
        this.kind = kind
        this.message = message
    }
}

/**
 * 一次执行的结果。
 *
 * `error` 是字段而不是异常路径：报告「程序失败了」是调用方的职责，
 * 不应通过异常传播。
 */
public struct PtcRunResult {
    /**
     * 程序最后一个顶层表达式的值，且成功跨过 JSON 边界时才有值。
     * 失败、无值或不可序列化的完成值都留空，不用字符串顶替。
     */
    public let value: Option<JsonValue>
    /** 按发出顺序累积的脚本输出。 */
    public let logs: ArrayList<String>
    /** 非空表示运行失败。 */
    public let error: Option<PtcRunFailure>

    public init(value: Option<JsonValue>, logs: ArrayList<String>, error: Option<PtcRunFailure>) {
        this.value = value
        this.logs = logs
        this.error = error
    }

    /** 是否运行成功。 */
    public func isOk(): Bool {
        this.error.isNone()
    }
}

/**
 * 子调用事件。
 *
 * 运行时把它翻译成 `AgentEvent` 再交给宿主。本包因此不必依赖 agent 包——
 * agent 包要在 `resolveTools()` 里构造 `RunXispTool`，反向依赖会成环。
 */
public enum PtcEvent <: ToString {
    /** 子调用开始。 */
    | DispatchStart(String, String)
    /** 子调用结束：callId、工具名、结果文本、是否失败。 */
    | DispatchEnd(String, String, String, Bool)
    /** 脚本输出片段（实时，与最终 logs 内容一致）。 */
    | Log(String)

    public func toString(): String {
        match (this) {
            case DispatchStart(callId, name) => "dispatch_start(${callId}, ${name})"
            case DispatchEnd(callId, name, _, isError) => "dispatch_end(${callId}, ${name}, error=${isError})"
            case Log(text) => "log(${text})"
        }
    }
}

/**
 * 子调用的授权结果。
 *
 * 与模型直调的 `beforeTool` 钩子语义对齐：除了放行与拒绝，还允许改写参数
 * （`Modify`）。不支持改写会让 PTC 与 native 模式在同一套钩子下行为分叉。
 */
public enum PtcAuthDecision {
    /** 放行，按原参数执行。 */
    | Allow
    /** 放行，并以给定参数替换原参数。 */
    | AllowWith(JsonValue)
    /** 拒绝，理由作为工具错误回给脚本。 */
    | Deny(String)
}

/**
 * 授权一次子调用。实现方应复用与模型直调相同的策略链：
 * 信任闸门 → 交互审批 → `beforeTool` 钩子。
 */
public type PtcAuthorizer = (Tool, JsonValue) -> PtcAuthDecision

/**
 * 一次 `run_xisp` 的执行环境。
 *
 * 由运行时在每轮组装工具时构造：闭包捕获该回合的取消标志、事件出口与授权逻辑。
 * 因此一个 `RunXispTool` 实例只在构造它的那一轮内有效，不跨回合复用。
 */
public struct PtcRunEnv {
    /** 工作目录（子调用据此解析相对路径）。 */
    public let workDir: String
    /** 所属会话 id。 */
    public let sessionId: String
    /** 外层取消检查。 */
    public let cancelled: () -> Bool
    /** 子调用与脚本输出的事件出口。 */
    public let emit: (PtcEvent) -> Unit
    /**
     * 子调用授权。实现方应复用与模型直调相同的策略链：
     * 信任闸门 → 交互审批 → `beforeTool` 钩子。
     */
    public let authorize: PtcAuthorizer
    /** 单次程序的子调用上限。 */
    public let maxSubCalls: Int64
    /** 经过时间预算；None 用配置缺省值。 */
    public let timeout: Option<Duration>
    /**
     * 单次子调用的时间预算；None 用配置缺省值。
     *
     * 程序整体预算（{@link timeout}）挡不住「子调用卡死」：求值器的中断检查只在
     * 跑指令时发生，而同步工具一旦阻塞就停在原生调用里。子调用必须自带预算，
     * 卡住时把失败交回程序，求值器才能重新拿到控制权。
     */
    public let toolTimeout: Option<Duration>
    /** 日志累计上限（字符数）。 */
    public let maxLogChars: Int64

    public init(
        workDir: String,
        sessionId: String,
        cancelled: () -> Bool,
        emit: (PtcEvent) -> Unit,
        authorize: PtcAuthorizer,
        maxSubCalls!: Int64 = 64,
        timeout!: Option<Duration> = None,
        toolTimeout!: Option<Duration> = None,
        maxLogChars!: Int64 = 32768
    ) {
        this.workDir = workDir
        this.sessionId = sessionId
        this.cancelled = cancelled
        this.emit = emit
        this.authorize = authorize
        this.maxSubCalls = maxSubCalls
        this.timeout = timeout
        this.toolTimeout = toolTimeout
        this.maxLogChars = maxLogChars
    }
}
