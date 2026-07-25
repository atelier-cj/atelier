package atelier.agent

import std.collection.*
import atelier.message.*
import jsonvalue.*

func makeMsgContent(text: String): ContentList {
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock(text))
    return ContentList(blocks)
}

@Test
func agentStartEvent_eventType() {
    let e = AgentStartEvent("session_1")
    @Expect(e.eventType(), "agent_start")
    @Expect(e.sessionId, "session_1")
}

@Test
func agentEndEvent_eventType() {
    let messages = ArrayList<Message>()
    messages.add(UserMessage(makeMsgContent("hi"), 100))
    let e = AgentEndEvent(messages)
    @Expect(e.eventType(), "agent_end")
    @Expect(e.messages.size, 1)
}

@Test
func turnStartEvent_eventType() {
    let e = TurnStartEvent()
    @Expect(e.eventType(), "turn_start")
}

@Test
func turnEndEvent_eventType() {
    let usage = TokenUsage(10, 20)
    let msg = AssistantMessage(makeMsgContent("response"), "gpt-4", "openai", StopReason.EndTurn, usage, 200)
    let results = ArrayList<ToolResultMessage>()
    results.add(ToolResultMessage("call_1", "get_weather", makeMsgContent("sunny"), false, 300))
    let e = TurnEndEvent(msg, results)
    @Expect(e.eventType(), "turn_end")
    @Expect(e.toolResults.size, 1)
}

@Test
func messageStartEvent_eventType() {
    let msg = UserMessage(makeMsgContent("hello"), 100)
    let e = MessageStartEvent(msg)
    @Expect(e.eventType(), "message_start")
}

@Test
func messageUpdateEvent_eventType() {
    let msg = UserMessage(makeMsgContent("original"), 100)
    let e = MessageUpdateEvent(msg, "delta_content")
    @Expect(e.eventType(), "message_update")
    @Expect(e.delta, "delta_content")
}

@Test
func messageEndEvent_eventType() {
    let msg = UserMessage(makeMsgContent("done"), 100)
    let e = MessageEndEvent(msg)
    @Expect(e.eventType(), "message_end")
}

@Test
func toolExecutionStartEvent_eventType() {
    let e = ToolExecutionStartEvent("tool_1", "get_weather")
    @Expect(e.eventType(), "tool_execution_start")
    @Expect(e.toolCallId, "tool_1")
    @Expect(e.toolName, "get_weather")
}

@Test
func toolExecutionUpdateEvent_eventType() {
    let e = ToolExecutionUpdateEvent("tool_1", "50%")
    @Expect(e.eventType(), "tool_execution_update")
    @Expect(e.toolCallId, "tool_1")
    @Expect(e.progress, "50%")
}

@Test
func toolExecutionEndEvent_eventType() {
    let e = ToolExecutionEndEvent("tool_1", "result_data", false)
    @Expect(e.eventType(), "tool_execution_end")
    @Expect(e.toolCallId, "tool_1")
    @Expect(e.result, "result_data")
    @Expect(e.isError, false)
}

@Test
func toolExecutionEndEvent_isError() {
    let e = ToolExecutionEndEvent("tool_1", "error_msg", true)
    @Expect(e.isError, true)
}

@Test
func compactionEvent_eventType() {
    let e = CompactionEvent("token limit reached", 1000, 500)
    @Expect(e.eventType(), "compaction")
    @Expect(e.reason, "token limit reached")
    @Expect(e.tokensBefore, 1000)
    @Expect(e.tokensAfter, 500)
}

@Test
func eventStream_emitAndReceive() {
    let stream = EventStream<String, Int64>()
    spawn {
        =>
        stream.emit("event1")
        stream.emit("event2")
        stream.setResult(42)
    }
    sleep(100 * Duration.millisecond)
    @Expect(stream.receive(), "event1")
    @Expect(stream.receive(), "event2")
    @Expect(stream.result(), 42)
}

@Test
func eventStream_resultWithoutConsuming() {
    let stream = EventStream<String, Int64>()
    spawn {
        =>
        stream.emit("e1")
        stream.setResult(99)
    }
    sleep(100 * Duration.millisecond)
    let res = stream.result()
    @Expect(res, 99)
    let ev = stream.receive()
    @Expect(ev, "e1")
}

@Test
func eventStream_setResultOnceSemantics() {
    let stream = EventStream<String, Int64>()
    let first = stream.setResult(1)
    let second = stream.setResult(2)
    @Expect(first, true)
    @Expect(second, false)
    @Expect(stream.result(), 1)
}

@Test
func eventStream_setError() {
    let stream = EventStream<String, Int64>()
    stream.setError(Exception("stream failed"))
    var caught = false
    try {
        stream.result()
    } catch (e: Exception) {
        caught = true
    }
    @Expect(caught, true)
}

@Test
func eventStream_closePreventsEmit() {
    let stream = EventStream<String, Int64>()
    @Expect(stream.emit("ok"), true)
    stream.close()
    @Expect(stream.emit("after_close"), false)
}

@Test
func eventStream_receiveWithTimeout() {
    let stream = EventStream<String, Int64>()
    spawn {
        =>
        sleep(200 * Duration.millisecond)
        stream.emit("late")
        stream.setResult(0)
    }
    let none = stream.receive(50 * Duration.millisecond)
    match (none) {
        case None => ()
        case _ => @Fail("expected None on timeout")
    }
    let some = stream.receive(300 * Duration.millisecond)
    match (some) {
        case Some(v) => @Expect(v, "late")
        case None => @Fail("expected event after wait")
    }
    stream.result()
}

@Test
func eventStream_producerConsumerConcurrent() {
    let stream = EventStream<Int64, String>()
    let fut = spawn {
        =>
        var sum = 0
        for (i in 0..10) {
            stream.emit(i)
            sum += i
        }
        stream.setResult("sum: ${sum}")
    }
    var received = 0
    var count = 0
    for (i in 0..10) {
        received += stream.receive()
        count += 1
    }
    @Expect(count, 10)
    let res = stream.result()
    @Expect(res, "sum: 45")
    fut.get()
}

@Test
func eventStream_allEventsBeforeResult() {
    let stream = EventStream<String, String>()
    spawn {
        =>
        stream.emit("a")
        stream.emit("b")
        stream.emit("c")
        stream.setResult("done")
    }
    sleep(50 * Duration.millisecond)
    let a = stream.receive()
    let b = stream.receive()
    let c = stream.receive()
    let r = stream.result()
    @Expect(a, "a")
    @Expect(b, "b")
    @Expect(c, "c")
    @Expect(r, "done")
}

@Test
func loopEventStream_typeAlias() {
    let stream: LoopEventStream = EventStream<AgentEvent, ArrayList<Message>>()
    let usage = TokenUsage(0, 0)
    let msg = AssistantMessage(makeMsgContent("reply"), "m", "p", StopReason.EndTurn, usage, 100)
    stream.emit(TurnStartEvent())
    stream.emit(MessageStartEvent(msg))
    stream.emit(MessageEndEvent(msg))
    let messages = ArrayList<Message>()
    messages.add(UserMessage(makeMsgContent("hi"), 0))
    stream.setResult(messages)
    let ev1 = stream.receive()
    let ev2 = stream.receive()
    let ev3 = stream.receive()
    @Expect(ev1.eventType(), "turn_start")
    @Expect(ev2.eventType(), "message_start")
    @Expect(ev3.eventType(), "message_end")
    let result = stream.result()
    @Expect(result.size, 1)
}
