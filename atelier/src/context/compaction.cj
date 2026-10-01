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

public let DEFAULT_PROMPT_TEMPLATE = """
你是一个上下文压缩引擎。请将以下对话压缩成一份结构化的摘要，以便另一个 AI 能够无缝接续工作。

<conversation>
{{conversation}}
</conversation>

{{#previous_summary}}
<previous_summary>
{{previous_summary}}
</previous_summary>
{{/previous_summary}}

输出要求：
1. 严格输出 JSON 格式
2. 必须包含以下字段：
   - goal: 用户的核心目标
   - key_findings: 关键发现列表
   - files_modified: 修改过的文件路径列表
   - errors: 遇到的错误及解决方案
   - pending_actions: 下一步待办事项
3. 不要添加任何额外的解释或散文。
4. 摘要的总长度请控制在 {{max_tokens}} tokens 以内。"""

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
        this.promptTemplate = DEFAULT_PROMPT_TEMPLATE
        this.outputSchema = None
        this.summaryModel = None
    }

    public init(enabled: Bool, thresholdRatio: Float64, headroomTokens: Int64,
        retainRatio: Float64, retainTokens: Option<Int64>, maxOverflowRetries: Int64,
        promptTemplate: String, outputSchema: Option<JsonValue>, summaryModel: Option<String>,
        summaryMaxTokens!: Int64 = 0) {
        this.enabled = enabled
        this.thresholdRatio = thresholdRatio
        this.headroomTokens = headroomTokens
        this.retainRatio = retainRatio
        this.retainTokens = retainTokens
        this.maxOverflowRetries = maxOverflowRetries
        this.summaryMaxTokens = summaryMaxTokens
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
            template, schema, summaryModel, summaryMaxTokens: summaryMax)
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
