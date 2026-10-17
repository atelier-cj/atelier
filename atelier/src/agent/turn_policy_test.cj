package atelier.agent

import atelier.message.*

// ==================== 回合收尾判定（decideTurnVerdict） ====================

func isVerdict(v: TurnVerdict, expected: TurnVerdict): Bool {
    match (v) {
        case expected => true
        case _ => false
    }
}

// 正常结束（没做过事）：直接收尾，不触发自验
@Test
func turnVerdict_endTurnWithoutWork() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.EndTurn, 0, 3, 0, 0, 2),
        TurnVerdict.End), true)
}

// 正常结束且做过事：先自验
@Test
func turnVerdict_endTurnAfterWorkVerifies() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.EndTurn, 0, 3, 5, 0, 2),
        TurnVerdict.VerifyBeforeFinish), true)
}

// 自验预算用完 → 收尾（不会无限自验）
@Test
func turnVerdict_verifyBudgetExhausted() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.EndTurn, 0, 3, 5, 2, 2),
        TurnVerdict.End), true)
}

// 自验关闭（预算 0）→ 收尾
@Test
func turnVerdict_verifyDisabled() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.EndTurn, 0, 3, 5, 0, 0),
        TurnVerdict.End), true)
}

// 截断且预算还有 → 同回合续跑
@Test
func turnVerdict_truncatedContinues() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.Length, 0, 3, 5, 0, 2),
        TurnVerdict.ContinueAfterTruncation), true)
}

// 截断但续跑预算用完 → 收尾（不会无限续跑）
@Test
func turnVerdict_truncatedBudgetExhausted() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.Length, 3, 3, 5, 0, 2),
        TurnVerdict.End), true)
}

// 续跑关闭（预算 0）→ 保持旧行为：截断即结束
@Test
func turnVerdict_continuationDisabled() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.Length, 0, 0, 5, 0, 2),
        TurnVerdict.End), true)
}

// 截断优先于自验：撞到上限说明这条没写完，不该先去核对产物
@Test
func turnVerdict_truncationTakesPrecedenceOverVerify() {
    // 即使做过事、自验预算还有，只要被截断就先续写
    @Expect(isVerdict(decideTurnVerdict(StopReason.Length, 0, 3, 5, 0, 2),
        TurnVerdict.ContinueAfterTruncation), true)
}

// 工具调用类停止原因（还没收敛）：既不是截断也不是完成 → 走收尾分支，
// 由上层工具执行逻辑接手（这个函数只答"这一轮模型响应之后该不该停"）
@Test
func turnVerdict_toolUseIsNotTerminal() {
    @Expect(isVerdict(decideTurnVerdict(StopReason.ToolUse, 0, 3, 0, 0, 2),
        TurnVerdict.End), true)
}
