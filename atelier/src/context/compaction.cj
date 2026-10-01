package atelier.context

import atelier.message.*
import std.collection.*
import mustache.{Template, MustacheComponent}
import stdx.serialization.serialization.*
import stdx.encoding.json.stream.*
import jsonvalue.*

/**
 * 压力预算：把宿主声明的窗口与**生效请求输出上限**换算成"什么时候压、压完保留多少"。
 *
 * 口径（与 dsh 一致）：
 * ```text
 * messageBudget  = W − O              // 窗口里留给消息的部分（O = 本次请求的输出预留）
 * pressureBudget = messageBudget − B  // 再留一笔余量 B（估算误差 / 图片 / 工具声明）
 * threshold      = floor(min(W × ratio, pressureBudget))
 * retain         = retainTokens ?? floor(messageBudget × retainRatio)
 * ```
 *
 * 三个不变量（`messageBudget > 0`、`pressureBudget > 0`、`retain < threshold`）任一不成立
 * 都**不压**：`spec = None` + `reason` 说明原因，调用方留痕一次即可 —— 配置坏了不该把会话
 * 变成不可用（溢出恢复那条路仍然可用）。
 */
public struct CompactSpec {
    /** 本路由的窗口 */
    public let contextWindow: Int64
    /** 窗口里留给消息的预算（W − O） */
    public let messageBudget: Int64
    /** 越过它就该压缩 */
    public let thresholdTokens: Int64
    /** 压缩后逐字保留的近期历史预算 */
    public let retainTokens: Int64
    /** 摘要子调用的输出上限 */
    public let summaryMaxTokens: Int64

    public init(contextWindow: Int64, messageBudget: Int64, thresholdTokens: Int64,
        retainTokens: Int64, summaryMaxTokens: Int64) {
        this.contextWindow = contextWindow
        this.messageBudget = messageBudget
        this.thresholdTokens = thresholdTokens
        this.retainTokens = retainTokens
        this.summaryMaxTokens = summaryMaxTokens
    }
}

/** 解析结果：`spec` 为 None 时 `reason` 说明为什么不压（配置错误） */
public struct CompactSpecResolution {
    public let spec: Option<CompactSpec>
    public let reason: String

    public init(spec: Option<CompactSpec>, reason: String) {
        this.spec = spec
        this.reason = reason
    }
}

public func resolveCompactSpec(cc: CompactionConfig, contextWindow: Int64,
    reservedCompletionTokens: Int64): CompactSpecResolution {
    if (contextWindow <= 0) {
        // 窗口未知 = 不做主动压缩（旧行为一致：拿不到窗口就不猜）
        return CompactSpecResolution(None, "context window unknown")
    }
    let messageBudget = contextWindow - reservedCompletionTokens
    if (messageBudget <= 0) {
        return CompactSpecResolution(None,
            "reserves ${reservedCompletionTokens} completion tokens of a ${contextWindow}-token window, leaving no message budget: raise the model contextWindow above the effective maxOutputTokens")
    }
    let pressureBudget = messageBudget - cc.headroomTokens
    if (pressureBudget <= 0) {
        return CompactSpecResolution(None,
            "reserves ${reservedCompletionTokens} completion + ${cc.headroomTokens} headroom of a ${contextWindow}-token window, leaving no pressure budget: reduce maxOutputTokens/headroomTokens or raise the contextWindow")
    }
    var threshold = Int64(Float64(contextWindow) * cc.thresholdRatio)
    if (pressureBudget < threshold) { threshold = pressureBudget }
    let retain = match (cc.retainTokens) {
        case Some(v) => v
        case None => Int64(Float64(messageBudget) * cc.retainRatio)
    }
    if (retain >= threshold) {
        return CompactSpecResolution(None,
            "retain (${retain}) must be less than the compaction threshold (${threshold})")
    }
    let summaryMax = if (cc.summaryMaxTokens > 0) { cc.summaryMaxTokens } else { cc.headroomTokens }
    CompactSpecResolution(Some(CompactSpec(contextWindow, messageBudget, threshold, retain, summaryMax)),
        "")
}

/**
 * 默认压缩指令（结构照 dsh 的 `COMPACTION_INSTRUCTION`：固定的 Markdown 检查点骨架 +
 * 一组硬规则；对话在前、指令在后，与 dsh「回放对话 → 末尾追加指令」的顺序一致）。
 *
 * 与 dsh 的两点差异，都是刻意的：
 * - 指令用中文：本工程其余提示词与用户会话都是中文，摘要必须服务同一场对话
 *   （dsh 的规则里写的是 "concise English engineering prose"）
 * - 对话由 `{{conversation}}` 内联在同一个 user 消息里（dsh 是回放整段消息再追加指令）
 */
public let DEFAULT_PROMPT_TEMPLATE = """
<conversation>
{{conversation}}
</conversation>

{{#previous_summary}}
<previous_summary>
{{previous_summary}}
</previous_summary>
{{/previous_summary}}

你是这个 AI 编程助手的压缩引擎。把上面这段对话压缩成一份结构化检查点，让另一个模型能在不丢失关键上下文的前提下接续工作。

严格按下面的 Markdown 结构输出：每一节都要保留、顺序不变。用简短要点，不要写大段散文；某一节没有内容就写 "(none)"，不要省略该节。

## Primary Request and Intent
- [用户最初与演进后的目标；措辞本身重要时逐字保留]

## Key Technical Concepts
- [涉及的技术、框架、模式与约定]

## Files and Code
- [精确路径：为什么重要、关键改动或代码片段]

## Errors and Fixes
- [错误：如何解决的，以及相关的用户反馈]

## Pending Jobs
- [明确要求但尚未完成的工作]

## Current Work
- [写这份检查点时正在做的事]

## Next Step
- [下一个动作，直接对着最近一次要求；没有就写 "(none)"]

## Critical Context
- [决策及其理由、约束、用户偏好、未决问题、继续所需的数据]

规则：
- 用简洁的工程化表述；保留精确的文件路径、命令、报错原文、标识符、数值、函数签名与语法片段。
- 忠实记录用户反馈与明确指令，尤其是纠正。
- 不要提到这次摘要请求，也不要提到上下文被压缩过。
- 只输出检查点文本：不要调用任何工具，不要做其它动作。
- 若上面给出了 <previous_summary>（那是上一份检查点），不要原样照抄：保留仍然成立的事实、丢掉过时的，把新信息并进同一套结构。"""
public struct CompactionConfig <: JsonSerializable & JsonDeserializable<CompactionConfig> {
    public let enabled: Bool
    /** 触发阈值占窗口的比例（dsh 默认 0.8） */
    public let thresholdRatio: Float64
    /** 输出预留之外的额外压力余量（默认 65536；估算误差/图片/工具声明的缓冲） */
    public let headroomTokens: Int64
    /** 逐字保留的近期历史占"消息预算"的比例（默认 0.16） */
    public let retainRatio: Float64
    /** 绝对保留预算；给定时压过 [retainRatio] */
    public let retainTokens: Option<Int64>
    /** 已确认上下文溢出后的最大重试次数（0 = 关闭溢出恢复） */
    public let maxOverflowRetries: Int64
    /** 摘要子调用的输出上限；0 = 跟随 [headroomTokens] */
    public let summaryMaxTokens: Int64
    /** 工具结果修剪；None = 用默认配置（开启，8192 码点 → 头 4096 + 标记 + 尾 1024） */
    public let prune: Option<ToolResultPruneConfig>
    public let promptTemplate: String
    public let outputSchema: Option<JsonValue>
    public let summaryModel: Option<String>

    public init() {
        this.enabled = true
        this.thresholdRatio = 0.8
        this.headroomTokens = 65536
        this.retainRatio = 0.16
        this.retainTokens = None
        this.maxOverflowRetries = 1
        this.summaryMaxTokens = 0
        this.prune = None
        this.promptTemplate = DEFAULT_PROMPT_TEMPLATE
        this.outputSchema = None
        this.summaryModel = None
    }

    public init(enabled: Bool, thresholdRatio: Float64, headroomTokens: Int64,
        retainRatio: Float64, retainTokens: Option<Int64>, maxOverflowRetries: Int64,
        promptTemplate: String, outputSchema: Option<JsonValue>, summaryModel: Option<String>,
        summaryMaxTokens!: Int64 = 0, prune!: Option<ToolResultPruneConfig> = None) {
        this.enabled = enabled
        this.thresholdRatio = thresholdRatio
        this.headroomTokens = headroomTokens
        this.retainRatio = retainRatio
        this.retainTokens = retainTokens
        this.maxOverflowRetries = maxOverflowRetries
        this.summaryMaxTokens = summaryMaxTokens
        this.prune = prune
        this.promptTemplate = promptTemplate
        this.outputSchema = outputSchema
        this.summaryModel = summaryModel
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("enabled").writeValue(this.enabled)
        w.writeName("thresholdRatio").writeValue(this.thresholdRatio)
        w.writeName("headroomTokens").writeValue(this.headroomTokens)
        w.writeName("retainRatio").writeValue(this.retainRatio)
        w.writeName("retainTokens").writeValue(this.retainTokens)
        w.writeName("maxOverflowRetries").writeValue(this.maxOverflowRetries)
        w.writeName("summaryMaxTokens").writeValue(this.summaryMaxTokens)
        match (this.prune) {
            case Some(p) =>
                w.writeName("prune")
                p.toJson(w)
            case None => w.writeName("prune").writeNullValue()
        }
        w.writeName("promptTemplate").writeValue(this.promptTemplate)
        w.writeName("outputSchema").writeValue(this.outputSchema)
        w.writeName("summaryModel").writeValue(this.summaryModel)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): CompactionConfig {
        var enabled = true
        var ratio = Float64(0.8)
        var headroom = Int64(65536)
        var retainRatio = Float64(0.16)
        var retain: Option<Int64> = None
        var overflowRetries = Int64(1)
        var summaryMax = Int64(0)
        var prune: Option<ToolResultPruneConfig> = None
        var template = DEFAULT_PROMPT_TEMPLATE
        var schema: Option<JsonValue> = None
        var summaryModel: Option<String> = None
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "enabled" => enabled = r.readValue<Bool>()
                case "thresholdRatio" => ratio = r.readValue<Float64>()
                case "headroomTokens" => headroom = r.readValue<Int64>()
                case "retainRatio" => retainRatio = r.readValue<Float64>()
                case "retainTokens" => retain = r.readValue<Option<Int64>>()
                case "maxOverflowRetries" => overflowRetries = r.readValue<Int64>()
                case "summaryMaxTokens" => summaryMax = r.readValue<Int64>()
                case "prune" =>
                    if (r.peek() == JsonNull) {
                        r.skip()
                        prune = None
                    } else {
                        prune = Some(ToolResultPruneConfig.fromJson(r))
                    }
                case "promptTemplate" => template = r.readValue<String>()
                case "outputSchema" =>
                    if (r.peek() == JsonNull) {
                        r.skip()
                        schema = None
                    } else {
                        schema = Some(JsonValue.fromJson(r))
                    }
                case "summaryModel" => summaryModel = r.readValue<Option<String>>()
                case _ => r.skip()
            }
        }
        r.endObject()
        CompactionConfig(enabled, ratio, headroom, retainRatio, retain, overflowRetries,
            template, schema, summaryModel, summaryMaxTokens: summaryMax, prune: prune)
    }
}

// 模板渲染上下文：实现 MustacheComponent（mustache-cj 1.2.1）
public class CompactionContext <: MustacheComponent {
    public let conversation: String
    public let previousSummary: Option<String>
    public let maxTokens: Int64

    public init(conversation: String, previousSummary: Option<String>, maxTokens: Int64) {
        this.conversation = conversation
        this.previousSummary = previousSummary
        this.maxTokens = maxTokens
    }

    public func mustache(): DataModel {
        let sb = DataModelStruct()
        sb.add(field<String>("conversation", this.conversation))
        match (this.previousSummary) {
            case Some(s) => sb.add(field<String>("previous_summary", s))
            case None => ()
        }
        sb.add(field<Int64>("max_tokens", this.maxTokens))
        sb
    }
}

// 渲染压缩提示词（模板 + 变量）
public func renderCompactionPrompt(config: CompactionConfig, conversationText: String,
    previousSummary: Option<String>, maxTokens: Int64): String {
    let template = Template()
    template.parse(config.promptTemplate)
    let ctx = CompactionContext(conversationText, previousSummary, maxTokens)
    let arr = [ctx]
    template.render(arr)
}

// 从消息中提取最近一条历史摘要（CompactionMessage 或 ArchiveMessage），供模板 {{#previous_summary}}
public func findPreviousSummary(messages: ArrayList<Message>): Option<String> {
    var i = messages.size - 1
    while (i >= 0) {
        match (messages[i]) {
            case cm: CompactionMessage => return Some(cm.summary)
            case am: ArchiveMessage => return Some(am.summary)
            case _ => ()
        }
        i--
    }
    None
}

// 极简 schema 校验：{required: [...], types: {name: "string|array|number|bool|object"}}
// 校验失败/解析失败返回 false（调用方降级原文）
public func validateSummary(config: CompactionConfig, schema: HashMap<String, JsonValue>, text: String): Bool {
    let parsed = try { JsonValue.parse(text) } catch (_) { return false }
    let obj = match (parsed) {
        case JsonValue.Map(m) => m
        case _ => return false
    }
    match (schema.get("required")) {
        case Some(JsonValue.Array(items)) =>
            for (item in items) {
                match (item) {
                    case JsonValue.String(key) =>
                        if (!obj.contains(key)) { return false }
                    case _ => ()
                }
            }
        case _ => ()
    }
    match (schema.get("types")) {
        case Some(JsonValue.Map(types)) =>
            for ((key, typeVal) in types) {
                match ((obj.get(key), typeVal)) {
                    case (Some(JsonValue.String(_)), JsonValue.String("string")) => ()
                    case (Some(JsonValue.Array(_)), JsonValue.String("array")) => ()
                    case (Some(JsonValue.Number(_)), JsonValue.String("number")) => ()
                    case (Some(JsonValue.Boolean(_)), JsonValue.String("bool")) => ()
                    case (Some(JsonValue.Map(_)), JsonValue.String("object")) => ()
                    case (None, _) => ()
                    case (Some(_), _) => return false
                }
            }
        case _ => ()
    }
    true
}

// 切点替换：保留最近 retainTokens，之前替换为 CompactionMessage(summary, tokensBefore, 0)
// retainTokens <= 0 时全部替换；单条消息即达标时仅保留其后消息
public func compactWithSummary(messages: ArrayList<Message>, retainTokens: Int64,
    summary: String, tokensBefore: Int64): ArrayList<Message> {
    if (retainTokens <= 0) {
        let r = ArrayList<Message>()
        r.add(CompactionMessage(summary, tokensBefore, 0))
        return r
    }
    var running: Int64 = 0
    var cutIndex: Int64 = 0
    var i = messages.size - 1
    while (i >= 0 && running < retainTokens) {
        running += estimateMessageTokens(messages[i])
        if (running >= retainTokens) { break }
        i--
    }
    cutIndex = i + 1
    cutIndex = protectCutPoint(messages, cutIndex)
    if (cutIndex <= 0) { return messages }
    let compacted = ArrayList<Message>()
    compacted.add(CompactionMessage(summary, tokensBefore, 0))
    for (j in cutIndex..Int64(messages.size)) {
        compacted.add(messages[Int64(j)])
    }
    compacted
}

/**
 * 从 `keepFrom` 起保留，之前替换为摘要（**溢出恢复**用：尽量多压，只留最后一段）。
 *
 * 与 [compactWithSummary] 的差别是切点由调用方直接指定（不按 token 预算回退），
 * 仍然过 [protectCutPoint]，保证不拆散工具调用对；切点落到 0 表示压无可压。
 */
public func compactFrom(messages: ArrayList<Message>, keepFrom: Int64,
    summary: String, tokensBefore: Int64): ArrayList<Message> {
    let cut = protectCutPoint(messages, keepFrom)
    if (cut <= 0) { return messages }
    let out = ArrayList<Message>()
    out.add(CompactionMessage(summary, tokensBefore, 0))
    for (j in cut..Int64(messages.size)) {
        out.add(messages[Int64(j)])
    }
    out
}

// 最后一条用户消息的下标（-1 = 没有）；溢出恢复时至少保住它，否则等于把本次输入丢了
public func lastUserIndex(messages: ArrayList<Message>): Int64 {
    var i = Int64(messages.size) - 1
    while (i >= 0) {
        match (messages[i]) {
            case _: UserMessage => return i
            case _ => ()
        }
        i--
    }
    -1
}

/**
 * provider 报的是不是"超上下文窗口"（可恢复）。
 *
 * 各家措辞不统一（OpenAI `maximum context length` / Anthropic `prompt is too long` /
 * DeepSeek 同 OpenAI），所以按**已知措辞**匹配小写文本；匹配不到就当普通失败处理——
 * 宁可少恢复一次，也不要把无关错误误判成溢出（那会白花一次摘要调用）。
 *
 * 长期做法是让 provider 层抛带错误码的异常（llm_api 侧），这里先按文本兜住。
 */
public func isContextOverflowError(errorText: String): Bool {
    let t = errorText.toAsciiLower()
    let markers = [
        "maximum context length",
        "context length exceeded",
        "context_length_exceeded",
        "context window exceeded",
        "context_window_exceeded",
        "prompt is too long",
        "input is too long",
        "too many tokens",
        "reduce the length of the messages"
    ]
    for (m in markers) {
        if (t.contains(m)) { return true }
    }
    false
}

/**
 * 工具结果修剪配置：把超长的工具输出换成"头 + 标记 + 尾"。
 *
 * 目的与摘要不同——**不发模型调用**，纯字符操作，而且可能让压力回到阈值内、
 * 从而把摘要整个省掉。与 dsh 一致：只在压缩触发条件满足后才跑。
 *
 * 语义要点：只影响**发出请求的那份**消息（运行时构造请求时用修剪版），落库的历史保持原样，
 * 所以回放/导出仍然拿得到完整输出。
 */
public struct ToolResultPruneConfig <: JsonSerializable & JsonDeserializable<ToolResultPruneConfig> {
    public let enabled: Bool
    /** 合并文本超过这么多**码点**才修剪 */
    public let thresholdChars: Int64
    public let headChars: Int64
    public let tailChars: Int64

    public init() {
        this.enabled = true
        this.thresholdChars = 8192
        this.headChars = 4096
        this.tailChars = 1024
    }

    public init(enabled: Bool, thresholdChars: Int64, headChars: Int64, tailChars: Int64) {
        this.enabled = enabled
        this.thresholdChars = thresholdChars
        this.headChars = headChars
        this.tailChars = tailChars
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("enabled").writeValue(this.enabled)
        w.writeName("thresholdChars").writeValue(this.thresholdChars)
        w.writeName("headChars").writeValue(this.headChars)
        w.writeName("tailChars").writeValue(this.tailChars)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): ToolResultPruneConfig {
        let def = ToolResultPruneConfig()
        var enabled = def.enabled
        var threshold = def.thresholdChars
        var head = def.headChars
        var tail = def.tailChars
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "enabled" => enabled = r.readValue<Bool>()
                case "thresholdChars" => threshold = r.readValue<Int64>()
                case "headChars" => head = r.readValue<Int64>()
                case "tailChars" => tail = r.readValue<Int64>()
                case _ => r.skip()
            }
        }
        r.endObject()
        ToolResultPruneConfig(enabled, threshold, head, tail)
    }
}

public let PRUNE_MARKER = "\n... [middle pruned] ...\n"

/**
 * 修剪一段文本：按**码点**切，不会劈开 emoji 的代理对。
 *
 * `head + 标记 + tail` 必须不超过 [ToolResultPruneConfig.thresholdChars]，
 * 否则修剪反而让文本变长（配置写歪时自动收紧尾部，不报错）。
 */
public func pruneText(text: String, cfg: ToolResultPruneConfig): String {
    let runes = text.toRuneArray()
    let total = Int64(runes.size)
    if (total <= cfg.thresholdChars) { return text }
    let markerLen = Int64(PRUNE_MARKER.toRuneArray().size)
    // 阈值小到连标记都放不下：宁可不动，也不能让"修剪"把文本变长
    if (cfg.thresholdChars <= markerLen + 1) { return text }
    // 收紧：头 + 标记 + 尾 <= 阈值（头先收，再按剩余预算收尾）
    var head = cfg.headChars
    if (head > cfg.thresholdChars - markerLen) { head = cfg.thresholdChars - markerLen }
    if (head > total) { head = total }
    let budget = cfg.thresholdChars - markerLen - head
    var tail = cfg.tailChars
    if (tail > budget) { tail = if (budget > 0) { budget } else { 0 } }
    if (head + tail >= total) { return text }
    let sb = StringBuilder()
    var i: Int64 = 0
    while (i < head) {
        sb.append(runes[i])
        i++
    }
    sb.append(PRUNE_MARKER)
    var j = total - tail
    while (j < total) {
        sb.append(runes[j])
        j++
    }
    sb.toString()
}

/**
 * 修剪一条工具结果里的文本块：合并所有文本块、超阈值就换成"头 + 标记 + 尾"，
 * 非文本块（图片等）保持原有顺序。返回 None = 这条不需要修剪。
 */
func prunedToolResult(msg: ToolResultMessage, cfg: ToolResultPruneConfig): Option<ToolResultMessage> {
    var merged = ""
    var textCount: Int64 = 0
    for (b in msg.content.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(t) =>
                merged = merged + t
                textCount++
            case _ => ()
        }
    }
    if (textCount == 0 || Int64(merged.toRuneArray().size) <= cfg.thresholdChars) {
        return None
    }
    let pruned = pruneText(merged, cfg)
    if (pruned == merged) { return None }
    let blocks = ArrayList<ContentBlock>()
    var inserted = false
    for (b in msg.content.blocks()) {
        match (b) {
            case ContentBlock.TextBlock(_) =>
                // 文本块合并成一段（插在第一个文本块的位置），其余文本块丢弃
                if (!inserted) {
                    blocks.add(ContentBlock.TextBlock(pruned))
                    inserted = true
                }
            case _ => blocks.add(b)
        }
    }
    Some(ToolResultMessage(msg.toolCallId, msg.toolName, ContentList(blocks), msg.isError, msg.timestamp))
}

/**
 * 修剪整份消息列表里的超大工具结果（**返回新列表，原列表不动**）。
 *
 * 只在压缩触发条件满足后调用；低于压力阈值的对话绝不该被触碰。
 */
public func pruneToolResults(messages: ArrayList<Message>, cfg: ToolResultPruneConfig): (ArrayList<Message>, Int64) {
    if (!cfg.enabled) { return (messages, 0) }
    let out = ArrayList<Message>()
    var prunedCount: Int64 = 0
    for (m in messages) {
        match (m) {
            case tr: ToolResultMessage =>
                match (prunedToolResult(tr, cfg)) {
                    case Some(p) =>
                        out.add(p)
                        prunedCount++
                    case None => out.add(m)
                }
            case _ => out.add(m)
        }
    }
    (out, prunedCount)
}

// 切点配对保护：cutIndex 不拆散 ToolCall ↔ ToolResult 对。
// 每个对视为不可切分区间 [l, r]（l=调用消息索引，r=结果消息索引），
// 合法切点 c 必须对所有区间满足 c <= l 或 c > r：
// a. 切点落在区间右端点（保留区第一条是 ToolResult）→ 前移保留其 ToolCall
// b. 切点落在区间内部其余位置 → 后移整体移除该对
// 区间法一次性收敛，交叉配对（如 [A(t1), A(t2), TR(t1), TR(t2)]）不会像
// 逐条前移/后移的迭代式实现那样在两个切点间无限振荡
public func protectCutPoint(messages: ArrayList<Message>, cutIndex: Int64): Int64 {
    let cut = cutIndex
    if (cut <= 0 || cut >= messages.size) { return cut }
    let pairs = ArrayList<(Int64, Int64)>()
    for (i in 0..Int64(messages.size)) {
        match (messages[Int64(i)]) {
            case tr: ToolResultMessage =>
                var j = Int64(i) - 1
                var found = false
                while (j >= 0 && !found) {
                    match (messages[Int64(j)]) {
                        case am: AssistantMessage =>
                            for (tc in am.toolCalls()) {
                                if (tc.id == tr.toolCallId) { found = true }
                            }
                        case _ => ()
                    }
                    if (!found) { j-- }
                }
                if (found) { pairs.add((Int64(j), Int64(i))) }
            case _ => ()
        }
    }
    if (pairs.size == 0) { return cut }
    if (!pairCoversCut(pairs, cut)) { return cut }
    match (messages[Int64(cut)]) {
        case _: ToolResultMessage =>
            // a. 保留区第一条是 ToolResult → 前移到最近合法切点，保留其 ToolCall
            var c = cut - 1
            while (c > 0 && pairCoversCut(pairs, c)) { c-- }
            c
        case _ =>
            // b. 切点在区间内部 → 后移到最近合法切点，整体移除该对
            var c = cut + 1
            while (c < Int64(messages.size) && pairCoversCut(pairs, c)) { c++ }
            c
    }
}

func pairCoversCut(pairs: ArrayList<(Int64, Int64)>, c: Int64): Bool {
    for ((l, r) in pairs) {
        if (l < c && c <= r) { return true }
    }
    false
}
