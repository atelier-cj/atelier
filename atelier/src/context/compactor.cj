package atelier.context

import atelier.message.*
import atelier.provider.*
import std.collection.*
import jsonvalue.JsonValue

/**
 * 一次压缩的机会：**要不要压、压哪里、怎么压**都在这里回答。
 *
 * 为什么不把「事务」也放进来（括弧事件 / 台账 / 会话级互斥）：那些是**框架对压缩的
 * 可观测性承诺**（消费端据此显示进度与审计、并发压缩不出分叉历史），必须由循环统一
 * 保证成对与串行。放开给实现自便，就要求每个实现都正确重做一遍，且做不到跨实现一致。
 *
 * 所以边界是：**Compactor 决策与改写历史；运行时负责时序、互斥与留痕。**
 */
public interface Compactor {
    /**
     * 本次请求前是否该压。
     *
     * 输入是**当前历史 + 路由信息**（窗口、输出预算），不涉及 provider 调用——
     * 实现可以只看数字决定，也可以自己再查别的状态。
     *
     * @param messages 当前历史（**不要就地修改**）
     * @param route 本次请求的路由事实（模型、窗口、输出上限）
     * @return 决策：不压（带原因）/ 压（带切点与预算）
     */
    func shouldCompact(messages: ArrayList<Message>, route: CompactRoute): CompactDecision

    /**
     * 执行压缩：把历史改写成「检查点 + 保留区」。
     *
     * 约定：
     * - **不得返回比入参更长的历史**（那是白花一次调用，还会下轮再触发）；
     * - 压不动时**原样返回** `messages`（运行时会记 `noop`）；
     * - 允许抛异常（运行时会按 `noop` 处理并留痕），但**不得就地修改** `messages`。
     *
     * @param messages 当前历史
     * @param plan [shouldCompact] 返回的压缩计划
     * @param ctx 执行上下文（provider / 提示装配 / 模型名），供实现发起摘要子调用
     * @return 改写后的历史
     */
    func compact(messages: ArrayList<Message>, plan: CompactPlan, ctx: CompactionRuntime): ArrayList<Message>

    /**
     * 工具结果修剪：把**单次请求**里的超大工具结果换成「头 + 标记 + 尾」。
     *
     * 与 [compact] 分开是因为作用域不同：修剪**只影响发给模型的这一份请求**，
     * 落库历史保持完整（回放/导出仍拿得到完整输出）；压缩是真的改写历史。
     *
     * 默认不修剪（返回原列表），实现按需覆写。
     */
    func pruneForRequest(messages: ArrayList<Message>, cfg: ToolResultPruneConfig): ArrayList<Message> {
        messages
    }
}

/**
 * 本次请求的路由事实：压缩判定需要它，但它们属于 (provider, model) 这对路由，
 * 不是 agent 自己的策略。
 */
public struct CompactRoute {
    /** 当前生效模型名（摘要子调用默认也用它） */
    public let model: String
    /** 该路由的上下文窗口 */
    public let contextWindow: Int64
    /** 本回合的输出上限（窗口里要扣掉它才是消息预算） */
    public let reservedCompletionTokens: Int64

    public init(model: String, contextWindow: Int64, reservedCompletionTokens: Int64) {
        this.model = model
        this.contextWindow = contextWindow
        this.reservedCompletionTokens = reservedCompletionTokens
    }
}

/** 压缩决策：不压时带原因（会被留痕一次），压时带计划。 */
public enum CompactDecision {
    /** 不压；[reason] 用于留痕（如窗口未知 / 预算算不出 / 还没到阈值） */
    | Skip(String)
    | Proceed(CompactPlan)
}

/**
 * 压缩计划：切点 + 摘要预算。
 *
 * [cutIndex] 是「前 cutIndex 条被摘要替换」的位置；保留区从它开始。
 * 实现必须保证切点**不拆散工具调用对**（用户消息与 assistant(tool_calls) + tool 结果
 * 之间的配对），否则下一轮请求会被 provider 判 400。
 */
public struct CompactPlan {
    /** 前多少条进入摘要区（保留区从这条开始） */
    public let cutIndex: Int64
    /** 摘要文本的长度上限（tokens） */
    public let summaryMaxTokens: Int64
    /** 压缩后逐字保留的近期历史预算（tokens） */
    public let retainTokens: Int64
    /** 触发原因：pressure（请求前压力）/ overflow（超窗恢复）/ manual（手动） */
    public let trigger: String

    public init(cutIndex: Int64, summaryMaxTokens: Int64, retainTokens: Int64, trigger: String) {
        this.cutIndex = cutIndex
        this.summaryMaxTokens = summaryMaxTokens
        this.retainTokens = retainTokens
        this.trigger = trigger
    }
}

/**
 * 压缩执行上下文：实现发起摘要子调用所需的一切。
 *
 * 为什么把 [systemText] / [tools] 也传进来：摘要子调用要**复用主对话的前缀**才能吃到
 * provider 的前缀缓存（按「缓存前缀单元完整匹配」计费）。前缀 = system 提示 + 工具声明
 * + 被压区域原样回放，指令作为最后一条 user 消息追加。
 */
public class CompactionRuntime {
    /** 发起摘要子调用用的 provider */
    public let provider: Provider
    /** 本回合生效的模型名（摘要实现通常直接用它，除非配置了专门的小模型） */
    public let model: String
    /** 本回合的系统提示文本（前缀的一部分） */
    public let systemText: String
    /** 本回合的工具声明（前缀的一部分） */
    public let tools: ArrayList<OpenAITool>
    /** 压缩配置（提示模板、输出 schema、摘要模型覆盖等） */
    public let config: CompactionConfig

    public init(provider: Provider, model: String, systemText: String,
        tools: ArrayList<OpenAITool>, config: CompactionConfig) {
        this.provider = provider
        this.model = model
        this.systemText = systemText
        this.tools = tools
        this.config = config
    }
}

// ==================== 文本提取（压缩与摘要共用） ====================

// 待压缩对话文本（截取到约 reserve*4 字节上限，避免子调用超长）
public func summarizeText(msgs: ArrayList<Message>, limit: Int64): String {
    let sb = StringBuilder()
    var used: Int64 = 0
    for (m in msgs) {
        let t = match (m) {
            case um: UserMessage => plainTextOf(um)
            case am: AssistantMessage => plainTextOf(am)
            case tm: ToolResultMessage => "[tool " + tm.toolName + "]: " + plainTextOf(tm)
            case cm: CompactionMessage => "[summary] " + checkpointBody(cm.summary)
            case am2: ArchiveMessage => "[archived " + am2.startIndex.toString() + "-" + am2.endIndex.toString() + "]: " + am2.summary
            case _ => ""
        }
        if (t == "") { continue }
        if (used + Int64(t.size) > limit * 4) {
            // 超限：截取该消息前缀到剩余额度，避免摘要子调用拿到空对话
            let remaining = limit * 4 - used
            if (remaining > 0) {
                let cut = if (Int64(t.size) < remaining) { Int64(t.size) } else { remaining }
                sb.append(t[0..cut])
                sb.append("\n")
            }
            break
        }
        sb.append(t)
        sb.append("\n")
        used += Int64(t.size)
    }
    sb.toString()
}

// 提取消息文本（ContentList 的 TextBlock 拼接）
public func plainTextOf(m: Message): String {
    let cl = match (m) {
        case um: UserMessage => um.content
        case am: AssistantMessage => am.content
        case tm: ToolResultMessage => tm.content
        case cm: CompactionMessage => ContentList.ofText(cm.summary)
        case _ => ContentList.ofText("")
    }
    let sb = StringBuilder()
    for (b in cl.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) => sb.append(t)
            case _ => ()
        }
    }
    sb.toString()
}

// ==================== 默认实现：BasicCompactor ====================

/**
 * 默认压缩策略：**摘要 + 切点替换**，行为与提出接口之前完全一致。
 *
 * 判定与改写分成两步，各自都能被单独理解：
 * - [shouldCompact]：算预算（`resolveCompactSpec`）→ 比压力 → 给出切点；
 * - [compact]：摘要被压区域（**复用主对话前缀**吃缓存）→ 拼「检查点 + 保留区」。
 *
 * 摘要失败时退化为占位摘要（保住会话能继续，而不是把 run 打断）——这是既定行为，
 * 换实现时**不必**照抄，但要知道默认实现为什么这样选。
 */
public class BasicCompactor <: Compactor {
    public init() {}

    public func shouldCompact(messages: ArrayList<Message>, route: CompactRoute): CompactDecision {
        let cc = CompactionConfig()
        let resolution = resolveCompactSpec(cc, route.contextWindow, route.reservedCompletionTokens)
        return decide(messages, route, resolution, cc)
    }

    /**
     * 带显式配置的判定：宿主配了 `[agent.compaction]` 时走这条。
     *
     * 单列一个方法而不是塞进接口：接口只约束「怎么问」，配置是实现的细节。
     */
    public func shouldCompactWith(messages: ArrayList<Message>, route: CompactRoute,
        cc: CompactionConfig): CompactDecision {
        let resolution = resolveCompactSpec(cc, route.contextWindow, route.reservedCompletionTokens)
        return decide(messages, route, resolution, cc)
    }

    private func decide(messages: ArrayList<Message>, route: CompactRoute,
        resolution: CompactSpecResolution, cc: CompactionConfig): CompactDecision {
        match (resolution.spec) {
            // 配置算不出预算（窗口未知 / 留不出余量）：不压，留痕一次
            case None => CompactDecision.Skip(resolution.reason)
            case Some(spec) =>
                let total = this.pressureOf(messages)
                if (total <= spec.thresholdTokens) {
                    return CompactDecision.Skip("under threshold (${total}/${spec.thresholdTokens})")
                }
                // 切点：先按保留预算算，再让出工具调用对的边界（拆散配对会被判 400）
                let rawCut = retainedCutIndex(messages, spec.retainTokens)
                let cut = protectCutPoint(messages, rawCut)
                if (cut <= 0) {
                    return CompactDecision.Skip("nothing to compact (retain budget covers all)")
                }
                CompactDecision.Proceed(CompactPlan(cut, spec.summaryMaxTokens,
                    spec.retainTokens, "pressure"))
        }
    }

    public func compact(messages: ArrayList<Message>, plan: CompactPlan,
        ctx: CompactionRuntime): ArrayList<Message> {
        let cc = ctx.config
        // 被压区域原样回放 + 末尾追加指令：前缀与主请求一致，才能吃到缓存
        let region = ArrayList<Message>()
        var i: Int64 = 0
        while (i < plan.cutIndex) {
            region.add(messages[i])
            i++
        }
        let summary = try {
            let conversation = summarizeText(region, 0)
            let prev = findPreviousSummary(region)
            let prompt = renderCompactionPrompt(cc, conversation, prev, plan.summaryMaxTokens)
            let summaryModel = match (cc.summaryModel) {
                case Some(m) => m
                case None => ctx.model
            }
            let reqMessages = ArrayList<Message>(region)
            reqMessages.add(UserMessage(ContentList.ofText(prompt), 0))
            let req = ChatRequest(summaryModel, reqMessages, Float64(0.2), plan.summaryMaxTokens,
                None, ctx.tools, systemPrompt: ctx.systemText)
            let resp = ctx.provider.chat(req)
            let raw = plainTextOf(resp.message)
            match (cc.outputSchema) {
                case Some(JsonValue.Map(schema)) =>
                    if (!validateSummary(cc, schema, raw)) {
                        throw Exception("summary failed schema validation")
                    }
                case _ => ()
            }
            raw
        } catch (e: Exception) {
            // 摘要失败退化为占位：会话能继续，而不是把 run 打断
            "... ${this.pressureOf(region)} previous tokens summarized ..."
        }
        // 注意：这里必须**原样返回 next**（哪怕它没变短）——压缩"没变短"由调用方
        // 按 `result.size < messages.size` 判定为 noop 并留痕，不是靠这里丢弃结果。
        // 丢弃结果会带来一个隐蔽的行为差异：摘要成功但保留区覆盖全文时（单条超长消息
        // 就属于这种），历史本应被替换成「检查点 + 原消息」，丢弃则什么都不发生。
        compactWithSummary(messages, plan.retainTokens, summary, this.pressureOf(messages))
    }

    public func pruneForRequest(messages: ArrayList<Message>,
        cfg: ToolResultPruneConfig): ArrayList<Message> {
        if (!cfg.enabled) { return messages }
        let (pruned, count) = pruneToolResults(messages, cfg)
        if (count == 0) { return messages }
        pruned
    }

    /**
     * 压力估算：以**最近一次带用量的 assistant 消息**为锚（它反映那次请求的提示词规模），
     * 加上其后新增消息的估算 —— 与 dsh「provider 用量锚 + 表面增量」同源。
     * 没有锚（首轮 / provider 不报用量）时退回整体估算。
     */
    public func pressureOf(messages: ArrayList<Message>): Int64 {
        var i = Int64(messages.size) - 1
        while (i >= 0) {
            match (messages[i]) {
                case am: AssistantMessage =>
                    if (am.usage.inputTokens > 0) {
                        let tail = ArrayList<Message>()
                        var j = i + 1
                        while (j < Int64(messages.size)) {
                            tail.add(messages[Int64(j)])
                            j++
                        }
                        return am.usage.inputTokens + estimateTokens(tail)
                    }
                case _ => ()
            }
            i--
        }
        estimateTokens(messages)
    }
}

/**
 * 不压缩实现：原样返回一切。
 *
 * 存在的意义有两个：① panel 模式下历史本就恒定，不该付摘要调用的钱；
 * ② 证明「换一个 Compactor 真的能跑」——只有默认实现可换时无法区分"接口成功"与
 * "碰巧默认实现就是那个行为"。
 */
public class NoopCompactor <: Compactor {
    public init() {}

    public func shouldCompact(messages: ArrayList<Message>, route: CompactRoute): CompactDecision {
        CompactDecision.Skip("compaction disabled (noop compactor)")
    }

    public func compact(messages: ArrayList<Message>, plan: CompactPlan,
        ctx: CompactionRuntime): ArrayList<Message> {
        messages
    }
}
