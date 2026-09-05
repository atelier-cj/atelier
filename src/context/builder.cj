package atelier.context

import atelier.message.*
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import atelier.tool.McpManager
import jsonvalue.*
import std.collection.*

public class ContextBuilder {
    private let skills: SkillRegistry
    private let env: SessionEnvironment
    private let mcpManager: Option<McpManager>
    private let promptBuilder: SystemPromptBuilder
    private let contributors: ArrayList<PromptSegmentContributor>

    public init(skills: SkillRegistry, env: SessionEnvironment,
        contributors!: ArrayList<PromptSegmentContributor> = ArrayList()) {
        this.skills = skills
        this.env = env
        this.mcpManager = None
        this.promptBuilder = SystemPromptBuilder()
        this.contributors = contributors
    }

    public init(skills: SkillRegistry, env: SessionEnvironment, mcpManager: McpManager,
        contributors!: ArrayList<PromptSegmentContributor> = ArrayList()) {
        this.skills = skills
        this.env = env
        this.mcpManager = Some(mcpManager)
        this.promptBuilder = SystemPromptBuilder()
        this.contributors = contributors
    }

    // run 一次：系统提示（若有）作为首条 UserMessage，再追加历史
    public func initMessages(systemPrompt: String, skillNames: ArrayList<String>,
        history: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        var text = this.promptBuilder.build(systemPrompt, skillNames, this.skills, this.env,
            contributors: this.contributors)
        match (this.mcpManager) {
            case Some(m) =>
                let catalog = this.promptBuilder.buildMcpCatalog(m)
                if (catalog != "") { text = text + catalog }
            case None => ()
        }
        let skillCatalog = this.promptBuilder.buildSkillCatalog(this.skills)
        if (skillCatalog != "") { text = text + skillCatalog }
        if (text != "") {
            // 幂等：history 首条已是相同系统提示则不重复注入（REPL 每轮复用 messages）
            var alreadyInjected = false
            if (history.size > 0) {
                match (history[0]) {
                    case um: UserMessage =>
                        var firstText = ""
                        for (b in um.content.blocks()) {
                            match (b) { case ContentBlock.TextBlock(t) => firstText = firstText + t; case _ => () }
                        }
                        if (firstText == text) { alreadyInjected = true }
                    case _ => ()
                }
            }
            if (!alreadyInjected) {
                result.add(UserMessage(ContentList.ofText(text), 0))
            }
        }
        for (m in history) { result.add(m) }
        result
    }

    // 每轮：组装 ChatRequest
    public func buildChatRequest(model: String, messages: ArrayList<Message>,
        temperature: Float64, maxOutputTokens: Int64,
        thinkingLevel: Option<String>, tools: ArrayList<OpenAITool>): ChatRequest {
        ChatRequest(model, messages, temperature, maxOutputTokens, thinkingLevel, tools)
    }

    // 应用 archive_history 调用对：钳制范围后替换为 ArchiveMessage，调用对自身移除（天然幂等）。
    // 从后往前处理：后面的调用对先应用，前面的索引不受影响；无调用对返回原列表。
    public func applyArchives(messages: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        for (m in messages) { result.add(m) }
        var i = result.size - 1
        while (i >= 0) {
            match (result[Int64(i)]) {
                case tr: ToolResultMessage where tr.toolName == "archive_history" =>
                    // 向前找对应的 ToolCall（最近的 AssistantMessage 中 id + name 匹配）
                    var callIdx: Int64 = -1
                    var start: Int64 = 0
                    var end: Int64 = 0
                    var summary = ""
                    var j = i - 1
                    while (j >= 0) {
                        match (result[Int64(j)]) {
                            case am: AssistantMessage =>
                                var matched = false
                                for (tc in am.toolCalls()) {
                                    if (tc.id == tr.toolCallId && tc.name == "archive_history") {
                                        matched = true
                                        let startOpt = extractIndex(tc.args, "start_index")
                                        let endOpt = extractIndex(tc.args, "end_index")
                                        let sumOpt = extractSummary(tc.args)
                                        let parsed = (startOpt, endOpt, sumOpt)
                                        match (parsed) {
                                            case (Some(s), Some(e), Some(su)) =>
                                                callIdx = j
                                                start = s
                                                end = e
                                                summary = su
                                            case _ => ()
                                        }
                                    }
                                }
                                if (matched) { break }
                            case _ => ()
                        }
                        if (callIdx >= 0) { break }
                        j--
                    }
                    if (callIdx >= 0) {
                        // 钳制：start 到 [0, callIdx-1]，end 到 [start, callIdx-1]（调用对前一条）
                        var ss = if (start < 0) { 0 } else { start }
                        if (ss >= callIdx) { i--; continue }
                        var ee = if (end > callIdx - 1) { callIdx - 1 } else { end }
                        if (ee < ss) { ee = ss }
                        // 重建：移除 [ss, callIdx-1] 与调用对，ArchiveMessage 插入在 ss 处
                        let next = ArrayList<Message>()
                        var k: Int64 = 0
                        while (k < result.size) {
                            if (k == ss) { next.add(ArchiveMessage(ss, ee, summary, 0)) }
                            if (k >= ss && k <= callIdx - 1) { k++; continue }
                            if (k == callIdx || k == i) { k++; continue }
                            next.add(result[Int64(k)])
                            k++
                        }
                        result.clear()
                        for (m in next) { result.add(m) }
                        i = result.size - 1
                        continue
                    }
                case _ => ()
            }
            i--
        }
        result
    }

    // 历史 ArchiveMessage 范围跳过：归档声明范围内的消息不进入 LLM 上下文
    // （ArchiveMessage 自身保留作为摘要，幂等：重复调用结果一致）
    public func applyArchiveMarks(messages: ArrayList<Message>): ArrayList<Message> {
        let ranges = ArrayList<(Int64, Int64)>()
        for (m in messages) {
            match (m) {
                case am: ArchiveMessage => ranges.add((am.startIndex, am.endIndex))
                case _ => ()
            }
        }
        if (ranges.size == 0) { return messages }
        let result = ArrayList<Message>()
        var i: Int64 = 0
        while (i < messages.size) {
            var skipped = false
            for ((s, e) in ranges) {
                if (i >= s && i <= e) { skipped = true; break }
            }
            if (!skipped) { result.add(messages[i]) }
            i++
        }
        // 防空上下文：全部被跳过（序号错位）时回退原列表
        if (result.size == 0) { return messages }
        result
    }
}

func extractIndex(args: JsonValue, key: String): Option<Int64> {
    match (args[key]) {
        case Some(JsonValue.Number(n)) => Some(Int64(n))
        case _ => None
    }
}

func extractSummary(args: JsonValue): Option<String> {
    match (args["summary"]) {
        case Some(JsonValue.String(s)) => Some(s)
        case _ => None
    }
}
