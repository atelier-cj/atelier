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

// ==================== 工具调用预算（decideToolBudget） ====================

func isBudget(v: ToolBudgetVerdict, expected: ToolBudgetVerdict): Bool {
    match (v) {
        case expected => true
        case _ => false
    }
}

// 预算远未用完：全部允许
@Test
func toolBudget_allAllowed() {
    @Expect(isBudget(decideToolBudget(0, 3, 50), ToolBudgetVerdict.AllAllowed), true)
    @Expect(isBudget(decideToolBudget(47, 3, 50), ToolBudgetVerdict.AllAllowed), true)  // 恰好用满
}

// 已用完：一个都不许（要结束回合，不是"跑完整批再说"）
@Test
func toolBudget_exhausted() {
    @Expect(isBudget(decideToolBudget(50, 1, 50), ToolBudgetVerdict.Exhausted), true)
    @Expect(isBudget(decideToolBudget(60, 1, 50), ToolBudgetVerdict.Exhausted), true)
}

// 本批超了：只允许剩余额度
@Test
func toolBudget_trimmed() {
    match (decideToolBudget(48, 5, 50)) {
        case Trimmed(allowed) => @Expect(allowed, Int64(2))
        case _ => @Fail("expected Trimmed(2)")
    }
}

// 边界：剩余额度刚好等于本批 → 不裁剪
@Test
func toolBudget_exactFitIsNotTrimmed() {
    @Expect(isBudget(decideToolBudget(45, 5, 50), ToolBudgetVerdict.AllAllowed), true)
}

// 裁剪时 allowed 必须为正：否则 Exhausted 与 Trimmed 的边界会重叠
@Test
func toolBudget_trimmedIsAlwaysPositive() {
    match (decideToolBudget(49, 5, 50)) {
        case Trimmed(allowed) => @Expect(allowed > 0, true)
        case _ => @Fail("expected Trimmed with positive allowance")
    }
}
