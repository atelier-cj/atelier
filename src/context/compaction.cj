package atelier.context

import atelier.message.*
import std.collection.*
import mustache.{Template, MustacheComponent}
import stdx.serialization.serialization.*
import stdx.encoding.json.stream.*
import jsonvalue.*

public func compactMessages(messages: ArrayList<Message>, contextWindow: Int64, reserveTokens: Int64, keepRecentTokens: Int64): ArrayList<Message> {
    let total = estimateTokens(messages)
    if (total <= reserveTokens || contextWindow == 0) {
        return messages  // no compaction needed
    }

    let threshold = contextWindow - reserveTokens
    if (total <= threshold) {
        return messages
    }

    // Simple strategy: keep the last keepRecentTokens worth of messages,
    // summarize everything before that
    var running: Int64 = 0
    var cutIndex: Int64 = 0
    var i = messages.size - 1
    while (i >= 0 && running < keepRecentTokens) {
        running += estimateMessageTokens(messages[i])
        i--
    }
    cutIndex = i + 1

    if (cutIndex <= 0) {
        return messages  // all messages fit
    }

    // Replace cut messages with a summary
    let compacted = ArrayList<Message>()
        let subList = ArrayList<Message>()
        for (k in 0..cutIndex) { subList.add(messages[Int64(k)]) }
        compacted.add(CompactionMessage("... ${cutIndex} previous messages summarized ...", estimateTokens(subList), 0))
        for (j in cutIndex..Int64(messages.size)) {
        compacted.add(messages[Int64(j)])
    }
    compacted
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
    public let reserveTokens: Int64
    public let keepRecentTokens: Int64
    public let promptTemplate: String
    public let outputSchema: Option<JsonValue>
    public let summaryModel: Option<String>

    public init() {
        this.enabled = true
        this.reserveTokens = 16384
        this.keepRecentTokens = 20000
        this.promptTemplate = DEFAULT_PROMPT_TEMPLATE
        this.outputSchema = None
        this.summaryModel = None
    }

    public init(enabled: Bool, reserveTokens: Int64, keepRecentTokens: Int64,
        promptTemplate: String, outputSchema: Option<JsonValue>, summaryModel: Option<String>) {
        this.enabled = enabled
        this.reserveTokens = reserveTokens
        this.keepRecentTokens = keepRecentTokens
        this.promptTemplate = promptTemplate
        this.outputSchema = outputSchema
        this.summaryModel = summaryModel
    }

    public func toJson(w: JsonWriter): Unit {
        w.startObject()
        w.writeName("enabled").writeValue(this.enabled)
        w.writeName("reserveTokens").writeValue(this.reserveTokens)
        w.writeName("keepRecentTokens").writeValue(this.keepRecentTokens)
        w.writeName("promptTemplate").writeValue(this.promptTemplate)
        w.writeName("outputSchema").writeValue(this.outputSchema)
        w.writeName("summaryModel").writeValue(this.summaryModel)
        w.endObject()
    }

    public static func fromJson(r: JsonReader): CompactionConfig {
        var enabled = true
        var reserve = Int64(16384)
        var keepRecent = Int64(20000)
        var template = DEFAULT_PROMPT_TEMPLATE
        var schema: Option<JsonValue> = None
        var summaryModel: Option<String> = None
        r.startObject()
        while (r.peek() != EndObject) {
            match (r.readName()) {
                case "enabled" => enabled = r.readValue<Bool>()
                case "reserveTokens" => reserve = r.readValue<Int64>()
                case "keepRecentTokens" => keepRecent = r.readValue<Int64>()
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
        CompactionConfig(enabled, reserve, keepRecent, template, schema, summaryModel)
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

// 切点替换：保留最近 keepRecentTokens，之前替换为 CompactionMessage(summary, tokensBefore, 0)
// keepRecentTokens <= 0 时全部替换
public func compactWithSummary(messages: ArrayList<Message>, keepRecentTokens: Int64,
    summary: String, tokensBefore: Int64): ArrayList<Message> {
    if (keepRecentTokens <= 0) {
        let r = ArrayList<Message>()
        r.add(CompactionMessage(summary, tokensBefore, 0))
        return r
    }
    var running: Int64 = 0
    var cutIndex: Int64 = 0
    var i = messages.size - 1
    while (i >= 0 && running < keepRecentTokens) {
        running += estimateMessageTokens(messages[i])
        i--
    }
    cutIndex = i + 1
    if (cutIndex <= 0) { return messages }
    let compacted = ArrayList<Message>()
    compacted.add(CompactionMessage(summary, tokensBefore, 0))
    for (j in cutIndex..Int64(messages.size)) {
        compacted.add(messages[Int64(j)])
    }
    compacted
}
