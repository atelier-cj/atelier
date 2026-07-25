package atelier.message

import std.collection.*
import jsonvalue.*

@Test
func contentBlock_textBlock() {
    let block = ContentBlock.TextBlock("hello")
    match (block) {
        case TextBlock(text) => @Expect(text, "hello")
        case _ => @Fail("expected TextBlock")
    }
}

@Test
func contentBlock_toolCall() {
    let tc = ToolCallBlock("call_1", "get_weather", JsonValue.String("{}"))
    let block = ContentBlock.ToolCall(tc)
    match (block) {
        case ToolCall(t) => @Expect(t.id, "call_1")
        case _ => @Fail("expected ToolCall")
    }
}

@Test
func contentBlock_toolResult() {
    let block = ContentBlock.ToolResultBlock("call_1", "sunny")
    match (block) {
        case ToolResultBlock(id, result) => @Expect(id, "call_1")
        case _ => @Fail("expected ToolResultBlock")
    }
}

@Test
func contentBlock_imageBlock() {
    let block = ContentBlock.ImageBlock("base64data", "image/png")
    match (block) {
        case ImageBlock(data, mime) => @Expect(data, "base64data")
        case _ => @Fail("expected ImageBlock")
    }
}

@Test
func contentList_ofText() {
    let cl = ContentList.ofText("hello")
    let blocks = cl.blocks()
    @Expect(blocks.size, 1)
    match (blocks[0]) {
        case TextBlock(text) => @Expect(text, "hello")
        case _ => @Fail("expected TextBlock")
    }
}

@Test
func contentList_toolCalls_empty() {
    let cl = ContentList.ofText("hello")
    let calls = cl.toolCalls()
    @Expect(calls.size, 0)
}

@Test
func contentList_toolCalls_with_tools() {
    let tc1 = ToolCallBlock("call_1", "get_weather", JsonValue.String("{}"))
    let tc2 = ToolCallBlock("call_2", "get_time", JsonValue.String("{}"))
    let blocks = ArrayList<ContentBlock>()
    blocks.add(ContentBlock.TextBlock("hello"))
    blocks.add(ContentBlock.ToolCall(tc1))
    blocks.add(ContentBlock.ToolCall(tc2))
    blocks.add(ContentBlock.ToolResultBlock("call_1", "sunny"))
    let cl = ContentList(blocks)
    let calls = cl.toolCalls()
    @Expect(calls.size, 2)
    @Expect(calls[0].id, "call_1")
    @Expect(calls[1].id, "call_2")
}
