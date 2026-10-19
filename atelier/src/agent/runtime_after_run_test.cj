package atelier.agent

/*
 * 收尾钩子（`afterRun`）的调用契约。
 *
 * **「run 结束了」是所有退出路径的事实，不是正常路径的专利。** provider 失败、
 * 循环体抛异常、Error 兜底，都同样意味着本次 run 结束 —— 宿主挂在 `afterRun` 上的
 * 收尾逻辑（落盘、释放外部资源、上报账目、配对 `beforeRun` 打开的括弧）必须照常执行。
 *
 * 钩子只挂在正常路径上时的表现是**静默的**：失败路径上宿主什么都不会做，
 * 而 `beforeRun` 已经执行过 —— 两边的括弧不配对，且没有任何报错。
 *
 * `callHooks` 内部对每个钩子各自 try/catch，因此收尾钩子自身出错也不会影响收尾，
 * 这也是它可以安全地放进 finally 的前提。
 */

import std.collection.*
import atelier.message.*
import atelier.provider.*
import atelier.tool.*
import atelier.session.*
import atelier.trust.*
import atelier.skill.*
import atelier.event.EventStream
import jsonvalue.*

// 记录 beforeRun / afterRun 的调用次数与顺序
class RunPhaseRecorder <: Hook {
    public var beforeRunCalls: Int64 = 0
    public var afterRunCalls: Int64 = 0
    public var turnCountAtAfterRun: Int64 = -1
    public override func beforeRun(ctx: HookContext): Unit {
        this.beforeRunCalls++
    }
    public override func afterRun(ctx: HookContext): Unit {
        this.afterRunCalls++
        this.turnCountAtAfterRun = ctx.turnCount
    }
}

// 流式调用直接抛异常的 provider：异常被 `invokeProvider` 吸收成一条失败消息
// （ProviderAttempt.Failed），run 走**正常收尾**路径 —— 与"框架级异常"区分开
class ThrowingOnStreamProvider <: Provider {
    public var calls: Int64 = 0
    public func name(): String { "throwing" }
    public func chat(req: ChatRequest): ChatResponse {
        ChatResponse(AssistantMessage(ContentList.ofText("SUM"), "", "", StopReason.EndTurn, TokenUsage(0, 0), 0))
    }
    public func chatStreaming(req: ChatRequest): EventStream<ChatDelta, AssistantMessage> {
        this.calls++
        throw Exception("provider exploded")
    }
}

// 工具声明阶段就抛异常的工具：`schema()` 在**循环内**被调用（renderNativeTools），
// 异常会冒到 runtime 的 catch —— 即"框架自身出问题"这条收尾路径。
//
// 不能用 provider 抛异常来构造：`invokeProvider` 内部已把 provider 异常吸收成
// 一条失败消息（ProviderAttempt.Failed），run 走的是正常收尾而不是 catch。
// 这正是需要区分的地方 —— 失败消息路径本来就该照常收尾，而框架级异常此前会跳过钩子。
class SchemaThrowingTool <: Tool {
    public func name(): String { "bad_schema" }
    public func description(): String { "schema throws" }
    public func schema(): JsonValue { throw Exception("schema exploded") }
    public func execute(ctx: ToolContext, args: JsonValue): ToolResult { ToolResult("ok", None, false, false) }
    public func executionMode(): ToolExecutionMode { ToolExecutionMode.Parallel }
}

func runWithHook(provider: Provider, toolReg: ToolRegistry,
    hooks: ArrayList<Hook>): ArrayList<Message> {
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    // 必须把工具列进 config.tools：否则它不在"可见工具"里，schema() 不会被调用，
    // 也就构造不出框架级异常
    let names = ArrayList<String>()
    names.add("bad_schema")
    let cfg = AgentConfig("t", None, "", None, "m", None, names, ArrayList<String>(), Int64(0),
        UInt32(20), Float32(0.7), UInt32(4096), None,
        false, None, UInt32(50), UInt32(30), UInt32(0),
        ArrayList(), None, Int64(0), Int64(0))
    let runtime = testRuntime(cfg, provider, toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let stream = runtime.chat(msgs)
    // 框架级异常会沿流抛出：本文件主要关心钩子是否被调用，故吞掉返回值
    try {
        stream.result()
    } catch (e: Exception) {
        // 预期：框架级异常或 provider 失败沿流抛出
        ArrayList<Message>()
    }
}

// 正常结束：beforeRun / afterRun 各一次（基线，锁住正常路径没被改动影响）
@Test
func runtime_afterRunHook_runsOnNormalCompletion() {
    let recorder = RunPhaseRecorder()
    let hooks = ArrayList<Hook>()
    hooks.add(recorder)
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    let provider = ScriptedMsgProvider(responses)
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let toolReg = ToolRegistry()
    let runtime = testRuntime(AgentConfig.default(), provider, toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    runtime.chat(msgs).result()

    @Expect(recorder.beforeRunCalls, Int64(1))
    @Expect(recorder.afterRunCalls, Int64(1))
}

// 框架级异常（工具声明阶段抛出，冒到 runtime 的 catch）：afterRun 仍必须被调用一次。
//
// 这条锁的是 B9 本身：把 afterRun 放回 try 内时，本用例会红。
@Test
func runtime_afterRunHook_runsOnFrameworkError() {
    let recorder = RunPhaseRecorder()
    let hooks = ArrayList<Hook>()
    hooks.add(recorder)
    let toolReg = ToolRegistry()
    toolReg.register(SchemaThrowingTool())
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    runWithHook(ScriptedMsgProvider(responses), toolReg, hooks)

    @Expect(recorder.beforeRunCalls, Int64(1))
    // 关键断言：框架级异常路径同样收尾（把 afterRun 移回 try 内时这条为 0）
    @Expect(recorder.afterRunCalls, Int64(1))
}

// provider 失败（被 invokeProvider 吸收成失败消息）：走的是正常收尾，afterRun 也要跑。
// 与上一条并排，说明"失败消息"与"框架级异常"是两条不同的收尾路径，钩子都必须执行。
@Test
func runtime_afterRunHook_runsOnProviderFailureMessage() {
    let recorder = RunPhaseRecorder()
    let hooks = ArrayList<Hook>()
    hooks.add(recorder)
    let provider = ThrowingOnStreamProvider()
    let toolReg = ToolRegistry()
    runWithHook(provider, toolReg, hooks)

    @Expect(recorder.beforeRunCalls, Int64(1))
    @Expect(recorder.afterRunCalls, Int64(1))
}

// 钩子自身抛异常不能影响收尾：它没让 run 变成错误、也没吞掉 AgentEndEvent
class ThrowingAfterRunHook <: Hook {
    public var calls: Int64 = 0
    public override func afterRun(ctx: HookContext): Unit {
        this.calls++
        throw Exception("hook exploded")
    }
}

@Test
func runtime_afterRunHook_itsOwnErrorDoesNotBreakShutdown() {
    let throwing = ThrowingAfterRunHook()
    let recorder = RunPhaseRecorder()
    let hooks = ArrayList<Hook>()
    hooks.add(throwing)
    hooks.add(recorder)
    let responses = ArrayList<AssistantMessage>()
    responses.add(endTurnMsg("ok"))
    let provider = ScriptedMsgProvider(responses)
    let providerReg = ProviderRegistry()
    providerReg.register("default", provider)
    let toolReg = ToolRegistry()
    let runtime = testRuntime(AgentConfig.default(), provider, toolReg,
        MemorySessionStore(), TrustManager(), SkillRegistry(), AgentRegistry(),
        providerReg, hooks, McpManager())
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText("hi"), 0))
    let history = runtime.chat(msgs).result()

    // 抛错的钩子被执行了；排在它后面的钩子照样执行（逐个隔离）
    @Expect(throwing.calls, Int64(1))
    @Expect(recorder.afterRunCalls, Int64(1))
    // 收尾没有被破坏：正常拿到回复
    @Expect(history.size >= 1, true)
}
