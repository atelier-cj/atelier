package atelier.tool

import jsonvalue.*
import std.time.*

/**
 * 工具预算策略：**只读**与**有副作用**两类分别给额度。
 *
 * 为什么分两类：被超时的执行不会被停掉（见 {@link executeTool}），于是超时的含义
 * 对两类工具完全不同——
 *
 * - 只读工具超时：白跑一趟，重试无害，代价只是时间；
 * - 有副作用工具超时：**结果未知**（可能已经落盘，也可能什么都没做）。模型若把
 *   它当成「失败了」直接重试，就可能把一次写入变成两次。
 *
 * 所以有副作用那一类既给更宽的额度（构建/安装这类正常耗时本就长），也在超时文本里
 * 明确「结果未知、先核实再重试」。只读/有副作用沿用 `ToolExecutionMode` 这条既有
 * 约定（信任闸门同源）。
 */
/**
 * 工具对自己时间预算的声明。
 *
 * 为什么要三态：**「没意见」与「不该有预算」是两件事**。`ask_user` 等的是人，
 * 人思考多久都不算卡死；若用同一个空值表达，框架预算就会悄悄套到它头上，
 * 于是「用户想了 31 秒」被报成「工具超时」。
 */
public enum ToolBudget <: ToString {
    /** 没意见：由框架策略（只读/有副作用）决定。 */
    | Default
    /** 本工具不该有预算（等人回答之类）。 */
    | Unbounded
    /** 工具自己的额度。 */
    | Limit(Duration)

    public func toString(): String {
        match (this) {
            case Default => "default"
            case Unbounded => "unbounded"
            case Limit(d) => "limit(${describeDuration(d)})"
        }
    }
}

public struct ToolBudgetPolicy {
    /** 只读（`Parallel`）工具的额度；None 或非正数 = 不限时。 */
    public let readOnly: Option<Duration>
    /** 有副作用（`Sequential`）工具的额度；None 或非正数 = 不限时。 */
    public let sideEffecting: Option<Duration>

    public init(readOnly: Option<Duration>, sideEffecting: Option<Duration>) {
        this.readOnly = readOnly
        this.sideEffecting = sideEffecting
    }

    /** 解析一次调用的实际额度：工具自声明优先，否则按只读/有副作用归类。 */
    public func forTool(tool: Tool): Option<Duration> {
        match (tool.timeoutBudget()) {
            case ToolBudget.Unbounded => None
            case ToolBudget.Limit(declared) => Some(declared)
            case ToolBudget.Default =>
                match (tool.executionMode()) {
                    case ToolExecutionMode.Parallel => this.readOnly
                    case ToolExecutionMode.Sequential => this.sideEffecting
                }
        }
    }

    /**
     * 两类里更宽的那个额度。
     *
     * 给「外层要包住一次在途子调用」的场景用（`run_xisp` 的自身预算）：子调用属于
     * 哪一类在算外层额度时还不知道，取宽的才不会提前掐断。
     */
    public func widest(): Option<Duration> {
        let a = match (this.readOnly) { case Some(d) => d.toMilliseconds(); case None => Int64(-1) }
        let b = match (this.sideEffecting) { case Some(d) => d.toMilliseconds(); case None => Int64(-1) }
        if (a < 0 || b < 0) {
            // 任一类不限时 = 子调用可能无限等，外层也不设限
            return None
        }
        Some(Duration.millisecond * (if (a > b) { a } else { b }))
    }
}

/**
 * 工具调用的墙钟预算。
 *
 * 工具是**同步**接口（`execute` 一直阻塞到返回），内部没有可协作的中断点，
 * 因此预算只能在调用边界上用「另起线程 + 限时等待」实现。
 *
 * 超时语义（重要）：
 * - 调用方立刻拿回一个失败结果（`isError = true`），回合继续前进，模型能看到
 *   失败原因并自行决定重试或换路——而不是整个回合被一个卡住的工具拖死。
 * - 被超时的**那次执行不会停止**：仓颉线程不可抢占，它会在后台一直跑到自己结束。
 *   所以预算是「不再等它」，不是「把它停掉」：它保护回合的前进，不保护副作用。
 * - `None` 或不足 1ms 的预算 = 不限时，直接在当前线程同步执行（不额外起线程）。
 */

public func executeTool(
    tool: Tool,
    ctx: ToolContext,
    args: JsonValue,
    budget: Option<Duration>
): ToolResult {
    let limit = match (budget) {
        case Some(value) => value
        case None => return tool.execute(ctx, args)
    }
    if (limit.toMilliseconds() <= 0) {
        return tool.execute(ctx, args)
    }

    let future = spawn {
        tool.execute(ctx, args)
    }
    try {
        future.get(limit)
    } catch (e: TimeoutException) {
        // 到这一步有两种可能：真的等满了预算，或者工具自己抛了 TimeoutException。
        // tryGet 区分两者：任务已结束（无论带结果还是带异常）就让它的结果/异常
        // 原样冒泡，仍在运行才是框架超时。
        match (future.tryGet()) {
            case Some(result) =>
                // 竞态：恰好在判定超时的瞬间完成——真结果优先，不伪造失败
                result
            case None =>
                // 协作式取消请求：本身不会停止线程，但让「可以自己放弃」的工具
                // （检查 Thread.hasPendingCancellation 的实现）有机会提前收尾
                future.cancel()
                ToolResult(timeoutText(tool, limit), None, true, false)
        }
    }
}

/**
 * 单一额度版本的解析（工具自声明优先）。
 *
 * 新调用点请用 {@link ToolBudgetPolicy.forTool}：它按只读/有副作用分流；
 * 这里保留给「手上只有一个额度」的场景与既有测试。
 */
public func toolBudget(tool: Tool, fallback: Option<Duration>): Option<Duration> {
    match (tool.timeoutBudget()) {
        case ToolBudget.Unbounded => None
        case ToolBudget.Limit(declared) => Some(declared)
        case ToolBudget.Default => fallback
    }
}

/**
 * 超时结果文本：说清是谁、等了多久，以及**接下来该怎么办**。
 *
 * 两类的差别不在措辞，而在模型据此做的下一步：读类重试无害，写类重试可能把一次
 * 写入变成两次——所以后者必须挑明「结果未知」。
 */
func timeoutText(tool: Tool, limit: Duration): String {
    let name = tool.name()
    let spent = describeDuration(limit)
    match (tool.executionMode()) {
        case ToolExecutionMode.Parallel =>
            "[tool timeout] '${name}' did not return within ${spent}; the call was abandoned " +
                "and may still be running in the background (declared side-effect-free)."
        case ToolExecutionMode.Sequential =>
            "[tool timeout] '${name}' did not return within ${spent}. The call was abandoned but " +
                "may still complete in the background, so its outcome is UNKNOWN — verify the " +
                "resulting state (read the file / check the effect) before retrying."
    }
}

/** 预算的可读形式：整秒写 `30s`，否则写毫秒。 */
func describeDuration(value: Duration): String {
    let ms = value.toMilliseconds()
    if (ms > 0 && ms % 1000 == 0) {
        return "${ms / 1000}s"
    }
    return "${ms}ms"
}
