package atelier.provider

import std.collection.*
import std.core.Duration
import atelier.message.*
import atelier.event.EventStream

func echoReq(text: String): ChatRequest {
    let msgs = ArrayList<Message>()
    msgs.add(UserMessage(ContentList.ofText(text), 0))
    ChatRequest("echo", msgs, Float64(0.7), Int64(1024), None, ArrayList<OpenAITool>())
}

// chat：回显最后一条用户文本
@Test
func echoProvider_chatEchoesLastUserText() {
    let p = EchoProvider()
    let resp = p.chat(echoReq("你好"))
    @Expect(p.name(), "echo")
    match (resp.message.content.blocks()[0]) {
        case ContentBlock.TextBlock(t) => @Expect(t, "echo: 你好")
        case _ => @Fail("expected text block")
    }
}

// chatStreaming：完整文本单帧 + finishReason，结果含回显
@Test
func echoProvider_chatStreamingReturnsText() {
    let p = EchoProvider()
    let stream = p.chatStreaming(echoReq("hi there"))
    var got = ""
    while (true) {
        match (stream.receive(Duration.millisecond * 500)) {
            case Some(delta) =>
                if (delta.delta != "") { got = got + delta.delta }
                match (delta.finishReason) {
                    case Some(_) => break
                    case None => ()
                }
            case None => break
        }
    }
    @Expect(got, "echo: hi there")
    let msg = stream.result()
    match (msg.content.blocks()[0]) {
        case ContentBlock.TextBlock(t) => @Expect(t, "echo: hi there")
        case _ => @Fail("expected text block")
    }
}
