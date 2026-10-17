package atelier.agent

import atelier.message.*

/**
 * 回合收尾的决策：**接着跑，还是收尾**。
 *
 * 抽出来的理由不是"架构好看"：这段判断原先散在循环体尾部，与事件发射、历史追加
 * 缠在一起，**无法单独测试**。它的三条分支（截断续跑 / 收尾自验 / 正常结束）
 * 各自都有明确的边界条件，出错的表现是「任务被半截交付」或「无限续跑」——
 * 都属于事后很难从日志看出来的那类。抽成纯函数后可以直接断言。
 */
public enum TurnVerdict {
    /** 输出被 token 上限截断，同一回合内再请求一次（不计新回合） */
    | ContinueAfterTruncation
    /** 模型宣布完成，但还没做过收尾自验：先要求它实操核对 */
    | VerifyBeforeFinish
    /** 正常收尾 */
    | End
}

/**
 * 判定一次模型响应之后该做什么。
 *
 * @param stopReason 本次响应的停止原因
 * @param lengthContinuations 本回合已因截断续跑的次数
 * @param maxLengthContinuations 续跑预算（0 = 关闭，保持「截断即结束」的旧行为）
 * @param toolCallCount 整个 run 累计的工具调用次数（0 = 还没干活，自验没意义）
 * @param verifyPasses 已做过的自验次数
 * @param maxVerifyPasses 自验预算（0 = 关闭）
 */
public func decideTurnVerdict(stopReason: StopReason, lengthContinuations: Int64,
    maxLengthContinuations: Int64, toolCallCount: Int64, verifyPasses: Int64,
    maxVerifyPasses: Int64): TurnVerdict {
    // 仓颉枚举没有内置 ==：用模式匹配取出「是否被截断」「是否宣布完成」
    let truncated = match (stopReason) {
        case StopReason.Length => true
        case _ => false
    }
    if (truncated) {
        // 预算还有就续跑；预算用完（含 0 = 关闭）则按旧行为结束
        return if (lengthContinuations < maxLengthContinuations) {
            TurnVerdict.ContinueAfterTruncation
        } else {
            TurnVerdict.End
        }
    }
    let announcedDone = match (stopReason) {
        case StopReason.EndTurn => true
        case _ => false
    }
    // 自验只对「真的做过事 + 正常结束」有意义：没干活的对话不需要核对产物
    if (announcedDone && toolCallCount > 0 && verifyPasses < maxVerifyPasses) {
        return TurnVerdict.VerifyBeforeFinish
    }
    TurnVerdict.End
}
