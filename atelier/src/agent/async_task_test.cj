package atelier.agent

import std.collection.*
import atelier.message.*
import atelier.tool.*

// 异步工具挂起表：登记 / 幂等回填 / 取走 / 消息元数据编解码。

@Test
func asyncRegistry_registerAndPending() {
    let reg = AsyncTaskRegistry()
    @Expect(reg.pendingCount(), 0)
    reg.register("req-1", "call-1", "bash")
    @Expect(reg.pendingCount(), 1)
    @Expect(reg.isPending("req-1"), true)
    @Expect(reg.isPending("req-2"), false)
}

@Test
func asyncRegistry_completeRemovesFromPending() {
    let reg = AsyncTaskRegistry()
    reg.register("req-1", "call-1", "bash")
    let ok = reg.complete(AsyncTaskResult("req-1", "call-1", "bash", "跑完了"))
    @Expect(ok, true)
    @Expect(reg.pendingCount(), 0)
    @Expect(reg.isPending("req-1"), false)
}

@Test
func asyncRegistry_completeIsIdempotent() {
    // 后台任务重试 / 宿主重复提交时不能产生两条结果——
    // 那会让历史里出现重复的 tool result
    let reg = AsyncTaskRegistry()
    reg.register("req-1", "call-1", "bash")
    @Expect(reg.complete(AsyncTaskResult("req-1", "call-1", "bash", "第一次")), true)
    @Expect(reg.complete(AsyncTaskResult("req-1", "call-1", "bash", "第二次")), false)
}

@Test
func asyncRegistry_unknownRequestRejected() {
    // 从没登记过的 requestId 不能凭空回填（会让历史多出一条无主结果）
    let reg = AsyncTaskRegistry()
    @Expect(reg.complete(AsyncTaskResult("ghost", "call-x", "bash", "x")), false)
}

@Test
func asyncRegistry_takeOnceOnly() {
    // 结果只能被取走一次：取过即删，避免重复回填同一轮
    let reg = AsyncTaskRegistry()
    reg.register("req-1", "call-1", "bash")
    reg.complete(AsyncTaskResult("req-1", "call-1", "bash", "结果"))
    @Expect(reg.take("req-1").isSome(), true)
    @Expect(reg.take("req-1").isNone(), true)
}

@Test
func asyncRegistry_takeCarriesPayload() {
    let reg = AsyncTaskRegistry()
    reg.register("req-1", "call-1", "bash")
    reg.complete(AsyncTaskResult("req-1", "call-1", "bash", "命令输出", isError: true))
    match (reg.take("req-1")) {
        case Some(r) =>
            @Expect(r.text, "命令输出")
            @Expect(r.isError, true)
            @Expect(r.toolCallId, "call-1")
            @Expect(r.toolName, "bash")
        case None => @Fail("应有结果")
    }
}

@Test
func asyncRegistry_drainCompleted() {
    let reg = AsyncTaskRegistry()
    reg.register("a", "ca", "t1")
    reg.register("b", "cb", "t2")
    reg.complete(AsyncTaskResult("a", "ca", "t1", "A 好了"))
    // 只取已完成的
    let got = reg.drainCompleted()
    @Expect(got.size, 1)
    @Expect(got[0].requestId, "a")
    // 取走后清空
    @Expect(reg.drainCompleted().size, 0)
    // b 仍在等
    @Expect(reg.isPending("b"), true)
}

@Test
func asyncRegistry_pendingIds() {
    let reg = AsyncTaskRegistry()
    reg.register("x", "cx", "t")
    reg.register("y", "cy", "t")
    let ids = reg.pendingIds()
    @Expect(ids.size, 2)
    @Expect(ids.contains("x"), true)
    @Expect(ids.contains("y"), true)
}

@Test
func asyncReason_isDistinctFromToolCall() {
    // 两个 reason 必须不同：消费方据此决定"要不要给用户提示 / 要不要设超时"
    //   等答复 → 可能永远不来（需超时/放弃）
    //   等后台 → 一定会来（任务已经在跑）
    @Expect(ExternalReasonAsyncTask, "async_task")
    @Expect(ExternalReasonAsyncTask == "tool_call", false)
}

// ---------- 消息元数据编解码 ----------

@Test
func asyncResult_encodeDecodeRoundtrip() {
    let r = AsyncTaskResult("req-9", "call-9", "grep", "找到 3 处匹配")
    let md = encodeAsyncResult(r)
    @Expect(md.get("requestId") ?? "", "req-9")
    @Expect(md.get("toolCallId") ?? "", "call-9")
    @Expect(md.get("toolName") ?? "", "grep")
    @Expect(md.get("isError") ?? "", "false")
}

@Test
func asyncResult_collectFromMessages() {
    // 恢复走"同 thread 的第二次 run"，结果随消息元数据带上来
    let r = AsyncTaskResult("req-1", "call-1", "bash", "输出", isError: false)
    let md = encodeAsyncResult(r)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("继续"), 0, metadata: md))
    let collected = collectAsyncResults(msgs)
    @Expect(collected.size, 1)
    match (collected.get("req-1")) {
        case Some(got) =>
            @Expect(got.text, "输出")
            @Expect(got.toolName, "bash")
        case None => @Fail("应收集到结果")
    }
}

@Test
func asyncResult_collectIgnoresOtherMetadata() {
    // 普通消息（无 kind 标记）不该被当成异步结果
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("你好"), 0))
    @Expect(collectAsyncResults(msgs).size, 0)
    // 有 kind 但不是异步结果的也不收
    let md = HashMap<String, String>()
    md["kind"] = "user_answer"
    msgs.add(UserMessage(ContentList.ofText("答复"), 0, metadata: md))
    @Expect(collectAsyncResults(msgs).size, 0)
}

@Test
func asyncResult_collectSkipsMalformed() {
    // 坏数据当作没有结果：宁可让调用继续挂着，也不拿半个结果去执行
    let md = HashMap<String, String>()
    md["kind"] = "async_tool_result"
    // 缺 requestId
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("x"), 0, metadata: md))
    @Expect(collectAsyncResults(msgs).size, 0)
}

@Test
func asyncResult_errorFlagRoundtrip() {
    let r = AsyncTaskResult("req-e", "call-e", "bash", "失败输出", isError: true)
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("继续"), 0, metadata: encodeAsyncResult(r)))
    match (collectAsyncResults(msgs).get("req-e")) {
        case Some(got) => @Expect(got.isError, true)
        case None => @Fail("应有结果")
    }
}

// ---------- 统一构造入口 ----------

@Test
func asyncToolResult_carriesAsyncReason() {
    let r = asyncToolResult("async-c1", "已提交后台执行", "c1")
    // 必须带 external：不带就等于"工具正常返回了"，run 不会挂起
    @Expect(r.external.isSome(), true)
    match (r.external) {
        case Some(req) =>
            @Expect(req.reason, ExternalReasonAsyncTask)
            @Expect(req.toolCallId, "c1")
            @Expect(req.id, "async-c1")
            // 挂起时不产生结果消息，所以 text 只是给前端看的一句话
            @Expect(req.message, "已提交后台执行")
        case None => @Fail("应带 external")
    }
}

@Test
func asyncToolResult_isNotError() {
    // 挂起不是失败：标成 error 会让上层以为工具挂了
    let r = asyncToolResult("async-c2", "提交了", "c2")
    @Expect(r.isError, false)
    @Expect(r.terminate, false)
}

@Test
func isAsyncTaskRequest_distinguishesFromUserInput() {
    // 两个 reason 必须能区分：等后台一定会来，等人可能永远不来
    let async = asyncToolResult("a", "x", "c")
    match (async.external) {
        case Some(req) => @Expect(isAsyncTaskRequest(req), true)
        case None => @Fail("应带 external")
    }
    // 等用户答复的（ask_user）不是异步任务
    let ask = ExternalRequest("q1", "input_required", "请确认", toolCallId: "c2")
    @Expect(isAsyncTaskRequest(ask), false)
    // 前端执行工具的也不是
    let frontend = ExternalRequest("f1", "tool_call", "由前端执行", toolCallId: "c3")
    @Expect(isAsyncTaskRequest(frontend), false)
}

@Test
func newAsyncRequestId_deterministic() {
    // 幂等回填靠它：同一次工具调用必须得到同一个 id
    @Expect(newAsyncRequestId("c1"), newAsyncRequestId("c1"))
    @Expect(newAsyncRequestId("c1") == newAsyncRequestId("c2"), false)
}
