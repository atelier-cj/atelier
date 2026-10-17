package atelier.agent

import atelier.message.Message
import atelier.tool.ExternalRequest
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

    /** 本回合因输出被截断而续跑的次数（每回合重置） */
    var lengthContinuations: Int64 = 0

    /** 收尾前自验已用次数（每次自验按一个新回合计） */
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

    init(messages: ArrayList<Message>) {
        this.messages = messages
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
 * 工具批次的收尾结论：**继续下一轮**，还是**本次 run 挂起**。
 *
 * 两种走向都结束当前回合（`TurnEndEvent` 已发），区别只在挂起时还要发
 * `SuspendEvent` 并把历史停在 `assistant(tool_calls)`，等调用方下次带回结果。
 */
internal enum ToolBatchOutcome {
    /** 本批执行完毕（含被跳过/拦截的），继续下一轮 */
    | ContinueRun
    /** 有调用在等外部结果：本次 run 到此为止 */
    | Suspended
}
