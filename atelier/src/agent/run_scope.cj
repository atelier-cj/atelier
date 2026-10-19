package atelier.agent

import atelier.message.{Message, AssistantMessage}
import atelier.tool.{ExternalRequest, ToolRegistry, ToolExecutor}
import atelier.ptc.PtcRunSeq
import std.collection.*
import std.time.MonoTime
import jsonvalue.*

/**
 * 一次 run 期间**跨回合保留的可变状态**。
 *
 * 为什么需要它：主循环体原先直接读写 8 个局部变量（历史、回合计数、续跑预算…），
 * 一旦把循环体按阶段拆成方法，每个方法都要既收这几个变量又回写它们 ——
 * 参数表立刻变成"4~9 个入参 + 同数量出参"。
 *
 * 收进一个对象后，每个阶段方法只收一个 `RunScope` 引用。
 *
 * **它不是"整个 runtime 的状态"**：字段只有下面这些，全部是「本次 run 内」的。
 * 装配期组件（provider / store / 工具表…）仍在 `AgentRuntime` 上，阶段方法通过
 * `this.` 访问，不进这里。
 *
 * **可见性 `internal`**：同包内（含将来的 `*_test.cj`）可见，
 * 同模块的其他包（`atelier.context` / `atelier.trust` …）不可见。
 */
internal class RunScope {
    /** 当前历史：初始为调用方传入的消息，之后被压缩 / 钩子改写 / 追加替换 */
    var messages: ArrayList<Message>

    /** 已完成回合数（受 `maxTurns` 约束） */
    var turnCount: Int64 = 0

    /** 整个 run 累计的工具调用次数（用于预算裁决与自验条件） */
    var toolCallCount: Int64 = 0

    /**
     * 本回合因输出被截断而续跑的次数（**每回合重置**）。
     *
     * 与 [verifyPasses] 是两个互不相干的预算，因为它们回答的问题不同：
     * 截断续跑是"同一条回复没写完"，模型仍在产出同一份内容 —— 所以它不推进回合计数、
     * 也不重置自己的预算（否则 `maxLengthContinuations` 形同虚设）；
     * 而自验是"模型已宣布完成，现在进入核对阶段"，那是一次**新的推理任务**
     * （新提示、新产出目标），因此按新回合计。
     *
     * 由此产生的一个**有意**行为：一次自验之后，本回合的续跑预算随之重置 ——
     * 核对阶段被截断时仍有完整的续跑额度可用，否则任务会在收尾阶段半截而无法自救。
     * 整轮的上界由 `maxTurns` 兜住，不会无限延展。
     */
    var lengthContinuations: Int64 = 0

    /**
     * 收尾前自验已用次数（**每次自验按一个新回合计**）。
     *
     * 与 [lengthContinuations] 的差异见该字段的注释：自验是新回合，续跑是同一回合的延续。
     */
    var verifyPasses: Int64 = 0

    /**
     * 本次迭代是「上一回合因截断而续跑」。
     *
     * 用途：阻止续跑路径重复推进回合计数、重置续跑预算、推进 MCP 冷却。
     * 值在循环顶部读取后立刻清掉（见 [openTurn]）。
     */
    var resumingSameTurn: Bool = false

    /** 上次工具执行时刻（用于批次间节流） */
    var lastToolTime: MonoTime = MonoTime.now()

    /** 循环是否该收敛 */
    var finished: Bool = false

    /**
     * 本次 run 以**挂起**收尾（有调用在等外部结果）。
     *
     * 收口（[AgentRuntime.settleHistory]）必须据此跳过：挂起时历史**刻意**停在
     * `assistant(tool_calls)` 而不写结果 —— 那条结果要由下一次 run 随宿主答复带回
     * （见 [ToolBatchOutcome.SuspendedForExternal]）。此时补占位结果不是"修历史"，
     * 而是伪造：恢复时会多出一条与本调用不对应的结果，且模型会以为工具已经跑过。
     *
     * **只有"真在等外部输入"才置位**：整批执行失败（[ToolBatchOutcome.BatchFailed]）
     * 那条路径已经给每个 call 补齐了错误结果，历史是完整的，不该被当成挂起跳过收口。
     */
    var suspended: Bool = false

    /**
     * 本次 run 的**工具视图**（根表的派生视图，收尾即弃）。
     *
     * 契约：run 作用域的工具实例（`RunXispTool`、`AgentTool`）只注册进这张视图，
     * 绝不写进 `HarnessSpec.tools` 那张根表。原因是不变量层面的：这些实例的构造参数
     * 绑着**这一次 run** 的上下文（`RunXispTool.env` 里的 workDir / sessionId /
     * cancelFlag / authorizer），而根表是同一份装配束下的多个 runtime 共享的。
     * 写进根表就等于把「某一次 run 的上下文」挂到了共享状态上：并发的另一个会话
     * 按名字分发时会命中它，于是按**别人**的 workDir 过信任闸门、按别人的取消标志
     * 判中断 —— 信任判定的键与请求来源脱节。
     *
     * 派生视图同时保留父表语义：run 期间宿主注册进根表的新工具（按需加载的 MCP 工具）
     * 在视图里照样可见，因此隔离不牺牲「本轮注册、本轮可用」。
     */
    var tools: ToolRegistry

    /**
     * `run_xisp` 的调用序号（**跨回合单调**）。
     *
     * 存在 run 作用域而不是 `RunXispTool` 实例上：那个实例每轮重建（绑本回合执行环境），
     * 序号随实例归零会让每回合第一次 PTC 都从 1 开始，子调用 id 跨回合撞号 ——
     * 而 ACP / AG-UI / activity 拿它当唯一键。见 [PtcRunSeq]。
     */
    let ptcRunSeq: PtcRunSeq = PtcRunSeq()

    /**
     * 本次 run 的工具执行器。
     *
     * 必须与 [tools] 同源：执行器按名字查表分发，用根表就等于绕开上面那条隔离
     * （run 期注册进视图的工具查不到，而根表里的残留实例反倒可能被选中）。
     */
    var toolExecutor: ToolExecutor

    init(messages: ArrayList<Message>, tools: ToolRegistry, toolExecutor: ToolExecutor) {
        this.messages = messages
        this.tools = tools
        this.toolExecutor = toolExecutor
    }
}

/**
 * 单个工具调用的**准入结论**。
 *
 * 为什么要有它：准入判定原先写成「三份重复的 10 行 if/else + 一次重复校验 +
 * 信任状态写入散落两个分支」。三条放行路径（自动放行 / 允许一次 / 总是允许）
 * 里，建 batch 条目与失败原因记录是**完全相同**的代码，抄三遍意味着改一处就得
 * 记得还有两处。
 *
 * 把"判定"与"执行副作用（写 batch、写信任状态）"分开后，判定本身可单测。
 */
internal enum ToolAdmission {
    /** 放行：参数可能已被 beforeTool 钩子改写 */
    | Allow(JsonValue)
    /** 不放行：`String` 是写进历史的原因（必须给出，否则模型不知道为何被跳过） */
    | Skip(String)
    /** 宿主要求先确认：整批挂起，等答复后重放 */
    | Suspend(ExternalRequest)
}

/**
 * 工具批次的收尾结论。
 *
 * 三条走向都结束当前回合（`TurnEndEvent` 已发），但**语义不同**，必须分开表达：
 *
 * - [ContinueRun]：本批做完（含被跳过/拦截的），接着下一轮。
 * - [SuspendedForExternal]：有调用在**等外部输入**（用户答复 / 表单）。历史刻意停在
 *   `assistant(tool_calls)`、不写结果 —— 那条结果要由下一次 run 随宿主答复带回。
 *   这是唯一允许"历史不配对"的收尾方式，因此也**必须**发 `SuspendEvent`：
 *   宿主只靠它知道"这次不是跑完了，是在等你"。
 * - [BatchFailed]：整批执行抛了异常，已为每个 call 补齐错误结果后收尾。历史是
 *   **完整**的（每个调用都有结果），不存在"等外部输入"，所以既不发 `SuspendEvent`，
 *   也不该让收口跳过 —— 它和 `SuspendEvent` 共用一个枚举值时，两件事都会被做错。
 *
 * **本状态的定位：框架层异常的兜底，不是工具失败的出口。**
 * 单个工具抛异常由 `executeTool` 隔离成一条 isError 结果（有无超时预算两种分支
 * 行为一致，见 tool/invoke.cj），批次照常继续；因此走到这里意味着**执行器自身**
 * 出了问题（如工具元数据方法抛错、注册表状态异常），而不是"某个工具跑挂了"。
 *
 * 正因如此，直接收尾（不再发一轮请求）是**刻意的**：框架状态已经可疑，继续跑等于
 * 带病发请求，代价比"这一轮到此为止"更高。若哪天它被当成"工具失败的正常出口"，
 * 那就说明 `executeTool` 的隔离被破坏了 —— 本注释就是那条判据。
 */
internal enum ToolBatchOutcome {
    /** 本批执行完毕（含被跳过/拦截的），继续下一轮 */
    | ContinueRun
    /** 有调用在等外部结果：本次 run 到此为止，历史停在 assistant(tool_calls) */
    | SuspendedForExternal
    /** 整批执行失败：每 call 已补齐错误结果，按失败收尾 */
    | BatchFailed
}

/**
 * 一次 provider 调用的结论（含溢出恢复重试后的结果）。
 *
 * 为什么连 `chatReq` 一起返回：溢出恢复会**重建请求**（保留 hook 改过的 model），
 * 而重建后的请求后续还要用（回合收尾、下一次迭代）。用元组带回，
 * 避免方法内捕获外部可变变量。
 */
internal enum ProviderAttempt {
    /** 拿到响应 */
    | Ok(AssistantMessage)
    /** 失败且无法恢复（事件与失败消息已由方法内部发出） */
    | Failed
}
