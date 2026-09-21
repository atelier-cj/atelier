package atelier.tool

import jsonvalue.*
import std.time.*

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
                ToolResult(timeoutText(tool.name(), limit), None, true, false)
        }
    }
}

/**
 * 解析一次调用的实际预算。
 *
 * 工具自己声明的预算优先于框架配置：只有工具知道内部是否还压着另一层预算，
 * 需要先把那层走完才能给出比「被外层掐断」更有信息量的失败（见
 * {@link Tool.timeoutBudget}）。
 */
public func toolBudget(tool: Tool, fallback: Option<Duration>): Option<Duration> {
    match (tool.timeoutBudget()) {
        case Some(declared) => Some(declared)
        case None => fallback
    }
}

/** 超时结果文本：说清是谁、等了多久、以及「还在后台跑」这个事实。 */
func timeoutText(name: String, limit: Duration): String {
    "[tool timeout] '${name}' did not return within ${describeDuration(limit)}; " +
        "the call was abandoned and may still be running in the background"
}

/** 预算的可读形式：整秒写 `30s`，否则写毫秒。 */
func describeDuration(value: Duration): String {
    let ms = value.toMilliseconds()
    if (ms > 0 && ms % 1000 == 0) {
        return "${ms / 1000}s"
    }
    return "${ms}ms"
}
