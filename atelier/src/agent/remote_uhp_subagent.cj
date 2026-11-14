package atelier.agent

import std.collection.*
import std.core.Duration
import std.env.getStdErr
import std.sync.*
import uhp.client.{TaskStream, UhpClient, parseJson}
import uhp.transport.StdHttpTransport
import uhp.types.generated.Response
import uhp.types.handwritten.*
import jsonvalue.*

// 远端 UHP 子 Agent：把**任意 UHP 服务端**（自带 session/容器/文件/记忆的 harness）
// 当作可持续子代理驱动。父侧既有的 `subagent_*` 工具零改动即可使用本句柄
// （与本地子、ACP 远程子、A2A 远程子同构）。
//
// ## 与另外三种执行位置的关键差异
//
// | 能力 | 这里 |
// |---|---|
// | 过程可见 | ✅ 有 SSE 事件流（能看，不能改） |
// | 中途 steer | ❌ 协议没有；只能 cancel 或等本轮结束 |
// | 子问父 | ✅ 但**以一轮 response 为界**：`incomplete` → 父回答 → 新开一轮 |
//
// `steer` 的缺失是**能力事实**，不是失败——父侧应当据此选择"等或取消重派"，
// 所以这里不假装支持，也没有对应的重写方法。
//
// ## 续聊的两种形态
//
// 同一个 UHP session 里可以连续开多轮 response；带 `previousResponseId` 能把
// 上一轮的上下文接起来。这里两者都用：session 保环境，previousResponseId 保对话。

// 一轮流式回合的收敛状态：终态 / 是否在等输入（等输入 ≠ 失败，会话仍然活着）
class UhpTurnOutcome {
    var status: String = ""          // completed / incomplete / failed / cancelled
    var inputRequired: Bool = false
    var errorText: String = ""
    var responseId: Option<String> = None
}

/**
 * 一轮远端回合的最小流接口。
 *
 * 抽这一层的理由：`TaskStream` 是具体的 HTTP 流，测试里没法造假；
 * 而本 handle 真正依赖的只有「下一个事件」这件事。
 */
public interface UhpTurnStream {
    func nextEvent(): Option<UhpEvent>
}

/** 把 SDK 的 TaskStream 适配成 UhpTurnStream。 */
class UhpSdkStream <: UhpTurnStream {
    private let inner: TaskStream

    public init(inner: TaskStream) {
        this.inner = inner
    }

    public func nextEvent(): Option<UhpEvent> {
        this.inner.next()
    }

    public func close(): Unit {
        this.inner.close()
    }
}

/**
 * 基于 UHP SDK 的 `UhpTurnRunner`：装配层（宿主的宿主）直接用这个。
 *
 * 协议细节留在这里，宿主只给"端点 + 令牌 + 选哪个 harness"。
 */
public class UhpHttpTurnRunner <: UhpTurnRunner {
    private let client: UhpClient
    private let harnessId: Option<String>
    private let model: Option<String>
    private let baseUrl: String
    private var lastError: String = ""
    private let lock = Mutex()

    public init(baseUrl: String, token: String, harnessId!: Option<String> = None,
        model!: Option<String> = None) {
        this.baseUrl = baseUrl
        this.harnessId = harnessId
        this.model = model
        this.client = UhpClient(baseUrl, token, StdHttpTransport(baseUrl))
    }

    public func openTurn(text: String, previousResponseId: Option<String>): Option<UhpTurnStream> {
        try {
            let stream = this.client.createTaskStreamWithInput(text, model: this.model,
                harnessId: this.harnessId, previousResponseId: previousResponseId)
            synchronized(this.lock) { this.lastError = "" }
            return Option<UhpTurnStream>.Some(UhpSdkStream(stream))
        } catch (e: Exception) {
            synchronized(this.lock) { this.lastError = e.message }
            return Option<UhpTurnStream>.None
        }
    }

    public func cancel(responseId: String): Unit {
        try {
            let _ = this.client.cancelResponse(responseId)
        } catch (e: Exception) {
            synchronized(this.lock) { this.lastError = e.message }
        }
    }

    public func describeError(): String {
        synchronized(this.lock) {
            if (this.lastError == "") { "无法连接 UHP 端点 " + this.baseUrl } else { this.lastError }
        }
    }
}

/**
 * 怎样开一轮远端回合。
 *
 * `baseUrl/token` 的实现在 cli/装配层注入；测试注入假实现。
 * 返回 None = 这一轮没开起来（已由实现方给出可读原因，见 errorText）。
 */
public interface UhpTurnRunner {
    func openTurn(text: String, previousResponseId: Option<String>): Option<UhpTurnStream>
    func cancel(responseId: String): Unit
    func describeError(): String
}

public open class RemoteUhpSubAgentHandle <: SubAgentHandle {
    private let runner: UhpTurnRunner
    private let boxAdder: (AgentMail) -> Unit
    // 上一轮的 response：下一轮带着它，远端据此接上下文
    private var lastResponseId: Option<String> = None
    // 当前在跑的那一轮（cancel 要寻址它）
    private var currentResponseId: Option<String> = None
    private let bufLock = Mutex()
    private var buffered: String = ""
    private var turnNo: Int64 = 0

    // 工具留痕回调：远端每次工具调用/输出都会回调一次（name, args, output, isError）。
    //
    // 为什么由调用方注入：**留痕是宿主的事**（写哪、留多久、算不算记忆），
    // 传输层只负责把事件流里已经有的东西交出来。协议本来就有这些事件，
    // 不交出去就会出现"子做了什么只能转述、无法自证"。
    public let onTool: Option<(String, String, String, Bool) -> Unit>
    // 已发出、等输出的工具调用（FIFO：同一轮里工具调用是顺序的）
    private let pendingTools = ArrayList<(String, String)>()
    private let toolLock = Mutex()
    // 本轮是否已经通过 `output_item.done` 交过工具调用（避免与终态兜底重复记）
    private var itemToolsSeen: Bool = false

    public init(subSessionId: String, parentSessionId: String, runner: UhpTurnRunner,
        boxAdder: (AgentMail) -> Unit, onTool!: Option<(String, String, String, Bool) -> Unit> = None) {
        super(subSessionId, parentSessionId)
        this.runner = runner
        this.boxAdder = boxAdder
        this.onTool = onTool
    }

    // 重写：投递 = 一次远端回合（worker 线程串行消费 inbox）
    public override func send(mail: AgentMail): Unit {
        if (this.exited.load()) { return }
        if (mail.kind != AgentMailKindUserText) { return }
        this.inbox.add(mail)
    }

    // 重写：中断进行中的远端任务。
    // UHP 只有 cancel，没有"中途改方向"——这条差异由父侧的策略层承担。
    public override func cancel(): Unit {
        this.cancelRequested.store(true)
        match (this.currentResponseId) {
            case Some(id) =>
                try {
                    this.runner.cancel(id)
                } catch (e: Exception) {
                    this.logRemote("取消失败：" + e.message)
                }
            case None => ()
        }
    }

    public override func close(): Unit {
        this.closeRequested.store(true)
        this.cancel()
        this.exited.store(true)
    }

    /** 起点：在独立线程里跑「收信 → 远端回合」循环。 */
    public func serveRemote(): Unit {
        while (!this.closeRequested.load()) {
            let mail = match (this.inbox.remove(Duration.second)) {
                case Some(m) => m
                case None => continue
            }
            if (this.closeRequested.load()) { break }
            this.runTurn(mail.text)
        }
        this.exited.store(true)
    }

    private func runTurn(text: String): Unit {
        this.turnNo++
        let replyKind = if (this.turnNo == Int64(1)) { AgentMailKindDone } else { AgentMailKindReply }
        synchronized(this.bufLock) { this.buffered = "" }
        let outcome = UhpTurnOutcome()
        try {
            let stream = match (this.runner.openTurn(text, this.lastResponseId)) {
                case Some(v) => v
                case None =>
                    this.deliver("远端 UHP 调用失败: " + this.runner.describeError(), replyKind)
                    return
            }
            this.itemToolsSeen = false
        this.pump(stream, outcome)
        this.flushPendingTools()
        } catch (e: Exception) {
            this.deliver("远端 UHP 调用失败: " + e.message, replyKind)
            return
        }
        // 等输入：这一轮到此为止，把问题交回父；会话保持（父的下一条消息即答复）
        if (outcome.inputRequired) {
            let q = this.takeBuffer()
            this.deliver(if (q == "") { "[远端等待补充输入]" } else { q }, replyKind)
            return
        }
        let body = this.takeBuffer()
        // 失败/中断时**已产出的部分也要带出去**，但必须标注它是残缺的：
        // 只给错误信息，父会以为子什么都没干；只给半截正文，父会当完整结论用。
        let finalText = match (outcome.status) {
            case "failed" =>
                let why = if (outcome.errorText == "") { "远端 UHP 任务失败（无详情）" } else { outcome.errorText }
                if (body == "") { why } else { body + "\n（" + why + "）" }
            case "cancelled" =>
                if (body == "") { "[cancelled]" } else { body + "\n（已取消）" }
            case _ =>
                if (body == "") { "[远端 UHP 无输出]" } else { body }
        }
        this.deliver(finalText, replyKind)
    }

    // 读完一轮事件流。返回时 outcome 里已带终态。
    private func pump(stream: UhpTurnStream, outcome: UhpTurnOutcome): Unit {
        while (true) {
            let ev = match (stream.nextEvent()) {
                case Some(e) => e
                case None => break
            }
            match (ev) {
                case OutputTextDelta(d) => this.appendText(d.delta)
                case Created(r) => this.noteResponse(r, outcome)
                case InProgress(r) => this.noteResponse(r, outcome)
                case Completed(r) =>
                    this.noteResponse(r, outcome)
                    this.noteToolsFromResponse(r)
                    outcome.status = "completed"
                    return
                case Incomplete(r) =>
                    this.noteResponse(r, outcome)
                    outcome.status = "incomplete"
                    // 缺信息才是"等父回答"；其它不完整原因（如 max output）按失败处理
                    outcome.inputRequired = this.looksLikeInputRequired(r)
                    return
                case Failed(r) =>
                    this.noteResponse(r, outcome)
                    outcome.status = "failed"
                    return
                case Error(e) =>
                    outcome.status = "failed"
                    outcome.errorText = "远端流错误：" + e.message
                    return
                case OutputItemDone(item) => this.noteItem(item)
                case _ => ()   // 未知事件容忍：流式协议要求如此
            }
        }
        // 流结束却没见到终态：不能当成功——那会把半截输出当结论
        if (outcome.status == "") {
            outcome.status = "failed"
            outcome.errorText = "远端流未给出终态事件（可能中断）"
        }
    }

    /**
     * 从 `response.output_item.done` 里取工具调用/结果。
     *
     * 协议里工具调用是两项：`function_call`（工具名 + 参数 JSON）与
     * `function_call_output`（输出）。两者各自一个 item，靠**顺序**配对——
     * 事件里没有共同的 id 字段（item id 在部分实现里缺失），所以用 FIFO。
     */
    // 回合结束仍没等到输出的工具调用也要交出去。
    //
    // 不是所有 harness 都会回传 `function_call_output`（实测 ACP 系只给调用不给输出），
    // 如果只在配对成功时才上报，这些 harness 就永远是 0 条——表现成"子没干活"，
    // 而实际上它干了，只是我们没记。
    private func flushPendingTools(): Unit {
        let cb = match (this.onTool) {
            case Some(c) => c
            case None => return
        }
        let left = synchronized(this.toolLock) {
            let items = ArrayList<(String, String)>(this.pendingTools)
            this.pendingTools.clear()
            items
        }
        for ((name, args) in left) {
            cb(name, args, "", false)
        }
    }

    private func noteItem(item: ItemEvent): Unit {
        let raw = match (item.itemRaw) {
            case Some(r) => r
            case None => return
        }
        let j = JsonValue.parse(raw)
        let fields = match (j) {
            case JsonValue.Map(m) => m
            case _ => return
        }
        let kind = match (fields.get("type")) {
            case Some(JsonValue.String(s)) => s
            case _ => return
        }
        let cb = match (this.onTool) {
            case Some(c) => c
            case None => return
        }
        match (kind) {
            case "function_call" =>
                synchronized(this.toolLock) { this.itemToolsSeen = true }
                let name = fieldText(fields, "name")
                let args = fieldText(fields, "arguments")
                synchronized(this.toolLock) { this.pendingTools.add((name, args)) }
            case "function_call_output" =>
                let out = fieldText(fields, "output")
                // remove(at:) 是唯一删单个元素的写法（remove(0) 会被当成区间）
                let pair = synchronized(this.toolLock) {
                    if (this.pendingTools.size == 0) { return }
                    this.pendingTools.remove(at: 0)
                }
                let (name, args) = pair
                // 远端把工具失败也放在 output 里（不是单独事件）：只在明确带错误标记时才标失败
                let isError = out.contains("\"is_error\":true") || out.contains("isError\":true")
                cb(name, args, out, isError)
            case _ => ()
        }
    }

    // 取字符串字段（缺失或类型不对 → 空串；留痕不该因为字段怪就整条丢掉）
    private func fieldText(fields: HashMap<String, JsonValue>, key: String): String {
        match (fields.get(key)) {
            case Some(JsonValue.String(v)) => v
            case _ => ""
        }
    }

    /**
     * 终态兜底：从响应体里取 `output` 数组里的工具调用。
     *
     * 为什么需要两套解析：流式协议里工具调用**应该**以 `response.output_item.done` 出现，
     * 但实测有的实现（ACP 系）只在终态 `response.completed` 的 `output` 数组里给一次，
     * 中间没有任何 item 事件。只认前一种，这类 harness 就会永远 0 条留痕。
     */
    private func noteToolsFromResponse(raw: ResponseEvent): Unit {
        if (synchronized(this.toolLock) { this.itemToolsSeen }) { return }
        let cb = match (this.onTool) {
            case Some(c) => c
            case None => return
        }
        let body = match (raw.responseRaw) {
            case Some(b) => b
            case None => return
        }
        let items = match (JsonValue.parse(body)) {
            case JsonValue.Map(m) => match (m.get("output")) {
                case Some(JsonValue.Array(a)) => a
                case _ => return
            }
            case _ => return
        }
        // 先收集再配对：`output` 数组里调用与输出是相邻两项，
        // 逐项立即上报会把一次调用拆成两条（一条没输出、一条没工具名），读起来像"跑了两次"。
        let calls = ArrayList<(String, String)>()
        let outputs = ArrayList<String>()
        for (item in items) {
            let fields = match (item) {
                case JsonValue.Map(m) => m
                case _ => continue
            }
            let kind = match (fields.get("type")) {
                case Some(JsonValue.String(t)) => t
                case _ => continue
            }
            match (kind) {
                case "function_call" =>
                    calls.add((fieldText(fields, "name"), fieldText(fields, "arguments")))
                case "function_call_output" =>
                    outputs.add(fieldText(fields, "output"))
                case _ => ()
            }
        }
        for (i in 0..calls.size) {
            let (name, args) = calls[i]
            let out = if (i < outputs.size) { outputs[i] } else { "" }
            cb(name, args, out, false)
        }
        // 输出比调用多（对端只回结果不回调用）：结果也得留，工具名留空
        if (outputs.size > calls.size) {
            for (i in calls.size..outputs.size) {
                cb("", "", outputs[i], false)
            }
        }
    }

    private func noteResponse(raw: ResponseEvent, outcome: UhpTurnOutcome): Unit {
        match (raw.responseRaw) {
            case Some(body) =>
                try {
                    let resp = parseJson<Response>(body)
                    if (resp.id != "") {
                        outcome.responseId = Some(resp.id)
                        this.currentResponseId = Some(resp.id)
                        this.lastResponseId = Some(resp.id)
                    }
                    if (resp.status != "") { outcome.status = resp.status }
                } catch (e: Exception) {
                    // 解析不了不该让整轮崩：文本已经靠 delta 累积下来了
                }
            case None => ()
        }
    }

    // 判断 incomplete 是否属于"要父补充输入"。
    //
    // 协议把原因放在 `incomplete_details.reason`，但本 SDK 这一版**没有把它建模**
    // （`ResponseIncompleteDetails` 只有 extras）。所以一律按"要输入"处理：
    // 保守方向——把问题交回父、会话保持打开，让父有机会补一句；
    // 反过来（当失败）会把一次本可继续的对话直接判死。
    private func looksLikeInputRequired(raw: ResponseEvent): Bool {
        true
    }

    private func appendText(t: String): Unit {
        synchronized(this.bufLock) {
            this.buffered = this.buffered + t
        }
    }

    private func takeBuffer(): String {
        synchronized(this.bufLock) {
            let s = this.buffered
            this.buffered = ""
            s
        }
    }

    private func deliver(body: String, kind: String): Unit {
        let text = if (body == "") { "[空]" } else { body }
        this.boxAdder(AgentMail(this.subSessionId, this.parentSessionId, kind, text))
    }

    private func logRemote(msg: String): Unit {
        try {
            getStdErr().write("[uhp] " + this.subSessionId + ": " + msg + "\n")
        } catch (e: Exception) {
            ()
        }
    }
}
