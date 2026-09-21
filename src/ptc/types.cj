package atelier.ptc

import jsonvalue.*
import std.collection.*
import std.time.*

/**
 * 工具呈现模式。
 *
 * native schema 与 SDK 声明是同一个可见工具集的两种投影，不是两次独立注册：
 * 切换模式只改变「通告给模型什么」，不改变工具本身的可用性。
 */
public enum ToolPresentationMode {
    /** 默认：工具以 JSON Schema 逐次通告（现网行为）。 */
    | Native
    /** 只通告 run_xisp，工具经 SDK 绑定暴露。 */
    | Ptc
    /** 原生 schema 与 SDK 并存。提示词成本翻倍，仅用于灰度对比。 */
    | Both
}

/**
 * 绑定调用的结果。
 *
 * 失败以值表达，而不是抛异常穿过求值器：脚本侧表现为可检出的错误值，
 * 与 xisp 的「错误即值」模型一致，程序可以用条件分支决定是否继续。
 */
public enum PtcBindingOutcome {
    | Ok(JsonValue)
    | Err(String)
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
