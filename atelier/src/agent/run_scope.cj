package atelier.agent

import atelier.message.Message
import std.collection.*
import std.time.MonoTime

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
