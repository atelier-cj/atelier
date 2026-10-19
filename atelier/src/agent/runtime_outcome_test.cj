package atelier.agent

/*
 * `outcomeOf`：从事件流读出「这次 run 该不该算成功」。
 *
 * 它存在的理由是**有真实消费者**：A2A 与 AG-UI 两个协议适配层此前各自用
 * `StopReason`（模型的 5 个值）推断 run 的结局，A2A 甚至要从 `AgentEndEvent` 的
 * 消息文本里匹配 `[Runtime error: ...]` 才能认出崩溃收尾。信息不足才需要猜，
 * 而现在 `TurnEndEvent.reason` 直接给出答案。
 *
 * 本文件锁住三元组（reason / succeeded / failureText）对每个变体的取值。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import jsonvalue.*

func outcomeEvent(reason: TurnEndReason, text: String): TurnEndEvent {
    TurnEndEvent(AssistantMessage(ContentList.ofText(text), "", "", StopReason.EndTurn,
        TokenUsage(0, 0), 0), ArrayList<ToolResultMessage>(), reason)
}

func eventsOf(evs: Array<AgentEvent>): ArrayList<AgentEvent> {
    let l = ArrayList<AgentEvent>()
    for (e in evs) { l.add(e) }
    l
}

// Completed：唯一的成功原因
@Test
func outcome_completedIsSuccess() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.Completed, "做完了")]))
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.Completed => ()
            case _ => @Fail("reason 应为 Completed")
        }
        case None => @Fail("应当取出 reason")
    }
    @Expect(out.succeeded, true)
    @Expect(out.failureText.isNone(), true)
}

// ToolBudgetExhausted：不是成功，也不该被当成 Completed（stopReason 表达不了这个）
@Test
func outcome_toolBudgetExhaustedIsFailure() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.ToolBudgetExhausted,
        "Max tool calls reached, skipping")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.ToolBudgetExhausted => ()
            case _ => @Fail("reason 应为 ToolBudgetExhausted")
        }
        case None => @Fail("应当取出 reason")
    }
    // 失败说明取自该回合的消息文本
    match (out.failureText) {
        case Some(t) => @Expect(t.contains("Max tool calls"), true)
        case None => @Fail("失败时应当给出说明")
    }
}

// BlockedByHook：被钩子拦下，不算成功
@Test
func outcome_blockedByHookIsFailure() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.BlockedByHook,
        "[Run short-circuited by hook]")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.BlockedByHook => ()
            case _ => @Fail("reason 应为 BlockedByHook")
        }
        case None => @Fail("应当取出 reason")
    }
}

// Suspended：等外部输入，不是成功（也不是失败——消费端按 reason 自行决定）
@Test
func outcome_suspendedIsNotSuccess() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.Suspended, "要确认")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.Suspended => ()
            case _ => @Fail("reason 应为 Suspended")
        }
        case None => @Fail("应当取出 reason")
    }
}

// Cancelled：调用方取消
@Test
func outcome_cancelledIsNotSuccess() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.Cancelled, "取消了")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.Cancelled => ()
            case _ => @Fail("reason 应为 Cancelled")
        }
        case None => @Fail("应当取出 reason")
    }
}

// Failed：provider 错误文本已在 message 里，直接从 reason 判断要不要取
@Test
func outcome_failedCarriesFailureText() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.Failed,
        "[provider error] boom")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.Failed => ()
            case _ => @Fail("reason 应为 Failed")
        }
        case None => @Fail("应当取出 reason")
    }
    match (out.failureText) {
        case Some(t) => @Expect(t.contains("boom"), true)
        case None => @Fail("Failed 应当带说明")
    }
}

// MaxTurnsReached：被上限掐断，不算成功
@Test
func outcome_maxTurnsReachedIsFailure() {
    let out = outcomeOf(eventsOf([outcomeEvent(TurnEndReason.MaxTurnsReached,
        "最后一回合的产出")]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.MaxTurnsReached => ()
            case _ => @Fail("reason 应为 MaxTurnsReached")
        }
        case None => @Fail("应当取出 reason")
    }
}

// 多回合：结局由**最后一条** TurnEndEvent 决定
@Test
func outcome_usesLastTurnEnd() {
    let out = outcomeOf(eventsOf([
        outcomeEvent(TurnEndReason.Completed, "中间回合"),
        outcomeEvent(TurnEndReason.ToolBudgetExhausted, "最后被预算掐断"),
    ]))
    @Expect(out.succeeded, false)
    match (out.reason) {
        case Some(r) => match (r) {
            case TurnEndReason.ToolBudgetExhausted => ()
            case _ => @Fail("应当取最后一条 TurnEndEvent 的 reason")
        }
        case None => @Fail("应当取出 reason")
    }
}

// 空事件流：不能当成功（否则"什么都没跑"会被报成完成）
@Test
func outcome_emptyEventsIsNotSuccess() {
    let out = outcomeOf(ArrayList<AgentEvent>())
    @Expect(out.reason.isNone(), true)
    @Expect(out.succeeded, false)
    @Expect(out.failureText.isNone(), true)
}

// 只有其它事件、没有回合结束事件：同样不算成功
@Test
func outcome_withoutTurnEndIsNotSuccess() {
    let out = outcomeOf(eventsOf([AgentStartEvent("s"), TurnStartEvent()]))
    @Expect(out.reason.isNone(), true)
    @Expect(out.succeeded, false)
}
