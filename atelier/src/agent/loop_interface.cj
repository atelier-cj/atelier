package atelier.agent

import atelier.message.*
import atelier.event.EventStream
import atelier.session.SessionEnvironment
import std.collection.*

/**
 * 一次执行的输入：**不要求 sessionId**。
 *
 * 会话挂靠是交互式宿主的形态，不是循环的本质；把 `sessionId` 设成非必填，
 * 是为了让「执行归属哪个会话」成为线索而不是前提。是否真的落会话、落给谁，
 * 由实现与装配决定。
 *
 * **注意 `attention` 之类字段不在这里**：曾设想装「注意力快照」（面板渲染 +
 * 最近 N 条 + 记忆概览），但那要求面板由本循环驱动——核实后不成立，面板型产品
 * 各自持有循环。**没有消费者就不加字段**；将来真有需求再加（加字段不改签名）。
 */
public class RunInput {
    /**
     * 本次执行的输入消息（新输入 + 需要一起喂进去的补充内容）。
     *
     * 无会话方案下这就是全部输入；会话方案下实现会先加载历史再拼接。
     */
    public let messages: ArrayList<Message>
    /**
     * 会话标识（可空串）。
     *
     * **非必填**：它是「这次执行归属哪个会话」的线索，而不是执行的前提。
     * 空串表示无会话上下文（一次性执行、或不关心归属的宿主）。
     */
    public let sessionId: String
    /** 本次执行的会话环境（工作目录等） */
    public let env: SessionEnvironment

    public init(messages: ArrayList<Message>, sessionId!: String = "",
        env!: SessionEnvironment = SessionEnvironment()) {
        this.messages = messages
        this.sessionId = sessionId
        this.env = env
    }
}

/**
 * Agent 循环：**一次执行怎么跑**。
 *
 * 形态选 interface 而非函数类型，理由有三条，缺一不可：
 * 1. **有状态**——`status()` 要跨调用保留（`idle`/`running`），函数靠闭包捕获状态
 *    对开发者不友好：状态藏在闭包里看不见、不好调试、不好复用；
 * 2. **多方法**——执行、取消、投递、查询状态，函数类型表达不了；
 * 3. **要能被替换**——这是本接口存在的全部意义。
 *
 * **不做的事**：不暴露阶段回调（`onBeforeRequest`/`onAfterTurn` 之类）。
 * 需要中间介入的场景已有 `Hook`（6 相位）覆盖；循环级替换要的就是"整个换掉"，
 * 再开一套回调只会让两套机制并存。
 */
public interface AgentLoop {
    /**
     * 当前生命周期状态。
     *
     * 必须是**比一次 run 长寿**的事实来源：run 结束后它回答 `Idle`。
     */
    func status(): AgentStatus

    /**
     * 执行一次 run，返回事件流（消费到 `AgentEndEvent` 收敛）。
     *
     * 实现约定：
     * - 事件流是**唯一**的进度出口（不另设回调）；
     * - 挂起不是失败：发 `SuspendEvent` 后结束本次 run，调用方带结果发起下一次；
     * - 产出的最终消息由 `EventStream.result()` 给出。
     *
     * **与 [chatWithSessionId] 的关系**：两者收敛到同一份实现，本方法只是
     * 「`sessionId` 可空」的语义化入口——宿主不必自造空会话 id。
     * **它不承载「面板模式」的期待**：面板型产品各自持有自己的循环，不使用本方法。
     */
    func drive(input: RunInput): EventStream<AgentEvent, ArrayList<Message>>

    /**
     * 请求取消正在跑的 run（幂等：未知/已结束的 run 是 no-op）。
     *
     * 语义是**协作式**：在当前检查点尽快收敛并按正常路径收尾（发 `AgentEndEvent`），
     * 不强制中断正在执行的工具。
     */
    func cancel(sessionId: String): Unit

    /**
     * 插话：把一条消息投给**正在跑**的 run，让它在下一次模型调用时可见。
     *
     * 语义约定（实现必须遵守，否则宿主无从预期）：
     * - **不打断正在执行的工具批次**——那交给 [cancel]；
     * - 消息在**下一次请求**时进入上下文，并带「用户中途补充」的标注；
     * - 目标 run 已结束或空闲时，消息**不丢失**，留待下一次 run 取用；
     * - 只接受用户消息，其它类型忽略。
     */
    func steer(sessionId: String, message: Message): Unit

    /**
     * 注入上下文：与 [steer] 的区别是**不唤醒**。
     *
     * 用于「给模型补一段参考信息，但不需要它现在就动」。执行中的 run 在下一个
     * 请求边界取走；空闲时一直挂着，直到下一次 [drive]。
     */
    func inject(sessionId: String, message: Message): Unit

    // ---------- 会话型入口（既有宿主的形态，保留为接口的一部分） ----------
    //
    // 它们不是"另一条路"，而是 [drive] 的会话特化：历史由调用方加载、执行归属
    // 指定会话。交互式宿主（CLI / ACP / AG-UI / 子 agent）依赖这两个签名，
    // 放进接口是为了让"换实现"对它们同样成立。

    /** 用内部生成的会话 id 执行一次（不归任何持久会话）。 */
    func chat(messages: ArrayList<Message>): EventStream<AgentEvent, ArrayList<Message>>

    /** 在指定会话下执行一次（历史由调用方负责加载与落库）。 */
    func chatWithSessionId(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): EventStream<AgentEvent, ArrayList<Message>>

    /**
     * 取消指定会话的回合（[cancel] 的会话特化名，既有宿主按这个名字调用）。
     *
     * 与 [cancel] 是同义：协作式收敛，不强制中断正在执行的工具。
     */
    func cancelSession(sessionId: String): Unit

    /**
     * 手动压缩：绕过阈值强制压一次（`/compact` 入口）。
     *
     * 与自动压缩共用同一条管线、同一个事务括弧、同一个会话级互斥——
     * 压不动时**如实返回原因**，不改动历史。
     */
    func compactNow(sessionId: String, messages: ArrayList<Message>,
        sessionEnv: SessionEnvironment): CompactionReport
}

/**
 * 循环工厂：把「怎么造一个 loop」也变成可替换的。
 *
 * 为什么需要它：只有接口还不够——**10 处硬编码构造**（server / cli / 子 agent …）
 * 意味着换实现要逐个改调用点。工厂把「用哪个实现」收成装配期的一个决定。
 *
 * 默认工厂返回 [AgentRuntime]（即改动前的行为）。
 */
public type AgentLoopFactory = (HarnessSpec, AgentConfig) -> AgentLoop
