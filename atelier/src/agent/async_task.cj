package atelier.agent

import std.collection.*
import std.sync.*
import atelier.message.*
import atelier.tool.*

// 异步工具挂起表：一次 run 因"工具在后台跑"而挂起时，记录待回填的任务。
//
// ## 为什么复用 ExternalRequest 而不是新造一套
//
// `ToolResult.external` 原本服务"前端执行工具 / 用户确认"，它的语义是
// **"本进程不产出结果，运行时挂起，调用方下次 run 带结果回来"**。
// 异步工具要的正是同一件事——差别只在**谁来填**：
//
//   前端执行 / 用户确认 → 人填
//   后台任务完成        → 线程填
//
// 机制同构，所以复用。这样挂起 / 恢复、历史收口（停在 assistant(tool_calls)）、
// 幂等回填这些已经验证过的部分都不必重写。
//
// ## 与"等用户答复"的区别
//
// 两者都发 SuspendEvent，但**下一步由谁推动**不同：
//
//   等答复 → 等外部（可能永远不来，需要超时/放弃策略）
//   等后台 → 一定会来（任务已经在跑），只需等
//
// 所以 reason 用不同的值区分：`tool_call`（等人/前端）vs `async_task`（等后台）。
// 消费方据此决定"要不要给用户提示 / 要不要设超时"。

// 异步任务的 reason 取值
// 异步任务的 reason 值**定义在 tool 层**（工具要构造它）；这里只是同义别名，
// 保持两边字符串一致，避免手写两处导致对不上。
public const ExternalReasonAsyncTask: String = AsyncTaskReason

// 一个后台任务的完成信号。
public class AsyncTaskResult {
    public let requestId: String
    public let toolCallId: String
    public let toolName: String
    // 回填给工具结果的内容
    public let text: String
    public let isError: Bool

    public init(requestId: String, toolCallId: String, toolName: String,
        text: String, isError!: Bool = false) {
        this.requestId = requestId
        this.toolCallId = toolCallId
        this.toolName = toolName
        this.text = text
        this.isError = isError
    }
}

// 挂起中的异步任务登记表。
//
// 为什么需要它：挂起之后，run 已经结束（历史停在 assistant(tool_calls)），
// 而此时后台任务还在跑。等它跑完，得有人记得"这个 requestId 对应哪次工具调用、
// 结果该填回哪里"。这个表就是那份记忆。
//
// **幂等**：同一个 requestId 重复回填只生效一次——后台任务重试、或者宿主重复
// 提交时不会产生两条结果（那样历史里会出现重复的 tool result）。
public class AsyncTaskRegistry {
    private let lock = Mutex()
    private let pending = HashMap<String, AsyncTaskResult>()
    private let done = HashMap<String, AsyncTaskResult>()

    public init() {}

    // 登记一个在跑的后台任务（挂起时调用）
    public func register(requestId: String, toolCallId: String, toolName: String): Unit {
        synchronized(this.lock) {
            this.pending[requestId] = AsyncTaskResult(requestId, toolCallId, toolName, "")
        }
    }

    // 完成回填。返回 false 表示这个 requestId 不认识或已回填过（幂等）。
    public func complete(r: AsyncTaskResult): Bool {
        synchronized(this.lock) {
            if (!this.pending.contains(r.requestId)) { return false }
            this.pending.remove(r.requestId)
            this.done[r.requestId] = r
            true
        }
    }

    // 是否还在等这个任务
    public func isPending(requestId: String): Bool {
        synchronized(this.lock) { this.pending.contains(requestId) }
    }

    public func pendingCount(): Int64 {
        synchronized(this.lock) { this.pending.size }
    }

    // 取走已完成的结果（取过即删：一次结果只该被回填一次）
    public func take(requestId: String): Option<AsyncTaskResult> {
        synchronized(this.lock) {
            match (this.done.get(requestId)) {
                case Some(r) =>
                    this.done.remove(requestId)
                    Option<AsyncTaskResult>.Some(r)
                case None => Option<AsyncTaskResult>.None
            }
        }
    }

    // 全部已完成但尚未取走的结果
    public func drainCompleted(): ArrayList<AsyncTaskResult> {
        synchronized(this.lock) {
            let out = ArrayList<AsyncTaskResult>()
            for ((k, _) in this.done) {
                match (this.done.get(k)) {
                    case Some(r) => out.add(r)
                    case None => ()
                }
            }
            this.done.clear()
            out
        }
    }

    // 全部未完成任务的 requestId（诊断用：谁卡住了）
    public func pendingIds(): ArrayList<String> {
        synchronized(this.lock) {
            let out = ArrayList<String>()
            for ((k, _) in this.pending) { out.add(k) }
            out
        }
    }
}

// 把异步任务完成的结果编码成一条"回填消息"的元数据。
//
// 为什么走消息元数据而不是构造参数：恢复走的是"同 thread 的第二次 run"，
// 宿主把结果随消息一起发上来，运行时开跑时收集一次（与 collectResumedAnswers 同构）。
// 这样"重放同一回合就能对上结果"，不需要额外的会话状态。
public func encodeAsyncResult(r: AsyncTaskResult): HashMap<String, String> {
    let md = HashMap<String, String>()
    md["kind"] = "async_tool_result"
    md["requestId"] = r.requestId
    md["toolCallId"] = r.toolCallId
    md["toolName"] = r.toolName
    md["isError"] = if (r.isError) { "true" } else { "false" }
    md["text"] = r.text
    md
}

// 从消息元数据里收集异步工具结果（与 collectResumedAnswers 一样扫一遍历史）。
//
// 坏数据当作"没有结果"：宁可让那次调用继续挂着，也不要拿半个结果去执行——
// 后者会让模型基于不完整的信息做决定，且很难事后发现。
public func collectAsyncResults(msgs: ArrayList<Message>): HashMap<String, AsyncTaskResult> {
    let out = HashMap<String, AsyncTaskResult>()
    for (m in msgs) {
        let md = metadataOf(m)
        if ((md.get("kind") ?? "") != "async_tool_result") { continue }
        let requestId = md.get("requestId") ?? ""
        if (requestId == "") { continue }
        let toolCallId = md.get("toolCallId") ?? ""
        let toolName = md.get("toolName") ?? ""
        let text = md.get("text") ?? ""
        let isError = (md.get("isError") ?? "false") == "true"
        out[requestId] = AsyncTaskResult(requestId, toolCallId, toolName, text, isError: isError)
    }
    out
}
