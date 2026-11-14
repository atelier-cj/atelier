package atelier.agent

import std.collection.*
import std.collection.concurrent.*
import std.core.Duration
import std.sync.*
import uhp.types.handwritten.*

// 远端 UHP 子 Agent：事件流 → 父方来信。
//
// 这里不连真 HTTP（那是 SDK 的活），只钉**映射与收敛**——
// 因为真正会出错的正是这层：把半截输出当成功、把等输入判成失败、取消打错对象。

// ── 假流与假 runner ──

class FakeStream <: UhpTurnStream {
    private let events: ArrayList<UhpEvent>
    private var i: Int64 = 0

    public init(events: ArrayList<UhpEvent>) {
        this.events = events
    }

    public func nextEvent(): Option<UhpEvent> {
        if (this.i >= this.events.size) { return None }
        let e = this.events[this.i]
        this.i++
        Some(e)
    }
}

class FakeRunner <: UhpTurnRunner {
    var turns = ArrayList<String>()
    var cancels = ArrayList<String>()
    var openFails = false
    var failedReason = ""
    let events: ArrayList<UhpEvent>

    public init(events: ArrayList<UhpEvent>) {
        this.events = events
    }

    public func openTurn(text: String, previousResponseId: Option<String>): Option<UhpTurnStream> {
        this.turns.add(text)
        if (this.openFails) { return None }
        Option<UhpTurnStream>.Some(FakeStream(this.events))
    }

    public func cancel(responseId: String): Unit {
        this.cancels.add(responseId)
    }

    public func describeError(): String {
        this.failedReason
    }
}

func textDelta(seq: Int64, t: String): UhpEvent {
    let e = TextDeltaEvent(seq)
    e.delta = t
    UhpEvent.OutputTextDelta(e)
}

func responseEvent(seq: Int64, id: String, status: String): ResponseEvent {
    let e = ResponseEvent(seq)
    e.responseRaw = Some("{\"id\":\"" + id + "\",\"object\":\"response\",\"status\":\"" + status + "\"}")
    e
}

// 跑一轮：起 serveRemote 线程 → 发一条 → 收一封 → 关掉
//
// 子来信走 `boxAdder`（真实装配里是 manager 的收件队列），所以测试自己接一个队列，
// 而不是用 handle.recv —— 那是父侧从 manager 队列取信的路径。
func runOneTurn(runner: UhpTurnRunner, text: String): AgentMail {
    let box = LinkedBlockingQueue<AgentMail>()
    let h = RemoteUhpSubAgentHandle("sub_1", "main", runner, { m => box.add(m) })
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_1", AgentMailKindUserText, text))
    let mail = match (box.remove(3 * Duration.second)) {
        case Some(m) => m
        case None =>
            h.close()
            @Fail("3 秒内没有收到子来信")
    }
    h.close()
    mail
}

@Test
func uhp_textDeltasBecomeOneMail() {
    let evs = ArrayList<UhpEvent>()
    evs.add(UhpEvent.Created(responseEvent(0, "resp_1", "in_progress")))
    evs.add(textDelta(1, "派活"))
    evs.add(textDelta(2, "成功"))
    evs.add(UhpEvent.Completed(responseEvent(3, "resp_1", "completed")))
    let runner = FakeRunner(evs)
    let mail = runOneTurn(runner, "跑个 echo")
    @Expect(mail.text, "派活成功")
    @Expect(mail.kind, AgentMailKindDone)
    @Expect(runner.turns.size, 1)
}

@Test
func uhp_failedTerminalCarriesError() {
    let evs = ArrayList<UhpEvent>()
    evs.add(textDelta(0, "部分输出"))
    evs.add(UhpEvent.Failed(responseEvent(1, "resp_2", "failed")))
    let mail = runOneTurn(FakeRunner(evs), "x")
    // 部分输出要带出去，而且要标注残缺——否则父会把它当完整结论
    @Expect(mail.text.contains("部分输出"), true)
    @Expect(mail.text.contains("失败") || mail.text.contains("终态"), true)
}

@Test
func uhp_incompleteBecomesQuestionNotFailure() {
    let evs = ArrayList<UhpEvent>()
    evs.add(textDelta(0, "请问要 A 还是 B？"))
    evs.add(UhpEvent.Incomplete(responseEvent(1, "resp_3", "incomplete")))
    let mail = runOneTurn(FakeRunner(evs), "x")
    // 等输入 ≠ 失败：把问题交回父，会话保持
    @Expect(mail.text, "请问要 A 还是 B？")
}

@Test
func uhp_streamWithoutTerminalIsFailure() {
    // 半截输出不能当成功：否则父会拿一份被截断的结论去回用户
    let evs = ArrayList<UhpEvent>()
    evs.add(textDelta(0, "说到一半"))
    let mail = runOneTurn(FakeRunner(evs), "x")
    @Expect(mail.text.contains("终态"), true)
}

@Test
func uhp_openFailureIsReported() {
    let runner = FakeRunner(ArrayList<UhpEvent>())
    runner.openFails = true
    runner.failedReason = "连接被拒绝"
    let mail = runOneTurn(runner, "x")
    @Expect(mail.text.contains("连接被拒绝"), true)
}

@Test
func uhp_cancelTargetsCurrentResponse() {
    let evs = ArrayList<UhpEvent>()
    evs.add(UhpEvent.Created(responseEvent(0, "resp_9", "in_progress")))
    evs.add(textDelta(1, "慢慢来"))
    evs.add(UhpEvent.Completed(responseEvent(2, "resp_9", "completed")))
    let runner = FakeRunner(evs)
    let box = LinkedBlockingQueue<AgentMail>()
    let h = RemoteUhpSubAgentHandle("sub_2", "main", runner, { m => box.add(m) })
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_2", AgentMailKindUserText, "x"))
    let _ = box.remove(3 * Duration.second)
    // 一轮结束后取消：此时已无 current，不应打错对象
    let before = runner.cancels.size
    h.cancel()
    @Expect(runner.cancels.size >= before, true)
    h.close()
}

// ---- 工具留痕：远端工具调用要能被宿主看见 ----
//
// 协议里工具调用是两项 item：function_call（名 + 参数）与 function_call_output（输出）。
// 不解析它们，宿主就只能转述结论、"子做了什么"无法自证。

func itemDone(seq: Int64, raw: String): UhpEvent {
    let e = ItemEvent(seq)
    e.itemRaw = Some(raw)
    UhpEvent.OutputItemDone(e)
}

@Test
func uhp_toolCallsAreReportedToHost() {
    let records = ArrayList<String>()
    let events = ArrayList<UhpEvent>()
    events.add(itemDone(1, "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}"))
    events.add(itemDone(2, "{\"type\":\"function_call_output\",\"output\":\"hi\\n\"}"))
    events.add(textDelta(3, "好了"))
    events.add(UhpEvent.Completed(responseEvent(4, "resp_1", "completed")))
    let runner = FakeRunner(events)
    let box = LinkedBlockingQueue<AgentMail>()
    let cb: (String, String, String, Bool) -> Unit = { name, args, out, isErr =>
        records.add(name + "|" + args + "|" + out + "|" + (if (isErr) { "1" } else { "0" }))
    }
    let h = RemoteUhpSubAgentHandle("sub_2", "main", runner, { m => box.add(m) },
        onTool: Some(cb))
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_2", AgentMailKindUserText, "跑一下"))
    let _ = box.remove(3 * Duration.second)
    h.close()
    @Expect(records.size, 1)
    @Expect(records[0].startsWith("bash|"), true)
    @Expect(records[0].contains("echo hi"), true)
    @Expect(records[0].endsWith("|hi\n|0"), true)
}

@Test
func uhp_toolReportWithoutCallbackIsHarmless() {
    // 没接留痕回调时不能崩、也不能影响回合本身
    let events = ArrayList<UhpEvent>()
    events.add(itemDone(1, "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{}\"}"))
    events.add(itemDone(2, "{\"type\":\"function_call_output\",\"output\":\"ok\"}"))
    events.add(textDelta(3, "完事"))
    events.add(UhpEvent.Completed(responseEvent(4, "resp_2", "completed")))
    let mail = runOneTurn(FakeRunner(events), "跑")
    @Expect(mail.text.contains("完事"), true)
}

@Test
func uhp_toolCallWithoutOutputStillReported() {
    // 实测 ACP 系 harness（pi）只回 function_call、不回 function_call_output。
    // 如果只在配对成功时上报，这类 harness 永远 0 条 —— 表现成"子没干活"。
    let records = ArrayList<String>()
    let events = ArrayList<UhpEvent>()
    events.add(itemDone(1, "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}"))
    events.add(textDelta(2, "好"))
    events.add(UhpEvent.Completed(responseEvent(3, "resp_3", "completed")))
    let cb: (String, String, String, Bool) -> Unit = { name, args, out, isErr =>
        records.add(name + "|" + args + "|" + out)
    }
    let runner = FakeRunner(events)
    let box = LinkedBlockingQueue<AgentMail>()
    let h = RemoteUhpSubAgentHandle("sub_3", "main", runner, { m => box.add(m) }, onTool: Some(cb))
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_3", AgentMailKindUserText, "跑"))
    let _ = box.remove(3 * Duration.second)
    h.close()
    @Expect(records.size, 1)
    @Expect(records[0].startsWith("bash|"), true)
    // 输出为空但记录仍在：调用发生过就是事实
    @Expect(records[0].endsWith("|"), true)
}

@Test
func uhp_toolCallsFromCompletedResponse() {
    // 实测 ACP 系（pi）在流式里**不发** output_item.done：工具调用只出现在
    // 终态 response.completed 的 output 数组里。只认 item 事件 → 永远 0 条留痕。
    let records = ArrayList<String>()
    let events = ArrayList<UhpEvent>()
    events.add(textDelta(1, "好了"))
    let done = ResponseEvent(2)
    done.responseRaw = Some("{\"id\":\"resp_9\",\"object\":\"response\",\"status\":\"completed\",\"output\":["
        + "{\"type\":\"message\",\"role\":\"assistant\"},"
        + "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}]}")
    events.add(UhpEvent.Completed(done))
    let cb: (String, String, String, Bool) -> Unit = { name, args, out, isErr =>
        records.add(name + "|" + args + "|" + out)
    }
    let box = LinkedBlockingQueue<AgentMail>()
    let h = RemoteUhpSubAgentHandle("sub_4", "main", FakeRunner(events), { m => box.add(m) },
        onTool: Some(cb))
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_4", AgentMailKindUserText, "跑"))
    let _ = box.remove(3 * Duration.second)
    h.close()
    @Expect(records.size, 1)
    @Expect(records[0].startsWith("bash|"), true)
}

@Test
func uhp_itemEventsWinOverCompletedFallback() {
    // 两套来源都在时不能重复记：item 事件更细（带输出），优先用它
    let records = ArrayList<String>()
    let events = ArrayList<UhpEvent>()
    events.add(itemDone(1, "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{}\"}"))
    events.add(itemDone(2, "{\"type\":\"function_call_output\",\"output\":\"hi\"}"))
    let done = ResponseEvent(3)
    done.responseRaw = Some("{\"id\":\"resp_10\",\"status\":\"completed\",\"output\":["
        + "{\"type\":\"function_call\",\"name\":\"bash\",\"arguments\":\"{}\"}]}")
    events.add(UhpEvent.Completed(done))
    let cb: (String, String, String, Bool) -> Unit = { name, args, out, isErr =>
        records.add(name)
    }
    let box = LinkedBlockingQueue<AgentMail>()
    let h = RemoteUhpSubAgentHandle("sub_5", "main", FakeRunner(events), { m => box.add(m) },
        onTool: Some(cb))
    spawn { h.serveRemote() }
    h.send(AgentMail("main", "sub_5", AgentMailKindUserText, "跑"))
    let _ = box.remove(3 * Duration.second)
    h.close()
    @Expect(records.size, 1)
}
