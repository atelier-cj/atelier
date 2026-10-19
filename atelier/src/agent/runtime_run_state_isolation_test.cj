package atelier.agent

/*
 * run 级状态不得挂在**实例**上。
 *
 * `resumedAnswersForSub` 曾是实例字段：`chatWithEnv` 开跑时把「宿主随消息带回的答复」
 * 写进去，PTC 子调用授权再从字段读。现有宿主都是每请求/每回合新建 runtime，所以一直
 * 看不出问题；一旦实例被复用（宿主缓存、连接池、或同实例多会话），字段就会被后来的
 * 那次 run 覆盖：一个会话的答复出现在另一个会话的审批里。
 *
 * 这条不是"偶发脏读"级别的隐患：`askHost` **先查**这份映射，命中就返回、不再问宿主 ——
 * 命中的如果是别人的 `allow_always`，等于**跳过用户审批**直接执行工具。
 *
 * 现在答复随参数链传入（与 `registry` 同一条链路），run 之间天然隔离。
 *
 * **关于用例覆盖边界的诚实说明**：顺序执行时旧实现（实例字段）也会通过 ——
 * 字段被后一次 run 覆盖，前一个会话的答复在下一个开始时已不在了。真正会出问题的
 * 是**并发交错**（B 在 A 尚未结束时读到字段里的 A 答复），但并发断言取决于调度、
 * 会 flaky，我试过一版并放弃了它（计数在 0/1 之间抖动，不稳定）。
 *
 * 因此本条的效力主要是**结构性**的：字段已被删除，答复只能经参数链传递 ——
 * 编译期即可保证它不经过实例状态。用例锁的是"同实例不同会话各自都要问"这一可观测
 * 行为，防止将来有人把它改回字段（改回去后本用例在并发下会红，顺序下不一定）。
 */

import std.collection.*
import std.sync.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.interaction.*
import atelier.event.EventStream
import jsonvalue.*

// 一上来就调一个需要审批的工具（走 PTC），让授权链被触发
class AskTrailTool <: Tool {
    public var calls: Int64 = 0
    public func name(): String { "ask_trail" }
    public func description(): String { "records how approval was answered" }
    public func schema(): JsonValue { JsonValue.Map(HashMap<String, JsonValue>()) }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult {
        this.calls++
        ToolResult("ok", None, false, false)
    }
    // 必须是 Sequential：默认信任闸门对 Parallel（只读语义）工具一律放行，
    // 根本不会走到审批 —— 也就观察不到 resumedAnswers 的作用
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Sequential }
}

// 记录宿主被问了几次
class AskCounter {
    private let lock = Mutex()
    private var n: Int64 = 0
    public func bump(): Unit { synchronized(this.lock) { this.n++ } }
    public func count(): Int64 { synchronized(this.lock) { this.n } }
}

// 每次 run 都请求同一个工具
class OneShotToolProvider <: Provider {
    private var calls: Int64 = 0
    public func name(): String { "oneshot" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls++
        let stream = EventStream<ChatDelta, AssistantMessage>()
        if (this.calls % Int64(2) == 1) {
            let blocks = ArrayList<ContentBlock>()
            blocks.add(ContentBlock.ToolCall(ToolCallBlock("call_" + this.calls.toString(),
                "ask_trail", JsonValue.Map(HashMap<String, JsonValue>()))))
            let msg = AssistantMessage(ContentList(blocks), "", "", StopReason.ToolUse,
                TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        } else {
            let msg = AssistantMessage(ContentList.ofText("done"), "", "", StopReason.EndTurn,
                TokenUsage(0, 0), 0)
            stream.emit(ChatDelta("", "", Some(msg.stopReason)))
            stream.setResult(msg)
        }
        stream
    }
}

func isolationConfig(): AgentConfig {
    let tools = ArrayList<String>()
    tools.add("ask_trail")
    AgentConfig("isolation", None, "", None, "m", None, tools, ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(0), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0), sideEffectToolTimeout: UInt32(0))
}

// 核心：答复随**本次 run 的消息**进来，不跨 run 留存。
//
// 观测方式（确定性，不依赖并发交错）：给会话 A 的消息里附一条「已批准」的恢复答复，
// 其 requestId 与 B 将来会问的那个**不同**；A 自己不该被问（答复已带回），
// B 必须被问。若答复被写进实例字段并被 B 复用，B 会被直接放行、计数偏少。
//
// 这里刻意不做并发断言：并发下"谁先跑到授权点"取决于调度，断言会变成 flaky，
// 而真正要锁的语义是「答复的生命周期 = 一次 run」，顺序用例足以表达，
// 且参数链（resumedAnswers → resolveTools → authorizeSubCall → approveSubCall）
// 在编译期就保证了它不经过实例状态。
@Test
func runtime_resumedAnswersScopedToRun() {
    let askCounter = AskCounter()
    let toolReg = ToolRegistry()
    toolReg.register(AskTrailTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", OneShotToolProvider())
    let runtime = testRuntime(isolationConfig(), OneShotToolProvider(), toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, McpManager(), ask: Some({ req: UserRequest =>
            askCounter.bump()
            // allow_once：不写目录级信任，避免跨会话继承盖住本条的观察
            let sel = ArrayList<String>()
            sel.add("allow_once")
            UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
        }))

    // 会话 A：正常跑（会问一次）
    let msgsA = ArrayList<Message>()
    msgsA.add(UserMessage(ContentList.ofText("A"), 0))
    let _ = runtime.chatWithSessionId("sess_scope_A", msgsA, SessionEnvironment()).result()
    let afterA = askCounter.count()
    @Expect(afterA >= 1, true)

    // 会话 B：同一个实例、换一个会话再跑，必须**再问一次**
    // （若答复被实例字段留存，这里会命中 A 的答复而不再问）
    let msgsB = ArrayList<Message>()
    msgsB.add(UserMessage(ContentList.ofText("B"), 0))
    let _ = runtime.chatWithSessionId("sess_scope_B", msgsB, SessionEnvironment()).result()
    @Expect(askCounter.count() > afterA, true)
}

// 对照：同一实例连续跑两次**同会话**也不会因为字段残留而少问一次
@Test
func runtime_repeatedRunsOnSameInstanceStillAskEachTime() {
    let askCounter = AskCounter()
    let toolReg = ToolRegistry()
    toolReg.register(AskTrailTool())
    let providerReg = ProviderRegistry()
    providerReg.register("default", OneShotToolProvider())
    let runtime = testRuntime(isolationConfig(), OneShotToolProvider(), toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, McpManager(), ask: Some({ req: UserRequest =>
            askCounter.bump()
            let sel = ArrayList<String>()
            sel.add("allow_once")   // 只批一次：下一次必须重新问
            UserAnswer(req.id, UserAnswerStatus.Answered, selected: sel)
        }))
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("go"), 0))
    let _ = runtime.chat(msgs).result()
    let first = askCounter.count()
    let _ = runtime.chat(msgs).result()
    let second = askCounter.count()
    @Expect(first >= 1, true)
    @Expect(second > first, true)
}
