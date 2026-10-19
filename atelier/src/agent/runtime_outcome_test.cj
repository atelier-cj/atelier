package atelier.agent

/*
 * `isSuccess(reason)`：这次 run 该不该算成功。
 *
 * 它存在的理由是**有具体的行会被替换**：A2A 与 AG-UI 两个协议适配层此前各自用
 * `stopReason`（模型的 5 个值）推断 run 的结局，A2A 甚至要从 `AgentEndEvent` 的
 * 消息文本里匹配 `[Runtime error: ...]` 才能认出崩溃收尾。有了 `TurnEndReason`，
 * 那些推断分支可以删掉，换成一次 `isSuccess` 调用。
 *
 * 本文件锁住 7 个变体的成功/非成功归属。
 */

import std.collection.*

// Completed 是唯一的成功原因
@Test
func outcome_completedIsSuccess() {
    @Expect(isSuccess(TurnEndReason.Completed), true)
}

// ToolBudgetExhausted：模型可能正常回了话，但任务被预算掐断 —— 不算成功。
// 这正是 stopReason 表达不了的情形。
@Test
func outcome_toolBudgetExhaustedIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.ToolBudgetExhausted), false)
}

// BlockedByHook：被钩子拦下
@Test
func outcome_blockedByHookIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.BlockedByHook), false)
}

// Suspended：等外部输入 —— 不是失败，但也不是"跑完了"
@Test
func outcome_suspendedIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.Suspended), false)
}

// Cancelled：调用方取消
@Test
func outcome_cancelledIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.Cancelled), false)
}

// Failed：provider / 批次 / 内部异常
@Test
func outcome_failedIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.Failed), false)
}

// MaxTurnsReached：被回合上限掐断
@Test
func outcome_maxTurnsReachedIsNotSuccess() {
    @Expect(isSuccess(TurnEndReason.MaxTurnsReached), false)
}
