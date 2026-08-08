package atelier.context

import atelier.message.*
import atelier.provider.*
import atelier.session.*
import atelier.skill.*
import std.collection.*

public class ContextBuilder {
    private let skills: SkillRegistry
    private let env: SessionEnvironment
    private let promptBuilder: SystemPromptBuilder

    public init(skills: SkillRegistry, env: SessionEnvironment) {
        this.skills = skills
        this.env = env
        this.promptBuilder = SystemPromptBuilder()
    }

    // run 一次：系统提示（若有）作为首条 UserMessage，再追加历史
    public func initMessages(systemPrompt: String, skillNames: ArrayList<String>,
        history: ArrayList<Message>): ArrayList<Message> {
        let result = ArrayList<Message>()
        let text = this.promptBuilder.build(systemPrompt, skillNames, this.skills, this.env)
        if (text != "") {
            result.add(UserMessage(ContentList.ofText(text), 0))
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
}
