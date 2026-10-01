package atelier.a2a

import std.collection.*
import jsonvalue.*
import a2a.types.*
import atelier.agent.*
import atelier.message.{AssistantMessage, ContentBlock, ContentList, StopReason, TokenUsage, ToolCallBlock, ToolResultMessage, UserMessage}
// 事件里的消息是 atelier（llm_api）类型，与 a2a.types.Message 同名，取别名区分
import atelier.message.Message as AtelierMessage
import atelier.tool.ExternalRequest

// ---------- 辅助构造 ----------

private func a2aAssistantMsg(content: ContentList, stopReason: StopReason): AssistantMessage {
    AssistantMessage(content, "", "", stopReason, TokenUsage(0, 0), 0)
}

private func a2aTextDelta(delta: String): MessageUpdateEvent {
    MessageUpdateEvent(a2aAssistantMsg(ContentList.ofText(delta), StopReason.EndTurn), delta)
}

private func a2aToolCallMsg(callId: String, name: String, args: JsonValue): AssistantMessage {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.ToolCall(ToolCallBlock(callId, name, args)))
    a2aAssistantMsg(ContentList(blocks), StopReason.ToolUse)
}

private func a2aArgs(): JsonValue {
    let m = HashMap<String, JsonValue>()
    m["cmd"] = JsonValue.String("ls -la")
    JsonValue.Map(m)
}

private func a2aStatusEvents(outs: ArrayList<StreamResponse>): ArrayList<TaskStatusUpdateEvent> {
    let res = ArrayList<TaskStatusUpdateEvent>()
    for (r in outs) {
        match (r.statusUpdate) {
            case Some(ev) => res.add(ev)
            case None => ()
        }
    }
    res
}

private func a2aArtifactEvents(outs: ArrayList<StreamResponse>): ArrayList<TaskArtifactUpdateEvent> {
    let res = ArrayList<TaskArtifactUpdateEvent>()
    for (r in outs) {
        match (r.artifactUpdate) {
            case Some(ev) => res.add(ev)
            case None => ()
        }
    }
    res
}

private func a2aArtifactText(ev: TaskArtifactUpdateEvent): String {
    let sb = StringBuilder()
    for (p in ev.artifact.parts) {
        match (p.text) {
            case Some(t) => sb.append(t)
            case None => ()
        }
    }
    sb.toString()
}

private func a2aToolStatus(ev: TaskArtifactUpdateEvent): String {
    match (ev.artifact.metadata) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("status")) {
                case Some(JsonValue.String(s)) => s
                case _ => ""
            }
        case _ => ""
    }
}

// ---------- 状态：回合开始 → WORKING ----------

@Test
func a2aTranslator_turnStartEmitsWorking() {
    let t = A2aTranslator("task_1", "ctx_1")
    let out = t.translate(TurnStartEvent())
    @Expect(out.size, 1)
    let sts = a2aStatusEvents(out)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Working)
    @Expect(sts[0].taskId, "task_1")
    @Expect(sts[0].contextId, "ctx_1")
    match (sts[0].status.timestamp) {
        case Some(ts) =>
            // 毫秒精度、Z 结尾的定宽 ISO 8601（"2026-10-02T01:02:03.123Z"）
            @Expect(ts.size, 24)
            @Expect(ts.endsWith("Z"), true)
        case None => @Fail("status update missing timestamp")
    }
    @Expect(t.turnCount(), 1)
    @Expect(t.isFinished(), false)
}

// 空增量 / 无关事件不产生任何输出
@Test
func a2aTranslator_emptyDeltaAndUnrelatedEventsNoop() {
    let t = A2aTranslator("task_1", "ctx_1")
    @Expect(t.translate(TurnStartEvent()).size, 1)
    @Expect(t.translate(a2aTextDelta("")).size, 0)
    @Expect(t.translate(AgentStartEvent("sess_1")).size, 0)
    @Expect(t.translate(CompactionStartEvent("c1", "pressure", 10)).size, 0)
    @Expect(t.translate(CompactionEndEvent("c1", "pressure", 10, 4, 100)).size, 0)
    @Expect(t.translate(CompactionEvent("pressure", 100, 10)).size, 0)
}

// ---------- 文本：多增量归并为同一产物的分片 ----------

// 首片 append=false 建立产物，中间片 append=true；收尾片带 lastChunk=true，
// 同回合所有分片共用一个 artifactId，逐片拼起来就是完整文本
@Test
func a2aTranslator_textDeltasMergeIntoChunksOfOneArtifact() {
    let t = A2aTranslator("task_1", "ctx_1")
    @Expect(t.translate(TurnStartEvent()).size, 1)

    // 首个增量只缓冲：等下一个增量到达才发片，lastChunk 才能落在有内容的分片上
    @Expect(t.translate(a2aTextDelta("你")).size, 0)
    let out2 = t.translate(a2aTextDelta("好"))
    let arts2 = a2aArtifactEvents(out2)
    @Expect(arts2.size, 1)
    @Expect(arts2[0].append, false)
    @Expect(arts2[0].lastChunk, false)
    @Expect(a2aArtifactText(arts2[0]), "你")
    @Expect(arts2[0].taskId, "task_1")
    @Expect(arts2[0].contextId, "ctx_1")

    let arts3 = a2aArtifactEvents(t.translate(a2aTextDelta("！")))
    @Expect(arts3.size, 1)
    @Expect(arts3[0].append, true)
    @Expect(arts3[0].lastChunk, false)
    @Expect(arts3[0].artifact.artifactId, arts2[0].artifact.artifactId)
    @Expect(a2aArtifactText(arts3[0]), "好")

    let out4 = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("你好！"), StopReason.EndTurn), ArrayList<ToolResultMessage>()))
    let arts4 = a2aArtifactEvents(out4)
    @Expect(arts4.size, 1)
    @Expect(arts4[0].append, true)
    @Expect(arts4[0].lastChunk, true)
    @Expect(arts4[0].artifact.artifactId, arts2[0].artifact.artifactId)
    @Expect(a2aArtifactText(arts4[0]), "！")
    let sts4 = a2aStatusEvents(out4)
    @Expect(sts4.size, 1)
    @Expect(sts4[0].status.state, TaskState.Completed)
    @Expect(t.isFinished(), true)

    // 三片归并 == 完整文本
    @Expect(a2aArtifactText(arts2[0]) + a2aArtifactText(arts3[0]) + a2aArtifactText(arts4[0]), "你好！")
}

// 单增量回合：收尾时发唯一一片（append=false + lastChunk=true）
@Test
func a2aTranslator_singleDeltaEmittedAsFinalChunk() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    @Expect(t.translate(a2aTextDelta("hi")).size, 0)
    let out = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("hi"), StopReason.EndTurn), ArrayList<ToolResultMessage>()))
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].append, false)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aArtifactText(arts[0]), "hi")
    @Expect(a2aStatusEvents(out)[0].status.state, TaskState.Completed)
}

// 非流式 provider：只有 MessageEnd/TurnEnd 带文本，收尾时补一片完整文本
@Test
func a2aTranslator_nonStreamedTextFlushedAtTurnEnd() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    let msg = a2aAssistantMsg(ContentList.ofText("非流式回答"), StopReason.EndTurn)
    let out = t.translate(TurnEndEvent(msg, ArrayList<ToolResultMessage>()))
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].append, false)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aArtifactText(arts[0]), "非流式回答")
    @Expect(a2aStatusEvents(out)[0].status.state, TaskState.Completed)
}

// ---------- 工具调用 → 工具产物 ----------

// 声明（MessageEnd 带 toolCalls）→ 产物落一份入参 data part + pending 元数据
@Test
func a2aTranslator_toolCallDeclaredAsArtifact() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    let out = t.translate(MessageEndEvent(a2aToolCallMsg("call_1", "bash", a2aArgs())))
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].append, false)
    @Expect(arts[0].lastChunk, false)
    @Expect(arts[0].artifact.artifactId, "tool_t1_call_1")
    match (arts[0].artifact.name) {
        case Some(n) => @Expect(n, "bash")
        case None => @Fail("artifact name missing")
    }
    @Expect(arts[0].artifact.parts.size, 1)
    match (arts[0].artifact.parts[0].data) {
        case Some(JsonValue.Map(m)) =>
            match (m.get("cmd")) {
                case Some(JsonValue.String(s)) => @Expect(s, "ls -la")
                case _ => @Fail("tool args mismatch")
            }
        case _ => @Fail("tool args data part missing")
    }
    @Expect(a2aToolStatus(arts[0]), "pending")
}

// 执行生命周期：start（running）→ update（进度文本）→ end（完成/失败 + lastChunk）
@Test
func a2aTranslator_toolExecutionLifecycleUpdates() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(MessageEndEvent(a2aToolCallMsg("call_1", "bash", a2aArgs())))

    let s = a2aArtifactEvents(t.translate(ToolExecutionStartEvent("call_1", "bash")))
    @Expect(s.size, 1)
    @Expect(s[0].append, true)
    @Expect(s[0].lastChunk, false)
    @Expect(s[0].artifact.artifactId, "tool_t1_call_1")
    @Expect(a2aToolStatus(s[0]), "running")
    @Expect(s[0].artifact.parts.size, 0)

    let u = a2aArtifactEvents(t.translate(ToolExecutionUpdateEvent("call_1", "processing...")))
    @Expect(u.size, 1)
    @Expect(u[0].append, true)
    @Expect(u[0].lastChunk, false)
    @Expect(a2aArtifactText(u[0]), "processing...")
    @Expect(a2aToolStatus(u[0]), "running")

    let e1 = a2aArtifactEvents(t.translate(ToolExecutionEndEvent("call_1", "done output", false)))
    @Expect(e1.size, 1)
    @Expect(e1[0].append, true)
    @Expect(e1[0].lastChunk, true)
    @Expect(a2aArtifactText(e1[0]), "done output")
    @Expect(a2aToolStatus(e1[0]), "completed")

    // 未声明过的调用（进程重启后接续等场景）：首片必须 append=false，
    // append=true 而产物不存在时参考实现会直接丢弃该片
    let e2 = a2aArtifactEvents(t.translate(ToolExecutionEndEvent("call_2", "boom", true)))
    @Expect(e2.size, 1)
    @Expect(e2[0].append, false)
    @Expect(e2[0].lastChunk, true)
    @Expect(a2aToolStatus(e2[0]), "failed")
    @Expect(a2aArtifactText(e2[0]), "boom")
}

// 工具回合不是任务终态：带工具结果的 TurnEnd 之后还有新回合，必须保持 WORKING
@Test
func a2aTranslator_toolTurnStaysWorkingThenCompletes() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(MessageEndEvent(a2aToolCallMsg("call_1", "bash", a2aArgs())))
    t.translate(ToolExecutionStartEvent("call_1", "bash"))
    t.translate(ToolExecutionEndEvent("call_1", "done", false))

    let results = ArrayList<ToolResultMessage>()
    results.add(ToolResultMessage("call_1", "bash", ContentList.ofText("done"), false, 0))
    let end1 = t.translate(TurnEndEvent(a2aToolCallMsg("call_1", "bash", a2aArgs()), results))
    @Expect(a2aStatusEvents(end1).size, 0)
    @Expect(t.isFinished(), false)

    let start2 = t.translate(TurnStartEvent())
    @Expect(a2aStatusEvents(start2)[0].status.state, TaskState.Working)
    @Expect(t.translate(a2aTextDelta("最终答复")).size, 0)
    let end2 = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("最终答复"), StopReason.EndTurn), ArrayList<ToolResultMessage>()))
    let sts = a2aStatusEvents(end2)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Completed)
    @Expect(t.isFinished(), true)
    // 两个回合的文本产物 id 不同（artifactId 在任务内必须唯一）
    let arts = a2aArtifactEvents(end2)
    @Expect(arts.size, 1)
    @Expect(arts[0].artifact.artifactId, "art_t2")
    @Expect(a2aArtifactText(arts[0]), "最终答复")
}

// 声明了却没执行到的工具（被跳过 / 等待外部执行等）：回合收尾时产物补 lastChunk，不留半开产物。
// 该回合是工具回合（ToolUse + 无结果），本身不是终态 —— 由随后的 AgentEnd 收口。
@Test
func a2aTranslator_unexecutedToolArtifactClosedAtTurnEnd() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(MessageEndEvent(a2aToolCallMsg("call_9", "bash", a2aArgs())))
    let out = t.translate(TurnEndEvent(
        a2aToolCallMsg("call_9", "bash", a2aArgs()), ArrayList<ToolResultMessage>()))
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].append, true)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aToolStatus(arts[0]), "skipped")
    @Expect(a2aStatusEvents(out).size, 0)
    @Expect(t.isFinished(), false)
    let fin = t.translate(AgentEndEvent(ArrayList<AtelierMessage>()))
    @Expect(a2aStatusEvents(fin)[0].status.state, TaskState.Completed)
    @Expect(t.isFinished(), true)
}

// ---------- 终态 ----------

// 异常回合：失败文本以 FAILED 状态消息下发（增量没发过也不会丢），终态后不再接受更新
@Test
func a2aTranslator_errorTurnEmitsFailedWithVisibleText() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("[provider error] HTTP 429"))
    let failed = a2aAssistantMsg(ContentList(blocks), StopReason.Error)
    let out = t.translate(TurnEndEvent(failed, ArrayList<ToolResultMessage>()))
    // 失败原因走终态状态消息，而不是塞进产物
    @Expect(a2aArtifactEvents(out).size, 0)
    let sts = a2aStatusEvents(out)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Failed)
    match (sts[0].status.message) {
        case Some(m) =>
            @Expect(m.role, Role.Agent)
            @Expect(m.text(), "[provider error] HTTP 429")
            @Expect(m.messageId, "msg_t1")
            match (m.contextId) {
                case Some(c) => @Expect(c, "ctx_1")
                case None => @Fail("status message missing contextId")
            }
            match (m.taskId) {
                case Some(tid) => @Expect(tid, "task_1")
                case None => @Fail("status message missing taskId")
            }
        case None => @Fail("failed status without message")
    }
    @Expect(t.isFinished(), true)
    // 终态后：任何后续事件都不再产生更新（同一 taskId 续聊须先 reset）
    @Expect(t.translate(a2aTextDelta("late")).size, 0)
    @Expect(t.translate(TurnStartEvent()).size, 0)
    @Expect(t.translate(TurnEndEvent(failed, ArrayList<ToolResultMessage>())).size, 0)
}

// 取消回合 → CANCELED
@Test
func a2aTranslator_abortedTurnEmitsCanceled() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(a2aTextDelta("做到一半"))
    let out = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("做到一半"), StopReason.Aborted), ArrayList<ToolResultMessage>()))
    // 半截文本先收尾（lastChunk），再下发终态
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aArtifactText(arts[0]), "做到一半")
    @Expect(a2aStatusEvents(out)[0].status.state, TaskState.Canceled)
    @Expect(t.isFinished(), true)
}

// 截断续跑（StopReason.Length）：TurnEnd 不是终态；产物先收尾，运行由 AgentEnd 收口
@Test
func a2aTranslator_lengthTurnStaysWorkingUntilAgentEnd() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(a2aTextDelta("半截"))
    let end = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("半截"), StopReason.Length), ArrayList<ToolResultMessage>()))
    @Expect(a2aStatusEvents(end).size, 0)
    @Expect(t.isFinished(), false)
    let arts = a2aArtifactEvents(end)
    @Expect(arts.size, 1)
    @Expect(arts[0].lastChunk, true)

    let fin = t.translate(AgentEndEvent(ArrayList<AtelierMessage>()))
    let sts = a2aStatusEvents(fin)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Completed)
    @Expect(t.isFinished(), true)
}

// 运行时 catch 路径的收尾哨兵：任务并没有成功，不能按 COMPLETED 下发；
// 已流出的半截文本仍要收干净（lastChunk）再报失败
@Test
func a2aTranslator_runtimeErrorSentinelEmitsFailed() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    @Expect(t.translate(a2aTextDelta("半截输出")).size, 0)
    let msgs = ArrayList<AtelierMessage>()
    msgs.add(UserMessage(ContentList.ofText("[Runtime error: boom]"), 0))
    let out = t.translate(AgentEndEvent(msgs))
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aArtifactText(arts[0]), "半截输出")
    let sts = a2aStatusEvents(out)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Failed)
    match (sts[0].status.message) {
        case Some(m) => @Expect(m.text(), "[Runtime error: boom]")
        case None => @Fail("failed status without message")
    }
    @Expect(t.isFinished(), true)
}

// 外部驱动的终态（tasks/cancel 已经回过 CANCELED 的场景）：幂等，非终态参数直接拒绝
@Test
func a2aTranslator_finishDrivesExternalTerminal() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(a2aTextDelta("输出中"))
    let out = t.finish(TaskState.Canceled)
    let arts = a2aArtifactEvents(out)
    @Expect(arts.size, 1)
    @Expect(arts[0].lastChunk, true)
    @Expect(a2aArtifactText(arts[0]), "输出中")
    let sts = a2aStatusEvents(out)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.Canceled)
    @Expect(t.isFinished(), true)
    @Expect(t.finish(TaskState.Failed).size, 0)

    var threw = false
    try {
        t.finish(TaskState.Working)
    } catch (e: Exception) {
        threw = true
    }
    @Expect(threw, true)
}

// ---------- 挂起 → INPUT_REQUIRED → 同 taskId 续聊 ----------

@Test
func a2aTranslator_suspendEmitsInputRequiredThenResumes() {
    let t = A2aTranslator("task_1", "ctx_1")
    t.translate(TurnStartEvent())
    t.translate(MessageEndEvent(a2aToolCallMsg("call_1", "bash", a2aArgs())))

    // 挂起路径：先 TurnEnd（工具未执行）→ 再 SuspendEvent
    let endOut = t.translate(TurnEndEvent(
        a2aToolCallMsg("call_1", "bash", a2aArgs()), ArrayList<ToolResultMessage>()))
    let endArts = a2aArtifactEvents(endOut)
    @Expect(endArts.size, 1)
    @Expect(endArts[0].lastChunk, true)
    @Expect(a2aToolStatus(endArts[0]), "skipped")

    let reqs = ArrayList<ExternalRequest>()
    reqs.add(ExternalRequest("req_1", "tool_call", "需要用户确认执行 bash", toolCallId: "call_1"))
    let out = t.translate(SuspendEvent(reqs))
    let sts = a2aStatusEvents(out)
    @Expect(sts.size, 1)
    @Expect(sts[0].status.state, TaskState.InputRequired)
    match (sts[0].status.message) {
        case Some(m) => @Expect(m.text(), "需要用户确认执行 bash")
        case None => @Fail("input-required status without message")
    }
    // 中断态不是终态
    @Expect(t.isFinished(), false)
    // run 收尾不得把中断态改成 COMPLETED
    @Expect(t.translate(AgentEndEvent(ArrayList<AtelierMessage>())).size, 0)
    @Expect(t.isFinished(), false)
    // 同 taskId 续聊：reset 清回合状态但保留回合号（产物 id 在任务内唯一）
    t.reset()
    @Expect(t.turnCount(), 1)
    t.translate(TurnStartEvent())
    @Expect(t.translate(a2aTextDelta("补充后的答复")).size, 0)
    let fin = t.translate(TurnEndEvent(
        a2aAssistantMsg(ContentList.ofText("补充后的答复"), StopReason.EndTurn), ArrayList<ToolResultMessage>()))
    let finSts = a2aStatusEvents(fin)
    @Expect(finSts.size, 1)
    @Expect(finSts[0].status.state, TaskState.Completed)
    let finArts = a2aArtifactEvents(fin)
    @Expect(finArts.size, 1)
    @Expect(finArts[0].artifact.artifactId, "art_t2")
    @Expect(a2aArtifactText(finArts[0]), "补充后的答复")
}
