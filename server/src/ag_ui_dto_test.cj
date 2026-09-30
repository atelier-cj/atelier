package server

import std.collection.*
import atelier.util.fromJsonString

// RunAgentInput 解析：协议字段可省、各家客户端形态有差异，
// 所以重点在「缺字段取默认」「content 两种形态」「未知字段不炸」。

@Test
func dto_runAgentInputFullRoundTrip() {
    // 注意：Cangjie 的多行字符串会处理 \" 转义，嵌 JSON 的字符串参数只能用普通字符串拼，
    // 否则拼出来的是非法 JSON（解析器会报「缺逗号」——那是实情，不是解析器的问题）。
    let json = "{\"threadId\":\"t1\",\"runId\":\"r1\",\"state\":{\"k\":\"v\"}," +
        "\"messages\":[" +
        "{\"id\":\"m1\",\"role\":\"user\",\"content\":\"你好\"}," +
        "{\"id\":\"m2\",\"role\":\"assistant\",\"content\":\"在想\"," +
        "\"toolCalls\":[{\"id\":\"c1\",\"type\":\"function\"," +
        "\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"ls\\\"}\"}}]}," +
        "{\"id\":\"m3\",\"role\":\"tool\",\"toolCallId\":\"c1\",\"content\":\"a.txt\"}]," +
        "\"tools\":[{\"name\":\"client_tool\",\"description\":\"前端工具\",\"parameters\":{\"type\":\"object\"}}]," +
        "\"context\":[{\"description\":\"当前页面\",\"value\":\"/settings\"}]," +
        "\"forwardedProps\":{\"agent\":\"a1\",\"systemPrompt\":\"简洁点\"}}"
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.threadId, "t1")
    @Expect(input.runId, "r1")
    @Expect(input.messages.size, 3)
    @Expect(input.messages[0].role, "user")
    @Expect(input.messages[0].content, "你好")
    @Expect(input.messages[1].toolCalls.size, 1)
    @Expect(input.messages[1].toolCalls[0].function.name, "bash")
    @Expect(input.messages[1].toolCalls[0].function.arguments, "{\"cmd\":\"ls\"}")
    @Expect(input.messages[2].toolCallId, "c1")
    @Expect(input.tools.size, 1)
    @Expect(input.tools[0].name, "client_tool")
    @Expect(input.context.size, 1)
    @Expect(input.context[0].value, "/settings")
    @Expect(input.agentName(), Some("a1"))
    @Expect(input.systemPromptOverride(), Some("简洁点"))
}

@Test
func dto_missingOptionalFieldsDefault() {
    let input = fromJsonString<RunAgentInput>("{\"threadId\":\"t\",\"runId\":\"r\"}")
    @Expect(input.messages.size, 0)
    @Expect(input.tools.size, 0)
    @Expect(input.context.size, 0)
    @Expect(input.state.isNone(), true)
    @Expect(input.forwardedProps.isNone(), true)
    @Expect(input.agentName().isNone(), true)
    @Expect(input.systemPromptOverride().isNone(), true)
}

@Test
func dto_unknownFieldsAreSkipped() {
    let json = "{\"threadId\":\"t\",\"runId\":\"r\",\"unknown\":{\"nested\":[1,2,3]},\"messages\":[]}"
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.threadId, "t")
    @Expect(input.messages.size, 0)
}

@Test
func dto_contentPartsArrayIsJoinedIntoText() {
    // 多模态客户端会把 content 写成分片数组，文本分片要拼起来，其余形态忽略
    let json = """
{"threadId":"t","runId":"r","messages":[
  {"id":"m1","role":"user","content":[{"type":"text","text":"第一段"},
                                      {"type":"image","url":"http://x/y.png"},
                                      {"type":"text","text":"第二段"}]}]}
"""
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.messages[0].content, "第一段第二段")
}

@Test
func dto_nullContentBecomesEmpty() {
    let json = "{\"threadId\":\"t\",\"runId\":\"r\",\"messages\":[{\"id\":\"m\",\"role\":\"assistant\",\"content\":null}]}"
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.messages[0].content, "")
}

@Test
func dto_agentNameIgnoresWrongType() {
    let json = "{\"threadId\":\"t\",\"runId\":\"r\",\"forwardedProps\":{\"agent\":123}}"
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.agentName().isNone(), true)
}

@Test
func dto_toolParametersKeptOpaque() {
    let json = "{\"threadId\":\"t\",\"runId\":\"r\",\"tools\":[{\"name\":\"x\"}]}"
    let input = fromJsonString<RunAgentInput>(json)
    @Expect(input.tools[0].name, "x")
    // 前端没给参数 schema 时保持 None，由服务端决定怎么兜（不伪造 schema）
    @Expect(input.tools[0].parameters.isNone(), true)
    @Expect(input.tools[0].description, "")
}

@Test
func dto_inputMessageToolResult() {
    let dto = fromJsonString<AgUiInputDTO>(
        "{\"runId\":\"r1\",\"kind\":\"tool_result\",\"toolCallId\":\"c1\",\"result\":\"done\",\"isError\":true}")
    @Expect(dto.runId, "r1")
    @Expect(dto.kind, "tool_result")
    @Expect(dto.toolCallId, "c1")
    @Expect(dto.result, "done")
    @Expect(dto.isError, true)
}

@Test
func dto_inputMessageUserAnswerDefaultsNoError() {
    let dto = fromJsonString<AgUiInputDTO>("{\"runId\":\"r1\",\"kind\":\"user_input\",\"text\":\"好\"}")
    @Expect(dto.text, "好")
    @Expect(dto.isError, false)
    @Expect(dto.toolCallId, "")
}
